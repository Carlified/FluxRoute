#!/usr/bin/env python3
"""make_tb.py - build a JoSIM test bench for the exported die netlist.

Reads the app-exported design config (die.tb.json: clock net, I/O nets, clock
frequency, ...), the tool config (config.json: paths + stimulus knobs), and a bit
spec, then writes die_tb.cir that wraps die.cir with:

  * a clock:   pulse(0 A <offset> r f w <T>)  -> DCSFQ-PTLTX -> <clock>_i
  * each data input: a PWL current pulse train (one 600uA pulse per '1')
                     -> DCSFQ-PTLTX -> <net>_i
  * each output: PTLRX-SFQDC -> 2 ohm sink, phase+voltage printed

The clock period comes from the config's clock frequency (period = 1000/freqGHz).
Data is launched dataPhasePs after the clock launch (the routed data paths are
shorter than the clock tree, so the stimulus has to compensate). The run length
covers the counterflow pipeline latency, which is several clock cycles.
Bit strings come from --bits (e.g. --bits a=11010010,b=01110101,cin=00011011) or
from the spec file (tb_spec.json: {"a": "11010010", ...}).

Usage:
  python make_tb.py --bits a=11010010,b=01110101,cin=00011011
  python make_tb.py --spec tb_spec.json
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DCSFQ = "mitll_DCSFQ-PTLTX/THmitll_DCSFQ-PTLTX_v3p0_extracted.cir"
PTLRX = "mitll_PTLRX-SFQDC/THmitll_PTLRX-SFQDC_v3p0_extracted.cir"


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def winpath(p):
    return os.path.abspath(p).replace("/", "\\")


def pwl(bits, period_ps, offset_ps, amp_ua, width_ps):
    """One triangular current pulse (0 -> A -> 0) at k*period + offset for each '1'."""
    pts = ["0 0"]
    for k, b in enumerate(bits):
        if b == "1":
            t = k * period_ps + offset_ps
            pts += [f"{fmt(t)}p 0", f"{fmt(t + width_ps)}p {fmt(amp_ua)}u",
                    f"{fmt(t + 2 * width_ps)}p 0"]
    return "pwl(" + " ".join(pts) + ")"


def fmt(v):
    return ("%g" % v)


def derive_launch(design, cfg, period):
    """Turn the exporter's timing JSON into absolute clock/data launch times.

    inputWindow* in die.tb.json are relative to the clock edge being sent. The
    window can be negative (data before the first clock edge); the testbench
    keeps both sources at or after settlePs by delaying whichever one is later.

    startupPeriods can shift the window to a later clock edge. It defaults to
    zero now that the PTL block delay matches the exporter.

    If the requested period is below minClockPeriodPs, the exporter's target
    window is inverted (no safe launch point at that frequency). In that case
    fall back to the min-period window, which is still a valid launch point for
    the simulated data-leading capture.
    """
    settle = float(cfg.get("settlePs", 50.0))
    use_window = bool(cfg.get("useInputWindow", True)) and bool(design.get("inputWindowFound"))
    if use_window:
        shift = float(cfg.get("startupPeriods", 0.0)) * period
        t_start = float(design.get("inputWindowTargetStartPs", 0.0)) + shift
        t_end = float(design.get("inputWindowTargetEndPs", 0.0)) + shift
        if t_start <= t_end:
            start, end = t_start, t_end
            source = "target window"
        else:
            start = float(design.get("inputWindowStartPs", 0.0)) + shift
            end = float(design.get("inputWindowEndPs", 0.0)) + shift
            source = "min-period window (target inverted)"
            print(f"WARNING: target period {period:g} ps is below the achievable "
                  f"minimum {design.get('minClockPeriodPs', float('nan')):g} ps; "
                  f"using the min-period input window {start:g} .. {end:g} ps")
            if start > end:
                start, end = end, start
        mode = str(cfg.get("inputWindowMode", "center")).lower()
        if mode == "start":
            rel = start
        elif mode == "end":
            rel = end
        elif mode == "positive":
            rel = max(0.0, start)
        else:
            rel = 0.5 * (start + end)
    else:
        rel = float(cfg.get("dataPhasePs", 58.0))
        start = end = rel
        source = "dataPhasePs fallback"

    if rel >= 0:
        clk_off = settle
        data_off = settle + rel
    else:
        data_off = settle
        clk_off = settle - rel
    return clk_off, data_off, rel, start, end, source


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--bits", help="comma-separated net=bits, e.g. a=101,b=110")
    ap.add_argument("--spec", help="JSON spec file {net: bits}")
    ap.add_argument("--out", help="output .cir (default: config.tbOut)")
    ap.add_argument("--time-step", type=float, help="override timeStepPs from config")
    ap.add_argument("--startup-periods", type=float,
                    help="override startupPeriods (skip this many clock edges)")
    ap.add_argument("--data-phase", type=float,
                    help="override data-clock relative launch phase in ps")
    ap.add_argument("--slots", type=int, help="override number of bit slots")
    ap.add_argument("--decode-start-periods", type=float,
                    help="override decodeStartPeriods")
    args = ap.parse_args()

    cfg = load_json(args.config)
    if args.startup_periods is not None:
        cfg = dict(cfg)
        cfg["startupPeriods"] = args.startup_periods
    if args.data_phase is not None:
        cfg = dict(cfg)
        cfg["useInputWindow"] = False
        cfg["dataPhasePs"] = args.data_phase
    if args.decode_start_periods is not None:
        cfg = dict(cfg)
        cfg["decodeStartPeriods"] = args.decode_start_periods
    out_dir = os.path.join(HERE, cfg["outputDir"])
    design = load_json(os.path.join(out_dir, cfg["designConfig"]))
    rsfq = cfg["rsfqLib"]

    # clock period (ps)
    period = cfg.get("clockPeriodPs", 0.0)
    if not period or period <= 0:
        freq = design.get("freqGHz", 0.0)
        if not freq or freq <= 0:
            raise SystemExit("no clock frequency: set freqGHz in the design config or clockPeriodPs in config.json")
        period = 1000.0 / freq
    print(f"clock period: {period:g} ps  ({1000.0/period:g} GHz)")

    # bit spec
    bits = {}
    if args.spec:
        bits = load_json(os.path.join(HERE, args.spec) if not os.path.isabs(args.spec) else args.spec)
    if args.bits:
        for tok in args.bits.split(","):
            if "=" in tok:
                n, b = tok.split("=", 1)
                bits[n.strip()] = b.strip()
    inputs = design.get("inputs", [])
    for n in inputs:
        bits.setdefault(n, "0" * int(cfg.get("slots", 8)))
    slots = max([len(v) for v in bits.values()] + [int(cfg.get("slots", 8))])
    if args.slots:
        slots = args.slots

    clk_off, data_off, data_rel, win_start, win_end, win_src = derive_launch(design, cfg, period)
    w = float(cfg.get("pulseWidthPs", 3.0))
    amp = float(cfg.get("pulseAmplitudeUa", 600.0))
    rf = float(cfg.get("riseFallPs", 2.0))
    dt = float(args.time_step if args.time_step else cfg.get("timeStepPs", 0.05))
    print(f"input window ({win_src}): {win_start:g} .. {win_end:g} ps relative to clock send")
    print(f"launch: clock {clk_off:g} ps, data {data_off:g} ps (data-clock {data_rel:g} ps)")

    L = []
    L.append("* die_tb.cir - generated by make_tb.py")
    L.append(f"* clock period {period:g} ps, {slots} slots")
    L.append(f"* clock launch {clk_off:g} ps, data launch {data_off:g} ps (data-clock {data_rel:g} ps)")
    L.append(f"* input window {win_start:g} .. {win_end:g} ps relative to clock send")
    L.append("")
    L.append(".include " + winpath(os.path.join(out_dir, cfg["cir"])))
    L.append(".include " + winpath(os.path.join(rsfq, DCSFQ)))
    L.append(".include " + winpath(os.path.join(rsfq, PTLRX)))
    L.append("")
    L.append("* ===== clock =====")
    L.append(f"I_clk 0 nclk pulse(0 {fmt(amp)}u {fmt(clk_off)}p {fmt(rf)}p {fmt(rf)}p {fmt(w)}p {fmt(period)}p)")
    L.append(f"XSCLK THmitll_DCSFQ-PTLTX nclk {design['clock']}_i")
    L.append("")
    L.append("* ===== data inputs =====")
    for n in inputs:
        b = bits.get(n, "")
        L.append(f"* {n} = {b}")
        L.append(f"I_{n} 0 n{n} {pwl(b, period, data_off, amp, w)}")
        L.append(f"XS{n} THmitll_DCSFQ-PTLTX n{n} {n}_i")
    L.append("")
    L.append("* ===== readout =====")
    for n in design.get("outputs", []):
        L.append(f"XR{n} THmitll_PTLRX-SFQDC {n}_o r{n}")
        L.append(f"R{n} r{n} 0 2")
    L.append("")
    L.append("* ===== analysis =====")
    # Output timing from the exporter: the first output reaches a pad
    # minOutputTravelPs after a clock edge, plus the pipeline depth in periods.
    max_depth = design.get("pipelineLevels")
    if max_depth is None:
        max_depth = cfg.get("pipelineLevels", cfg.get("pipelineLatencySlots", 4.0))
    max_depth = float(max_depth)
    # minOutputTravelPs already includes the round trip that triggers the final
    # pipeline level, so the number of whole periods to add is max depth - 1.
    levels = max(0.0, max_depth - 1.0)
    travel = float(design.get("minOutputTravelPs", 0.0)) if design.get("outputTravelFound") else 0.0
    watch = clk_off + levels * period + travel
    # The watch formula already includes the final level trigger for the
    # current cell library. decodeStartPeriods is an escape hatch for a die
    # whose first usable output window is one edge earlier/later.
    decode_start = watch + float(cfg.get("decodeStartPeriods", 0.0)) * period
    margin = float(cfg.get("outputMarginPs", period))
    stop = max(decode_start + (slots - 1) * period + margin,
               data_off + (slots - 1) * period + levels * period + travel + margin)
    rows = stop / dt
    safe_rows = int(cfg.get("josimMaxRows", 80000))
    # JoSIM v2.7 memory scales with the number of time points. Measured on this
    # 8 GB machine: 80k rows complete, 100k rows crash with no CSV written.
    # Keep a wide margin; the default 1200 ps / 0.05 ps is only 24k rows.
    if rows > safe_rows:
        raise SystemExit(
            f"requested {rows:.0f} time points exceeds the JoSIM safe limit "
            f"of {safe_rows} (set josimMaxRows/timeStepPs in config.json)")
    print(f"output watch/start: {watch:g} ps (max depth {max_depth:g}, "
          f"{'data leads' if data_rel <= 0 else 'data lags'} -> {levels:g} periods, travel {travel:g} ps)")
    print(f"decode window start: {decode_start:g} ps")
    print(f"run length: {stop:g} ps, step {dt:g} ps -> {rows:.0f} points (safe <= {safe_rows})")
    L.append(f"* output watch {watch:g} ps, decode window {decode_start:g} ps "
             f"(max depth {max_depth:g}, periods {levels:g}, travel {travel:g} ps)")
    L.append(f".tran {fmt(dt)}p {fmt(stop)}p 0")
    probe = ["p(B3.XSCLK)", "v(clk_i)", "i(I_clk)"]
    probe += [f"i(I_{n})" for n in inputs]
    probe += [f"v({n}_i)" for n in inputs]
    probe += [f"p(B1.XR{n})" for n in design.get("outputs", [])]
    probe += [f"v(r{n})" for n in design.get("outputs", [])]
    L.append(".print " + " ".join(probe))
    L.append(".end")

    out = args.out or os.path.join(out_dir, cfg["tbOut"])
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    meta = {
        "periodPs": period,
        "clockSendPs": clk_off,
        "dataLaunchPs": data_off,
        "dataPhasePs": data_rel,
        "inputWindowStartPs": win_start,
        "inputWindowEndPs": win_end,
        "inputWindowSource": win_src,
        "pipelineLevels": max_depth,
        "outputPeriods": levels,
        "minOutputTravelPs": travel,
        "outputWatchStartPs": watch,
        "decodeWindowStartPs": decode_start,
        "slots": slots,
        "stopPs": stop,
        "timeStepPs": dt,
    }
    meta_path = os.path.splitext(out)[0] + ".meta.json"
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"wrote {out}")
    print(f"wrote {meta_path}")


if __name__ == "__main__":
    main()

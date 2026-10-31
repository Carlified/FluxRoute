#!/usr/bin/env python3
"""checkbits.py - recover a bit vector from JoSIM phase traces.

A phase column "P(B..|X..)" advances by 2*pi per SFQ pulse. Splitting the run into
clock windows and counting the 2*pi steps per window recovers the serial bit
stream the circuit emitted on that node.

Usage:
  python checkbits.py --cols "P(B1|XRS),P(B1|XRC)" --period 100 --slots 8
  python checkbits.py --cols "P(B1|XRS)" --expect 10111100
"""
import argparse
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def load_json(path):
    if not os.path.exists(path):
        raise SystemExit(
            f"config not found: {path}\n"
            "Copy tools/config.example.json to tools/config.json and fill in the "
            "paths for your machine (JoSIM, RSFQ library, output folder).")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--csv", help="CSV (default <outputDir>/die_tb.csv)")
    ap.add_argument("--cols", required=True, help="comma-separated phase column substrings")
    ap.add_argument("--period", type=float, help="clock period in ps (default from design freq)")
    ap.add_argument("--slots", type=int, help="number of windows (default config.slots)")
    ap.add_argument("--start", type=float,
                    help="first window start in ps (default: decodeWindowStartPs from <csv>.meta.json, else outputWatchStartPs, else 0)")
    ap.add_argument("--expect", help="expected bits (printed for comparison)")
    args = ap.parse_args()

    import csv as csvmod
    cfg = load_json(args.config)
    out_dir = os.path.join(HERE, cfg["outputDir"])
    csv_path = args.csv or os.path.join(out_dir, "die_tb.csv")

    meta = {}
    meta_path = os.path.splitext(csv_path)[0] + ".meta.json"
    if os.path.exists(meta_path):
        try:
            meta = load_json(meta_path)
        except (OSError, ValueError, TypeError):
            meta = {}

    period = args.period
    if not period:
        period = meta.get("periodPs")
    if not period:
        design = load_json(os.path.join(out_dir, cfg["designConfig"]))
        period = 1000.0 / design["freqGHz"]

    slots = args.slots or int(meta.get("slots", cfg.get("slots", 8)))
    start = args.start
    if start is None:
        start = float(meta.get("decodeWindowStartPs",
                              meta.get("outputWatchStartPs", 0.0)))

    with open(csv_path, newline="") as f:
        rd = csvmod.reader(f)
        header = [c.strip().strip('"') for c in next(rd)]
        data = [[float(x) for x in row] for row in rd]

    def col_index(sub):
        hits = [i for i, c in enumerate(header) if sub.lower() in c.lower()]
        if not hits:
            raise SystemExit(f"no column matches '{sub}'")
        return hits[0]

    print(f"{os.path.basename(csv_path)}: period {period:g} ps, {slots} slots, window start {start:g} ps")
    if args.expect:
        print(f"expected : {args.expect}")

    for sub in args.cols.split(","):
        ci = col_index(sub.strip())
        name = header[ci]
        tcol = 0  # time is column 0
        bits = []
        for k in range(slots):
            lo = start + k * period
            hi = lo + period
            vals = [data[r][ci] for r in range(len(data)) if lo <= data[r][tcol] * 1e12 < hi]
            if not vals:
                bits.append("?")
                continue
            slips = (max(vals) - min(vals)) / (2 * math.pi)
            bits.append("1" if slips >= 0.5 else "0")
        got = "".join(bits)
        tag = ""
        if args.expect:
            exp = args.expect.strip()
            tag = "  OK" if got[:len(exp)] == exp else "  MISMATCH"
        print(f"{name:22s}: {got}{tag}")


if __name__ == "__main__":
    main()

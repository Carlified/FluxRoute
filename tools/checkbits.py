#!/usr/bin/env python3
"""checkbits.py - recover a bit vector from JoSIM phase traces.

A phase column "P(B1|XRS)" advances by 2*pi per SFQ pulse. Splitting the run
into clock windows and counting the 2*pi steps per window recovers the serial
bit stream the circuit emitted on that node.

    python checkbits.py --csv <design>/<stem>_tb.csv --cols sum,cout
    python checkbits.py --dir <design> --cols sum,cout --expect 10111100

--dir looks for <dir>/<stem>_tb.csv (stem = folder name); the meta JSON that
make_tb.py writes next to the CSV supplies the period, slot count and first
decode window, so none of them need repeating.
"""
import argparse
import csv as csvmod
import json
import math
import os


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def resolve_csv(args):
    if args.csv:
        return os.path.abspath(args.csv)
    if not args.dir:
        raise SystemExit("pass --csv <file.csv> or --dir <design output folder>")
    out_dir = os.path.abspath(args.dir)
    stem = args.stem or os.path.basename(os.path.normpath(out_dir))
    return os.path.join(out_dir, stem + "_tb.csv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", help="design output folder (holds <stem>_tb.csv)")
    ap.add_argument("--stem", help="design stem (default: the folder name)")
    ap.add_argument("--csv", help="CSV to decode (default: <dir>/<stem>_tb.csv)")
    ap.add_argument("--cols", required=True, help="comma-separated phase column substrings")
    ap.add_argument("--period", type=float, help="clock period in ps (default: from the meta)")
    ap.add_argument("--slots", type=int, help="number of windows (default: from the meta)")
    ap.add_argument("--start", type=float,
                    help="first window start in ps (default: decodeWindowStartPs from the meta)")
    ap.add_argument("--expect", help="expected bits (printed for comparison)")
    args = ap.parse_args()

    csv_path = resolve_csv(args)
    if not os.path.exists(csv_path):
        raise SystemExit(f"no such CSV: {csv_path}\n"
                         "run make_tb.py --run first, or pass --csv")

    meta = {}
    meta_path = os.path.splitext(csv_path)[0] + ".meta.json"
    if os.path.exists(meta_path):
        try:
            meta = load_json(meta_path)
        except (OSError, ValueError, TypeError):
            meta = {}

    period = args.period or meta.get("periodPs")
    if not period:
        # last resort: the design config next to the CSV
        cand = os.path.join(os.path.dirname(csv_path),
                            str(meta.get("design", "")) + ".tb.json")
        if os.path.exists(cand):
            design = load_json(cand)
            if design.get("freqGHz"):
                period = 1000.0 / design["freqGHz"]
    if not period:
        raise SystemExit("no clock period: pass --period or keep the .meta.json next to the CSV")

    slots = args.slots or int(meta.get("slots", 8))
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

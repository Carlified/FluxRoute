#!/usr/bin/env python3
"""plot_csv.py - inspect and plot JoSIM result CSVs.

JoSIM writes a CSV whose first column is `time` (seconds) and whose remaining
columns are signal names like "I(L1|XDUT)", "P(B3|XDUT)" (phase, radians - one
SFQ = a 2*pi step), "V(NODE)". Loading uses only the stdlib, so `--list` and the
text summary always work; plotting uses plotly (browser, shared cursors) if
installed, else matplotlib, else prints a summary.

Install a plotter once:  pip install plotly        (or: pip install matplotlib)

Usage:
  python plot_csv.py --list
  python plot_csv.py --cols SUMP,COUTR,CLK
  python plot_csv.py --csv die_tb.csv --cols "V(SUMR)" --ps --save out.html
"""
import argparse
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_config(path=None):
    with open(path or os.path.join(HERE, "config.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def load_csv(path):
    with open(path, newline="") as f:
        rd = csv.reader(f)
        header = [c.strip().strip('"') for c in next(rd)]
        rows = [[float(x) for x in r] for r in rd if r]
    return header, rows


def resolve_cols(header, wanted):
    if not wanted:
        return header[1:]
    out = []
    for w in wanted:
        wl = w.lower()
        hits = [c for c in header[1:] if wl in c.lower()]
        if not hits:
            print(f"  (no column matches '{w}')")
        out.extend(hits)
    seen, res = set(), []
    for c in out:
        if c not in seen:
            seen.add(c)
            res.append(c)
    return res


def summary(header, rows, cols):
    tcol = 0
    for c in cols:
        ci = header.index(c)
        v = [r[ci] for r in rows]
        print(f"{c:24s} min={min(v): .4e} max={max(v): .4e} swing={max(v)-min(v): .4e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", help="path to config.json")
    ap.add_argument("--csv", help="CSV to read (default: <outputDir>/die_tb.csv)")
    ap.add_argument("--cols", help="comma-separated column substrings to plot")
    ap.add_argument("--groups", help="semicolon-separated groups; each group is a comma-separated "
                                     "list of column substrings and becomes one stacked subplot row")
    ap.add_argument("--list", action="store_true", help="list columns and exit")
    ap.add_argument("--x", default="time", help="x column (default: time)")
    ap.add_argument("--ps", action="store_true", help="plot x in picoseconds")
    ap.add_argument("--save", help="save to this file (.html for plotly, else image)")
    args = ap.parse_args()

    cfg = load_config(args.config)
    path = args.csv or os.path.join(HERE, cfg["outputDir"], "die_tb.csv")
    header, rows = load_csv(path)

    if args.list:
        print(f"{path}: {len(rows)} rows, {len(header) - 1} signals")
        for c in header:
            print("  " + c)
        return

    wanted = [w.strip() for w in args.cols.split(",")] if args.cols else []
    cols = resolve_cols(header, wanted)
    if not cols:
        sys.exit("nothing to plot")

    xi = header.index(args.x)
    x = [r[xi] * (1e12 if args.ps else 1.0) for r in rows]
    ydata = {c: [r[header.index(c)] for r in rows] for c in cols}
    label_x = "time (ps)" if args.ps else "time (s)"
    title = os.path.basename(path) + " - " + ", ".join(cols[:6]) + ("..." if len(cols) > 6 else "")

    try:
        import plotly.graph_objects as go
        fig = go.Figure()
        for c in cols:
            fig.add_trace(go.Scatter(x=x, y=ydata[c], mode="lines", name=c))
        fig.update_layout(title=title, xaxis_title=label_x, hovermode="x unified")
        if args.save:
            fig.write_html(args.save)
            print(f"saved {args.save}")
        else:
            fig.show()
        return
    except ImportError:
        pass

    try:
        import matplotlib
        if args.save:
            matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots()
        for c in cols:
            ax.plot(x, ydata[c], label=c)
        ax.set_title(title)
        ax.set_xlabel(label_x)
        ax.legend(fontsize="small")
        ax.grid(True, alpha=0.3)
        if args.save:
            fig.savefig(args.save, dpi=130, bbox_inches="tight")
            print(f"saved {args.save}")
        else:
            plt.show()
        return
    except ImportError:
        pass

    print("no plotting library found (pip install plotly  or  pip install matplotlib); summary only:")
    summary(header, rows, cols)


if __name__ == "__main__":
    main()

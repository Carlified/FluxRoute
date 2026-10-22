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
  python plot_csv.py --ps --save die_tb.html \
      --groups "P(B3|XSCLK);I(I_A),I(I_B);P(B1|XRSUM)"
    (each ';'-separated group becomes a stacked subplot row)
  python plot_csv.py --ps --save die_tb_axes.html --separate --groups "..."
    (one subplot / y-axis per signal)
  Add --sliders with a grouped HTML save to get per-trace zero-level controls.
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
    for c in cols:
        ci = header.index(c)
        v = [r[ci] for r in rows]
        print(f"{c:24s} min={min(v): .4e} max={max(v): .4e} swing={max(v)-min(v): .4e}")


OFFSET_JS = r"""
<script>
(function () {
  var GROUPS = __GROUPS__;
  var AXES = __AXES__;
  var tries = 0;

  function init() {
    if (document.getElementById('offset-panel')) return;
    var gd = document.querySelector('.plotly-graph-div');
    if (!gd || !gd.data || !gd.data.length) {
      if (tries++ < 60) setTimeout(init, 100);
      return;
    }

    var traces = gd.data;
    var fullData = gd._fullData || traces;
    var orig = traces.map(function (t) { return Array.prototype.slice.call(t.y); });
    var spans = orig.map(function (y) {
      var mn = Infinity, mx = -Infinity;
      for (var i = 0; i < y.length; i++) {
        if (y[i] < mn) mn = y[i];
        if (y[i] > mx) mx = y[i];
      }
      var s = mx - mn;
      return (isFinite(s) && s > 0) ? s : 1;
    });
    var offsets = new Array(traces.length).fill(0);
    var pending = new Array(traces.length).fill(false);
    var inputs = [];

    var panel = document.createElement('div');
    panel.id = 'offset-panel';
    panel.style.cssText = 'position:fixed;top:8px;right:8px;z-index:9999;background:rgba(255,255,255,0.94);border:1px solid #888;border-radius:6px;padding:8px;font:12px sans-serif;max-height:88vh;overflow:auto;width:320px;box-shadow:0 2px 8px rgba(0,0,0,0.25)';
    var title = document.createElement('div');
    title.innerHTML = '<b>Channel offsets</b><div style="color:#666;margin:2px 0 6px">Drag a slider to shift that trace zero level.</div>';
    panel.appendChild(title);

    var btnRow = document.createElement('div');
    btnRow.style.cssText = 'display:flex;gap:6px;margin-bottom:6px';
    var autoBtn = document.createElement('button');
    autoBtn.textContent = 'Auto-stack';
    var resetBtn = document.createElement('button');
    resetBtn.textContent = 'Reset';
    btnRow.appendChild(autoBtn);
    btnRow.appendChild(resetBtn);
    panel.appendChild(btnRow);

    function relayoutAxis(i) {
      var obj = {};
      obj[AXES[i] + '.autorange'] = true;
      Plotly.relayout(gd, obj);
    }

    function apply(i) {
      if (pending[i]) return;
      pending[i] = true;
      requestAnimationFrame(function () {
        pending[i] = false;
        var y = orig[i].map(function (v) { return v + offsets[i]; });
        Plotly.restyle(gd, { y: [y] }, [i]);
        relayoutAxis(i);
      });
    }

    function setOffset(i, off) {
      offsets[i] = off;
      inputs[i].value = off;
      var val = inputs[i].parentNode.querySelector('span');
      if (val) val.textContent = ' ' + off.toExponential(2);
      apply(i);
    }

    traces.forEach(function (t, i) {
      var row = document.createElement('div');
      row.style.cssText = 'margin:5px 0;padding-top:5px;border-top:1px solid #eee';
      var lab = document.createElement('label');
      lab.style.cssText = 'display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
      var tc = (fullData[i] && fullData[i].line && fullData[i].line.color) || '#333';
      lab.style.color = tc;
      lab.textContent = t.name;
      var val = document.createElement('span');
      val.style.cssText = 'float:right;font-weight:400;color:#555';
      val.textContent = ' 0.00e+0';
      lab.appendChild(val);

      var s = document.createElement('input');
      s.type = 'range';
      var span = spans[i];
      s.min = -4 * span;
      s.max = 4 * span;
      s.step = span / 200;
      s.value = 0;
      s.style.width = '100%';
      inputs.push(s);
      s.addEventListener('input', function () {
        var off = parseFloat(s.value);
        offsets[i] = off;
        val.textContent = ' ' + off.toExponential(2);
        apply(i);
      });

      row.appendChild(lab);
      row.appendChild(s);
      panel.appendChild(row);
    });
    document.body.appendChild(panel);

    autoBtn.addEventListener('click', function () {
      GROUPS.forEach(function (idxs) {
        var span = 1;
        idxs.forEach(function (i) { if (spans[i] > span) span = spans[i]; });
        var spacing = span * 1.15;
        idxs.forEach(function (i, j) { setOffset(i, -j * spacing); });
      });
    });
    resetBtn.addEventListener('click', function () {
      traces.forEach(function (t, i) { setOffset(i, 0); });
    });
    autoBtn.click();
  }

  if (document.readyState === 'complete') init();
  else window.addEventListener('load', init);
  setTimeout(init, 600);
})();
</script>
"""


def inject_offset_sliders(path, groups, axes):
    js = OFFSET_JS.replace("__GROUPS__", json.dumps(groups)).replace("__AXES__", json.dumps(axes))
    with open(path, "r", encoding="utf-8") as f:
        html = f.read()
    if 'id="offset-panel"' in html or "id='offset-panel'" in html:
        return
    if "</body>" in html:
        html = html.replace("</body>", js + "\n</body>", 1)
    else:
        html += js
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", help="path to config.json")
    ap.add_argument("--csv", help="CSV to read (default: <outputDir>/die_tb.csv)")
    ap.add_argument("--cols", help="comma-separated column substrings to plot")
    ap.add_argument("--groups", help="semicolon-separated groups; each group is a comma-separated "
                                     "list of column substrings and becomes one stacked subplot row")
    ap.add_argument("--separate", action="store_true", help="one subplot with its own y-axis per signal")
    ap.add_argument("--sliders", action="store_true", help="add browser sliders for per-trace zero-level offsets")
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

    groups = None
    if args.groups:
        groups = []
        for g in args.groups.split(";"):
            g = g.strip()
            if not g:
                continue
            gcols = resolve_cols(header, [t.strip() for t in g.split(",") if t.strip()])
            if gcols:
                groups.append(gcols)
        cols, seen = [], set()
        for g in groups:
            for c in g:
                if c not in seen:
                    seen.add(c)
                    cols.append(c)
        if not cols:
            sys.exit("nothing to plot")
    else:
        wanted = [w.strip() for w in args.cols.split(",")] if args.cols else []
        cols = resolve_cols(header, wanted)
        if not cols:
            sys.exit("nothing to plot")

    if args.separate:
        if groups:
            groups = [[c] for g in groups for c in g]
        else:
            groups = [[c] for c in cols]

    xi = header.index(args.x)
    x = [r[xi] * (1e12 if args.ps else 1.0) for r in rows]
    ydata = {c: [r[header.index(c)] for r in rows] for c in cols}
    label_x = "time (ps)" if args.ps else "time (s)"
    title = os.path.basename(path) + " - " + ", ".join(cols[:6]) + ("..." if len(cols) > 6 else "")

    try:
        import plotly.graph_objects as go
        group_idx, group_axes = [], []
        if groups:
            from plotly.subplots import make_subplots
            n = len(groups)
            fig = make_subplots(rows=n, cols=1, shared_xaxes=True, vertical_spacing=0.035,
                                subplot_titles=[", ".join(g) for g in groups])
            trace_i = 0
            for ri, g in enumerate(groups, 1):
                row_idx = []
                axis = "yaxis" if ri == 1 else f"yaxis{ri}"
                for c in g:
                    row_idx.append(trace_i)
                    group_axes.append(axis)
                    trace_i += 1
                    fig.add_trace(go.Scatter(x=x, y=ydata[c], mode="lines", name=c), row=ri, col=1)
                group_idx.append(row_idx)
            fig.update_layout(title=title, height=max(420, 150 * n), hovermode="x unified",
                              showlegend=not (args.sliders and groups))
            fig.update_xaxes(title_text=label_x, row=n, col=1)
        else:
            fig = go.Figure()
            for c in cols:
                fig.add_trace(go.Scatter(x=x, y=ydata[c], mode="lines", name=c))
            fig.update_layout(title=title, xaxis_title=label_x, hovermode="x unified")
        if args.save:
            fig.write_html(args.save, include_plotlyjs=True, full_html=True)
            if args.sliders and groups:
                inject_offset_sliders(args.save, group_idx, group_axes)
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
        if groups:
            n = len(groups)
            fig, axes = plt.subplots(n, 1, sharex=True, figsize=(12, 2.0 * n + 1))
            if n == 1:
                axes = [axes]
            for ax, g in zip(axes, groups):
                for c in g:
                    ax.plot(x, ydata[c], label=c)
                ax.legend(fontsize="small")
                ax.grid(True, alpha=0.3)
            axes[-1].set_xlabel(label_x)
        else:
            fig, ax = plt.subplots()
            for c in cols:
                ax.plot(x, ydata[c], label=c)
            ax.set_xlabel(label_x)
            ax.legend(fontsize="small")
            ax.grid(True, alpha=0.3)
        fig.suptitle(title)
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

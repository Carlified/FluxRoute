# FluxRoute

FluxRoute is a place-and-route flow for **RSFQ / PTL superconducting logic**. It
takes a cell library (LEF) and a logic netlist (BLIF) and walks the whole path to
a manufacturable layout: splitter insertion, flip-flop pipelining, clock-tree
synthesis and balancing, floorplanning and placement, bias-network expansion,
multi-layer maze routing with vias, timing/clock/resonance validation, and GDS /
SPICE / testbench export.

The GUI (`PnRGUI`) is a Delphi FireMonkey application; the simulation and GDS
helpers are Python scripts in [`tools/`](tools).

```
LEF + BLIF -> splitters -> pipeline (DFF) -> clock tree -> placement/floorplan
          -> bias expansion -> routing -> validation -> GDS / CIR / testbench
```

**Scope:** combinational, PTL-only designs with a single clock. The tool inserts
the flip-flop pipeline itself; stateful (sequential) macros, multiple clock
domains and cyclic netlists are outside its scope, and one flip-flop type is used
per run.

## Features

- **Parsing** — LEF cell library (layers, MACRO/PIN geometry, power ports and
  bias-current metadata), Verilog cell timing (delay, setup/hold, input spacing)
  and BLIF netlists, with connectivity, pin and clock-level diagnostics shown on
  the netlist page exactly as parsed.
- **Splitter insertion** — fans high-fanout nets out through splitter trees,
  using a DP that minimises added delay for the selected splitter cell(s).
- **Pipelining** — two modes on one slider: **compact** (minimum flip-flops, with
  flip-flops folded back down splitter trees) and **delay-levelised** (threshold
  driven, for maximum clock speed). Outputs are padded to a common depth.
- **Clock network** — trunk + per-level row subtrees, placement of junctions and
  stage buffers, and validation that every clocked cell's clock arrives before
  its data (trunk buffers are inserted until it holds).
- **Placement** — barycentre ordering, wrapped bands, band-aware clock rows, and
  a preserved layout across rebuilds. I/O pads are anchored, reorderable, and
  kept clear of the clock pad.
- **Bias network** — per-band bias rows, trunk packing by current, automatic die
  growth (capped) when the lines do not fit.
- **Routing** — sequential maze routing per layer, then a via pass; per-pin layer
  masks, via shafts and pin pillars are honoured; length-fixing buffers are
  inserted by validation with a one-block clearance rule.
- **Validation** — clock timing, PTL length, resonant straight runs (with an A*
  resonance guard), bias allocation, cell overlap, fanout and stage balance, and
  a final requirements audit that gates export.
- **Export** — `<stem>.gds` (via `gdstk`), `<stem>.cir` netlist with PTL/via
  blocks, `<stem>.tb.json` testbench config, and `<stem>.metrics.json`
  (wirelength, timing, clock limits, area, routing runtime).

## Download

Prebuilt binaries are attached to the [Releases](../../releases) page when
available (`FluxRoute-<version>-win64.zip`, `FluxRoute-<version>-macos-*.zip`).
The macOS bundle is unsigned unless noted in the release: right-click the app and
choose **Open** the first time, or run
`xattr -dr com.apple.quarantine PnRGUI.app`.

## Requirements

| | |
|---|---|
| GUI | RAD Studio / Delphi (FireMonkey). Windows 10/11; macOS via cross-compilation — see [docs/BUILDING.md](docs/BUILDING.md) |
| Python | 3.9+ for the helper scripts, with `gdstk` for the in-app cell viewer and GDS export ([`tools/requirements.txt`](tools/requirements.txt)) |
| Simulator | [JoSIM](https://github.com/JoSIM-Tools/JoSIM) for testbench simulation (optional) |
| Design data | A LEF cell library and the matching cell sources (`.v`, `.gds`, `.cir`) — not included |

## Building

Full instructions, including producing a permanent macOS `.app` and release
packages, are in **[docs/BUILDING.md](docs/BUILDING.md)**. Short version:

1. Open `PnRGUI.dproj` in RAD Studio.
2. Pick the target platform (`Win64`, `OSX64` or `OSXARM64`) and the `Release`
   configuration.
3. **Build** (Shift+F9). The binary lands in `Win64\Release\PnRGUI.exe` or
   `OSXARM64\Release\PnRGUI.app` — no PAServer needed to *build*.

## Quick start

1. **Library page** — load your LEF file, then select the folder holding the
   cell sources. Both are required before the flow continues. With the MIT-LL
   library use [`examples/RSFQlib/library_fixed.lef`](examples/RSFQlib/library_fixed.lef);
   [that folder's guide](examples/RSFQlib/README.md) lists the files to prune
   from a stock RSFQlib checkout.
2. **Components page** — choose the splitter cell(s), the flip-flop and the
   buffer cells.
3. **Netlist page** — load a BLIF (try [`examples/blif/rca4.blif`](examples/blif/rca4.blif)
   or [`examples/blif/ham74_syndrome.blif`](examples/blif/ham74_syndrome.blif)).
   The page shows the parsed model: I/O, every gate with its clock level, every
   net with its driver and loads, and any errors.
4. **Pipeline page** — drag the slider between compact and delay-levelised mode.
5. **Clock page** — inspect/rebuild the clock network.
6. **Placement / Floorplan** — set the design rules, optimise, then **Expand
   Bias Lines**.
7. **Routing** — **Route and Validate** runs routing, bias, clock/length
   validation and the final audit in one action.
8. **Export** — set the output folder/stem, the formats, and the *Block
   library* folder ([`examples/RSFQlib/blocklib`](examples/RSFQlib/blocklib)
   for the sample library; the exporter places a pre-verified GDS block per
   block kind, so it cannot run without one).

## Repository layout

| Path | Contents |
|---|---|
| `PnRGUI.dproj`, `PnRGUI.dpr` | GUI application project |
| `MainWindow.pas`, `*.inc` | Form, pages (clock, pipeline, placement, floorplan, routing, config, export) |
| `BlifLibrary.pas`, `LefLibrary.pas` | LEF/BLIF parsing and model |
| `SplitterInsert.pas`, `FlipFlopInsert.pas`, `Pipeline*.pas` | Splitter trees, pipelining, levelisation |
| `ClockNetwork.pas`, `ClockValidate.pas` | Clock tree synthesis and timing validation |
| `Export*.pas`, `ExportMetrics.inc` | GDS/DEF recipe, CIR netlist, testbench and metrics |
| `U*.pas` | Shared geometry, physics, naming, design-config and UI helpers |
| `BlifParser.*`, `LefParser.*` | Standalone console parsers for the same formats |
| `tools/` | Python helpers (testbench, bit checks, plots, GDS writer/reader) |
| `examples/blif/` | Example netlists |
| `examples/outputs/` | Verified design exports with their JoSIM decks and results |
| `docs/` | Build and release documentation |
| `examples/RSFQlib/` | Sample LEF, export block library and the RSFQlib pruning guide |

## Helper tools

The Python tools work on one design folder at a time (the folder the Export
page writes `<stem>.cir`, `<stem>.tb.json`, `.gds`, ... into). Copy
[`tools/config.example.json`](tools/config.example.json) to `tools/config.json`
and fill in your machine's paths (the JoSIM binary and the RSFQ cell library);
the real `config.json` is gitignored.

| Script | Purpose |
|---|---|
| `tools/make_tb.py` | Build the JoSIM deck from `<stem>.cir` + `<stem>.tb.json`; `--run` simulates it with `josimCli`, `--decode` prints the recovered bits, `--io-nodes` probes the I/O ports for a trace |
| `tools/checkbits.py` | Decode output phase traces into a bit vector (period/slots/window come from the meta JSON) |
| `tools/josim-plot.py` | Official JoSIM trace viewer/plotter (stacked/grid/combined layouts, HTML export) |
| `tools/gds_to_json.py` | Convert a GDS to JSON for the in-app cell viewer |
| `tools/write_die_gds.py` | Write the die GDS from the app's placement recipe |

`make_tb.py` and `checkbits.py` take `--dir <design folder>`; `--stem` defaults
to the folder name, which is how the app lays its outputs out. `josim-plot.py`
takes the trace CSV path directly. For example:

```powershell
python tools/make_tb.py --dir Win64/Release/output/full_adder `
  --bits a=10110011,b=01011101,cin=00110010 --run --decode
python tools/checkbits.py --dir Win64/Release/output/full_adder --cols sum,cout
# a port-probe trace (clock, data inputs, outputs) for viewing
python tools/make_tb.py --dir Win64/Release/output/full_adder `
  --bits a=10110011,b=01011101,cin=00110010 --io-nodes --run --out Win64/Release/output/full_adder/full_adder_io_tb.cir
python tools/josim-plot.py Win64/Release/output/full_adder/full_adder_io_tb.csv -t stacked -x Win64/Release/output/full_adder/full_adder_io.html
```

Verified examples with their decks and recorded results live in
[`examples/outputs/`](examples/outputs/README.md): each folder runs as-is with
`josim-cli` and reproduces the result listed there.

The phase probes address a junction inside the testbench's own transmitter and
readout cells; `probeClockJunction` / `probeOutputJunction` in `config.json` name
those junctions for the cell library you use.

## Timing and testbench guide

This section is the minimum needed to use the timing fields correctly. The
exporter's `minClockPeriodPs` is **not** just a cell delay; it is the maximum of
three independent constraints.

### 1. Clock and input window

- The clock period is `1000 / freqGHz` ps.
- `inputWindowTargetStartPs` / `inputWindowTargetEndPs` are relative to the
  **clock send** at the circuit's clock input.
- The testbench launches data at `clockSend + dataPhase`. The exported target
  window is a range of valid `dataPhase` values, not a fixed delay.
- Every input bit of a word must be captured on the **same clock edge**. Do not
  accept a result where some bits use one edge and others use the next edge,
  even if the output happens to look correct.

Real input windows are usually split into:

```text
leading pass -> dead band -> lagging pass -> dead band -> next pass
```

The dead bands are real; the stated window may start inside one. Search the
whole window, and only report a phase after all inputs have been checked.

### 2. The three clock-period limits

`<stem>.metrics.json` reports all three:

```text
minPeriodTimingPs       data path + setup
minPeriodSpacingPs      input-to-input spacing
minPeriodWindowExtraPs  input-window penalty added to the timing term
minClockPeriodPs        final exported period
clockLimiter            which term is limiting
```

The final period is not necessarily the cell timing limit. In the tested
circuits the input-window term was often the limiter, and the measured
all-input maximum was much higher than the exported value. Conversely, a
single test vector can make a frequency look faster than it really is.

### 3. Output watch vs decode window

The testbench computes:

```text
outputWatch = clockSend + (pipelineLevels - 1) * period + outputTravel
```

This is an **earliest** output estimate, not the first data-valid slot: a
clocked cell only latches on an edge after the clock send, so the first usable
output window is one period later:

```text
decode start = outputWatch + 1 period
```

For the full-adder example at 10 GHz:

```text
clockSend = 50 ps
dataPhase = 81.15 ps  ->  dataLaunch = 131.15 ps
outputWatch = 277.2 ps
decode start = 377.2 ps  (one period later)
```

`make_tb.py` applies this offset automatically: the first word is captured on the
edge after the clock send, and the launch phase is already inside the exported
window, so the offset is one period for every design tested -- not a function of
the lag. `--decode-start-periods` overrides it. Starting the decoder at the
watch time shifts every bit one slot late.

### 4. Testbench recipe

1. Use the exported target window, normally its **centre**.
2. Put **all input combinations** in the run, not just one vector:
   full adder 8, KSA2 32, Dadda 2x2 16, Hamming 128, etc.
3. At the target frequency, sweep the data phase and record the leading,
   dead, and lagging bands. Refine edges at 1–2 ps.
4. For the fastest frequency, start from the known passing point and make the
   period shorter until failure. Search phases around the expected window; do
   not assume monotonicity.
5. Use a **fine time step** near the limit. A coarse step can incorrectly pass
   a marginal circuit. KSA2 passed at 0.2 ps but failed at 0.1 ps at the same
   period/phase.
6. Decode each output on a **shared slot grid** with fixed calibrated offsets.
   Do not independently re-anchor each output; that can hide a one-cycle drift
   in `cout` or another output.
7. Prefer output-node pulses for bit validation; phase traces can be useful but
   can also accumulate or hide a shifted pulse. When using phases, verify the
   same result from node pulses.

### 5. Common failure signatures

| Symptom | Likely cause |
|---|---|
| JoSIM says `Invalid PWL definition` | malformed input PWL; every pulse needs `0 -> 0 -> amplitude -> 0` |
| One-slot case passes, multi-slot fails | stream/pipeline issue; verify all inputs and the data interval |
| All outputs shift by one slot | the decode window is one period out; `make_tb` uses watch + 1 period, `--decode-start-periods` overrides it |
| `cout` drifts relative to `sum` | independent output anchoring is hiding a cycle slip; use a common grid |
| A frequency passes one vector but fails another | maximum was tested with a single pattern; use all input combinations |
| Coarse run passes, fine run fails | time-step convergence; use 0.1 ps or finer at the boundary |

### 6. Worked full-adder result

```text
target:        10 GHz, window 39.3–123 ps, centre 81.15 ps
watch:         277.2 ps
decode start:  377.2 ps
inputs:        all 8 combinations
sum:           01101001  OK
cout:          00010111  OK

true all-input maximum: 25.75 ps / 38.83 GHz
25.70 ps fails; 25.75 ps passes at phases 15–17 ps
```

### 7. Trace viewing

Use the official JoSIM plotter, not a hand-rolled CSV plot:

```powershell
python tools/josim-plot.py <trace.csv> -t stacked -x <trace.html>
```

`stacked` gives one row per trace; `-s` selects a subset of columns. For a
phase-only viewer, `make_tb.py` can produce phase probes; for logic validation,
use `--output-nodes` and inspect the output pad voltages.

## Timing concepts a designer needs

These are the physical/design rules that matter, independent of the test script.

- **Clocked cells are stateful.** The pipeline needs at least one valid clock edge before data is meaningful; power-up/reset state is unknown. Leave a startup cycle and do not treat the first output window as data.
- **A word is captured on one clock edge.** All input bits must meet the same capturing edge. Capturing some bits on the first edge and others on the next is invalid, even if a particular output pattern happens to look correct.
- **The capture edge is not at the clock source.** The clock tree delays the edge at the first clocked cells; the data path has its own delay. Compare data arrival with clock arrival at the **same cell pin**, not with the ideal clock send. Clock/data path skew is part of the window.
- **The real window has leading and lagging capture modes.** A dead band separates them where data arrives too close to the cell clock edge. A target window start can fall inside that dead band; the real lagging window starts after it.
- **The slowest input sets the upper edge.** Different bit paths have different delays and skew. The last arriving bit must still meet setup, so it controls the late edge; the earliest arrival/clock interaction controls the early edge.
- **Clock period has three physical limits:** slowest data path + setup, input-to-input spacing, and the input-window/launch constraint. The usable period is the maximum of the three, not just the DFF delay; `clockLimiter` names the active one.
- **Latency is not throughput.** Clock frequency sets how often a new word can be accepted; pipeline depth sets how many cycles later its result appears. A shorter period does not mean the output appears earlier relative to its input.
- **The output watch is an earliest bound.** Data launch delay and pipeline depth shift the valid output window by whole periods. Reading at the watch time can be one or more cycles early.
- **Outputs can have different latencies.** `sum` and `cout`, or different product bits, may emerge at different offsets. Require a common slot grid and fixed per-output offsets; do not independently re-anchor outputs.
- **Source and interconnect delays are real timing.** DCSFQ data-vs-clock delay, PTL delay, clock-tree row delay and skew all shift the effective window. They are not testbench artifacts to ignore.
- **Timing must hold for every input pattern.** The worst-case data path and the slowest bit are what matter. A fast pass on one vector does not establish a general maximum frequency.
- **At the minimum period the target window may invert or fragment.** There may be no single valid launch point; the real behavior can be several pass bands separated by dead bands.

These are observations from the current cell library and tested designs; use them as design rules, not universal process constants.

## Practical testbench gotchas

- **Probe count does not drive JoSIM memory**; simulation nodes × time points do. `-m` only suppresses printed output. For large circuits, run one-shot first, hold unused high-order inputs constant, or reduce the time-step/run length. A smaller CSV does not mean a smaller solve.
- **All input patterns matter.** A maximum frequency found with one vector is not a general maximum. Test all input combinations and report a failure if any pattern fails.
- **Throw away single-vector frequency claims.** Pattern-specific passes produced several false maxima during testing (notably the full adder and KSA2).
- **Check time-step convergence.** KSA2 passed at 0.2 ps and failed at 0.1 ps at the same period/phase. Re-run at least the boundary point with a halved step before signing off.
- **Do not trust exit code alone.** JoSIM can exit 0 while printing warnings such as malformed PWL definitions. Inspect the log; a malformed source can corrupt only the first pulse and still leave a plausible-looking waveform.
- **A valid PWL pulse needs `0 0`, then `t 0`, `t+w amplitude`, `t+2w 0`.** The first zero and the low point before/after the pulse matter.
- **All-ones input streams hide transition-sensitive behavior.** A one-slot all-ones case can pass while multi-slot streams lose pulses. Test both isolated cases and back-to-back streams.
- **Node pulses are the primary logic check; phase traces are secondary.** Phase outputs can accumulate or shift a whole cycle. Confirm every phase pass against output-node pulses.
- **Never anchor each output independently.** Use a common slot grid with fixed, calibrated output offsets. Independent anchoring hid a one-cycle `cout` drift in the full adder.
- **Watch startup and ringing.** Probe thresholds must exclude secondary ringing peaks and startup pulses; use the first primary peak and the documented decode window.
- **JoSIM is case-insensitive for names.** Case-only net or instance differences merge silently. Check for collisions before trusting a netlist.
- **Splitter-before-output changes the probe name.** The `tb.json` output name may already include a splitter suffix; inspect the netlist and confirm the actual `<name>_o` net.
- **Use variant copies for library experiments.** Do not edit shared `blocklib` subcircuits to test a hypothesis; copy the subcircuits, modify the copy, and point a variant netlist at it.
- **Release and Debug outputs are different trees.** A stale Debug path or an old `--dir` can generate a testbench against the wrong export. Use explicit `--dir`/`--stem`.
- **Frequency is not always monotonic.** Full-adder passes at 28/30 ps failed while 25/32 ps points passed. Search period and phase together; do not interpolate a maximum.
- **`outputWatch` is an earliest bound, not data-valid time.** When data lags, apply the decode offset; the target window may also extend beyond one period or invert at the minimum period.
- **Use `josim-plot.py` for trace viewing.** `--output-nodes` is for logic validation; stacked/grid/combined layouts are handled by the official plotter.

### Timing sign-off checklist

Before claiming a timing result:

1. All input combinations tested.
2. Target-window phase measured and dead bands identified.
3. Fastest period tested from the known maximum until failure.
4. Boundary checked with a halved time step.
5. Outputs decoded on a common slot grid.
6. Phase results confirmed with output-node pulses.
7. Raw CSV, time step, period, phase, slots, and decode offset retained.
8. Old single-vector or coarse-step results removed from the report.

## Known limitations

- `.def` export is not implemented.
- The macOS bundle is produced by cross-compilation and is unsigned; macOS will
  quarantine it on download (see [docs/BUILDING.md](docs/BUILDING.md) for the
  codesign/notarise path).
- The cell viewer and GDS export need Python with `gdstk`; the rest of the
  GUI runs without Python.
- The router has no rip-up step and there is no LVS; layouts are checked with
  external DRC/LVS tools.
- Timing uses a fixed per-cell delay: one worst-case number per cell, with no
  dependence on load or interconnect.

## Licence

FluxRoute is free software: you can redistribute it and/or modify it under the
terms of the **GNU General Public License, version 3** ([LICENSE](LICENSE)).
There is no warranty, to the extent permitted by law.

The Corresponding Source is this repository. If you distribute a binary, convey
the source for that same version: the "Source code" archives GitHub generates
for a tagged release are exactly that, so do not remove them from a release.

`examples/RSFQlib/library_fixed.lef` comes from
[`sunmagnetics/RSFQlib`](https://github.com/sunmagnetics/RSFQlib) (GPL-3.0).

JoSIM, gdstk, RAD Studio and the other RSFQ cell libraries are external projects
under their own licences.

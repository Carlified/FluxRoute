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

## Features

- **Parsing** — LEF cell library (layers, MACRO/PIN geometry, power ports) and
  BLIF netlists, with connectivity, pin and clock-level diagnostics shown on the
  netlist page exactly as parsed.
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
| Python | 3.9+ for the helper tools (`gdstk` for GDS, `matplotlib`/`numpy` for plotting) |
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
   cell sources. Both are required before the flow continues.
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
8. **Export** — pick the output folder/stem and the formats.

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
| `docs/` | Build and release documentation |
| `TECH_DEBT.md` | Developer notes and refactoring register |

## Helper tools

The Python tools read the files exported by the app. Copy
[`tools/config.example.json`](tools/config.example.json) to `tools/config.json`
and fill in your machine's paths (JoSIM binary, RSFQ library, output folder) —
the real `config.json` is gitignored.

| Script | Purpose |
|---|---|
| `tools/make_tb.py` | Build a JoSIM testbench from `<stem>.cir` + `<stem>.tb.json` |
| `tools/checkbits.py` | Decode simulated output phases into bits |
| `tools/plot_csv.py` | Plot a JoSIM CSV |
| `tools/gds_to_json.py` | Convert a GDS to JSON for the in-app cell viewer |
| `tools/write_die_gds.py` | Write the die GDS from the app's placement recipe |
| `tools/splitter_dp_tests.py` | Compare the splitter DP against brute force |

## Known limitations

- `.def` export is not implemented.
- The macOS bundle is produced by cross-compilation and is unsigned; macOS will
  quarantine it on download (see [docs/BUILDING.md](docs/BUILDING.md) for the
  codesign/notarise path).
- GDS and testbench export need Python with `gdstk` installed; the GUI itself
  does not.

## Licence

[MIT](LICENSE). JoSIM, gdstk, RAD Studio and the RSFQ cell libraries are
external projects with their own licences.

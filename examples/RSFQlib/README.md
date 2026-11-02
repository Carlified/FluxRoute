# RSFQ cell library — sample LEF and pruning guide

FluxRoute does not ship the MIT-LL / ColdFlux RSFQ cell library. Get it from
[`sunmagnetics/RSFQlib`](https://github.com/sunmagnetics/RSFQlib) (v3.0) and point
the app's **Library** page at it. This folder holds what makes a stock checkout usable by the tool: the LEF to
load, a block library to export with, and the list of files to remove.

## The LEF: use `library_fixed.lef`

`library_fixed.lef` describes the same 16 cells as the stock
`lef_files/lef_6_metals.lef` — the `PAD`, the four `ALWAYS0` variants and the
eleven PTL-enabled `*T` cells — and differs in the three things the flow needs:

- **Two routing layers, one via.** Only `M1` (horizontal) and `M3` (vertical) are
  `TYPE ROUTING`; `M0`, `M2`, `M4` and `M7` are ground planes and `M5`/`M6` are
  cell metal. The only via is `M1` to `M3`, the stacked `via1`+`via2` pair that
  passes through an isolated island in the `M2` plane. The stock files declare
  every metal from `M1` to `M6` as routing with five via types, so the router
  would happily use layers the cell blocks never wire on.
- **`VDD` power pins** (`USE POWER`, on `M5` at the top and bottom edges) on the
  eleven biased cells; the `PAD` and the four `ALWAYS0` cells draw no bias. The
  stock LEF defines no power pins at all, so bias expansion has nothing to
  connect.
- **Bias metadata in a non-standard comment.** Each `VDD` port carries
  `# top edge, 50uA` or `# bottom edge, 50uA` inside the pin block. While a pin
  is open the parser reads such a comment as that port's edge and its current
  limit (`uA`, `mA` or `A`), which is what the bias rows are sized from. LEF has
  no field for a port current, hence the extension.

Load it on the Library page. The stock `lef_*_metals.lef` files in the RSFQlib
repository are not used by this flow.

## Block library (export data)

The exporter does not draw geometry itself: for every block kind the routed
layout contains (PTL runs, bends, vias, bias tracks, ground fill) it places a
pre-verified GDS block and, where one exists, a CIR subcircuit, all looked up
through `manifest.json`. Cell instances come from the RSFQlib checkout, so an
export needs both folders.

| Folder | What it is |
|---|---|
| `blocklib/` | The default library behind the report's results: square PTL and bias bends, and a ground-plane fill for every unused grid block (so the routed metal is hidden under the planes). |
| `blocklib_mitred/` | The alternative of report Appendix D: mitred (45°) PTL bends and no fill block, which leaves the routing visible. |

On the **Export** page, set *Block library* to one of these folders (or to your
own with the same layout) and the cell-source folder to the pruned RSFQlib
checkout. The blocks are 10 um tiles on a 10 um grid (`gridPitchUm` in the
manifest), and the CIR subcircuits are what appear in the exported netlist;
bias and track kinds are marked `noCir`/`structuralOnly` and are omitted from
the CIR, as the report describes.

## Prune a stock RSFQlib

The tool resolves a cell's model files by extension and takes the **first**
match: `.v` for timing, `.cir` for the SPICE export. RSFQlib ships several files
of the same type per cell, which makes that choice depend on directory order, so
keep exactly one of each:

| keep | remove | why |
|---|---|---|
| `<cell>_v3p0.v` | `<cell>_v3p0_selfcontained.v` | a second `.v` for the same cell |
| `<cell>_v3p0_extracted.cir` | `<cell>_v3p0_base.cir`, `<cell>_v3p0_idx.cir` | three `.cir` files for the same cell; the extracted netlist is the one the export uses |
| | `<cell>_v3p0_testbench.cir` | per-cell testbench `.cir`; not needed by the flow |

In a stock v3.0 checkout that is **120 files**: 35 `_base.cir`, 35 `_idx.cir`,
27 `_testbench.cir` and 23 `_selfcontained.v`.

### PowerShell

```powershell
$lib = "C:\path\to\RSFQlib"     # the folder containing mitll_AND2T, mitll_DFFT, ...

# drop the duplicate models and the per-cell testbenches;
# remove -WhatIf once the list looks right
Get-ChildItem $lib -Recurse -File |
  Where-Object { $_.Name -match '_(base|idx|testbench)\.cir$|_selfcontained\.v$' } |
  Remove-Item -WhatIf
```

### bash

```sh
cd /path/to/RSFQlib
find . -type f \( -name '*_base.cir' -o -name '*_idx.cir' \
  -o -name '*_testbench.cir' -o -name '*_selfcontained.v' \) -delete
```

Also delete the leftover `__pycache__` folders and the scratch
`mitll_JTLT/test.csv`.

After pruning, each cell folder still holds its `.v`, `.GDS`, `.cir`,
`_PCell.py`, `_lvs.json`, `_mesh.msh`, `_schematic.sch` and, where the library
ships one, the timing-extraction PDF — only the duplicate models are gone.

## Licence

The cell library is not part of FluxRoute: [`sunmagnetics/RSFQlib`](https://github.com/sunmagnetics/RSFQlib)
is distributed under **GPL-3.0**. `library_fixed.lef` is a modified version of
`lef_6_metals.lef` from that project and is included here under those terms, with
the cell names and geometry from that project.

# RSFQ cell library — sample LEF and pruning guide

FluxRoute does not ship the MIT-LL / ColdFlux RSFQ cell library. Get it from
[`sunmagnetics/RSFQlib`](https://github.com/sunmagnetics/RSFQlib) (v3.0) and point
the app's **Library** page at it. This folder holds the two things that make a
stock checkout usable by the tool: the LEF to load, and the list of files to
remove.

## The LEF: use `library_fixed.lef`

`library_fixed.lef` describes the same 16 cells as the stock
`lef_files/lef_6_metals.lef` — the `PAD`, the four `ALWAYS0` variants and the
eleven PTL-enabled `*T` cells — with the fixes the flow needs:

- **`VDD` power pins** (`USE POWER`) on the eleven biased cells, so the bias
  network has something to connect to. The stock LEF defines no power pins at
  all, so bias expansion cannot work with it.
- the `M0`..`M7` metal and via-cut stack in the form the LEF reader expects.

Load it on the Library page. The stock `lef_*_metals.lef` files in the RSFQlib
repository are not used by this flow.

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

FluxRoute itself is licensed under GPL-3.0 as well, so the two are compatible;
there is no mixed-licence folder to worry about.

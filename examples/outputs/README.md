# Example outputs

Designs exported by FluxRoute, with the JoSIM decks and the recorded result
for every input combination. Each folder is self-contained: `lib/` holds the
PTL blocks and SFQ cell subcircuits that the decks include, and every
`.include` is relative, so there are no machine-specific paths.

| folder | function | clock | levels | patterns | step | decode start | result |
|---|---|---|---|---|---|---|---|
| `mult_2x2/` | 2x2 array multiplier, `p = a * b` (4 bit) | 10 GHz | 3 | 16 | 0.05 ps | 389.9 ps | pass |
| `rca2/` | 2-bit ripple-carry adder, `s = a + b + cin` | 8 GHz | 5 | 32 | 0.2 ps | 710 ps | pass |
| `ksa2/` | 2-bit Kogge-Stone adder, `s = a + b + cin` | 10 GHz | 5 | 32 | 0.1 ps | 588.5 ps | pass |
| `hamming74/` | Hamming(7,4) syndrome + `err`, 7 in / 4 out | 8 GHz | 4 | 128 | 0.2 ps | 591 ps | pass |

"Pass" means every pattern was decoded twice on the same shared grid: once
from the output phase traces and once from the pads (one pulse per bit), and
the input pads also read back the stimulus. The stimulus, the expected output
strings and the full command trail for each design are in `<stem>_result.txt`.

`hamming74/` ships its 128 patterns as four 32-pattern decks (`_tb_a` ..
`_tb_d`), because a single run either exceeds `make_tb`'s 80000-point guard or
crashes JoSIM: each chunk keeps the same decode grid, so the chunks are just
slices of one run.

## Files per design

| file | contents |
|---|---|
| `<stem>.cir` | exported SPICE netlist: gates, clock tree, PTLs, bias |
| `<stem>.gds` | flattened die layout, one top cell `DIE` |
| `<stem>.metrics.json` | gate/net/junction counts, area, wirelength, timing |
| `<stem>.tb.json` | pad names, clock, pipeline levels, input window, travel |
| `<stem>_tb.cir` | phase-probe deck (DCSFQ -> PTL -> cell -> SFQDC) |
| `<stem>_io_tb.cir` | I/O-pad deck, the one used for the waveform |
| `<stem>_tb.meta.json`, `<stem>_io_tb.meta.json` | decode grid: period, watch, start, slots, step |
| `<stem>_result.txt` | vectors, expected outputs, commands, timings |
| `lib/` | PTL blocks and the SFQ cells the two decks include |

`<stem>.recipe.json` is not included: it records the absolute library paths of
the exporting machine, so it is only meaningful next to that export.

## Reproduce

From a design folder, with `josimCli` from `tools/config.json` on the path:

```text
josim-cli -o rca2_io_tb.csv rca2_io_tb.cir
python ../../../tools/josim-plot.py rca2_io_tb.csv -t stacked -x trace.html
```

The CSV and the HTML are not committed (3-10 MB each); the decks regenerate
them in under a minute. To rebuild the decks from `<stem>.cir` and
`<stem>.tb.json` instead, follow `<stem>_result.txt`.

The cell subcircuits in `lib/` come from the RSFQlib project (per-file
permission notice included in each file); the PTL blocks are the export block
library written by the app.
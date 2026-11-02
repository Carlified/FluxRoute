# Testing a routed design

This walks through one complete pass on the full adder, from the exported files
to a verified waveform. The same steps apply to every design; the working copy
of the result is committed in [`examples/outputs/full_adder/`](../examples/outputs/full_adder).

## What you need

- an exported design folder: `<stem>.cir`, `<stem>.gds`, `<stem>.metrics.json`,
  `<stem>.tb.json` (the Export page writes all of them)
- JoSIM with `josim-cli` on the path, or the full path in `tools/config.json`
- the Python helpers: `pip install -r tools/requirements.txt`, and
  `tools/config.json` (copy `tools/config.example.json`) with your `josimCli`
  path

All commands below run from the repository root in PowerShell, with

```powershell
$design = "Win64/Release/output/full_adder"
```

## 1. Read the timing metadata

```powershell
Get-Content $design/full_adder.tb.json
```

```json
{
  "stem": "full_adder", "clock": "clk",
  "inputs": ["a", "b", "cin"], "outputs": ["sum", "cout"],
  "freqGHz": 10, "pipelineLevels": 3,
  "ptlDelayFsPerUm": 10, "coreUm": 10,
  "dieWUm": 600, "dieHUm": 1000, "maxPtlLengthUm": 800,
  "minClockPeriodPs": 34.2,
  "inputWindowFound": true,
  "inputWindowStartPs": 39.3, "inputWindowEndPs": 57.2,
  "inputWindowTargetStartPs": 39.3, "inputWindowTargetEndPs": 123,
  "outputTravelFound": true, "minOutputTravelPs": 27.2
}
```

Two windows matter. `inputWindowTarget*` is the band the launcher is free to
use; `inputWindow*` is the narrower band the tool actually verified (it is the
intersection with the clock period and the pad-to-first-cell delay).
`make_tb.py` launches at the centre of the target window unless you pick
another point with `dataPhasePs` in the config.

## 2. Build the vectors

Test every input combination, not one vector. The convention is: pattern `k`
puts the inputs from `tb.json` (in order) on bits `n-1 .. 0` of `k`, and the
first input name is the highest bit.

For the three-input adder that gives 8 patterns:

```text
     A     = 00001111
     B     = 00110011
     CIN   = 01010101
```

The expected outputs follow from the function, not from the design:

```text
     SUM   = 01101001      sum = a ^ b ^ cin
     COUT  = 00010111      cout = (a & b) | (cin & (a ^ b))
```

Strings are slot order: `A[0], A[1], ...` are consecutive clock cycles.

## 3. Build, run and decode the phase deck

```powershell
python tools/make_tb.py --dir $design `
  --bits "a=00001111,b=00110011,cin=01010101" --slots 8 `
  --run --decode --expect "sum=01101001,cout=00010111"
```

`make_tb.py` writes `full_adder_tb.cir`, runs `josim-cli` on it, and passes the
CSV to `checkbits.py`. The interesting part of the output:

```text
clock period: 100 ps  (10 GHz)
input window (target window): 39.3 .. 123 ps relative to clock send
launch: clock 50 ps, data 131.15 ps (data-clock 81.15 ps)
output watch: 277.2 ps (max depth 3, periods 2, travel 27.2 ps)
decode shift: 1 period(s) (auto: first capture edge after the data)
decode window start: 377.2 ps
run length: 1177.2 ps, step 0.05 ps -> 23544 points (safe <= 80000)
...
P(B1|XRSUM)           : 01101001  OK
P(B1|XRCOUT)          : 00010111  OK
```

JoSIM prints a progress bar for each step; ignore it. `OK` means the decoded
stream matches the expectation string; `MISMATCH` prints both strings and the
first differing slot.

## 4. Understand the decode grid

`outputWatch` is an earliest bound: clock send + one period per pipeline
level after the first, plus the output travel.

```text
outputWatch = 50 + (3 - 1) * 100 + 27.2 = 277.2 ps
```

The first word is captured on the clock edge after it is launched, so the
first usable output window is one period later. That is the decode start:
`377.2 ps`. Every slot after that is one period wide, and the same grid is used
for every output - do not anchor each output separately, or a cycle slip can
hide.

`--decode-start-periods` overrides the offset if a die behaves differently.
Setting the decoder at the watch time shifts the whole stream one slot late.

## 5. Probe the pads and look at the waveform

The phase probes measure a junction inside the testbench's own transmitter and
receiver, so they prove what the flops saw. The pad nodes are closer to the
design, so check them too:

```powershell
python tools/make_tb.py --dir $design `
  --bits "a=00001111,b=00110011,cin=01010101" --slots 8 --io-nodes `
  --out $design/full_adder_io_tb.cir --run
```

Now there is one trace per pad. Each input slot should produce one SFQ pulse
on `V(a_i)`, `V(b_i)`, `V(cin_i)` at the launch phase, and each output slot one
pulse on `V(sum_o)`, `V(cout_o)` inside its decode window.

```powershell
python tools/josim-plot.py $design/full_adder_io_tb.csv -t stacked `
  -x $design/full_adder_io_trace.html
# or a static image:
python tools/josim-plot.py $design/full_adder_io_tb.csv -t stacked `
  -o $design/full_adder_io_trace.png -d 1600x1000
```

What the picture should show, left to right: the clock, `a` low for the first
four slots and high for the last four, `b` alternating in pairs, `cin`
alternating every slot, and outputs only from the decode start on. A pulse that
is present in the phase trace but missing on a pad (or the reverse) is a real
discrepancy and must be resolved before the design is called good.

## 6. Check the pads independently

Decoding the pads with a peak-per-window test is deliberately simpler than the
phase decoder, so the two do not share code or assumptions. Read the pulses
back, then compare the bits with the truth table:

```text
V(sum_o)   : 01101001  OK
V(cout_o)  : 00010111  OK
V(a_i)     : 00001111  OK
V(b_i)     : 00110011  OK
V(cin_i)   : 01010101  OK
```

Reading the inputs back matters as much as the outputs: it proves the vectors
actually reached the die and the slot order is what you think it is.

## 7. Record the result

Write a short `<stem>_result.txt` next to the exports with the vectors, the
expected outputs, the decode grid, the commands, the time step and the verdict
- what you see in `examples/outputs/*/`. Keeping it next to the run means a
later change can be re-checked against a known-good baseline.

## When it fails

| What you see | What it usually means |
|---|---|
| every output shifted by one slot | decode window is one period out; `make_tb` uses watch + 1 period, check the override |
| phase traces OK, pads wrong | probe placement or a broken PTL between the cell and the pad |
| one output wrong at some slots | pattern-dependent path or a stuck net; compare the failing slot with its neighbours |
| `Invalid PWL definition` | malformed input pulse; each pulse needs `0 0`, `t 0`, `t+w amplitude`, `t+2w 0` |
| `requested N time points exceeds ...` | the vector set is too long for one run; see below |
| JoSIM exits `3221226505` (0xC0000409) | out of memory: nodes x time points is too high |

A run costs memory in simulation nodes times time points, not in CSV size. The
2,400-line 2-bit adders ran 38-66k points; hamming74 (2,119 lines, 296
junctions) crashed at 66,264. When the full vector set does not fit, split it
into equal chunks (hamming74 runs 128 patterns as four 32-pattern decks). Each
chunk's first pattern launches at the same phase, so the decode grid does not
change and the concatenated bits are the same as one long run would give.

## Limits worth remembering

- all input combinations, always; a fast pass on one vector proves little
- fine time steps near the limit (0.1-0.2 ps at 8-10 GHz); a coarse step can
  falsely pass a marginal design
- re-run at least the boundary point with a halved step
- 0.05 ps is comfortable for the small designs; large vector sets need either
  a coarser step or chunking

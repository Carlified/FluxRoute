# PnRGUI — Open items & operational notes

Living register, kept lean. Completed refactor history lives in git; this file only
tracks what still matters for future work.

## Open / parked (the only actionable items)

- **Error-handling sweep (§10)** — parked until the program is feature-complete, when a
  full sweep is planned: add a real log sink (file + UI), never swallow, `raise` on
  broken invariants. Current state is acceptable: no silent `except`s (the two
  best-effort recent-list saves are documented), all handlers report via
  `lblStatus`/`ShowMessage`.
- **Performance (§12)** — parked until a real design needs it: cache `TraceLengthUm` on
  `TRoutedTrace`, heap-based longest-over-limit selection, incremental bias/route
  re-runs. Current non-blocking state: `PublishTrace` is throttled and re-entrancy-
  gated; trace length is hoisted out of the per-segment loop; validation still re-routes
  per buffer attempt (the router is the arbiter by design).
- **Nested-procedure promotion (§13)** — parked (high-risk / low-reward): the heap-local
  helpers in `LeeRoute`/`RunRouting`/`RouteBiasLines`/`InsertBufferForTrace`/
  `DrawResonancePulses` capture loop state; extraction risks hard-to-find bugs in the
  most-verified path. The `with` reductions are style churn. Revisit only if the routing
  core is frozen.
- **Testing** — unit tests declined by the owner for now (features may change). If ever
  revisited, `UGeometry`/`UPhysics`/`UColors`/`UNetNaming`/`UDesignConfig`/`UConstants`
  are pure and testable. Minor outstanding check: confirm `LefParser.dpr`/`BlifParser.dpr`
  share `LefLibrary`/`BlifLibrary` rather than being divergent copies.

## Coding rules (hard constraints for future edits)

- No new `TryDimParse`, no new `Edit*.`/`Memo*.` access from logic, no new domain types
  in `MainWindow.pas`.
- Routing-validation buffers live on a throwaway model clone (`FOwnedPlacementModel`),
  scrapped on leaving the Routing page, re-routing, pipeline rebuild, or workspace
  reset. Never route or validate against a committed validation clone.

## Build & verification protocol (important)

- **No command-line compiler** (Community Edition gate). The loop: change → user builds
  in the IDE → user copies the Messages pane (from clipboard) → assistant reads it.
- Normalize touched `.pas`/`.fmx`/`.inc` to CRLF (no lone LF, no trailing whitespace,
  single final newline); sanity-check the combined `begin`/`end` counts across
  unit+includes.

## Incident lesson (do not repeat)

The first pipeline extraction used a PowerShell slice with a negative end index
(`$lines[1813..-3]`), which PowerShell treats as reverse-from-end and corrupted
`MainWindow.pas`. It was recovered by content-anchored landmark search + byte-equivalence
verification. **Never use a negative index in a PS slice; verify with exact-string checks
before writing.**

## Current shape (orientation)

- `MainWindow.pas` is ~1.7k lines of form wiring + `{$I}`-included feature code:
  `ConfigIO` / `Pipeline` / `Placement` / `FloorPlan` / `Routing` / `ClockPage`. The
  include-file pattern is the interim form standard (Delphi can't split a class across
  units).
- Shared pure units: `UGeometry`, `UPhysics`, `UColors`, `UNetNaming`, `URoutingLegend`,
  `UDesignConfig`, `UConstants`, `PlacementTypes`.
- Wizard progress is one `TFlowStage` enum (`fsVirgin → fsSplitters → fsPlacement →
  fsBias → fsRouted → fsValidated`); controls renamed (`btnLoadLef`, `lblStatus`, …).
- Config is parsed once into `FDesignConfig` at the UI boundary; algorithms read the
  snapshot, never `Edit*.Text`.
## Export feature — Phase 1 ✅

- Domain direction-agnostic per owner: instance kinds exclude direction (a run's
  orientation is stored for rotation only); bends and bias junctions are their own
  kinds; PTL never splits.
- `ExportModel.pas` (Phase-1 enumeration, composite block model): emits block
  KINDS, not raw geometry - pure PTL straight runs (one kind per layer), single-
  layer 90 deg bends, VIA COMPOSITES (never standalone; `m1>m3 S/L/R/180` per
  metal pair, curved-90 split by handedness because the stack pins which metal is
  on top), bias junctions by connection count (3conn/4conn), terminals; plus a
  placed-cell tally by name and the always-required TRACK (ground/track tile).
  `TRoutedTrace` moved to `PlacementTypes` (form-free).
- Temporary verification entry: `RunExportScan` prints a per-kind tally to
  MemoRouting after validation succeeds. **Awaiting IDE build + a validating run.**
## Export feature — Phase 1 + 2 ✅, Phase 3 next

- Phase 1 ✅ (enumeration: PTL/BIAS runs+bends, VIA composites S|L|R|180, bias
  splits by conn-count, terminals; direction-agnostic; cells tally). User-verified.
- Phase 2 ✅ (block library, user-verified): kind-key grammar; manifest JSON
  (save/load); triple-check with tiering - full PTL/VIA need GDS+LEF+CIR,
  BIAS 
oCir (voltage-source lines) and TRACK structuralOnly (optional LEF,
  if_unused per-layer fill GDS) need GDS only; cells resolve from the parsed
  library (.v/.gds/.cir via TCell.SourceFiles, LEF from memory); template
  manifest auto-written to blocklib\manifest.json as the import form.
- Phase 3 (next): Export page (status panel, options, .cir/.def/.gds checkboxes,
  results log) + preflight "missing blocks" dialog + library-path control.
- Phase 4: GDS writer (works from the GDS cells alone). Phase 5: DEF. Phase 6: CIR.
- Note: user hand-builds GDS block files first; .cir/.lef per block can lag -
  preflight reports which kinds still need them, and PTL/VIA require them to pass.- Phase 4 (GDS) slice 1 ✅: UPython.pas (shared python runner, extracted from
  CellViewer; qualified UPython. calls - the viewer keeps its copy for now),
  tools/write_die_gds.py (gdstk) + ExportGDS.pas (recipe JSON). The Export button,
  with .gds ticked, writes a placement recipe (runs as AREFs, bends rot-0, vias,
  splits, placed cells, die boundary on layer 0) into the temp dir and runs
  tools/write_die_gds.py to <out-dir>/<stem>.gds. Known deferrals: per-bend rotation
  (authoring convention "+X->+Y" documented), full TRACK ground-tile tiling +
  if_unused fills. Verify: build; validate; Export tab -> Recheck -> tick .gds
  -> Export; open die.gds in KLayout.
## Export feature - CIR (Phase 6) v
- `ExportCIR.pas` (form-free, mirrors `ExportGDS.pas`): `BuildCirText(...)` builds a
  flat SPICE netlist from the design snapshot. The form-side `RunCirExport` is now a
  thin wrapper (gather + write); the enumeration + netlist logic live in the unit.
  Reuses the shared `ExportScanAll` enumeration and the `ExportLibrary` kind grammar.
- Shape: `.include`s (library subckts + each placed cell's `.cir`); one X per placed
  cell (pins -> nets, clock pin -> its row tap net `clk_row_*`); one X per routed
  PTL/VIA block, each a two-port element chained node_i -> node_{i+1}, driver/load
  pins bound to net_i/net_o. Bias family + TRACK omitted.
- Block map keyed by (cell, layer) so two PTL layers may share a cell; vias keyed by
  cell. PTL caps (`PTLCAP`) are real two-port elements, not structural (manifest +
  `KindTemplatePins` + `KindNeedsCir` all agree).
- `PnRGUI.dpr` lists `ExportCIR`.
- Test bench: **not yet written** - next slice. Cell TBs use SOURCECELL/LOADINCELL/
  SINKCELL + PWL/pulse sources; DCSFQ drives directly. JoSIM (v2.7) scopes `.param`
  per subckt and needs a `.tran` control card (exported deck has none yet).

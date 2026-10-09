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
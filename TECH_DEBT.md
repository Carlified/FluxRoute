# PnRGUI — Codebase Audit & Tech-Debt Register

Working reference for the cleanup effort. Line numbers are from the current tree and
will drift as we edit; counts were measured, not guessed.

## Headline numbers (MainWindow.pas)

| Metric | Value |
|---|---|
| Lines | 10,291 (next-largest unit: `FlipFlopInsert.pas` @ 1,278 — ~8x) |
| Methods/functions, all on `TForm1` | 144 |
| `TForm1` state fields | ~100 (plus ~260 locals/interfaces) |
| `TryDimParse(...)` calls | 69 |
| `Edit*.` references | 139 |
| `Memo*/ListBox*/Combo*/CheckBox*/PaintBox*.` references | 208 |
| `with` statements | 72 |
| Boolean "mode" flags | 25 |
| References to auto-named controls (`Button1`, `Label1`, `TabItem7`, …) | 46 |
| `try` / `except` (silent `except end;`) | 48 / 6 (2 silent) |
| `raise` | 0 |
| Longest methods | `BuildFloorplan` ~639, `PaintPipeline` ~561, `PaintFloorplan` ~464, `RunRouting` ~408, `PaintClockNetwork` ~386, `LeeRoute` ~378, `RouteBiasLines` ~360, `InsertBufferForTrace` ~359, `BuildClockSubtreePlacements` ~302 |

---

## 1. CRITICAL — `MainWindow.pas` is a god object

**Problem.** One ~10k-line unit owns the entire application: library/netlist loading,
cell-selection UI, pipeline, clock, floorplan, placement optimisation, routing,
routing validation, buffer insertion, six different visualisations, project
save/load, and the window plumbing.

**Evidence.** 144 `TForm1` methods; 10,291 lines; the next-largest unit is 1,278.

**Why it hurts.** Every change risks an unrelated feature; nothing is independently
testable or reusable; merge conflicts; navigation is by line number, not name;
compile times; and the AI-assisted edits keep regressing adjacent code.

**Fix.** Extract feature by feature into real units (types + an engine class per
feature), leaving the form as thin event wiring. See §15 for the order.

---

## 2. CRITICAL — the GUI *is* the data model

**Problem.** Domain logic reads and writes FMX controls directly instead of a model.
Config values are re-parsed from text boxes on nearly every operation.

**Evidence.**
- 69 `TryDimParse(...)` calls, most re-parsing `EditCoreSize.Text`, `EditDieW.Text`,
  `EditPTLLength.Text`, `EditFreqGHz.Text`, … inline mid-algorithm
  (e.g. `RunRouting`, `LeeRoute`, `DrawRoutedTraces`, `BuildFloorplan`).
- 139 direct `Edit*.` references and 208 `Memo*/ListBox*/PaintBox*` references from
  what should be pure logic (`RunRouting` appends to `MemoRouting.Lines`,
  `BuildFloorplan` writes `ListBoxFloorplanErrors`, etc.).
- Validation/business rules live inside `ValidatePlacement` (~150 lines of
  UI-message-emitting code).

**Why it hurts.** Logic can't run without a form; impossible to unit-test; unit
conversions and parsing are scattered; a typo in a text box changes algorithm
behaviour at runtime; "the config" has no single source of truth.

**Fix.** Introduce a `TDesignConfig` (value object) parsed once at the UI boundary;
pass it (or a `TPlacementEngine`) into the algorithms. Log/report through an
interface, not `MemoRouting`.

---

## 3. HIGH — domain types are declared inside the form unit

**Problem.** All the domain records/enums live in `MainWindow.pas`'s `type` block:
`TFloorplanCell`, `TPlacedComponent`, `TBiasPort`, `TBiasGroup`, `TPadConnection`,
`TPlacedClockNode`, `TSpineComponent`, `TRoutedTrace`, `TRouteJob`, `TRouteJobKind`,
`TValidationBuffer`, `TPlaceSnapshot`, `TClockTreeNode`, … (lines ~38–154).

**Why it hurts.** Any other unit that wants to reason about placement/routing must
`uses MainWindow`, dragging in FMX and the whole form. It cements the god object.
These are the natural homes of the extracted engines.

**Fix.** Move each cluster into its feature unit (`PlacementTypes.pas`,
`RoutingTypes.pas`, …) or the engine unit that owns it.

---

## 4. HIGH — copy-paste duplication

**Evidence.**
- `CollectLogic`/`CollectClock` nested procs exist **twice**, byte-for-byte:
  `ButtonExpandBiasClick` (lines ~2982/2995) and `RouteBiasLines` (~6965/6977).
  `SharedTracks` (~3012) duplicates `PartitionBiasPorts`+merge logic.
- Canvas mapping helpers `WX`/`WY` redefined in **three** paint methods
  (`PaintFloorplan` ~4962, `PaintRouting` ~5431, `PaintClockNetwork` ~9678).
- `HslColor`/`LayerColor` redefined in `PaintRouting` (~5444) while the class also
  has `HslToColor`/`RoutingLayerColor` (~5779/5816) — two colour systems.
- `RectOverlap` in `InsertBufferForTrace` (~7825) duplicates the rect math used by
  floorplan overlap checks.
- The legend layout constants are **duplicated with a warning comment**:
  `DrawRoutingLegend` (`LegendPad=8; RowH=18; BoxSize=12; PanelW=70`, ~5866) and
  `PaintBox4MouseDown` (`… // must match DrawRoutingLegend`, ~5675). Classic
  drift bug — hit-testing silently misaligns if only one is edited.
- `SegDir`/`DirUnit` axis-direction helpers repeated in the routing/validation code.

**Why it hurts.** Fix a bug in one copy, miss the other; two sources of truth.

**Fix.** One `Geometry`/`Canvas` helper unit (mapping, rect overlap, HSL, direction
helpers) and one legend module (layout + draw + hit-test together).

---

## 5. HIGH — the four god-paint methods

**Evidence.** `PaintPipeline` ~561, `PaintFloorplan` ~464, `PaintClockNetwork` ~386,
`PaintRouting` ~262 lines each, mixing: coordinate mapping, culling, cell/port
rendering, trace rendering, legends, hit-test geometry, and layout constants.

**Why it hurts.** Untestable; any visual tweak risks logic; zoom/pan math duplicated
per method; the draw order is implicit and fragile (we just moved wire drawing to fix
a z-order bug).

**Fix.** A `TPageRenderer` per page split into layout / draw layers; a shared
`TViewport` (pan/zoom/world↔screen) object; a `TLegend` component owning its own
draw + hit-test.

---

## 6. HIGH — validation mutates shared models in place

**Evidence.** `RunRoutingValidation` → `InsertBufferForTrace`/`TryInsertBuffer` add
gates to `FPlacementModel` / `FClockBufferedModel`, split nets, then to "revert" they
remove the gate/net and re-run the **entire** bias-expansion + routing
(`RunBiasExpansionAndRouting`). `FPlacementModel = FPipelineModel` is the *same object*,
so clock/pipeline rebuilds silently inherit validation buffers.

**Why it hurts.** No transactional boundary; partial failure leaves half-mutated
netlists; correctness depends on the re-run reproducing the prior state exactly;
the ownership overlap (`FPlacementModel` aliasing `FPipelineModel`) is an invisible
landmine.

**Fix.** Clone-on-write: build a candidate model, validate it, commit or discard.
Never alias two "models" to one object.

---

## 7. MEDIUM — boolean-flag state machine

**Evidence.** 25 `F…: Boolean` "mode" flags: `FPlacementInitialized`,
`FFormattingPlacement`, `FFloorplanValid`, `FBiasExpansionDone`,
`FPlacementOptimized`, `FSplittersInserted`, `FRoutingSucceeded`,
`FRoutingValidated`, `FRouteLengthColor`, `FSwitchingTab`, `FLoadingProject`,
`FClosePromptActive`, `FAllowClose`, `FSliderUpdating`, `FDragging`,
`FClockDragging`, `FPlanDragging`, `FRouteDragging`, `FPadDragging`,
`FOrderChanged`, `FManhattanItem`(object-as-flag), …
Goated by ordering rules spread across `UpdateUI`, `TabControl1Change`, the click
handlers, and `ResetWorkspace`.

**Why it hurts.** States that must never coexist *can* coexist; the "what's allowed
now" logic is scattered and re-derived; easy to enable a button that calls code whose
preconditions aren't met.

**Fix.** An explicit wizard-state enum + a single transition/validity function; make
illegal states unrepresentable.

---

## 8. MEDIUM — manual memory management everywhere

**Evidence.** 204 `.Create` vs 75 `.Free`; `FormDestroy` frees ~25 owned lists/dicts
by hand; models use `TObjectList<…>(True)` owning flags; `TList<TNetConnection>` of
records copied around (`AddRange`) to snapshot/restore; `FPads`, `FPlacedComponents`
hold raw `TGateInstance` pointers that alias model gates.

**Why it hurts.** Leak/double-free risk; ownership rules are undocumented; the
"snapshot then restore" pattern is easy to get wrong.

**Fix.** Prefer `TArray<T>`/`TDictionary` with clear ownership, or interfaces with
reference counting; centralise teardown; document who owns `TGateInstance`.

---

## 9. MEDIUM — hardcoded magic & protocol strings

**Evidence.**
- Net-name conventions hardcoded: `'clk'`, `'clk_row_'`, `'clk_delay_'`,
  `'__clkbuf_'`, `'bias_'`, `'bias_trunk'`, `'__vbuf_'` (39 occurrences).
- The physics constant: `Lr := 500.0 / (FreqGHz * Delay)` (unit-baking in code).
- Pixel colours as literals (`$FF909090`, `$FF404040`, `$E6FFFFFF`, …) scattered.
- Numeric tuning constants inline: `TurnPenalty=3`, `ViaPenalty=8`, margins,
  `DangerHalfWidthBlocks=0.25`, `CrossHalfBlocks`-era values.
- `Button1/Button3/Button5`, `Label1/Label2`, `Memo1`, `TabItem1…8`, `TabControl1`
  never renamed (46 refs).

**Why it hurts.** A rename in the netlist/clock generator silently breaks routing
filters; conventions are invisible; magic constants can't be tuned/document tested.

**Fix.** Named constants / a `NetNaming` helper; a palette module; a `Physics`
helper with unit-tested conversions; rename the controls.

---

## 10. MEDIUM — error handling

**Evidence.** 6 `except` blocks, 0 `raise`; two are silent:
`except end;` at ~809 and ~1264 (recent-projects save/load swallow everything).
Parse errors are routed by writing to `Label1.Text` (`'Failed to parse LEF file.'`).

**Why it hurts.** Failures vanish; the user sees a generic label; bugs in save/load
are invisible; no stack info anywhere.

**Fix.** Log to a real sink (file + UI), never swallow; remove broad silent handlers;
surface actionable messages.

---

## 11. MEDIUM — mixed UI wiring patterns

**Evidence.** Some handlers are bound in the `.fmx`
(`OnChange = EditPlacementChanged`), others re-bound in `FormCreate`
(`EditCoreSize.OnChange := EditPlacementChanged;` ~1447-1472), with the comment
"bind live … regardless of the .fmx event bindings". Both exist for different
controls.

**Why it hurts.** You can't tell where a handler is wired from either file alone;
the same handler may be attached twice.

**Fix.** One convention: wire in the `.fmx` OR in code, not both; document it.

---

## 12. MEDIUM — recompute / re-run as the control flow

**Evidence.** `RunBiasExpansionAndRouting` re-runs the whole bias expansion + full
re-route after every buffer attempt (and again on revert). `PublishTrace` calls
`PaintBox4.Repaint` + `Application.ProcessMessages` per trace. `TraceLengthUm` is
recomputed per trace per paint. `RunRoutingValidation` rescans all traces each loop.

**Why it hurts.** Slow on real designs; `ProcessMessages` re-entrancy is dangerous;
performance is O(design²)-ish by construction.

**Fix.** Incremental/dirty-flag updates; cache lengths on the trace record; drop
`ProcessMessages` (or gate it); separate "measure" from "render".

---

## 13. LOW — pervasive nested procedures capturing outer locals

**Evidence.** Heavy nested/`with` usage inside `LeeRoute`, `RunRouting`,
`ButtonExpandBiasClick`, `RouteBiasLines`, `InsertBufferForTrace`,
`DrawResonancePulses` (and 72 `with` statements). Many are needed (heap-local helpers
in a hot loop) but most are just terseness.

**Why it hurts.** Hard to read/step; accidental capture bugs; can't reuse or test the
helpers; `for`-loop-var capture (an actual bug we hit) is easy to reintroduce.

**Fix.** Promote reusable helpers to standalone functions/methods; reserve nesting for
genuinely hot inner loops.

---

## 14. LOW — comments compensating for structure

**Evidence.** Extremely comment-dense (mostly a *good* habit here), but many comments
explain *why a hack exists* ("the buffered model also holds every signal net …",
"Classic sequential maze", "must match DrawRoutingLegend") rather than what the code
does.

**Why it hurts.** The comments are load-bearing — remove them and intent is lost,
because the structure doesn't speak for itself.

**Fix.** As features are extracted, let names/types carry the intent and demote the
essays to short doc-comments on the new units.

---

## 15. Testing & tooling

- **No unit tests** anywhere. Domain algorithms (placement order, bias partitioning,
  Lee routing, resonance windows, netlist split) are pure logic begging for tests.
- **Community Edition** — no command-line compile, so changes are verified only by
  building in the IDE. (See note below.)
- Two standalone parsers (`LefParser.dpr`, `BlifParser.dpr`) exist beside the units;
  confirm they share `LefLibrary`/`BlifLibrary` and aren't divergent copies.

---

## Proposed cleanup order (feature by feature)

Extraction targets, lowest-risk / highest-value first. "Real unit" = a feature class +
its types moved out; the form ends up as event wiring only.

1. **Extract shared primitives first** (pure, no form dependency):
   `UGeometry` (rect overlap, direction, canvas world↔screen), `UColors` (palette +
   HSL), `UNetNaming`, `UPhysics` (resonance/length conversions), `Legend` (layout +
   draw + hit-test in one place). Kills §4 duplication.
2. **Placement/floorplan** (the original next step): `PlacementTypes.pas` +
   `TPlacementEngine` — config, build, order/optimise, bias geometry, paint layout.
3. **Pipeline** (`TPipelineModel` + renderer) — `PaintPipeline` is the single biggest
   method.
4. **Clock** (`TClockEngine` + renderer).
5. **Routing** (`TRouter`, `TBiasRouter`, `TValidation`) — biggest domain logic;
   do after the models are extracted so it stops mutating form fields.
6. **Project/IO** (`TProjectController`) — already partly in `ProjectData`.
7. **Slim the form**: state enum (§7), rename controls (§9), one wiring convention
   (§11), centralised teardown (§8).

Rule of thumb while doing this: **no new `TryDimParse`, no new `Edit*.`/`Memo*.`
access from logic, no new types in `MainWindow.pas`.**

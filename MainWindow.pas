unit MainWindow;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  System.Diagnostics,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.ListBox, FMX.Memo, FMX.Layouts, FMX.TabControl,
  FMX.Objects, FMX.Edit,
  System.IOUtils, System.JSON, System.Math, System.Math.Vectors,
  System.Generics.Collections, System.StrUtils,
  UGeometry, UPhysics, UColors, UNetNaming, URoutingLegend,
  PlacementTypes, UDesignConfig, UConstants,
  ExportModel, ExportLibrary, ExportGDS,
  ExportCIR, ClockValidate,
  UPython,
  LefLibrary,
  BlifLibrary,
  CellViewer,
  VerilogTiming,
  SplitterInsert,
  PipelineConfig,
  PipelineAnalysis,
  FlipFlopInsert, ClockNetwork,
  ProjectData,
  FMX.DialogService,
  FMX.Memo.Types, FMX.ScrollBox;

const
  // Top-level wizard page indexes. A Start/project page is at the front.
  // Order: Start, Library, Cell selection, BLIF loading, Pipeline, Clock,
  // Placement configuration, Floorplan, Routing.
  TabStart = 0;
  TabLibrary = 1;
  TabComponents = 2; // cell selection (splitters/FF/buffers)
  TabNetlist = 3;    // BLIF loading
  TabPipeline = 4;
  TabClock = 5;
  TabPlacement = 6;  // floorplanning / placement configuration
TabFloorplan = 7;  // floorplan visualisation
TabRouting = 8;    // final routing
TabExport = 9;     // export the routed circuit (final page)

type
  // One routed trace: the net it belongs to and the grid blocks (cell centres)
// it passes through, in order. Layers holds the routing-layer name for each
// point (via crossings change the layer between consecutive points).
  // One point-to-point routing job: a driver pin -> a load pin (a signal net,
  // or one link of a clock net's fan-out). Kind distinguishes them for the
  // summary counts; Start/Goal are the pin grid blocks on the primary layer.
  TRouteJobKind = (rkSignal, rkClock);
  TRouteJob = record
    NetName: string;
    Kind: TRouteJobKind;
    Driver: TGateInstance;
    DriverPin: string;
    Load: TGateInstance;
    LoadPin: string;
    Dist: Integer;  // Manhattan pin distance (ordering)
    Start, Goal: TPoint; // terminal grid blocks (resolved once)
    // Routing layers each pin may connect on (bit k = FRouteLayers[k]).
    // High(UInt64) marks a pad or a shapeless synthetic cell: any layer.
    StartMask, GoalMask: UInt64;
    StartValid, GoalValid: Boolean;
    Routed: Boolean;
    Path: TArray<TPoint>;
    PathLayers: TArray<Integer>;
  end;
  TRouteJobArray = TArray<TRouteJob>;

  // Buffer validation inserts to break an over-long PTL; its slot records where
  // it sits so it can be re-applied after a floorplan rebuild.
  TValidationBuffer = record
    Gate: TGateInstance;
    NetName: string;
    IsClock: Boolean; // True if inserted into a clock link (clock model)
    Band: Integer;    // band the buffer sits in (-1 for the clock trunk)
    RowType: Integer; // 0 = logic row, 1 = clock row, 2 = clock trunk
    X: Integer;       // top-left X in grid cells
    Y: Integer;       // top-left Y in grid cells (absolute; trunk uses it directly)
  end;

  // Progress through the wizard flow. Each milestone implies the earlier ones.
  // Some actions step back (bias invalidation, re-routing) - see the assignments.
  TFlowStage = (fsVirgin, fsSplitters, fsPlacement, fsBias, fsRouted, fsValidated);

  TForm1 = class(TForm)
    TabControl1: TTabControl;
    LabelStartHint: TLabel;
    ButtonNewProject: TButton;
    ButtonOpenProject: TButton;
    LabelRecent: TLabel;
    ListBoxRecent: TListBox;
    TabItem1: TTabItem;
    WelcomeLabel: TLabel;
    btnLoadLef: TButton;
    TabItem2: TTabItem;
    btnLoadLibrary: TButton;
    lstCells: TListBox;
    MemoLayers: TMemo;
    btnLoadBlif: TButton;
    memoNetlist: TMemo;
    TabItem3: TTabItem;
    Label2: TLabel;
    SubTabControl: TTabControl;
    SubTabSplitters: TTabItem;
    SubTabDFF: TTabItem;
    SubTabBuffers: TTabItem;
    ListBoxSplitters: TListBox;
    ListBoxDFF: TListBox;
    ListBoxBuffers: TListBox;
    ListBoxSelected: TListBox;
    EditCoreSize: TEdit;
    EditRowHeight: TEdit;
    LabelCoreDim: TLabel;
    LabelRowCells: TLabel;
    EditDieW: TEdit;
    EditDieH: TEdit;
    LabelDieAreaText: TLabel;
    EditUtilization: TEdit;
    EditBiasCurrent: TEdit;
    EditTrunkCurrent: TEdit;
    EditPTLLength: TEdit;
    EditFreqGHz: TEdit;
    EditPTLDelay: TEdit;
    EditPulseWidth: TEdit;
    ComboBiasLayer: TComboBox;
    LabelBiasLayer: TLabel;
    ListBoxPlacementErrors: TListBox;
    TabItem5: TTabItem;
    PaintBox1: TPaintBox;
    TrackBar1: TTrackBar;
    LabelMode: TLabel;
    LabelFreqLeft: TLabel;
    LabelFreqRight: TLabel;
    TabItem6: TTabItem;
    PaintBox2: TPaintBox;
    PaintBox3: TPaintBox;
    ButtonOptimize: TButton;
    ButtonExpandBias: TButton;
    CheckBoxShowNames: TCheckBox;
    CheckBoxShowLogicWires: TCheckBox;
    CheckBoxShowClockWires: TCheckBox;
  CheckBoxSeedBuffers: TCheckBox;
    CheckBoxShowFloorplan: TCheckBox;
    CheckBoxShowCells: TCheckBox;
    ListBoxFloorplanErrors: TListBox;
    SplitterErrors: TSplitter;
    ButtonRunRouting: TButton;
    MemoRouting: TMemo;
    SplitterRouting: TSplitter;
    PaintBox4: TPaintBox;
    ButtonBack: TButton;
    ButtonNext: TButton;
    MemoExportStatus: TMemo;
    EditBlockLibDir: TEdit;
    ButtonBrowseLib: TButton;
    EditExportDir: TEdit;
    EditExportStem: TEdit;
    CheckExportGds: TCheckBox;
    CheckExportDef: TCheckBox;
    CheckExportCir: TCheckBox;
    CheckExportMetrics: TCheckBox;
    ButtonPreflight: TButton;
    ButtonExport: TButton;
    ButtonHelp: TButton;
    MemoExportLog: TMemo;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
    procedure btnLoadLefClick(Sender: TObject);
    procedure btnLoadLibraryClick(Sender: TObject);
    procedure btnLoadBlifClick(Sender: TObject);
    procedure lstCellsDblClick(Sender: TObject);
    procedure ListBoxSplittersDblClick(Sender: TObject);
    procedure ListBoxDFFDblClick(Sender: TObject);
    procedure ListBoxBuffersDblClick(Sender: TObject);
    procedure ListBoxSelectedDblClick(Sender: TObject);
    procedure TabControl1Change(Sender: TObject);
  procedure TabControl1Changing(Sender: TObject; var AllowChange: Boolean);
    procedure TrackBar1Change(Sender: TObject);
    procedure ButtonBackClick(Sender: TObject);
    procedure ButtonNextClick(Sender: TObject);
    procedure ButtonHelpClick(Sender: TObject);
    procedure UpdateNavButtons;
    procedure ButtonNewProjectClick(Sender: TObject);
    procedure ButtonOpenProjectClick(Sender: TObject);
    procedure ListBoxRecentDblClick(Sender: TObject);
    procedure EditPlacementChanged(Sender: TObject);
    procedure EditPlacementKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: WideChar; Shift: TShiftState);
    procedure ComboBiasLayerChange(Sender: TObject);
    procedure PopulateBiasLayerCombo;
procedure ButtonOptimizeClick(Sender: TObject);
    procedure ButtonExpandBiasClick(Sender: TObject);
    procedure CheckBoxToggleChange(Sender: TObject);
  procedure CheckBoxSeedBuffersChange(Sender: TObject);
    procedure ButtonRunRoutingClick(Sender: TObject);
    procedure ButtonBrowseLibClick(Sender: TObject);
    procedure ButtonPreflightClick(Sender: TObject);
    procedure ButtonExportClick(Sender: TObject);
    procedure PaintBox1MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure PaintBox1MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PaintBox1MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
  private
    FLefFile: string;
    FCellFolder: string;
    FBlifFile: string;
    FLib: TLibrary;
    FModel: TBlifModel;
    FSplitterNames: TStringList;
    FCandidateCells: TList<TCell>;
    FCellDelays: TDictionary<string, Double>;
    FFlipFlopNames: TStringList;
    FFlipFlopCandidates: TList<TCell>;
    FBufferNames: TStringList;
    FBufferCandidates: TList<TCell>;
    FPipelineRows: TArray<TList<TGateInstance>>;
    FPipelineModel: TBlifModel;
    // Cached pipeline-page layout: rebuilt only when the model changes, so
    // panning/zooming never re-walks the circuit.
    FPipeRowsModel: TBlifModel;
    FPipeGridPos: TDictionary<TGateInstance, TPoint>; // tree position per gate
    FPipeInputCol: TDictionary<string, Integer>;      // level-0 column per input
    FPipeOutGrid: TDictionary<string, TPoint>;        // (column, level) per output
    FPipeLevelDepth: TArray<Integer>;                 // rows used per clock level
    FPipeLevelYOff: TArray<Integer>;                  // first-row offset per level
    FPipeHasGateRow: TArray<Boolean>;                 // level holds clocked gates
    FPipeArea, FPipeWorstPath: Double;
    FSliderPos: Integer;
    FSliderUpdating: Boolean;
    FSliderTimer: TTimer;
    FMaxWorstPath: Double;
    FMinDelay: Double;
    FThreshold: Double;
    FCompactWorstDelay: Double;
    FClockModel: TBlifModel;      // deep copy of the DFF-inserted netlist
    FClockBufferedModel: TBlifModel; // copy with delay blocks -> buffer chains
    FClockNet: TClockNetworkInfo; // clock stage registry (top-down)
    FProject: TProjectFile;
    FProjectPath: string;
    FLoadingProject: Boolean;
    FRecent: TStringList;
    FLastProject: string;
    FClosePromptActive: Boolean;
    FAllowClose: Boolean;
    FPlacementInitialized: Boolean;
    FFormattingPlacement: Boolean;
    FBiasLayer: string;
    FDesignConfig: TDesignConfig; // parsed placement/routing config snapshot
    FPanX, FPanY: Single;
    FDragX, FDragY: Single;
    FDragging: Boolean;
    FZoom: Single;
    FClockPanX, FClockPanY: Single;
    FClkDragX, FClkDragY: Single;
    FClkDragging: Boolean;
    FClockZoom: Single;
    FPlanPanX, FPlanPanY: Single;
    FPlanDragX, FPlanDragY: Single;
    FPlanDragging: Boolean;
    FPlanZoom: Single;
    FPlanNeedsFit: Boolean;
    FRoutePanX, FRoutePanY: Single;
    FRouteZoom: Single;
    FRouteNeedsFit: Boolean;
    FRouteDragX, FRouteDragY: Single;
    FRouteDragging: Boolean;
    FRoutingLayers: TStringList;
    FRoutingLayerEnabled: TDictionary<string, Boolean>;
    FRouteTraces: TArray<TRoutedTrace>;
    FRouteSignalLayer: string;
    FRouteLayers: TArray<string>;          // routing layer names, in library order
    FRouteObstacles: TArray<TArray<Boolean>>; // [layerIdx][block] pin-geometry blocks
    FRouteObstaclesW, FRouteObstaclesH: Integer;
        FFlowStage: TFlowStage;         // wizard progress (fsVirgin..fsValidated)
    FPublishSinceRepaint: Integer;  // PublishTrace live-repaint throttle counter
    FRoutingBusy: Boolean;          // blocks re-entrant routing via the message pump
    FRouteLengthColor: Boolean;  // trace colouring: length scale vs layer colour
    FValidationBuffers: TArray<TValidationBuffer>; // clock trunk buffers (validation)
    FLengthBuffers: TArray<TLengthBufferPlacement>; // length mask (validation)
    FMinClockPeriodPs: Double;                      // timing-derived min clock period
  // The three limits behind it (ps), kept for the export and the logs:
  FMinPeriodTimingPs: Double;                     // data path + setup
  FMinPeriodSpacingPs: Double;                    // cell input-spacing requirement
  FMinPeriodWindowExtraPs: Double;                // extra period the input window needed
  FInputWindowFound: Boolean;                     // first-batch launch window valid
  FInputWindowStartPs: Double;                    // earliest launch at the min period (+1 initial period)
  FInputWindowEndPs: Double;                      // latest launch (period independent) (+1 initial period)
  FInputWindowTargetFound: Boolean;               // window at the requested frequency
  FInputWindowTargetStartPs: Double;              // earliest launch at that period (+1 initial period)
  FInputWindowTargetEndPs: Double;                // latest launch at that period (+1 initial period)
  FOutputTravelFound: Boolean;                    // output travel time measured
  FOutputTravelPs: Double;                        // clock sent -> first output pad
    FValidationBlocked: TStringList;               // failed buffer slots 'band:row:x'
    FValidationBufIdx: Integer;                    // unique suffix for split net names
    FPlacementErrorCount: Integer;
    FFloorplanErrorCount: Integer;
  FBiasExpansionFailed: Boolean;                  // bias lines do not fit the die
  FRouteFailedLinks: Integer;                     // links the router could not route
  FBiasGatesSeen: Integer;                        // powered cells allotted bias
  FBiasGateSet: TDictionary<TGateInstance, Boolean>; // the gates themselves (audit)
  FClockLevelSkew: TArray<Double>;                // per clock level, max-min arrival
  FRouteRuntimeMs: Int64;                         // wall-clock of the routing stage
    FSwitchingTab: Boolean;
    FFloorplan: TArray<TFloorplanCell>;
    FFloorplanLayer: TArray<SmallInt>; // clock level per cell, -1 = none
    FFloorplanW, FFloorplanH: Integer;
    FFloorplanValid: Boolean;
    FPlacedComponents: TArray<TPlacedComponent>;
    FGatePlacement: TDictionary<TGateInstance, TPoint>; // gate -> grid cell
    FPadMap: TDictionary<string, TPoint>; // primary net -> immobile pad cell
    FPads: TArray<TPadConnection>; // ordered pads, for rendering
    FPadOrderInput: TArray<Integer>; // display order of input pad indices
    FPadOrderOutput: TArray<Integer>; // display order of output pad indices
    FPadDragging: Boolean; // dragging a pad to reorder it
    FPadDragIdx: Integer; // FPads index of the dragged pad
    FPadDragX: Single; // dragged pad's current X (grid blocks)
    FClockPadIdx: Integer; // FPads index of the clock input (-1 if none)
    FDroppedCells: Integer; // logic cells that did not fit during placement
    FClockSubtree: TArray<TArray<TPlacedClockNode>>; // balanced subtree per layer
    FSpine: TArray<TSpineComponent>; // placed clock trunk (splitters + buffers)
    FPlacementModel: TBlifModel; // model used for floorplan (post-DFF pipeline)
    FOwnedPlacementModel: TBlifModel; // private clone validation mutates (nil = alias)
    FBlockLibDir: string;         // block-library root (PDK); '' = none configured
    FExportMissingKinds: Integer;   // kinds the library did not cover (preflight)
    // Band layout snapshot for the ordering algorithm.
    FPlanCore: Double;
    FPlanLevels: TArray<Integer>;
    FPlanNumLayers: Integer;
    FPlanLevelFirstBand: TArray<Integer>;
    FPlanLevelBandCount: TArray<Integer>;
    FPlanBandStarts: TArray<Integer>;
    FPlanXLeft: Integer;  // left edge of the rows (bias trunk is at XLeft-1)
    FPlanXRight: Integer; // right edge of the rows (feed column at XRight)
    FPlanRowHBlocks: Integer;
    FPlanBandHeight: TArray<Integer>; // actual height per band (incl. extra rows)
    FLogicRowExtra: TArray<Integer>; // extra rows added to a band's LOGIC row
    FClockRowExtra: TArray<Integer>; // extra rows added to a band's CLOCK row
    // Bias-line current-capacity geometry computed by the bias helpers and applied
    // in BuildFloorplan (extra row heights and the two flanking lane widths).
    // [band][0=top, 1=middle] extra bias rows. Persists across floorplan
    // rebuilds (BuildFloorplan remaps it by layer/chunk); there is no teardown,
    // so expansion leaves permanent headroom - a known quirk, not unbounded.
    FBiasRowH: TArray<TArray<Integer>>;
    FBottomBiasH: Integer;              // extra rows on the bottom-most bias line
    FBiasLaneW: TArray<Integer>;        // [0]=left feed lane, [1]=right lane width (>=1)
    // The block-based bias network built by RouteBiasLines (one cell per grid
    // block with its neighbour directions on the bias layer). Both the routing
    // page paint and the export enumerator read this directly.
    FBiasCells: TArray<TBiasCell>;
    FPlanMaxRowW: Integer;              // row-width override for the nudge (0=auto)
    FPlanBiasTrunkW: Integer;           // far-left bias trunk width in columns (>=1)
    FPlanDieWExtra: Integer;            // run-time die widening (bias growth), in blocks
    FPlanTrunkW: Integer;               // snapshot: clock trunk width (RowHBlocks)
    FPlanLane0W: Integer;               // snapshot: left feed bias lane width
    FPlanLane1W: Integer;               // snapshot: far-right bias lane width
    FPlanLastTotalH: Integer;           // snapshot: last TotalH (bias-fit checks)
    FOrderChanged: Boolean;
    FSuppressLayoutCheck: Boolean; // skip the intermediate layout validation
    FManhattanItem: TListBoxItem; // live 'total wire length' diagnostic line
    // ---- Ownership ----
    // The form owns FLib, FModel, FPipelineModel, FClockModel/FClockBufferedModel
    // and the workspace containers below; they are created and freed together
    // (InitWorkspaceContainers / FreeWorkspaceContainers). Everything the
    // containers hold is BORROWED: the TCell items belong to FLib, the
    // TGateInstance keys/arrays belong to the models. FPlacementModel is a
    // non-owning alias into FPipelineModel/FModel (cleared by the free helpers).
    procedure InitWorkspaceContainers;
    procedure FreeWorkspaceContainers;
    procedure ScrapValidationModel;
    procedure RemoveClockValidationBuffers;
    // Length-fixing validation buffers live in their own mask layer: positioned
    // over the logic/clock rows, visible to routing/bias but never merged into
    // FPlacedComponents/FSpine/the clock subtree.
    procedure ReapplyLengthBufferMask;
    // Shared clearance test for the buffer mask layer: true when a W x H buffer
    // at (X, Y) touches any placed cell, clock node, trunk cell or length buffer.
    // One clear block is required on each side, the same gap the row packer uses.
    function BufferSlotBlocked(X, Y, W, H: Integer;
      SkipGate: TGateInstance = nil): Boolean;
    // Nearest free buffer slot: outward from (WantBand, WantRowType, WantX), same
    // band's other row next, then the nearest bands. W/H are the buffer's own
    // footprint (one buffer cell type, so it is a fixed calculation per run).
    function FindBufferSlot(WantBand, WantRowType, WantX, W, H: Integer;
      out ABand, ARowType, AX, AY: Integer): Boolean;
    procedure RemoveLengthBuffers;
    function IsLengthMaskGate(G: TGateInstance): Boolean;
    procedure CheckValidationBufferOwnership;
    procedure FreeLib;
    procedure ResetWorkspace;
    procedure LoadLibraryFromFile(const Path: string; AShowErrors: Boolean = True);
    procedure SetCellFolderPath(const Path: string; AShowErrors: Boolean = True);
    procedure LoadNetlistFromFile(const Path: string; AShowErrors: Boolean = True);
    // Dumps the model the tool is working on into the netlist memo: the parsed
    // view (inputs/outputs, gates with levels and pin=net, nets with drivers and
    // loads) plus the parse/connectivity/level errors.
    procedure RenderNetlist(Model: TBlifModel; Errors: TStrings);
    procedure ApplyProjectSettings;
    procedure OpenProjectFile(const Path: string);
    procedure SaveProjectFileAs;
    procedure SaveProjectState;
    procedure UpdateRecentList;
    procedure RemoveRecentProject(const Path: string);
    procedure InitializePlacementConfig;
    procedure ValidateFloorplanLayout;
    procedure FormatPlacementFields;
    procedure AddPlacementMsg(const Text: string; Color: TAlphaColor; IsError: Boolean);
    // True only with a usable LEF and the cell folder: every later page needs
    // both, so the library page must be completed before the flow continues.
    function LibraryReady: Boolean;
    procedure UpdateUI;
    function IsSplitterCandidate(const Cell: TCell; out NumOutputs: Integer): Boolean;
    function CellDelayPs(const Cell: TCell): Double;
    function DelayTextPs(const Delay: Double): string;
    procedure PopulateSelectionTab;
    procedure RefreshSelectedList;
    procedure RemoveSelection(const AName: string);
    procedure RunSplitterInsertion;
    procedure FreePipelineRows;
    procedure BuildPipelineRows(const AModel: TBlifModel);
    procedure PaintPipeline(Sender: TObject; Canvas: TCanvas);
    procedure FreePipelineModel;
    procedure BuildPipelineModel;
    procedure SliderTimerTimer(Sender: TObject);
    procedure UpdateModeLabel;
    procedure UpdateLimitLabels;
    procedure RepaintPipelinePage;
    procedure FreeClockModel;
    procedure BuildClockModel;
    procedure PaintClockNetwork(Sender: TObject; Canvas: TCanvas);
    procedure RepaintClockPage;
    procedure PaintBox2MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintBox2MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PaintBox2MouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintFloorplan(Sender: TObject; Canvas: TCanvas);
    procedure BuildFloorplan;
    procedure RepaintFloorplanPage;
    procedure AddFloorplanError(const Text: string);
    procedure ReportBiasError(const Text: string);
    function RunFinalChecks: Boolean;
    function BuildMetricsJson: string;
    procedure RunMetricsExport(const OutDir, Stem: string);
    function TotalManhattanDistance: Double;
    procedure UpdateManhattanDiagnostic;
    function GetPad(const ANetName: string; var P: TPoint): Boolean;
    function PadSlotX(k, N, Right: Integer): Single;
    // Right edge (exclusive) of the output pad row: the clock pad is fixed in
    // the middle of the clock trunk on the same row, so the outputs stop short
    // of it instead of being spread across its space.
    function OutputPadRight: Integer;
    function NearestPadSlot(DragX: Single; N, Right: Integer): Integer;
    function PreviewPadOrder(const Ord: TArray<Integer>;
      DragIdx, Slot: Integer): TArray<Integer>;
    procedure ReapplyPadOrder;
    function PadDisplayX(Idx: Integer): Integer; // pad X while dragging
    procedure BuildClockSubtreePlacements;
    procedure BuildSpinePlacement;
    procedure ValidatePlacement;
    procedure RefreshDesignConfig;
    function NetManhattan(Net: TNet): Double;
    function CellCenterUm(G: TGateInstance; Core: Double;
      var UX, UY: Double): Boolean;
    procedure SetPlanCell(X, Y: Integer; Kind: TFloorplanCell; ALayer: Integer);
    function GetPlanCell(X, Y: Integer): TFloorplanCell;
    procedure FillPlanRect(X0, Y0, X1, Y1: Integer; Kind: TFloorplanCell;
      ALayer: Integer);
    procedure PaintBox3MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintBox3MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PaintBox3MouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintRouting(Sender: TObject; Canvas: TCanvas);
    procedure RepaintRoutingPage;
    procedure PaintBox4MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintBox4MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure PaintBox4MouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure BuildRoutingLayers;
    function RoutingLayerEnabled(const ALayer: string): Boolean;
    procedure ToggleRoutingLayer(const ALayer: string);
    procedure DrawRoutingLegend(Canvas: TCanvas);
    procedure RunRouting;
    procedure RunRoutingValidation;
    // Clock-arrival validation. Returns False when no buffer slot could be
    // found (validation failed); AInserted is True when a trunk buffer was
    // added (the caller then re-runs the length check).
    function RunClockValidation(out AInserted: Boolean): Boolean;
procedure AppendScanTally(const D: TExportDesign;
      const Cells: TArray<TExportCellCount>; const Lines: TStrings);
    procedure AppendClockSummary(const Lines: TStrings);
    procedure ReportLibraryCoverage(const D: TExportDesign;
      const Cells: TArray<TExportCellCount>; const Lines: TStrings);
    procedure ReportCellFileStatus(const Cells: TArray<TExportCellCount>;
      const Lines: TStrings; NeedGds, NeedCir: Boolean);
    procedure RefreshExportPreflight;
    procedure RunGdsExport(const OutDir, Stem: string);
    procedure RunCirExport(const OutDir, Stem: string);
    procedure RunTbConfigExport(const OutDir, Stem: string);
    function HasValidationBufferTraces: Boolean;
    function TraceLengthUm(const ATr: TRoutedTrace; Core: Double): Double;
    function IsBiasTrace(const ATr: TRoutedTrace): Boolean;
    function PathLengthUm(const Pts: TArray<TPoint>; Core: Double): Double;
    // Index of a routing-layer NAME in the router's own layer list
    // (FRouteLayers, which is what indexes FRouteObstacles) - not the UI list.
    function RouteLayerIndex(const AName: string): Integer;
    procedure BlockTrace(ATraceIdx: Integer);
    procedure UnblockTrace(ATraceIdx: Integer);
    function RerouteTrace(ATraceIdx: Integer): Boolean;
    function FindMinDelayBufferCell: TCell;
    function FindMaxDelayBufferCell: TCell;
    procedure ReapplyValidationBuffers;
    function RunBiasExpansionAndRouting: Boolean;
    function TryInsertBuffer(IsClock: Boolean; const NetName: string;
      Driver, Load: TGateInstance; const DriverPin, LoadPin: string;
      APadLoad, AIsLengthFix: Boolean;
      BufCell: TCell; const InPin, OutPin: string;
      ABand, ARowType, AX, AY: Integer): Boolean;
    function InsertBufferForTrace(ATraceIdx: Integer): Boolean;
    procedure DrawRoutedTraces(Canvas: TCanvas);
    procedure DrawResonancePulses(Canvas: TCanvas; Core, ScaleCap: Double);
    // Routing layers a pin's LEF shapes allow (bit k = FRouteLayers[k]).
    function PortLayerMask(G: TGateInstance; const PinName: string): UInt64;
    function FirstMaskLayer(Mask: UInt64): Integer;
    function GatePinBlock(G: TGateInstance; const PinName: string;
      ALayer: Integer; var P: TPoint): Boolean;
    function GatePinBlockAt(G: TGateInstance; const PinName: string;
      ALayer, AX, AY: Integer; Rotated: Boolean; var P: TPoint): Boolean;
    procedure BuildRoutingObstacles;
    // Windowed A* maze: UseLayer >= 0 pins one layer (no vias), < 0 allows all
    // layers via vias; turns cost more than straight; path/layers fill OutPath/OutLayers.
    // StartMask/GoalMask restrict the layers the two pins can be reached on.
    function LeeRoute(Start, Goal: TPoint; UseLayer: Integer;
      StartMask, GoalMask: UInt64;
      var OutPath: TArray<TPoint>; var OutLayers: TArray<Integer>): Boolean;
    procedure OrderLayer(L: Integer; CrossOnly: Boolean);
    procedure ResolvePlacementOverlaps;
    procedure OptimizePlacement;
    function ClockLimiterName: string;
    // Rebuilds the geometry (bands, bias rows/lanes, die) and puts the optimized
    // placement back. OldModel is the model the current placement was built
    // from, when FPlacementModel has already been swapped for a clone.
    procedure RebuildFloorplanPreserve(OldModel: TBlifModel = nil);
    function BandIndexOfY(Y: Integer): Integer; // band containing grid row Y
    // Bias-line current-capacity helpers. Each returns True on success; a
    // horizontal shortage is absorbed by widening the die (GrowDieWidth); any
    // remaining failure is reported via AddFloorplanError, layout unchanged.
    function GrowDieWidth(AddCols: Integer): Boolean;
    function EffectiveDieWUm: Double; // die width in use (config + growth)
    function IncreaseBiasRowHeight(Band, Which, ByRows: Integer): Boolean;
    function IncreaseClockTrunkColumn(ColIdx, ByCols: Integer): Boolean;
    function IncreaseBiasTrunkColumn(ByCols: Integer): Boolean;
    function IncreaseTopBottomBiasRow(IsTop: Boolean; ByRows: Integer): Boolean;
    procedure BuildBiasRows(MaxUa: Double; out Rows: TArray<TBiasRow>);
    function PackBiasTrunks(const Currents: TArray<Double>;
      Limit: Double): TArray<Integer>;
    function MaxUaGreaterThanLargestPort: Boolean;
    // Bias-line routing: collects a row's edge ports, partitions them into
    // current groups, and routes each group as a horizontal track to the trunk.
    procedure CollectCellPorts(G: TGateInstance; AX, AY: Integer;
      AEdge: TPortEdge; var Ports: TArray<TBiasPort>);
    function PartitionBiasPorts(const Ports: TArray<TBiasPort>;
      AMaxUa: Double): TArray<TBiasGroup>;
    // Clock bias: trunk cells are rotated 90 deg CCW, so top/bottom ports face
    // left/right; partitions group by Y (left side top-to-bottom, right reversed).
    procedure CollectTrunkPorts(IsLeft: Boolean; var Ports: TArray<TBiasPort>);
    function PartitionTrunkPorts(const Ports: TArray<TBiasPort>;
      AMaxUa: Double; Descending: Boolean): TArray<TBiasGroup>;
    procedure RouteBiasLines;
    // Geometry accessors for the variable-height bias rows (used by the
    // packing, ordering, clock-subtree and spine placements).
    function BandTopBiasH(Band: Integer): Integer;   // height of a band's top bias row
    function BandMidBiasH(Band: Integer): Integer;   // height of a band's middle bias row
    function BandLogicRowY(Band: Integer): Integer;  // top Y of a band's logic row
    function BandClockRowY(Band: Integer): Integer;  // top Y of a band's clock row
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

procedure TForm1.FreeLib;
begin
  if FPlacementModel = FModel then
    FPlacementModel := nil; // drop the non-owning alias before its target dies
  FModel.Free;
  FModel := nil;
  FLib.Free;
  FLib := nil;
end;

procedure TForm1.ResetWorkspace;
begin
  FFlowStage := fsVirgin;
  FPlacementInitialized := False;
  FPlacedComponents := nil;
  FGatePlacement.Clear;
  FLogicRowExtra := nil;
  FClockRowExtra := nil;
  FBiasRowH := nil;
  FBottomBiasH := 0;
  FBiasLaneW := nil;
  FPlanMaxRowW := 0;
  // Growth state from the previous project must not narrow this one's rows:
  // BuildFloorplan only ever raises these, never re-derives them from config.
  FPlanBiasTrunkW := 1;
  FPlanDieWExtra := 0; // run-time growth never survives a reset
  FRouteFailedLinks := 0;
  FBiasGatesSeen := 0;
  FreeAndNil(FBiasGateSet); // borrowed gate pointers die with the models
  FClockLevelSkew := nil;
  FMinClockPeriodPs := 0; // and the three limits behind it
  FMinPeriodTimingPs := 0;
  FMinPeriodSpacingPs := 0;
  FMinPeriodWindowExtraPs := 0;
  FRouteRuntimeMs := 0;
  ScrapValidationModel; // validation never survives a workspace reset
  FPlacementModel := nil;
  FRouteTraces := nil;   // the routed state dies with the circuit
  MemoRouting.Lines.Clear;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  FreeLib;
  FLefFile := '';
  FCellFolder := '';
  FBlifFile := '';
  FSplitterNames.Clear;
  FCandidateCells.Clear;
  FCellDelays.Clear;
  FFlipFlopNames.Clear;
  FFlipFlopCandidates.Clear;
  FBufferNames.Clear;
  FBufferCandidates.Clear;
  lstCells.Clear;
  ListBoxSplitters.Clear;
  ListBoxDFF.Clear;
  ListBoxBuffers.Clear;
  ListBoxSelected.Clear;
  memoNetlist.Lines.Clear;
  UpdateLimitLabels;
end;

procedure TForm1.LoadLibraryFromFile(const Path: string; AShowErrors: Boolean);
var
  Lib: TLibrary;
  Problem: string;
  i: Integer;
begin
  if not TFile.Exists(Path) then
  begin
    if AShowErrors then
      ShowMessage('LEF file not found: ' + Path);
    Exit;
  end;

  ResetWorkspace;
  FLefFile := Path;

  try
    Lib := LoadLefLibrary(FLefFile);
  except
    on E: Exception do
    begin
      if AShowErrors then
        ShowMessage('Failed to parse LEF file:' + sLineBreak + sLineBreak + E.Message);
      UpdateUI;
      Exit;
    end;
  end;

  // A file can parse and still be useless (no cells, no routing layer, no
  // ports). Refuse it here: the library page stays locked and the flow cannot
  // continue into a failure that only shows up pages later.
  Problem := LefLibraryProblem(Lib);
  if Problem <> '' then
  begin
    Lib.Free;
    if AShowErrors then
      ShowMessage('LEF library cannot be used:' + sLineBreak + sLineBreak +
        Problem + sLineBreak + sLineBreak +
        'Fix the LEF file and load it again.');
    UpdateUI;
    Exit;
  end;

  FLib := Lib;
  // Show the parsed layer stack with each layer's purpose.
  MemoLayers.Lines.BeginUpdate;
  try
    MemoLayers.Lines.Clear;
    for i := 0 to FLib.Layers.Count - 1 do
      case FLib.Layers[i].LayerType of
        ltRouting:
          MemoLayers.Lines.Add(Format('%s: routing %s, W %.1f, P %.1f, O %.1f',
            [FLib.Layers[i].Name, LowerCase(FLib.Layers[i].Direction),
             FLib.Layers[i].Width, FLib.Layers[i].Pitch,
             FLib.Layers[i].Offset]));
        ltCut:
          MemoLayers.Lines.Add(Format('%s: via cut, W %.1f',
            [FLib.Layers[i].Name, FLib.Layers[i].Width]));
        ltMasterslice:
          MemoLayers.Lines.Add(Format('%s: masterslice', [FLib.Layers[i].Name]));
        ltOverlap:
          MemoLayers.Lines.Add(Format('%s: overlap', [FLib.Layers[i].Name]));
      else
        MemoLayers.Lines.Add(FLib.Layers[i].Name);
      end;
  finally
    MemoLayers.Lines.EndUpdate;
  end;
  for i := 0 to FLib.Cells.Count - 1 do
    lstCells.Items.Add(FLib.Cells[i].Name);
  PopulateBiasLayerCombo;
  UpdateUI;
end;

procedure TForm1.SetCellFolderPath(const Path: string; AShowErrors: Boolean);
begin
  FCellFolder := Path;
  if FLib = nil then
    Exit;

  if not TDirectory.Exists(FCellFolder) then
  begin
    if AShowErrors then
      ShowMessage('Cell folder no longer exists.');
    Exit;
  end;

  FLib.FindCellSourceFiles(FCellFolder);
  UpdateUI;
end;

procedure TForm1.LoadNetlistFromFile(const Path: string; AShowErrors: Boolean);
var
  Errors: TStringList;
  Problem: string;
begin
  if FLib = nil then
    Exit;

  if not TFile.Exists(Path) then
  begin
    if AShowErrors then
      ShowMessage('BLIF file not found: ' + Path);
    Exit;
  end;

  FBlifFile := Path;
  FModel.Free; // a new BLIF file invalidates the previously parsed netlist
  FModel := nil;
  FFlowStage := fsVirgin;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  UpdateLimitLabels;
  FCellDelays.Clear;
  memoNetlist.Lines.Clear;

  Errors := TStringList.Create;
  try
    try
      FModel := ParseBlif(FBlifFile, FLib, Errors);
    except
      on E: Exception do
      begin
        if AShowErrors then
          ShowMessage('Failed to parse BLIF file:' + sLineBreak + sLineBreak + E.Message);
        UpdateUI;
        Exit;
      end;
    end;

    CheckNetConnectivity(FModel, Errors);

    ComputeClockLevels(FModel, Errors);

    // Show exactly what the parser produced, errors included.
    RenderNetlist(FModel, Errors);

    // An empty model is not a circuit: refuse it here, say why, and leave the
    // flow locked instead of letting later pages fail one by one.
    Problem := BlifModelProblem(FModel);
    if Problem <> '' then
    begin
      memoNetlist.Lines.Add('');
      memoNetlist.Lines.Add('NETLIST REJECTED: ' + Problem);
      if AShowErrors then
        ShowMessage('BLIF netlist cannot be used:' + sLineBreak + sLineBreak +
          Problem + sLineBreak + sLineBreak +
          'The netlist page shows what the parser read.');
      if FPlacementModel = FModel then
        FPlacementModel := nil;
      FModel.Free;
      FModel := nil;
      FFlowStage := fsVirgin;
      FreePipelineRows;
      FreePipelineModel;
      FreeClockModel;
      UpdateUI;
      Exit;
    end;
  finally
    Errors.Free;
  end;
  UpdateUI;
end;

// Dumps the model into the netlist memo. On the pipeline page the DFF-inserted
// model is shown, because that is what the pipeline view is built from.
procedure TForm1.RenderNetlist(Model: TBlifModel; Errors: TStrings);
var
  Dump: TStringList;
  DumpModel: TBlifModel;
  i: Integer;
  Gate: TGateInstance;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  NetName, Line: string;
begin
  if Model = nil then
    Exit;
  DumpModel := Model;
  if (TabControl1.TabIndex = TabPipeline) and (FPipelineModel <> nil) and
     (FPipelineModel <> Model) then
    DumpModel := FPipelineModel;
  Dump := TStringList.Create;
  try
    Dump.Add('Model: ' + DumpModel.Name);
    Dump.Add('');
    Dump.Add('Primary inputs: ' + DumpModel.Inputs.CommaText);
    Dump.Add('Primary outputs: ' + DumpModel.Outputs.CommaText);
    Dump.Add('');
    Dump.Add(Format('Gates (%d):', [DumpModel.Gates.Count]));
    for i := 0 to DumpModel.Gates.Count - 1 do
    begin
      Gate := DumpModel.Gates[i];
      Line := Format('  %3d. %-14s [L%d]', [i + 1, Gate.CellName, Gate.ClockLevel]);
      for Conn in Gate.Connections do
        Line := Line + Format('  %s=%s', [Conn.PinName, Conn.NetName]);
      Dump.Add(Line);
    end;
    Dump.Add('');
    Dump.Add(Format('Nets (%d):', [DumpModel.Nets.Count]));
    for NetName in DumpModel.Nets.Keys do
    begin
      Net := DumpModel.Nets[NetName];
      Line := '  ' + NetName + ':';
      for NC in Net.Connections do
        if NC.Gate = nil then
          Line := Line + '  (pad)'
        else if NC.IsDriver then
          Line := Line + Format('  drive=%s.%s', [NC.Gate.CellName, NC.PinName])
        else
          Line := Line + Format('  load=%s.%s', [NC.Gate.CellName, NC.PinName]);
      Dump.Add(Line);
    end;
    Dump.Add('');
    if (Errors <> nil) and (Errors.Count > 0) then
    begin
      Dump.Add(Format('ERRORS (%d):', [Errors.Count]));
      for i := 0 to Errors.Count - 1 do
        Dump.Add('  ' + Errors[i]);
    end
    else
      Dump.Add('No errors.');
    memoNetlist.Lines.Assign(Dump);
  finally
    Dump.Free;
  end;
end;

function TForm1.LibraryReady: Boolean;
begin
  Result := (FLib <> nil) and (FCellFolder <> '');
end;

procedure TForm1.UpdateUI;
var
  LibReady: Boolean;
  HasTwoWay: Boolean;
  i: Integer;
  Cell: TCell;
  NumOutputs: Integer;
begin
  LibReady := LibraryReady;
  btnLoadLibrary.Enabled := (FLib <> nil);
  btnLoadBlif.Enabled := (FLib <> nil);
  lstCells.Enabled := LibReady;
  MemoLayers.Enabled := LibReady;
  if LibReady then
  begin
    lstCells.Opacity := 1.0;
    MemoLayers.Opacity := 1.0;
  end
  else
  begin
    lstCells.Opacity := 0.5;
    MemoLayers.Opacity := 0.5;
  end;
  ButtonBack.Enabled := (TabControl1.TabIndex > 0);
  ButtonNext.Enabled := (FLib <> nil) and
    (TabControl1.TabIndex < TabControl1.TabCount - 1);
  if TabControl1.TabIndex = TabLibrary then
    ButtonNext.Enabled := ButtonNext.Enabled and LibReady; // LEF + library folder
  if TabControl1.TabIndex = TabComponents then
  begin
    HasTwoWay := False;
    if FLib <> nil then
      for i := 0 to FSplitterNames.Count - 1 do
      begin
        Cell := FLib.FindCell(FSplitterNames[i]);
        if (Cell <> nil) and IsSplitterCandidate(Cell, NumOutputs) and
           (NumOutputs = 2) then
        begin
          HasTwoWay := True;
          Break;
        end;
      end;
    ButtonNext.Enabled := ButtonNext.Enabled and
      (FSplitterNames.Count > 0) and HasTwoWay and
      (FFlipFlopNames.Count > 0) and (FBufferNames.Count > 0);
  end;
  if TabControl1.TabIndex = TabNetlist then
    ButtonNext.Enabled := ButtonNext.Enabled and (FModel <> nil);
  if TabControl1.TabIndex = TabClock then
    ButtonNext.Enabled := ButtonNext.Enabled and (FClockNet <> nil);
  if TabControl1.TabIndex = TabPlacement then
    ButtonNext.Enabled := ButtonNext.Enabled and FPlacementInitialized and
      (FPlacementErrorCount = 0);
  if TabControl1.TabIndex = TabFloorplan then
  begin
    // The bias expansion is a one-shot latch: enabled only once the placement
    // has been optimised and the floorplan is valid; disabled again once run.
    // Progress past the floorplan requires the expansion to have been run.
    ButtonExpandBias.Enabled := (FFlowStage >= fsPlacement) and FFloorplanValid and
      (FFlowStage < fsBias);
    ButtonNext.Enabled := ButtonNext.Enabled and
      (FFloorplanErrorCount = 0) and (FPlacementErrorCount = 0) and
      (FFlowStage >= fsBias);
  end
  else
    ButtonExpandBias.Enabled := False;
  // Routing page: validation only after routing; re-routing is locked until the
  // validation loop completes, so a new state is never routed over an unverified one.
  // Export stays unreachable until the circuit is validated, so gate Next here
  // rather than bouncing back after the click.
  if TabControl1.TabIndex = TabRouting then
    ButtonNext.Enabled := ButtonNext.Enabled and (FFlowStage >= fsValidated);
  UpdateNavButtons;
end;

{$I ConfigIO.inc}


procedure TForm1.ScrapValidationModel;
begin
  // Clock validation buffers live in the persistent buffered clock model (the
  // signal ones live on the throwaway placement clone), so take them out
  // explicitly: going back must start from the pristine clock tree.
  RemoveLengthBuffers;
  RemoveClockValidationBuffers;
  if FOwnedPlacementModel = nil then
    Exit;
  // The clone's gates are referenced by FValidationBuffers and the bias audit
  // set, so those go with it (they are meaningless once the model is gone).
  FValidationBuffers := nil;
  FreeAndNil(FBiasGateSet);
  FBiasGatesSeen := 0;
  // Restore the pristine base: validation results never travel backwards.
  FPlacementModel := FPipelineModel;
  if FPlacementModel = nil then
    FPlacementModel := FModel;
  FOwnedPlacementModel.Free;
  FOwnedPlacementModel := nil;
end;

procedure TForm1.InitWorkspaceContainers;
begin
  FSplitterNames := TStringList.Create;
  FFlipFlopNames := TStringList.Create;
  FBufferNames := TStringList.Create;
  FCandidateCells := TList<TCell>.Create;
  FFlipFlopCandidates := TList<TCell>.Create;
  FBufferCandidates := TList<TCell>.Create;
  FCellDelays := TDictionary<string, Double>.Create;
  FGatePlacement := TDictionary<TGateInstance, TPoint>.Create;
  FPadMap := TDictionary<string, TPoint>.Create;
  FRoutingLayers := TStringList.Create;
  FRoutingLayerEnabled := TDictionary<string, Boolean>.Create;
  FValidationBlocked := TStringList.Create;
  FProject := TProjectFile.Create;
  FRecent := TStringList.Create;
  FSliderTimer := TTimer.Create(Self); // owned by the form
end;

procedure TForm1.FreeWorkspaceContainers;
begin
  // Models first (they own the gates/nets the containers below borrow), then
  // the containers themselves. FSliderTimer is not freed here: it is owned by
  // the form (Create(Self)) and released with it.
  ScrapValidationModel;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  FreeLib;
  FSplitterNames.Free;
  FFlipFlopNames.Free;
  FBufferNames.Free;
  FCandidateCells.Free;
  FFlipFlopCandidates.Free;
  FBufferCandidates.Free;
  FCellDelays.Free;
  FGatePlacement.Free;
  FPadMap.Free;
  FRoutingLayers.Free;
  FRoutingLayerEnabled.Free;
  FValidationBlocked.Free;
  FProject.Free;
  FRecent.Free;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  InitWorkspaceContainers;
  lstCells.OnDblClick := lstCellsDblClick;
  ListBoxRecent.OnDblClick := ListBoxRecentDblClick;
  ListBoxSplitters.OnDblClick := ListBoxSplittersDblClick;
  ListBoxDFF.OnDblClick := ListBoxDFFDblClick;
  ListBoxBuffers.OnDblClick := ListBoxBuffersDblClick;
  ListBoxSelected.OnDblClick := ListBoxSelectedDblClick;
  // Placement configuration edits: bind live + Enter re-validation directly
  // so the page recalculates regardless of the .fmx event bindings.
  PaintBox1.OnPaint := PaintPipeline;
  PaintBox1.OnMouseDown := PaintBox1MouseDown;
  PaintBox1.OnMouseMove := PaintBox1MouseMove;
  PaintBox1.OnMouseUp := PaintBox1MouseUp;
  PaintBox2.OnPaint := PaintClockNetwork;
  PaintBox2.OnMouseDown := PaintBox2MouseDown;
  PaintBox2.OnMouseMove := PaintBox2MouseMove;
  PaintBox2.OnMouseUp := PaintBox2MouseUp;
  PaintBox3.OnPaint := PaintFloorplan;
  PaintBox3.OnMouseDown := PaintBox3MouseDown;
  PaintBox3.OnMouseMove := PaintBox3MouseMove;
  PaintBox3.OnMouseUp := PaintBox3MouseUp;
  PaintBox4.OnPaint := PaintRouting;
  PaintBox4.OnMouseDown := PaintBox4MouseDown;
  PaintBox4.OnMouseMove := PaintBox4MouseMove;
  PaintBox4.OnMouseUp := PaintBox4MouseUp;
  OnMouseWheel := FormMouseWheel;
  FZoom := 1.0;
  FClockZoom := 1.0;
  FPlanZoom := 1.0;
  FRouteZoom := 1.0;
  TabControl1.OnChange := TabControl1Change;
  TabControl1.OnChanging := TabControl1Changing;
  FSliderPos := 0;
  FSliderTimer.Interval := 200;
  FSliderTimer.Enabled := False;
  FSliderTimer.OnTimer := SliderTimerTimer;
  LoadRecentProjects(FLastProject, FRecent);
  UpdateRecentList;
  UpdateModeLabel;
  UpdateLimitLabels;
  UpdateUI;
  // Always start on the Start page; recent projects are opened explicitly.
  TabControl1.TabIndex := TabStart;
end;

procedure TForm1.FormKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  // Ctrl+S on Windows, Cmd+S on macOS. Only the explicit save actions open
  // the Save As dialog; everything else saves silently or never asks.
  if (Key = Ord('S')) and ((ssCtrl in Shift) or (ssCommand in Shift)) then
  begin
    Key := 0;
    // Ctrl/Cmd+Shift+S always writes to a new name; Ctrl/Cmd+S saves in place
    // and only asks for a name when the project has never been saved.
    if (ssShift in Shift) or (FProjectPath = '') then
      SaveProjectFileAs
    else
      SaveProjectState;
  end;
end;

procedure TForm1.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // Re-entrant close after the user confirmed (Yes/No) in the callback.
  if FAllowClose then
  begin
    CanClose := True;
    Exit;
  end;
  // A prompt is already showing; keep the window open until it resolves.
  if FClosePromptActive then
  begin
    CanClose := False;
    Exit;
  end;
  // A saved project is always up to date (auto-save), and a fresh session
  // with nothing loaded has nothing to protect: close normally.
  if (FProjectPath <> '') or (FLib = nil) then
  begin
    SaveProjectState; // persist the latest state (e.g. slider) before closing
    CanClose := True;
    Exit;
  end;
  // Unsaved work that was never written to a project file: ask asynchronously.
  FClosePromptActive := True;
  TDialogService.MessageDialog('Save the current project before closing?',
    TMsgDlgType.mtConfirmation, mbYesNoCancel, TMsgDlgBtn.mbYes, 0,
    procedure(const AResult: TModalResult)
    begin
      FClosePromptActive := False;
      case AResult of
        mrYes:
        begin
          SaveProjectFileAs;
          // Saved successfully: let the dialog fully unwind, then close.
          if FProjectPath <> '' then
          begin
            FAllowClose := True;
            TThread.ForceQueue(nil, procedure begin Close; end);
          end;
          // Save As cancelled: stay open with the work untouched.
        end;
        mrNo:
        begin
          FAllowClose := True;
          TThread.ForceQueue(nil, procedure begin Close; end);
        end;
      end;
    end);
  CanClose := False;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FreeWorkspaceContainers;
end;

procedure TForm1.btnLoadLefClick(Sender: TObject);
begin
  OpenDialog1.Filter := 'LEF files (*.lef)|*.lef|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;
  LoadLibraryFromFile(OpenDialog1.FileName);
end;

procedure TForm1.btnLoadLibraryClick(Sender: TObject);
var
  Folder: string;
begin
  if FLib = nil then
    Exit;

  Folder := FCellFolder;
  if not SelectDirectory('Select folder containing cell source files', '', Folder) then
    Exit;
  SetCellFolderPath(Folder);
end;

procedure TForm1.btnLoadBlifClick(Sender: TObject);
begin
  if FLib = nil then
    Exit;

  OpenDialog1.Filter := 'BLIF files (*.blif)|*.blif|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;
  LoadNetlistFromFile(OpenDialog1.FileName);
end;

function TForm1.IsSplitterCandidate(const Cell: TCell; out NumOutputs: Integer): Boolean;
var
  Port: TPort;
  NumInputs: Integer;
begin
  NumInputs := 0;
  NumOutputs := 0;
  for Port in Cell.Ports do
    case Port.Direction of
      pdInput: Inc(NumInputs);
      pdOutput: Inc(NumOutputs);
    end;
  Result := (NumInputs = 1) and (NumOutputs >= 2);
end;

function TForm1.CellDelayPs(const Cell: TCell): Double;
var
  Timing: TCellTiming;
  i: Integer;
begin
  if FCellDelays.TryGetValue(Cell.Name, Result) then
    Exit;
  Result := -1;
  for i := 0 to Cell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(Cell.SourceFiles[i]), '.v') then
    begin
      Timing := ParseVerilogTiming(Cell.SourceFiles[i]);
      if Timing <> nil then
      begin
        Result := Timing.OutputDelayPs;
        Timing.Free;
        Break;
      end;
    end;
  FCellDelays.AddOrSetValue(Cell.Name, Result);
end;

function TForm1.DelayTextPs(const Delay: Double): string;
begin
  if Delay < 0 then
    Result := 'no timing'
  else
    Result := Format('%.1f ps', [Delay]);
end;

procedure TForm1.RefreshSelectedList;
var
  i: Integer;
  Cell: TCell;
  Delay: Double;
  Item: TListBoxItem;
begin
  ListBoxSelected.Clear;
  if FLib = nil then
    Exit;

  // Splitters (green).
  for i := 0 to FSplitterNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FSplitterNames[i]);
    if Cell = nil then
      Continue;
    Delay := CellDelayPs(Cell);
    Item := TListBoxItem.Create(ListBoxSelected);
    Item.Parent := ListBoxSelected;
    Item.Text := Format('%s (%s)', [Cell.Name, DelayTextPs(Delay)]);
    Item.TagString := Cell.Name;
    Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
    Item.TextSettings.FontColor := PalGreen;
  end;

  // Flip-flops (red).
  for i := 0 to FFlipFlopNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FFlipFlopNames[i]);
    if Cell = nil then
      Continue;
    Delay := CellDelayPs(Cell);
    Item := TListBoxItem.Create(ListBoxSelected);
    Item.Parent := ListBoxSelected;
    Item.Text := Format('%s (%s)', [Cell.Name, DelayTextPs(Delay)]);
    Item.TagString := Cell.Name;
    Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
    Item.TextSettings.FontColor := PalRedDeep;
  end;

  // Buffers (light blue).
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if Cell = nil then
      Continue;
    Delay := CellDelayPs(Cell);
    Item := TListBoxItem.Create(ListBoxSelected);
    Item.Parent := ListBoxSelected;
    Item.Text := Format('%s (%s)', [Cell.Name, DelayTextPs(Delay)]);
    Item.TagString := Cell.Name;
    Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
    Item.TextSettings.FontColor := PalBlueLight;
  end;
end;

procedure TForm1.PopulateSelectionTab;
var
  i: Integer;
  Cell: TCell;
  NumOutputs: Integer;
  ClockPin, DataPin, OutputPin, InPin, OutPin: string;
  Delay: Double;
begin
  // Possible splitters (already-selected ones are excluded).
  ListBoxSplitters.Clear;
  FCandidateCells.Clear;
  if FLib <> nil then
    for i := 0 to FLib.Cells.Count - 1 do
    begin
      Cell := FLib.Cells[i];
      if not IsSplitterCandidate(Cell, NumOutputs) then
        Continue;
      if FSplitterNames.IndexOf(Cell.Name) >= 0 then
        Continue;
      Delay := CellDelayPs(Cell);
      ListBoxSplitters.Items.Add(Format('%s (%d-way, %s)',
        [Cell.Name, NumOutputs, DelayTextPs(Delay)]));
      FCandidateCells.Add(Cell);
    end;
  if ListBoxSplitters.Items.Count = 0 then
    ListBoxSplitters.Items.Add('(no splitter cells: need 1 input, 2+ outputs)');

  // Possible flip-flops. Only a single FF type is supported, so once one is
  // selected the list is exhausted.
  ListBoxDFF.Clear;
  FFlipFlopCandidates.Clear;
  if FFlipFlopNames.Count >= 1 then
    ListBoxDFF.Items.Add('(one flip-flop already selected)')
  else if FLib <> nil then
    for i := 0 to FLib.Cells.Count - 1 do
    begin
      Cell := FLib.Cells[i];
      if not IsFlipFlopCandidate(Cell, ClockPin, DataPin, OutputPin) then
        Continue;
      Delay := CellDelayPs(Cell);
      ListBoxDFF.Items.Add(Format('%s (%s)',
        [Cell.Name, DelayTextPs(Delay)]));
      FFlipFlopCandidates.Add(Cell);
    end;
  if ListBoxDFF.Items.Count = 0 then
    ListBoxDFF.Items.Add('(no flip-flop cells)');

  // Possible buffers (already-selected ones are excluded).
  ListBoxBuffers.Clear;
  FBufferCandidates.Clear;
  if FLib <> nil then
    for i := 0 to FLib.Cells.Count - 1 do
    begin
      Cell := FLib.Cells[i];
      if not IsBufferCandidate(Cell, InPin, OutPin) then
        Continue;
      if FBufferNames.IndexOf(Cell.Name) >= 0 then
        Continue;
      Delay := CellDelayPs(Cell);
      ListBoxBuffers.Items.Add(Format('%s (%s)',
        [Cell.Name, DelayTextPs(Delay)]));
      FBufferCandidates.Add(Cell);
    end;
  if ListBoxBuffers.Items.Count = 0 then
    ListBoxBuffers.Items.Add('(no buffer cells)');

  RefreshSelectedList;
end;

procedure TForm1.RemoveSelection(const AName: string);
var
  Idx: Integer;
begin
  Idx := FSplitterNames.IndexOf(AName);
  if Idx >= 0 then
    FSplitterNames.Delete(Idx)
  else
  begin
    Idx := FFlipFlopNames.IndexOf(AName);
    if Idx >= 0 then
      FFlipFlopNames.Delete(Idx)
    else
    begin
      Idx := FBufferNames.IndexOf(AName);
      if Idx >= 0 then
        FBufferNames.Delete(Idx);
    end;
  end;
end;

procedure TForm1.ListBoxSplittersDblClick(Sender: TObject);
var
  Cell: TCell;
begin
  if (ListBoxSplitters.ItemIndex < 0) or
     (ListBoxSplitters.ItemIndex >= FCandidateCells.Count) then
    Exit;
  Cell := FCandidateCells[ListBoxSplitters.ItemIndex];
  if FSplitterNames.IndexOf(Cell.Name) < 0 then
    FSplitterNames.Add(Cell.Name);
  PopulateSelectionTab;
  UpdateUI;
end;

procedure TForm1.ListBoxDFFDblClick(Sender: TObject);
var
  Cell: TCell;
begin
  if (ListBoxDFF.ItemIndex < 0) or
     (ListBoxDFF.ItemIndex >= FFlipFlopCandidates.Count) then
    Exit;
  // Insertion supports a single flip-flop type; only the first is accepted.
  if FFlipFlopNames.Count >= 1 then
    Exit;
  Cell := FFlipFlopCandidates[ListBoxDFF.ItemIndex];
  FFlipFlopNames.Add(Cell.Name);
  PopulateSelectionTab;
  UpdateUI;
end;

procedure TForm1.ListBoxBuffersDblClick(Sender: TObject);
var
  Cell: TCell;
begin
  if (ListBoxBuffers.ItemIndex < 0) or
     (ListBoxBuffers.ItemIndex >= FBufferCandidates.Count) then
    Exit;
  Cell := FBufferCandidates[ListBoxBuffers.ItemIndex];
  if FBufferNames.IndexOf(Cell.Name) < 0 then
    FBufferNames.Add(Cell.Name);
  PopulateSelectionTab;
  UpdateUI;
end;

procedure TForm1.ListBoxSelectedDblClick(Sender: TObject);
var
  Item: TListBoxItem;
begin
  if ListBoxSelected.ItemIndex < 0 then
    Exit;
  Item := ListBoxSelected.ItemByIndex(ListBoxSelected.ItemIndex);
  if Item = nil then
    Exit;
  RemoveSelection(Item.TagString);
  PopulateSelectionTab;
  UpdateUI;
end;

{$I Pipeline.inc}


procedure TForm1.PaintBox1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  if Button = TMouseButton.mbLeft then
  begin
    FDragging := True;
    FDragX := X;
    FDragY := Y;
  end;
end;

procedure TForm1.PaintBox1MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FDragging then
  begin
    FPanX := FPanX + (X - FDragX);
    FPanY := FPanY + (Y - FDragY);
    FDragX := X;
    FDragY := Y;
    RepaintPipelinePage;
  end;
end;

procedure TForm1.PaintBox1MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FDragging := False;
end;

procedure TForm1.PaintBox2MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  if Button = TMouseButton.mbLeft then
  begin
    FClkDragging := True;
    FClkDragX := X;
    FClkDragY := Y;
  end;
end;

procedure TForm1.PaintBox2MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FClkDragging then
  begin
    FClockPanX := FClockPanX + (X - FClkDragX);
    FClockPanY := FClockPanY + (Y - FClkDragY);
    FClkDragX := X;
    FClkDragY := Y;
    RepaintClockPage;
  end;
end;

procedure TForm1.PaintBox2MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FClkDragging := False;
end;

procedure TForm1.PaintBox3MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
var
  i, BlockX, BlockY: Integer;
begin
  if Button = TMouseButton.mbLeft then
  begin
    // Try to grab a pad cell first; otherwise pan the floorplan.
    if FPlanZoom > 0 then
    begin
      BlockX := Trunc((X - FPlanPanX) / FPlanZoom / FPlanCore);
      BlockY := Trunc((Y - FPlanPanY) / FPlanZoom / FPlanCore);
      for i := 0 to High(FPads) do
        if (i <> FClockPadIdx) and
           (BlockX = FPads[i].X) and (BlockY = FPads[i].Y) then
        begin
          FPadDragging := True;
          FPadDragIdx := i;
          FPadDragX := (X - FPlanPanX) / FPlanZoom / FPlanCore;
          RepaintFloorplanPage;
          Exit;
        end;
    end;
    FPlanDragging := True;
    FPlanDragX := X;
    FPlanDragY := Y;
  end;
end;

procedure TForm1.PaintBox3MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
var
  BlockX: Single;
begin
  if FPadDragging then
  begin
    BlockX := (X - FPlanPanX) / FPlanZoom / FPlanCore;
    if BlockX < FPlanXLeft then
      BlockX := FPlanXLeft;
    if BlockX > FPlanXRight - 1 then
      BlockX := FPlanXRight - 1;
    FPadDragX := BlockX;
    RepaintFloorplanPage;
  end
  else if FPlanDragging then
  begin
    FPlanPanX := FPlanPanX + (X - FPlanDragX);
    FPlanPanY := FPlanPanY + (Y - FPlanDragY);
    FPlanDragX := X;
    FPlanDragY := Y;
    RepaintFloorplanPage;
  end;
end;

procedure TForm1.PaintBox3MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
var
  N, Slot: Integer;
begin
  if FPadDragging then
  begin
    // Snap to the nearest slot and commit the new order (persists across
    // optimize, since only the pad-order arrays are changed).
    if FPads[FPadDragIdx].IsInput then
    begin
      N := Length(FPadOrderInput);
      Slot := NearestPadSlot(FPadDragX, N, FPlanXRight);
      FPadOrderInput := PreviewPadOrder(FPadOrderInput, FPadDragIdx, Slot);
    end
    else
    begin
      N := Length(FPadOrderOutput);
      Slot := NearestPadSlot(FPadDragX, N, OutputPadRight);
      FPadOrderOutput := PreviewPadOrder(FPadOrderOutput, FPadDragIdx, Slot);
    end;
    ReapplyPadOrder;
    FPadDragging := False;
    RepaintFloorplanPage;
  end;
  FPlanDragging := False;
end;

// Band index containing grid row Y, using the stored per-band starts/heights.
// Returns -1 if Y is outside every band (e.g. a pad or routing row).
{$I Placement.inc}


{$I FloorPlan.inc}


{$I Routing.inc}
{$I ClockValidate.inc}
{$I FinalChecks.inc}
{$I ExportMetrics.inc}


procedure TForm1.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
var
  MinZ, MaxZ: Single;

  // Zoom around the cursor position; returns True if the zoom changed.
  function ZoomAt(ABox: TControl; var APanX, APanY, AZoom: Single;
    AMinZoom, AMaxZoom: Single): Boolean;
  var
    LocalPos, WorldPos: TPointF;
    R: TRectF;
    NewZoom: Single;
  begin
    Result := False;
    LocalPos := ABox.ScreenToLocal(Screen.MousePos);
    R := TRectF.Create(0, 0, ABox.Width, ABox.Height);
    if not R.Contains(LocalPos) then
      Exit;
    NewZoom := AZoom * Power(1.1, WheelDelta / 120.0);
    if NewZoom < AMinZoom then
      NewZoom := AMinZoom;
    if NewZoom > AMaxZoom then
      NewZoom := AMaxZoom;
    if NewZoom = AZoom then
      Exit;
    WorldPos.X := (LocalPos.X - APanX) / AZoom;
    WorldPos.Y := (LocalPos.Y - APanY) / AZoom;
    APanX := LocalPos.X - WorldPos.X * NewZoom;
    APanY := LocalPos.Y - WorldPos.Y * NewZoom;
    AZoom := NewZoom;
    Result := True;
  end;

begin
  Handled := False;
  RefreshDesignConfig;
  if TabControl1.TabIndex = TabPipeline then
  begin
    if ZoomAt(PaintBox1, FPanX, FPanY, FZoom, 0.2, 5.0) then
    begin
      Handled := True;
      RepaintPipelinePage;
    end;
  end
  else if TabControl1.TabIndex = TabClock then
  begin
    if ZoomAt(PaintBox2, FClockPanX, FClockPanY, FClockZoom, 0.2, 5.0) then
    begin
      Handled := True;
      RepaintClockPage;
    end;
  end
  else if TabControl1.TabIndex = TabFloorplan then
  begin
    // Zoom-out limit fits the whole die (keyed on the larger die dimension);
    // zoom-in limit makes a single core block about as large as the canvas.
    MinZ := 0.01;
    MaxZ := 5.0;
    if (FDesignConfig.CoreUm > 0) and (FDesignConfig.DieWUm > 0) and
       (FDesignConfig.DieHUm > 0) and (PaintBox3.Height > 20) then
    begin
      MinZ := (Min(PaintBox3.Width, PaintBox3.Height) - 20) / Max(EffectiveDieWUm, FDesignConfig.DieHUm);
      MaxZ := (Max(PaintBox3.Width, PaintBox3.Height) - 20) / FDesignConfig.CoreUm;
      if MinZ < 0.01 then
        MinZ := 0.01;
      if MaxZ < MinZ then
        MaxZ := MinZ;
    end;
    if ZoomAt(PaintBox3, FPlanPanX, FPlanPanY, FPlanZoom, MinZ, MaxZ) then
    begin
      Handled := True;
      RepaintFloorplanPage;
    end;
  end
  else if TabControl1.TabIndex = TabRouting then
  begin
    // Zoom-out limit fits the whole die; zoom-in makes a block fill the canvas.
    MinZ := 0.01;
    MaxZ := 5.0;
    if (FDesignConfig.CoreUm > 0) and (FDesignConfig.DieWUm > 0) and
       (FDesignConfig.DieHUm > 0) and (PaintBox4.Height > 20) then
    begin
      MinZ := (Min(PaintBox4.Width, PaintBox4.Height) - 20) / Max(EffectiveDieWUm, FDesignConfig.DieHUm);
      MaxZ := (Max(PaintBox4.Width, PaintBox4.Height) - 20) / FDesignConfig.CoreUm;
      if MinZ < 0.01 then
        MinZ := 0.01;
      if MaxZ < MinZ then
        MaxZ := MinZ;
    end;
    if ZoomAt(PaintBox4, FRoutePanX, FRoutePanY, FRouteZoom, MinZ, MaxZ) then
    begin
      Handled := True;
      RepaintRoutingPage;
    end;
  end;
end;


{$I ClockPage.inc}
{$I PageHelp.inc}


// Routing (and the validation that runs with it) owns the workspace while it
// runs: leaving would scrap the traces it is building.
procedure TForm1.TabControl1Changing(Sender: TObject; var AllowChange: Boolean);
begin
  if FRoutingBusy then
  begin
    AllowChange := False;
    MemoRouting.Lines.Add('[routing] still running - wait for it to finish before ' +
      'leaving this page.');
  end;
end;

procedure TForm1.TabControl1Change(Sender: TObject);
begin
  UpdateNavButtons;
  // The Routing page state belongs to the circuit routed there; navigating back
  // discards it so a re-placed circuit never shows or validates against stale traces.
  if TabControl1.TabIndex < TabRouting then
  begin
    ScrapValidationModel;
    FRouteTraces := nil;
    MemoRouting.Lines.Clear;
  end;
  // Re-entrancy guard: bouncing back from the Routing tab to the Floorplan tab
  // re-fires this handler; the Floorplan branch below does the rebuild.
  if FSwitchingTab then
    Exit;
  // Nothing past the library page is reachable until that page is complete: a
  // LEF that failed to load (or loaded unusable) leaves FLib nil, and every
  // later page would only fail. Bounce back to the library page instead.
  if (TabControl1.TabIndex > TabLibrary) and (not LibraryReady) then
  begin
    FSwitchingTab := True;
    try
      TabControl1.TabIndex := TabLibrary;
    finally
      FSwitchingTab := False;
    end;
    UpdateUI;
    Exit;
  end;
  // ... and the netlist page must produce a usable model before the pipeline and
  // later pages are reachable (an empty BLIF leaves FModel nil).
  if (TabControl1.TabIndex > TabNetlist) and (FModel = nil) then
  begin
    FSwitchingTab := True;
    try
      TabControl1.TabIndex := TabNetlist;
    finally
      FSwitchingTab := False;
    end;
    UpdateUI;
    Exit;
  end;
  // The Routing tab is only reachable after the placement has been optimised
  // AND the bias lines expanded, with no placement or floorplan errors. Reject
  // the switch and bounce back to the Floorplan tab otherwise.
  if (TabControl1.TabIndex = TabRouting) and
     not ((FFlowStage >= fsBias) and
          (FFloorplanErrorCount = 0) and (FPlacementErrorCount = 0)) then
  begin
    FSwitchingTab := True;
    try
      TabControl1.TabIndex := TabFloorplan;
    finally
      FSwitchingTab := False;
    end;
    UpdateUI;
    Exit;
  end;
  if TabControl1.TabIndex = TabComponents then
  begin
    SubTabControl.TabIndex := 0; // default to the Splitters sub-tab
    PopulateSelectionTab;
  end;
  if TabControl1.TabIndex = TabPlacement then
  begin
    // The GCD/mode derivation runs once (per library); re-entry only
    // re-validates the current field values.
    if not FPlacementInitialized then
      InitializePlacementConfig
    else
      ValidatePlacement;
  end;
  if TabControl1.TabIndex = TabFloorplan then
  begin
    // Opening the tab must not reshuffle an optimised/expanded placement.
    if FFlowStage >= fsPlacement then
      RebuildFloorplanPreserve
    else
      BuildFloorplan;
  end;
  if TabControl1.TabIndex = TabRouting then
  begin
    FRoutePanX := 0;
    FRoutePanY := 0;
    FRouteZoom := 1.0;
    FRouteNeedsFit := True;
    BuildRoutingLayers;
    RepaintRoutingPage;
  end;
  if TabControl1.TabIndex = TabExport then
  begin
    // Export is the final page: it needs a validated circuit. Bounce back to
    // the Routing page otherwise.
    if FFlowStage < fsValidated then
    begin
      FSwitchingTab := True;
      try
        TabControl1.TabIndex := TabRouting;
      finally
        FSwitchingTab := False;
      end;
      UpdateUI;
      Exit;
    end;
    RefreshExportPreflight;
  end;
  if TabControl1.TabIndex = TabPipeline then
  begin
    FPanX := 0;
    FPanY := 0;
    FZoom := 1.0;
    // Prerequisite: splitter insertion must have run on this netlist.
    if (FModel <> nil) and (FFlowStage < fsSplitters) then
      RunSplitterInsertion;
    // Keep the thumb at the restored position without re-triggering a build.
    FSliderUpdating := True;
    try
      if Round(TrackBar1.Value) <> FSliderPos then
        TrackBar1.Value := FSliderPos;
    finally
      FSliderUpdating := False;
    end;
    BuildPipelineModel;
    UpdateModeLabel;
    UpdateLimitLabels;
    RepaintPipelinePage;
    // The netlist memo follows the model the page works on (DFF-inserted).
    RenderNetlist(FModel, nil);
  end;
  if TabControl1.TabIndex = TabClock then
  begin
    // Clock stage: always rebuild from the current DFF-inserted netlist.
    FClockPanX := 0;
    FClockPanY := 0;
    FClockZoom := 1.0;
    // Prerequisites: splitters inserted, then the pipeline (DFF-inserted)
    // model built - the clock view is derived from it.
    if (FModel <> nil) and (FFlowStage < fsSplitters) then
      RunSplitterInsertion;
    if FPipelineModel = nil then
    begin
      BuildPipelineModel;
      UpdateModeLabel;
      UpdateLimitLabels;
    end;
    BuildClockModel;
    RepaintClockPage;
  end;
  UpdateUI;
end;

procedure TForm1.RunSplitterInsertion;
var
  SplitterTypes: TArray<TSplitterType>;
  i: Integer;
  Cell: TCell;
  NumOutputs: Integer;
  Delay: Double;
  Errors: TStringList;
begin
  if FModel = nil then
  begin
    ShowMessage('Parse a BLIF netlist first.');
    Exit;
  end;
  if FSplitterNames.Count = 0 then
  begin
    ShowMessage('Select at least one splitter cell first.');
    Exit;
  end;

  SetLength(SplitterTypes, FSplitterNames.Count);
  for i := 0 to FSplitterNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FSplitterNames[i]);
    if Cell = nil then
    begin
      ShowMessage(Format('Splitter cell "%s" is no longer in the library.',
        [FSplitterNames[i]]));
      Exit;
    end;
    if not IsSplitterCandidate(Cell, NumOutputs) then
    begin
      ShowMessage(Format('Cell "%s" is not a valid splitter (need 1 input, 2+ outputs).',
        [Cell.Name]));
      Exit;
    end;
    Delay := CellDelayPs(Cell);
    if Delay < 0 then
    begin
      ShowMessage(Format('No timing found for splitter cell "%s" - run "Load Library" first so its .v file is found.',
        [Cell.Name]));
      Exit;
    end;
    SplitterTypes[i].CellName := Cell.Name;
    SplitterTypes[i].OutputCount := NumOutputs;
    SplitterTypes[i].DelayPs := Delay;
  end;

  InsertSplitters(FModel, FLib, SplitterTypes);
  // Zero inserted is still a valid outcome - nothing required splitting -
  // so allow moving on just as if splitters had been added.
  if FFlowStage < fsSplitters then FFlowStage := fsSplitters;

  Errors := TStringList.Create;
  try
    ComputeClockLevels(FModel, Errors);
  finally
    Errors.Free;
  end;
  UpdateUI;
end;

procedure TForm1.lstCellsDblClick(Sender: TObject);
var
  Cell: TCell;
  Viewer: TCellViewerForm;
begin
  if FLib = nil then Exit;
  if (lstCells.ItemIndex < 0) or (lstCells.ItemIndex >= FLib.Cells.Count) then
    Exit;
  Cell := FLib.Cells[lstCells.ItemIndex];
  Viewer := TCellViewerForm.Create(nil);
  Viewer.SetCell(Cell);
  Viewer.Show;
end;

procedure TForm1.ButtonBackClick(Sender: TObject);
begin
  if FRoutingBusy then
    Exit;
  if TabControl1.TabIndex > 0 then
    TabControl1.TabIndex := TabControl1.TabIndex - 1;
  UpdateUI;
end;

procedure TForm1.ButtonNextClick(Sender: TObject);
begin
  if FRoutingBusy then
    Exit;
  // Leaving the BLIF tab runs the splitter insertion automatically.
  if (TabControl1.TabIndex = TabNetlist) and (FFlowStage < fsSplitters) then
    RunSplitterInsertion;
  if TabControl1.TabIndex < TabControl1.TabCount - 1 then
    TabControl1.TabIndex := TabControl1.TabIndex + 1;
  UpdateUI;
end;

procedure TForm1.ButtonRunRoutingClick(Sender: TObject);
var
  SW: TStopwatch;
begin
  if FRoutingBusy then
    Exit;
  if FBiasExpansionFailed then
  begin
    // The bias rows are under-sized; routing would spill into neighbouring rows.
    MemoRouting.Lines.Add('[bias] routing blocked: the bias lines do not fit the die. ' +
      'Increase the die size or reduce the bias current, then expand the bias lines again.');
    Exit;
  end;
  FRoutingBusy := True;
  try
    // Routing always starts from the pristine model: a committed validation
    // clone (with its buffers) is never what the router works on.
    ScrapValidationModel;
    // Validation-inserted extra rows go away, but never the placement itself:
    // once the user has optimised (and bias-expanded) the rows, routing rebuilds
    // the geometry only. Re-packing here would discard the layout they approved
    // and re-optimise from the sequential starting positions.
    FLogicRowExtra := nil;
    FClockRowExtra := nil;
    if FFlowStage >= fsPlacement then
      RebuildFloorplanPreserve
    else
    begin
      BuildFloorplan;
      if FFloorplanErrorCount = 0 then
        OptimizePlacement;
    end;
    // Maze route: all nets on the first layer, then the next layer for the
    // failures, ... then a via pass. Reports its own per-layer progress.
    SW := TStopwatch.StartNew;
    RunRouting;
    // Bias lines: always routable programmatically, run after the main circuit
    // routing so the floorplan is settled. Each partition group becomes one track.
    RouteBiasLines;
    // Report the route time even when the route failed: the number is what the
    // user compares between runs.
    MemoRouting.Lines.Add(Format('Routing time: %.2f s.',
      [SW.Elapsed.TotalSeconds]));
    // Routing and validation are one action now: validate immediately when the
    // route completed cleanly (RunRouting only advances the stage on success).
    if FFlowStage >= fsRouted then
      RunRoutingValidation;
    // The reported route time covers the whole action, validation included.
    FRouteRuntimeMs := SW.ElapsedMilliseconds;
    // Total from the start of the action (not just the validation slice).
    MemoRouting.Lines.Add(Format('Total time (routing + validation): %.2f s.',
      [SW.Elapsed.TotalSeconds]));
    MemoRouting.Lines.Add(
      'Bias lines routed from the partition groups.');
    // Validation-inserted buffers (ClockLevel -1, so BuildFloorplan skips them)
    // must be re-applied to the layout after the rebuild.
    ReapplyValidationBuffers;
    UpdateUI;
  finally
    FRoutingBusy := False;
  end;
end;

// Prints the per-kind instance tally (runs / bends / via composites / splits /
// cells / track) into Lines.
procedure TForm1.AppendScanTally(const D: TExportDesign;
  const Cells: TArray<TExportCellCount>; const Lines: TStrings);
var
  RunKey, BendKey, ViaKey, SplitKey: TDictionary<string, Int64>;
  Tot: Int64;
  i: Integer;
  s: string;
  V: TExportViaBlock;
begin
  RunKey := TDictionary<string, Int64>.Create;
  BendKey := TDictionary<string, Int64>.Create;
  ViaKey := TDictionary<string, Int64>.Create;
  SplitKey := TDictionary<string, Int64>.Create;
  try
    for i := 0 to High(D.Runs) do
    begin
      if D.Runs[i].Family = xfPtl then
        s := 'PTL ' + D.Runs[i].Layer
      else
        s := 'BIAS ' + D.Runs[i].Layer;
      if RunKey.ContainsKey(s) then
        Tot := RunKey[s]
      else
        Tot := 0;
      RunKey.AddOrSetValue(s, Tot + D.Runs[i].Count);
    end;
    for i := 0 to High(D.Bends) do
    begin
      if D.Bends[i].Family = xfPtl then
        s := 'PTL ' + D.Bends[i].Layer
      else
        s := 'BIAS ' + D.Bends[i].Layer;
      if BendKey.ContainsKey(s) then
        Tot := BendKey[s]
      else
        Tot := 0;
      BendKey.AddOrSetValue(s, Tot + 1);
    end;
    for i := 0 to High(D.ViaBlocks) do
    begin
      V := D.ViaBlocks[i];
      s := V.LoLayer + '_' + V.HiLayer;
      case V.Kind of
        vkViaBend:
          if V.Variant > 0 then
            s := s + ' BENDN'
          else
            s := s + ' BENDS';
        vkViaTurn: s := s + ' TURN';
      else
        s := s + ' STRAIGHT';
      end;
      if ViaKey.ContainsKey(s) then
        Tot := ViaKey[s]
      else
        Tot := 0;
      ViaKey.AddOrSetValue(s, Tot + 1);
    end;
    for i := 0 to High(D.Splits) do
    begin
      s := 'BIAS ' + D.Splits[i].Layer + ' ' + IntToStr(D.Splits[i].ConnCount) + 'conn';
      if SplitKey.ContainsKey(s) then
        Tot := SplitKey[s]
      else
        Tot := 0;
      SplitKey.AddOrSetValue(s, Tot + 1);
    end;

    Lines.Add(Format('runs=%d bends=%d viaBlocks=%d splits=%d terminals=%d',
      [Length(D.Runs), Length(D.Bends), Length(D.ViaBlocks), Length(D.Splits),
       Length(D.Terminals)]));
    for s in RunKey.Keys do
      Lines.Add('  run     ' + s + ' = ' + IntToStr(RunKey[s]) + ' blocks');
    for s in BendKey.Keys do
      Lines.Add('  bend    ' + s + ' = ' + IntToStr(BendKey[s]));
    for s in ViaKey.Keys do
      Lines.Add('  ptl+via ' + s + ' = ' + IntToStr(ViaKey[s]));
    for s in SplitKey.Keys do
      Lines.Add('  split   ' + s + ' = ' + IntToStr(SplitKey[s]));
    for i := 0 to High(Cells) do
      Lines.Add('  cell    ' + Cells[i].Name + ' = ' + IntToStr(Cells[i].Count));
    Lines.Add('  track   TRK (ground/track tile) = always required');
  finally
    RunKey.Free;
    BendKey.Free;
    ViaKey.Free;
    SplitKey.Free;
  end;
end;

// Reports which block kinds the design needs and whether a configured library
// covers them (Phase 2 verification; the import UI arrives later).
procedure TForm1.ReportLibraryCoverage(const D: TExportDesign;
  const Cells: TArray<TExportCellCount>; const Lines: TStrings);
var
  Kinds: TList<string>;
  Lib: TExportLibrary;
  BlockRoot, ManifestPath, KindsText: string;
  Pitch: Double;
  NeedGds, NeedCir: Boolean;
  i: Integer;
  MissingTally: Integer;
  Missing, Errors: TStringList;
  k: string;
begin
  Kinds := TList<string>.Create;
  Lib := TExportLibrary.Create;
  Missing := TStringList.Create;
  Errors := TStringList.Create;
  // Per-format preflight: only the export types the user selected are required,
  // so missing files for the other types never block the chosen export.
  NeedGds := CheckExportGds.IsChecked;
  NeedCir := CheckExportCir.IsChecked;
  try
    CollectDesignKinds(D, Kinds);
    FExportMissingKinds := Kinds.Count;
    Lines.Add('  blocks  required kinds = ' + IntToStr(Kinds.Count));
    KindsText := '';
    for k in Kinds do
      KindsText := KindsText + k + ', ';
    Lines.Add('    ' + Copy(KindsText, 1, Length(KindsText) - 2));
    BlockRoot := '';
    if FBlockLibDir <> '' then
      BlockRoot := FBlockLibDir
    else if TDirectory.Exists(TPath.Combine(GetCurrentDir, 'blocklib')) then
      BlockRoot := TPath.Combine(GetCurrentDir, 'blocklib');
    if BlockRoot <> '' then
      ManifestPath := TPath.Combine(BlockRoot, 'manifest.json');
    Pitch := FDesignConfig.CoreUm;
    if Pitch <= 0 then
      Pitch := FPlanCore;
    if (ManifestPath <> '') and TFile.Exists(ManifestPath) then
    begin
      Lib.LoadFile(ManifestPath);
      MissingTally := 0;
      for k in Kinds do
      begin
        if not Lib.Find(k) then
        begin
          Missing.Add(k);
          Inc(MissingTally);
        end
        else if not CheckBlockTriple(BlockRoot, Lib.Blocks[k], Errors,
          NeedGds, NeedCir and KindNeedsCir(k)) then
          Missing.Add(k + ' (triple FAIL)');
      end;
      FExportMissingKinds := Missing.Count;
      Lines.Add(Format('  library %s: %d kinds loaded; %d needed, %d missing/failed',
        [ManifestPath, Lib.BlockCount, Kinds.Count, Missing.Count]));
      Lines.Add(Format('  checking: GDS=%s CIR=%s',
        [BoolToStr(NeedGds, True), BoolToStr(NeedCir, True)]));
      for i := 0 to Missing.Count - 1 do
        Lines.Add('    missing ' + Missing[i]);
      if Missing.Count > 0 then
        Lines.Add('    -> "Import a prepared library" or fill these next.');
      for i := 0 to Errors.Count - 1 do
        Lines.Add('      ! ' + Errors[i]);
      // Merge scaffolding for the kinds the manifest is missing (never touch the
      // entries the user has already filled in).
      if MissingTally > 0 then
      begin
        WriteManifestTemplate(ManifestPath, Pitch, Kinds);
        Lines.Add('    -> added scaffolding for the missing kinds to ' + ManifestPath);
      end;
    end
    else
    begin
      // No library yet: write a ready-to-fill manifest, so the user only supplies
      // real sizes/pins and drops the block files.
      if BlockRoot = '' then
        BlockRoot := TPath.Combine(GetCurrentDir, 'blocklib');
      TDirectory.CreateDirectory(BlockRoot);
      ManifestPath := TPath.Combine(BlockRoot, 'manifest.json');
      WriteManifestTemplate(ManifestPath, Pitch, Kinds);
      Lines.Add('  no block library; wrote template manifest to ' + ManifestPath);
      Lines.Add('    fill sizeUm/pins per block, drop the .gds/.lef/.cir files next to it, then re-validate.');
    end;
  finally
    Errors.Free;
    Missing.Free;
    Lib.Free;
    Kinds.Free;
  end;
end;

// Cells resolve their layout/schematic from the already-parsed design library,
// not from the block-library manifest: each cell's SourceFiles (filled by
// FindCellSourceFiles) must include a .gds and a .cir; the LEF macro is derived
// from the parsed cell (single library LEF), so only GDS/CIR are checked here.
procedure TForm1.ReportCellFileStatus(const Cells: TArray<TExportCellCount>;
  const Lines: TStrings; NeedGds, NeedCir: Boolean);
var
  Cell: TCell;
  i, j: Integer;
  HasGds, HasCir: Boolean;
begin
  if FLib = nil then
    Exit;
  for i := 0 to High(Cells) do
  begin
    Cell := FLib.FindCell(Cells[i].Name);
    if Cell = nil then
    begin
      Lines.Add('  ! cell ' + Cells[i].Name + ': not found in the library.');
      Continue;
    end;
    HasGds := False;
    HasCir := False;
    for j := 0 to Cell.SourceFiles.Count - 1 do
    begin
      if SameText(ExtractFileExt(Cell.SourceFiles[j]), '.gds') then
        HasGds := True;
      if SameText(ExtractFileExt(Cell.SourceFiles[j]), '.cir') then
        HasCir := True;
    end;
    if (not HasGds) and NeedGds then
      Lines.Add('  ! cell ' + Cells[i].Name + ': missing .gds source in the cell folder.');
    if (not HasCir) and NeedCir then
      Lines.Add('  ! cell ' + Cells[i].Name + ': missing .cir source in the cell folder.');
  end;
end;

// Clocking summary for the export page: the fastest clock the timing analysis
// allows, the target set in the placement settings, and the depth of the clock
// tree.
procedure TForm1.AppendClockSummary(const Lines: TStrings);
var
  MaxGHz, TargetGHz: Double;
  Levels: Integer;
begin
  if FClockNet = nil then
  begin
    Lines.Add('Clocking: no clock network built yet.');
    Exit;
  end;
  // One clock level per row tree, so this is the number of clock subtrees and
  // the depth of the pipeline (not the stage delays between the levels).
  Levels := FClockNet.Rows.Count;
  TargetGHz := FDesignConfig.FreqGHz;
  MaxGHz := 0;
  if FMinClockPeriodPs > 0 then
    MaxGHz := 1000.0 / FMinClockPeriodPs; // ps period -> GHz
  if MaxGHz > 0 then
  begin
    Lines.Add(Format('Clocking: max %.2f GHz (%.1f ps period), ' +
      'target %.2f GHz, %d pipeline level(s).',
      [MaxGHz, FMinClockPeriodPs, TargetGHz, Levels]));
    Lines.Add(Format('  Period limits: data path %.1f ps, input spacing %.1f ps, ' +
      'input window +%.1f ps -> limited by %s.',
      [FMinPeriodTimingPs, FMinPeriodSpacingPs, FMinPeriodWindowExtraPs,
       ClockLimiterName]));
  end
  else
    Lines.Add(Format('Clocking: max unknown (validation not run), ' +
      'target %.2f GHz, %d pipeline level(s).',
      [TargetGHz, Levels]));
  if FInputWindowFound then
  begin
    Lines.Add(Format('Input window, tightest (%.1f ps period): %.1f to %.1f ps from ' +
      'when the first clock edge is sent (includes one initial clock period for cell ' +
      'reset; t = 0 at the pad, not its arrival at the cells); later batches are one ' +
      'period apart.',
      [FMinClockPeriodPs, FInputWindowStartPs, FInputWindowEndPs]));
    if FInputWindowTargetFound then
      Lines.Add(Format('Input window, target %.2f GHz (%.1f ps period): %.1f to %.1f ps ' +
        'from when the first clock edge is sent (includes one initial clock period).',
        [TargetGHz, 1000.0 / TargetGHz, FInputWindowTargetStartPs,
         FInputWindowTargetEndPs]));
  end;
  if FOutputTravelFound then
    Lines.Add(Format('Output start: the earliest output reaches a pad %.1f ps after ' +
      'the clock edge is sent (clock tree, final logic layer and interconnect). ' +
      'Add the clock send offset and levels x period to get the time to start ' +
      'sampling the outputs.', [FOutputTravelPs]));
  if (MaxGHz > 0) and (TargetGHz > MaxGHz) then
    Lines.Add(Format('WARNING: target %.2f GHz is faster than the achievable max ' +
      '%.2f GHz - the circuit cannot be clocked at the requested speed.',
      [TargetGHz, MaxGHz]));
end;

// Recomputes the export preflight: routed-instance coverage (missing kinds /
// triple-check failures) and the placed-cell file status. Runs when entering
// the Export tab or on Recheck.
procedure TForm1.RefreshExportPreflight;
var
  D: TExportDesign;
  Cells: TArray<TExportCellCount>;
  Names: TList<string>;
  Gate: TGateInstance;
begin
  if FBlockLibDir <> '' then
    EditBlockLibDir.Text := FBlockLibDir;
  MemoExportStatus.Lines.Clear;
  MemoExportLog.Lines.Clear;
  if (FLib = nil) or ((Length(FRouteTraces) = 0) and (Length(FBiasCells) = 0)) then
  begin
    MemoExportStatus.Lines.Add('No routed circuit to export yet - run through the pipeline.');
    ButtonExport.Enabled := False;
    Exit;
  end;
  MemoExportStatus.Lines.Add('-- Export readiness --');
  ExportScanAll(FRouteTraces, FBiasCells, FRouteLayers, D);
  Names := TList<string>.Create;
  try
    if FPlacementModel <> nil then
      for Gate in FPlacementModel.Gates do
        if Gate <> nil then
          Names.Add(Gate.CellName);
    ExportScanCells(Names.ToArray, Cells);
  finally
    Names.Free;
  end;
  AppendScanTally(D, Cells, MemoExportStatus.Lines);
  ReportLibraryCoverage(D, Cells, MemoExportStatus.Lines);
  ReportCellFileStatus(Cells, MemoExportStatus.Lines,
    CheckExportGds.IsChecked, CheckExportCir.IsChecked);
  MemoExportStatus.Lines.Add('');
  AppendClockSummary(MemoExportStatus.Lines);
  ButtonExport.Enabled := FFlowStage >= fsValidated;
  if FFlowStage < fsValidated then
    MemoExportStatus.Lines.Add('~ Run Routing first - Export is locked until then.');
end;

procedure TForm1.ButtonBrowseLibClick(Sender: TObject);
var
  d: string;
begin
  d := FBlockLibDir;
  if SelectDirectory('Block library (PDK) folder', '', d) then
  begin
    FBlockLibDir := d;
    EditBlockLibDir.Text := d;
    RefreshExportPreflight;
  end;
end;

procedure TForm1.ButtonPreflightClick(Sender: TObject);
begin
  RefreshExportPreflight;
end;

procedure TForm1.ButtonExportClick(Sender: TObject);
begin
  RefreshExportPreflight;
  if FFlowStage < fsValidated then
  begin
    MemoExportLog.Lines.Add('Export locked: run Routing first.');
    Exit;
  end;
  if FExportMissingKinds > 0 then
  begin
    MemoExportLog.Lines.Add(Format(
      'Export blocked: %d block kind(s) missing or unverified (see the status memo).',
      [FExportMissingKinds]));
    Exit;
  end;
  MemoExportLog.Lines.Add('Export ready - all block kinds present and verified.');
  if CheckExportGds.IsChecked then
    RunGdsExport(EditExportDir.Text, EditExportStem.Text);
  if CheckExportCir.IsChecked then
    RunCirExport(EditExportDir.Text, EditExportStem.Text);
  if CheckExportMetrics.IsChecked then
    RunMetricsExport(EditExportDir.Text, EditExportStem.Text);
  if (not CheckExportGds.IsChecked) and (not CheckExportCir.IsChecked) and
     (not CheckExportMetrics.IsChecked) then
    MemoExportLog.Lines.Add('No output format selected - tick .gds/.cir/.stats first.');
end;

// Phase 4 (GDS): builds the write_die_gds.py placement recipe from the routed
// instances + placed cells and runs the gdstk script to write <Stem>.gds into
// OutDir. Bends are placed rot-0 for now (their rotation refinement is a later
// slice, as is full track/ground tiling).
procedure TForm1.RunGdsExport(const OutDir, Stem: string);
var
  D: TExportDesign;
  Lib: TExportLibrary;
  Kinds: TList<string>;
  Sources: TArray<string>;
  Instances: TArray<TGDSInstance>;
  BlockRoot: string;
  Core, DieWUm, DieHUm: Double;
  i, j, n: Integer;
  Ent: TExportBlockEntry;
  Ins: TGDSInstance;
  R: TExportRun;
  BU: TExportBend;
  V: TExportViaBlock;
  Sp: TExportSplit;
  Tm: TExportTerminal;
  P: TPlacedComponent;
  Mb: TPoint;
  Node: TPlacedClockNode;
  Spine: TSpineComponent;
  Cell: TCell;
  CellH: Double;
  kk: Integer;
  DieWb, DieHb, gx, gy, run0, f0, fx0: Integer;
  SrcSeen: TDictionary<string, Boolean>;
  CellOcc: TArray<Boolean>;
  LayerOcc: TDictionary<Int64, TDictionary<string, Boolean>>;
  Lst: TDictionary<string, Boolean>;
  Key: Int64;
  Ly: string;
  Recipe, RecipePath, ErrPath, OutPath, ErrMsg: string;
  ExitCode: Integer;

begin
  BlockRoot := '';
  if FBlockLibDir <> '' then
    BlockRoot := FBlockLibDir
  else if TDirectory.Exists(TPath.Combine(GetCurrentDir, 'blocklib')) then
    BlockRoot := TPath.Combine(GetCurrentDir, 'blocklib');
  Lib := TExportLibrary.Create;
  Kinds := TList<string>.Create;
  try
    if (BlockRoot <> '') and
       TFile.Exists(TPath.Combine(BlockRoot, 'manifest.json')) then
      Lib.LoadFile(TPath.Combine(BlockRoot, 'manifest.json'));

    ExportScanAll(FRouteTraces, FBiasCells, FRouteLayers, D);
    CollectDesignKinds(D, Kinds);

    Core := FDesignConfig.CoreUm;
    if Core <= 0 then
      Core := FPlanCore;
    DieWUm := EffectiveDieWUm;
    DieHUm := FDesignConfig.DieHUm;
    if (DieWUm <= 0) or (DieHUm <= 0) then
    begin
      DieWUm := FFloorplanW * Core;
      DieHUm := FFloorplanH * Core;
    end;

    // Sources: the block library cells for the used kinds, then the placed
    // cells' own GDS (resolved from the parsed library).
    for j := 0 to Kinds.Count - 1 do
      if Lib.GetBlock(Kinds[j], Ent) then
      begin
        n := Length(Sources);
        SetLength(Sources, n + 1);
        if Ent.GdsFile <> '' then
          Sources[n] := TPath.Combine(BlockRoot, Ent.GdsFile)
        else
          Sources[n] := TPath.Combine(BlockRoot, Ent.Name + '.gds');
      end;

    // Instances: runs (unit tile arrayed along the run), bends (rot 0 for now),
    // via composites, bias splits, and the placed cells.
    for i := 0 to High(D.Runs) do
    begin
      R := D.Runs[i];
      if R.Dir = xdH then
        Ins := GdsArrayed(
          KindDefaultName(KindRun(R.Family, R.Layer, R.Taps)), R.X0 * Core, R.Y0 * Core, 0,
          R.Count, 1, Core, 0)
      else
        Ins := GdsArrayed(
          KindDefaultName(KindRun(R.Family, R.Layer, R.Taps)), R.X0 * Core, R.Y0 * Core, 90,
          1, R.Count, 0, Core);
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    for i := 0 to High(D.Bends) do
    begin
      BU := D.Bends[i];
      Ins := GdsSingle(
        KindDefaultName(KindBend(BU.Family, BU.Layer, BU.Taps)), BU.X * Core, BU.Y * Core);
      // Rotate the authored corner (canonical W+S) onto this turn's two
      // neighbour directions. Data direction is irrelevant - just the geometry.
      Ins.RotDeg := 90 * NodeRotation(
        DirBitOf(-BU.InX, -BU.InY) or DirBitOf(BU.OutX, BU.OutY));
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    for i := 0 to High(D.ViaBlocks) do
    begin
      V := D.ViaBlocks[i];
      Ins := GdsSingle(
        KindDefaultName(KindVia(V.LoLayer, V.HiLayer, V.Kind, V.Variant)),
        V.X * Core, V.Y * Core);
      Ins.RotDeg := V.RotDeg;
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    for i := 0 to High(D.Splits) do
    begin
      Sp := D.Splits[i];
      Ins := GdsSingle(
        KindDefaultName(KindSplit(Sp.Layer, Sp.ConnCount, Sp.Taps)), Sp.X * Core, Sp.Y * Core);
      Ins.RotDeg := 90 * NodeRotation(Sp.Dirs);
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    // Every line endpoint (deg-1 cell) gets a cap block whose single stub points
    // at the wire, rotated to face its neighbour. The bias trunk is the exception:
    // it ends in the top row heading straight up out of the die, and a cap would
    // close the line at the cell edge. Emit a straight bias tile there (same
    // orientation as a vertical bias run) so the metal runs to the boundary.
    for i := 0 to High(D.Terminals) do
    begin
      Tm := D.Terminals[i];
      if (Tm.Family = xfBias) and (Tm.Y = 0) then
      begin
        Ins := GdsSingle(KindDefaultName(KindRun(xfBias, Tm.Layer, '')),
          Tm.X * Core, Tm.Y * Core);
        Ins.RotDeg := 90;
      end
      else
      begin
        Ins := GdsSingle(
          KindDefaultName(KindCap(Tm.Family, Tm.Layer, Tm.Taps)), Tm.X * Core, Tm.Y * Core);
        Ins.RotDeg := 90 * NodeRotation(Tm.Dirs);
      end;
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    for i := 0 to High(FPlacedComponents) do
    begin
      P := FPlacedComponents[i];
      if P.CellName = '' then
        Continue;
      Ins := GdsSingle(P.CellName, P.X * Core, P.Y * Core);
      // Cells are referenced by their EXACT GDS file (their in-file name may
      // carry a version suffix), not by an assumed cell name.
      Cell := FLib.FindCell(P.CellName);
      if Cell <> nil then
        for j := 0 to Cell.SourceFiles.Count - 1 do
          if SameText(ExtractFileExt(Cell.SourceFiles[j]), '.gds') then
          begin
            Ins.SrcFile := Cell.SourceFiles[j];
            Break;
          end;
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    // Length-fixing buffers: they live behind the placement mask (only in
    // FGatePlacement), so they are not in FPlacedComponents.
    for i := 0 to High(FLengthBuffers) do
    begin
      if (FLengthBuffers[i].Gate = nil) or
         (FLengthBuffers[i].Gate.CellName = '') then
        Continue;
      if not FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, Mb) then
        Continue;
      Ins := GdsSingle(FLengthBuffers[i].Gate.CellName, Mb.X * Core, Mb.Y * Core);
      Cell := FLib.FindCell(FLengthBuffers[i].Gate.CellName);
      if Cell <> nil then
        for j := 0 to Cell.SourceFiles.Count - 1 do
          if SameText(ExtractFileExt(Cell.SourceFiles[j]), '.gds') then
          begin
            Ins.SrcFile := Cell.SourceFiles[j];
            Break;
          end;
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;
    // Clock-tree interior cells (splitters/buffers), placed unrotated like the
    // logic cells; the clock leaves are real gates already in FPlacedComponents.
    for i := 0 to High(FClockSubtree) do
      for j := 0 to High(FClockSubtree[i]) do
      begin
        Node := FClockSubtree[i][j];
        if Node.IsLeaf or (Node.Gate = nil) or (Node.Gate.CellName = '') then
          Continue;
        Ins := GdsSingle(Node.Gate.CellName, Node.X * Core, Node.Y * Core);
        Cell := FLib.FindCell(Node.Gate.CellName);
        if Cell <> nil then
          for kk := 0 to Cell.SourceFiles.Count - 1 do
            if SameText(ExtractFileExt(Cell.SourceFiles[kk]), '.gds') then
            begin
              Ins.SrcFile := Cell.SourceFiles[kk];
              Break;
            end;
        n := Length(Instances);
        SetLength(Instances, n + 1);
        Instances[n] := Ins;
      end;
    // Clock trunk (spine) cells. Rotated trunk cells use the routing page's
    // exact transform (local (x,y) -> canvas (CellH - y, x), i.e. a 90 deg
    // rotation plus reflection about the cell origin); unrotated overflow
    // buffers are placed like logic cells.
    for i := 0 to High(FSpine) do
    begin
      Spine := FSpine[i];
      if (Spine.Gate = nil) or (Spine.Gate.CellName = '') then
        Continue;
      if Spine.Rotated and (Spine.Gate.Cell <> nil) then
      begin
        CellH := Spine.Gate.Cell.Height;
        Ins := GdsSingle(Spine.Gate.CellName,
          Spine.X * Core + CellH, DieHUm - Spine.Y * Core);
        Ins.RotDeg := -90;
        Ins.Mirror := True;
      end
      else
        Ins := GdsSingle(Spine.Gate.CellName, Spine.X * Core, Spine.Y * Core);
      Cell := FLib.FindCell(Spine.Gate.CellName);
      if Cell <> nil then
        for j := 0 to Cell.SourceFiles.Count - 1 do
          if SameText(ExtractFileExt(Cell.SourceFiles[j]), '.gds') then
          begin
            Ins.SrcFile := Cell.SourceFiles[j];
            Break;
          end;
      n := Length(Instances);
      SetLength(Instances, n + 1);
      Instances[n] := Ins;
    end;

    // ---- Track / fill layer ----
    // Every grid block without a cell gets a TRACK_TILE. Then, for each layer in
    // the TRACK block's if_unused list, any track block that carries no geometry
    // on that layer (no bias line, PTL or via pair) also gets the fill shape.
    // Tiles/fills cover the whole die, no further.
    if Lib.GetBlock(AlwaysRequiredKind, Ent) and (Core > 0) and
       (FFloorplanW > 0) and (FFloorplanH > 0) then
    begin
      DieWb := FFloorplanW;
      DieHb := FFloorplanH;
      SetLength(CellOcc, DieWb * DieHb);
      for i := 0 to High(FPlacedComponents) do
        for gy := FPlacedComponents[i].Y to FPlacedComponents[i].Y + FPlacedComponents[i].H - 1 do
          for gx := FPlacedComponents[i].X to FPlacedComponents[i].X + FPlacedComponents[i].W - 1 do
            if (gx >= 0) and (gx < DieWb) and (gy >= 0) and (gy < DieHb) then
              CellOcc[gy * DieWb + gx] := True;
      for i := 0 to High(FClockSubtree) do
        for j := 0 to High(FClockSubtree[i]) do
          if not FClockSubtree[i][j].IsLeaf then
            for gy := FClockSubtree[i][j].Y to FClockSubtree[i][j].Y + FClockSubtree[i][j].H - 1 do
              for gx := FClockSubtree[i][j].X to FClockSubtree[i][j].X + FClockSubtree[i][j].W - 1 do
                if (gx >= 0) and (gx < DieWb) and (gy >= 0) and (gy < DieHb) then
                  CellOcc[gy * DieWb + gx] := True;
      for i := 0 to High(FLengthBuffers) do
        if (FLengthBuffers[i].Gate <> nil) and
           FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, Mb) then
          for gy := Mb.Y to Mb.Y + FLengthBuffers[i].H - 1 do
            for gx := Mb.X to Mb.X + FLengthBuffers[i].W - 1 do
              if (gx >= 0) and (gx < DieWb) and (gy >= 0) and (gy < DieHb) then
                CellOcc[gy * DieWb + gx] := True;
      for i := 0 to High(FSpine) do
        for gy := FSpine[i].Y to FSpine[i].Y + FSpine[i].H - 1 do
          for gx := FSpine[i].X to FSpine[i].X + FSpine[i].W - 1 do
            if (gx >= 0) and (gx < DieWb) and (gy >= 0) and (gy < DieHb) then
              CellOcc[gy * DieWb + gx] := True;

      // Per-block set of layers that already carry geometry.
      LayerOcc := TDictionary<Int64, TDictionary<string, Boolean>>.Create;
      try
        for i := 0 to High(D.Runs) do
          for kk := 0 to D.Runs[i].Count - 1 do
          begin
            if D.Runs[i].Dir = xdH then
            begin
              gx := D.Runs[i].X0 + kk;
              gy := D.Runs[i].Y0;
            end
            else
            begin
              gx := D.Runs[i].X0;
              gy := D.Runs[i].Y0 + kk;
            end;
            Key := Int64(gy) * DieWb + gx;
            if not LayerOcc.TryGetValue(Key, Lst) then
            begin
              Lst := TDictionary<string, Boolean>.Create;
              LayerOcc.Add(Key, Lst);
            end;
            Lst.AddOrSetValue(D.Runs[i].Layer, True);
          end;
        for i := 0 to High(D.Bends) do
        begin
          Key := Int64(D.Bends[i].Y) * DieWb + D.Bends[i].X;
          if not LayerOcc.TryGetValue(Key, Lst) then
          begin
            Lst := TDictionary<string, Boolean>.Create;
            LayerOcc.Add(Key, Lst);
          end;
          Lst.AddOrSetValue(D.Bends[i].Layer, True);
        end;
        for i := 0 to High(D.ViaBlocks) do
        begin
          Key := Int64(D.ViaBlocks[i].Y) * DieWb + D.ViaBlocks[i].X;
          if not LayerOcc.TryGetValue(Key, Lst) then
          begin
            Lst := TDictionary<string, Boolean>.Create;
            LayerOcc.Add(Key, Lst);
          end;
          Lst.AddOrSetValue(D.ViaBlocks[i].LoLayer, True);
          Lst.AddOrSetValue(D.ViaBlocks[i].HiLayer, True);
        end;
        for i := 0 to High(D.Splits) do
        begin
          Key := Int64(D.Splits[i].Y) * DieWb + D.Splits[i].X;
          if not LayerOcc.TryGetValue(Key, Lst) then
          begin
            Lst := TDictionary<string, Boolean>.Create;
            LayerOcc.Add(Key, Lst);
          end;
          Lst.AddOrSetValue(D.Splits[i].Layer, True);
        end;
        // Terminators carry metal too: the bias trunk's top end is a straight bias
        // tile and a cap is a line endpoint. Every terminal block counts as
        // occupied on its own layer, otherwise the per-layer fill is laid over it.
        for i := 0 to High(D.Terminals) do
        begin
          Key := Int64(D.Terminals[i].Y) * DieWb + D.Terminals[i].X;
          if not LayerOcc.TryGetValue(Key, Lst) then
          begin
            Lst := TDictionary<string, Boolean>.Create;
            LayerOcc.Add(Key, Lst);
          end;
          Lst.AddOrSetValue(D.Terminals[i].Layer, True);
        end;

        // Emit track tiles (and fills) as horizontal runs, row by row.
        for gy := 0 to DieHb - 1 do
        begin
          gx := 0;
          while gx < DieWb do
          begin
            if CellOcc[gy * DieWb + gx] then
            begin
              Inc(gx);
              Continue;
            end;
            run0 := gx;
            while (gx < DieWb) and (not CellOcc[gy * DieWb + gx]) do
              Inc(gx);
            Ins := GdsArrayed(KindDefaultName(AlwaysRequiredKind),
              run0 * Core, gy * Core, 0, gx - run0, 1, Core, 0);
            n := Length(Instances);
            SetLength(Instances, n + 1);
            Instances[n] := Ins;
            // Fills: the if_unused layers absent from each block of this run.
            for kk := 0 to High(Ent.IfUnused) do
            begin
              if Ent.IfUnused[kk].Gds = '' then
                Continue;
              Ly := Ent.IfUnused[kk].Layer;
              fx0 := run0;
              while fx0 < gx do
              begin
                if LayerOcc.TryGetValue(Int64(gy) * DieWb + fx0, Lst) and
                   Lst.ContainsKey(Ly) then
                begin
                  Inc(fx0);
                  Continue;
                end;
                // f0, not run0: run0 is the whole tile run and the next
                // if_unused layer has to start from its beginning, not from
                // where this layer's last fill sub-run began.
                f0 := fx0;
                while (fx0 < gx) and
                      (not (LayerOcc.TryGetValue(Int64(gy) * DieWb + fx0, Lst) and
                            Lst.ContainsKey(Ly))) do
                  Inc(fx0);
                Ins := GdsArrayed('', f0 * Core, gy * Core, 0, fx0 - f0, 1, Core, 0);
                Ins.Cell := ChangeFileExt(ExtractFileName(Ent.IfUnused[kk].Gds), '');
                Ins.SrcFile := TPath.Combine(BlockRoot, Ent.IfUnused[kk].Gds);
                n := Length(Instances);
                SetLength(Instances, n + 1);
                Instances[n] := Ins;
              end;
            end;
          end;
        end;
      finally
        for Lst in LayerOcc.Values do
          Lst.Free;
        LayerOcc.Free;
      end;
    end;

    // Every referenced cell GDS must be in the sources (logic, clock-tree and
    // spine cells each carry their exact file); add them once, deduplicated.
    SrcSeen := TDictionary<string, Boolean>.Create;
    try
      for i := 0 to High(Sources) do
        SrcSeen.AddOrSetValue(LowerCase(Sources[i]), True);
      for i := 0 to High(Instances) do
        if (Instances[i].SrcFile <> '') and
           (not SrcSeen.ContainsKey(LowerCase(Instances[i].SrcFile))) then
        begin
          SrcSeen.AddOrSetValue(LowerCase(Instances[i].SrcFile), True);
          n := Length(Sources);
          SetLength(Sources, n + 1);
          Sources[n] := Instances[i].SrcFile;
        end;
    finally
      SrcSeen.Free;
    end;

    TDirectory.CreateDirectory(OutDir);
    OutPath := TPath.Combine(OutDir, Stem + '.gds');
    RecipePath := TPath.Combine(TPath.GetTempPath,
      'pnr_die_' + IntToStr(TThread.GetTickCount) + '.json');
    ErrPath := ChangeFileExt(RecipePath, '.err');
    Recipe := BuildDieRecipe(DieWUm, DieHUm, Core, Sources, Instances, OutPath, 0);
    TFile.WriteAllText(RecipePath, Recipe);
    // Keep the recipe next to the output for inspection/debugging.
    TFile.WriteAllText(TPath.Combine(OutDir, Stem + '.recipe.json'), Recipe);
    MemoExportLog.Lines.Add(Format('GDS: %d instances, %d sources -> %s',
      [Length(Instances), Length(Sources), OutPath]));
    MemoExportLog.Lines.Add('  recipe: ' + TPath.Combine(OutDir, Stem + '.recipe.json'));
    ExitCode := UPython.RunPythonScript('write_die_gds.py',
      '"' + RecipePath + '"', ErrPath, ErrMsg);
    if ExitCode = 0 then
      MemoExportLog.Lines.Add('GDS written OK.')
    else
      MemoExportLog.Lines.Add('GDS FAILED: ' + ErrMsg);
  finally
    Kinds.Free;
    Lib.Free;
  end;
end;


// Exports a flat SPICE netlist: .include lines for the block-library and placed
// cell subckt files, one X-instance per placed cell with its pins bound to their
// netlist nets, and the bias trunk as a supply source. Structural TRACK blocks
// and the per-tile PTL/via geometry are omitted (the cells carry the function).
// Exports a flat SPICE netlist: .include lines for the block-library and placed
// cell subckt files, one X-instance per placed cell (pins bound to their nets)
// and per routed PTL/VIA block, chained by shared nodes. The bias family has no
// circuit equivalent and is omitted; caps terminate each PTL run.
// Phase 6 (CIR): writes <Stem>.cir. The netlist construction lives in ExportCIR
// (form-free, mirroring ExportGDS); here we only gather the design snapshot and
// write the file.
procedure TForm1.RunCirExport(const OutDir, Stem: string);
var
  Lib: TExportLibrary;
  ClockModel: TBlifModel;
  BlockRoot, OutPath, CirText: string;
begin
  BlockRoot := '';
  if FBlockLibDir <> '' then
    BlockRoot := FBlockLibDir
  else if TDirectory.Exists(TPath.Combine(GetCurrentDir, 'blocklib')) then
    BlockRoot := TPath.Combine(GetCurrentDir, 'blocklib');
  Lib := TExportLibrary.Create;
  try
    if (BlockRoot <> '') and
       TFile.Exists(TPath.Combine(BlockRoot, 'manifest.json')) then
      Lib.LoadFile(TPath.Combine(BlockRoot, 'manifest.json'));
    // The clock subtree/spine cells are placed from the buffered clone
    // (FClockBufferedModel), so the clock-tree route endpoints must be bound
    // against that model - FClockModel would not match the placed gates.
    ClockModel := FClockBufferedModel;
    if ClockModel = nil then
      ClockModel := FClockModel;
    CirText := ExportCIR.BuildCirText(FRouteTraces, FBiasCells, FRouteLayers,
      FPlacedComponents, FClockSubtree, FSpine, FLengthBuffers,
      FPlacementModel, ClockModel, Lib, BlockRoot, Stem);
    TDirectory.CreateDirectory(OutDir);
    OutPath := TPath.Combine(OutDir, Stem + '.cir');
    TFile.WriteAllText(OutPath, CirText);
    MemoExportLog.Lines.Add(Format('CIR: %d cells + PTL/via blocks -> %s',
      [Length(FPlacedComponents), OutPath]));
    RunTbConfigExport(OutDir, Stem);
  finally
    Lib.Free;
  end;
end;

// Writes <Stem>.tb.json next to the netlist: the clock net, the input/output
// nets and the design numbers (clock frequency, PTL delay, pitch, die size) the
// Python test-bench tools read.
procedure TForm1.RunTbConfigExport(const OutDir, Stem: string);
var
  ClockNet: string;
  Ins, Outs: TArray<string>;
  i, Levels: Integer;
begin
  ClockNet := '';
  if (FClockPadIdx >= 0) and (FClockPadIdx <= High(FPads)) then
    ClockNet := FPads[FClockPadIdx].NetName
  else if FClockNet <> nil then
    ClockNet := FClockNet.SourceNet;
  SetLength(Ins, 0);
  SetLength(Outs, 0);
  for i := 0 to High(FPads) do
  begin
    if (i = FClockPadIdx) or (FPads[i].NetName = '') then
      Continue;
    if FPads[i].IsInput then
    begin
      SetLength(Ins, Length(Ins) + 1);
      Ins[High(Ins)] := FPads[i].NetName;
    end
    else
    begin
      SetLength(Outs, Length(Outs) + 1);
      Outs[High(Outs)] := FPads[i].NetName;
    end;
  end;
  Levels := 0;
  if FClockNet <> nil then
    Levels := FClockNet.Rows.Count;
  TDirectory.CreateDirectory(OutDir);
  TFile.WriteAllText(TPath.Combine(OutDir, Stem + '.tb.json'),
    ExportCIR.BuildTbJson(Stem, ClockNet, Ins, Outs,
      // The field is entered in fs/um, so export the same number the user set.
      FDesignConfig.FreqGHz, FDesignConfig.PtlDelayPsPerUm * 1000,
      FDesignConfig.CoreUm, FDesignConfig.DieWUm, FDesignConfig.DieHUm,
      FDesignConfig.MaxPtlLengthUm, FMinClockPeriodPs,
      FInputWindowFound, FInputWindowStartPs, FInputWindowEndPs,
      FInputWindowTargetStartPs, FInputWindowTargetEndPs,
      FOutputTravelFound, FOutputTravelPs, Levels));
  MemoExportLog.Lines.Add(Format('TB config: %d in / %d out, clock "%s".',
    [Length(Ins), Length(Outs), ClockNet]));
  AppendClockSummary(MemoExportLog.Lines);
end;




end.

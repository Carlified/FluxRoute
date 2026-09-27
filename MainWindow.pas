unit MainWindow;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.ListBox, FMX.Memo, FMX.Layouts, FMX.TabControl,
  FMX.Objects, FMX.Edit,
  System.IOUtils, System.JSON, System.Math, System.Math.Vectors,
  System.Generics.Collections, System.StrUtils,
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

type
  // One block of the floorplanning grid (for future maze routing).
  // The _Fill kinds mark space extended out to the row extremities after the
  // allocated width (drawn lighter; the allocated/fill split is not stored
  // beyond these kinds).
  TFloorplanCell = (fcEmpty, fcLogic, fcClock, fcBias, fcLogicFill, fcClockFill);

  // A placed logic component: its grid cell inside the floorplan.
  TPlacedComponent = record
    Gate: TGateInstance;
    InstanceName: string;
    CellName: string;
    ClockLevel: Integer;
    X, Y: Integer; // top-left grid cell of the component
    W, H: Integer; // component size in grid cells (cell width/height / core)
  end;

  // One power port of a placed cell on a given edge, in grid coordinates. Used
  // to partition the row's bias demand into groups and to route the bias lines.
  TBiasPort = record
    Gate: TGateInstance;
    Edge: TPortEdge; // peTop or peBottom
    X, Y: Integer;   // port grid block (the offshoot connects here)
    CurrentUa: Double;
  end;

  // One partition of a channel's side: the ports it contains (left to right)
  // plus the total current it must carry.
  TBiasGroup = record
    Ports: TArray<TBiasPort>; // the group's ports, in placement order
    TotalUa: Double;
  end;

  // Immobile I/O anchor: an external input/output net pinned to a grid block
  // at the top/bottom of the die. Used to anchor the barycentre relaxation so
  // the layout cannot float freely.
  TPadConnection = record
    NetName: string;
    X, Y: Integer; // grid cell (single block, for now)
    IsInput: Boolean;
  end;

// One placed clock-tree cell: a real splitter/buffer (interior) or a clocked
  // leaf. Children index the containing layer's node array.
  TPlacedClockNode = record
    Gate: TGateInstance;
    IsLeaf: Boolean;
    X, Y: Integer; // top-left grid cell
    W, H: Integer; // real cell footprint in grid cells
    Band: Integer; // layer-band this node is placed in (interior nodes)
    Children: TArray<Integer>;
  end;

  // One placed spine (clock trunk) component: a junction splitter or a stage
  // buffer. Trunk cells are rotated 90 deg CCW (the cell top faces the bias
  // line), so the placed footprint swaps width and height (W = cell height,
  // H = cell width). Overflow buffers lie on a band's clock row, unrotated.
  TSpineComponent = record
    Gate: TGateInstance;
    IsJunction: Boolean;
    X, Y: Integer; // top-left grid cell
    W, H: Integer; // placed footprint
    Rotated: Boolean;
    Band: Integer; // -1 = in the trunk; else the overflow band index
  end;

  // One routed trace: the net it belongs to and the grid blocks (cell centres)
// it passes through, in order. Layers holds the routing-layer name for each
// point (via crossings change the layer between consecutive points).
  TRoutedTrace = record
    NetName: string;
    Points: TArray<TPoint>;
    Layers: TArray<string>;
  end;

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
    StartValid, GoalValid: Boolean;
    Routed: Boolean;
    Path: TArray<TPoint>;
    PathLayers: TArray<Integer>;
  end;
  TRouteJobArray = TArray<TRouteJob>;

// A buffer the routing validation has inserted to break up an over-long PTL.
// The gate lives in the placement model (signal PTLs) or the clock model (clock
// links); the slot records where it must sit so it can be re-applied after the
// floorplan rebuilds.
  TValidationBuffer = record
    Gate: TGateInstance;
    NetName: string;
    IsClock: Boolean; // True if inserted into a clock link (clock model)
    Band: Integer;    // band the buffer sits in (-1 for the clock trunk)
    RowType: Integer; // 0 = logic row, 1 = clock row, 2 = clock trunk
    X: Integer;       // top-left X in grid cells
    Y: Integer;       // top-left Y in grid cells (absolute; trunk uses it directly)
  end;

// Snapshot of a placed cell's horizontal position relative to its row, used to
// preserve the optimized placement when the bias lines are expanded (the
// geometry rebuild must not reshuffle the cells horizontally).
  TPlaceSnapshot = record
    Gate: TGateInstance;
    X: Integer; // X offset from the row's left edge at snapshot time
  end;

  TForm1 = class(TForm)
    TabControl1: TTabControl;
    LabelStartTitle: TLabel;
    LabelStartHint: TLabel;
    ButtonNewProject: TButton;
    ButtonOpenProject: TButton;
    LabelRecent: TLabel;
    ListBoxRecent: TListBox;
    TabItem1: TTabItem;
    WelcomeLabel: TLabel;
    Button1: TButton;
    TabItem2: TTabItem;
    Button3: TButton;
    ListBox1: TListBox;
    MemoLayers: TMemo;
    Label1: TLabel;
    Button5: TButton;
    Memo1: TMemo;
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
    EditPTLLength: TEdit;
    EditFreqGHz: TEdit;
    EditPTLDelay: TEdit;
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
    Label8: TLabel;
    PaintBox2: TPaintBox;
    PaintBox3: TPaintBox;
    ButtonOptimize: TButton;
    ButtonExpandBias: TButton;
    CheckBoxShowNames: TCheckBox;
    CheckBoxShowLogicWires: TCheckBox;
    CheckBoxShowClockWires: TCheckBox;
    CheckBoxShowFloorplan: TCheckBox;
    CheckBoxShowCells: TCheckBox;
    ListBoxFloorplanErrors: TListBox;
    SplitterErrors: TSplitter;
    ButtonRunRouting: TButton;
    MemoRouting: TMemo;
    ButtonValidateRouting: TButton;
    SplitterRouting: TSplitter;
    PaintBox4: TPaintBox;
    ButtonBack: TButton;
    ButtonNext: TButton;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
    procedure Button1Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure ListBox1DblClick(Sender: TObject);
    procedure ListBoxSplittersDblClick(Sender: TObject);
    procedure ListBoxDFFDblClick(Sender: TObject);
    procedure ListBoxBuffersDblClick(Sender: TObject);
    procedure ListBoxSelectedDblClick(Sender: TObject);
    procedure TabControl1Change(Sender: TObject);
    procedure TrackBar1Change(Sender: TObject);
    procedure ButtonBackClick(Sender: TObject);
    procedure ButtonNextClick(Sender: TObject);
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
    procedure ButtonRunRoutingClick(Sender: TObject);
    procedure ButtonValidateRoutingClick(Sender: TObject);
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
    FSplittersInserted: Boolean;
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
    FRoutingSucceeded: Boolean;  // routing completed with zero failed links
    FRoutingValidated: Boolean;  // the routing validation loop has run to completion
    FRouteLengthColor: Boolean;  // trace colouring: length scale vs layer colour
    FValidationBuffers: TArray<TValidationBuffer>; // buffers validation inserted
    FValidationBlocked: TStringList;               // failed buffer slots 'band:row:x'
    FValidationBufIdx: Integer;                    // unique suffix for split net names
    FPlacementErrorCount: Integer;
    FFloorplanErrorCount: Integer;
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
    // Bias-line current-capacity geometry (set by the bias helpers, applied in
    // BuildFloorplan): extra height per band's TOP/MIDDLE bias row, the extra
    // height of the bottommost full-width bias row, and the width of the two
    // vertical bias lanes flanking the clock trunk (the feed column and the
    // far-right lane; base 1 each). The green clock trunk itself is not a bias
    // zone and stays at its row-width size.
    FBiasRowH: TArray<TArray<Integer>>; // [band][0=top,1=middle] extra rows
    FBottomBiasH: Integer;              // extra rows on the bottom-most bias line
    FBiasLaneW: TArray<Integer>;        // [0]=left feed lane, [1]=right lane width (>=1)
    FPlanMaxRowW: Integer;              // row-width override for the nudge (0=auto)
    FPlanTrunkW: Integer;               // snapshot: clock trunk width (RowHBlocks)
    FPlanLane0W: Integer;               // snapshot: left feed bias lane width
    FPlanLane1W: Integer;               // snapshot: far-right bias lane width
    FPlanLastTotalH: Integer;           // snapshot: last TotalH (bias-fit checks)
    FBiasExpansionDone: Boolean;        // bias expansion has run (latching)
    FPlacementOptimized: Boolean;       // Optimize Placement has been pressed
    FOrderChanged: Boolean;
    FManhattanItem: TListBoxItem; // live 'total wire length' diagnostic line
    procedure FreeLib;
    procedure ResetWorkspace;
    procedure LoadLibraryFromFile(const Path: string; AShowErrors: Boolean = True);
    procedure SetCellFolderPath(const Path: string; AShowErrors: Boolean = True);
    procedure LoadNetlistFromFile(const Path: string; AShowErrors: Boolean = True);
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
    procedure UpdateUI;
    procedure RenderNetlist(Model: TBlifModel; Errors: TStrings);
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
    function TotalManhattanDistance: Double;
    procedure UpdateManhattanDiagnostic;
    function GetPad(const ANetName: string; var P: TPoint): Boolean;
    function PadSlotX(k, N, Right: Integer): Single;
    function NearestPadSlot(DragX: Single; N, Right: Integer): Integer;
    function PreviewPadOrder(const Ord: TArray<Integer>;
      DragIdx, Slot: Integer): TArray<Integer>;
    procedure ReapplyPadOrder;
    function PadDisplayX(Idx: Integer): Integer;
    procedure BuildClockSubtreePlacements;
    procedure BuildSpinePlacement;
    procedure ValidatePlacement;
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
    function HslToColor(H, S, L, A: Single): TAlphaColor;
    function RoutingLayerColor(const ALayer: string): TAlphaColor;
    function LengthColor(T: Double): TAlphaColor;
    procedure RunRouting;
    procedure RunRoutingValidation;
    function TraceLengthUm(const ATr: TRoutedTrace; Core: Double): Double;
    function IsBiasTrace(const ATr: TRoutedTrace): Boolean;
    function PathLengthUm(const Pts: TArray<TPoint>; Core: Double): Double;
    procedure BlockTrace(ATraceIdx: Integer);
    procedure UnblockTrace(ATraceIdx: Integer);
    function RerouteTrace(ATraceIdx: Integer): Boolean;
    function FindMinDelayBufferCell: TCell;
    procedure ReapplyValidationBuffers;
    procedure RunBiasExpansionAndRouting;
    function TryInsertBuffer(IsClock: Boolean; const NetName: string;
      Driver, Load: TGateInstance; const DriverPin, LoadPin: string;
      APadLoad: Boolean;
      BufCell: TCell; const InPin, OutPin: string;
      ABand, ARowType, AX, AY: Integer): Boolean;
    function InsertBufferForTrace(ATraceIdx: Integer): Boolean;
    procedure DrawRoutedTraces(Canvas: TCanvas);
    function GatePinBlock(G: TGateInstance; const PinName: string;
      ALayer: Integer; var P: TPoint): Boolean;
    function GatePinBlockAt(G: TGateInstance; const PinName: string;
      ALayer, AX, AY: Integer; Rotated: Boolean; var P: TPoint): Boolean;
    procedure BuildRoutingObstacles;
    // A* maze router. If UseLayer >= 0, routes on that single layer only (no
    // vias); if UseLayer < 0, routes over all layers with via transitions. Hard
    // pin-geometry blocks are the only obstacles (the goal cell is exempt). The
    // search is confined to a window around the terminals with an expansion
    // budget; turns are penalised over going straight. The path (inclusive of
    // start and goal) goes to OutPath, with each point's routing-layer index in
    // OutLayers.
    function LeeRoute(Start, Goal: TPoint; UseLayer: Integer;
      var OutPath: TArray<TPoint>; var OutLayers: TArray<Integer>): Boolean;
    procedure OrderLayer(L: Integer; CrossOnly: Boolean);
    procedure ResolvePlacementOverlaps;
    procedure OptimizePlacement;
    procedure RebuildFloorplanPreserve; // rebuild bias geometry, keep placement
    function BandIndexOfY(Y: Integer): Integer; // band containing grid row Y
    // Bias-line current-capacity helpers. Each returns True on success; on
    // failure it reports the reason via AddFloorplanError and leaves the layout
    // unchanged.
    function IncreaseBiasRowHeight(Band, Which, ByRows: Integer): Boolean;
    function IncreaseClockTrunkColumn(ColIdx, ByCols: Integer): Boolean;
    function IncreaseTopBottomBiasRow(IsTop: Boolean; ByRows: Integer): Boolean;
    function MaxUaGreaterThanLargestPort: Boolean;
    // Bias-line routing: collects a row's edge ports, partitions them into
    // current groups, and routes each group as a horizontal track to the trunk.
    procedure CollectCellPorts(G: TGateInstance; AX, AY: Integer;
      AEdge: TPortEdge; var Ports: TArray<TBiasPort>);
    function PartitionBiasPorts(const Ports: TArray<TBiasPort>;
      AMaxUa: Double): TArray<TBiasGroup>;
    // Clock bias: the trunk cells are rotated 90 deg CCW, so their "top" ports
    // face left and "bottom" ports face right. CollectTrunkPorts gathers one
    // side's ports; PartitionTrunkPorts groups them by Y (top-to-bottom for the
    // left side, bottom-to-top for the right).
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
  FModel.Free;
  FModel := nil;
  FLib.Free;
  FLib := nil;
end;

procedure TForm1.ResetWorkspace;
begin
  FSplittersInserted := False;
  FPlacementInitialized := False;
  FPlacedComponents := nil;
  FGatePlacement.Clear;
  FLogicRowExtra := nil;
  FClockRowExtra := nil;
  FBiasRowH := nil;
  FBottomBiasH := 0;
  FBiasLaneW := nil;
  FPlanMaxRowW := 0;
  FBiasExpansionDone := False;
  FPlacementOptimized := False;
  FRoutingSucceeded := False;
  FRoutingValidated := False;
  FPlacementModel := nil;
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
  ListBox1.Clear;
  ListBoxSplitters.Clear;
  ListBoxDFF.Clear;
  ListBoxBuffers.Clear;
  ListBoxSelected.Clear;
  Memo1.Lines.Clear;
  UpdateLimitLabels;
end;

procedure TForm1.LoadLibraryFromFile(const Path: string; AShowErrors: Boolean);
var
  Lib: TLibrary;
  i: Integer;
begin
  if not TFile.Exists(Path) then
  begin
    Label1.Text := 'LEF file not found: ' + Path;
    if AShowErrors then
      ShowMessage(Label1.Text);
    Exit;
  end;

  ResetWorkspace;
  FLefFile := Path;
  Label1.Text := 'Parsing: ' + ExtractFileName(FLefFile);

  try
    Lib := LoadLefLibrary(FLefFile);
  except
    on E: Exception do
    begin
      Label1.Text := 'Failed to parse LEF file.';
      if AShowErrors then
        ShowMessage('Failed to parse LEF file:' + sLineBreak + sLineBreak + E.Message);
      UpdateUI;
      Exit;
    end;
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
    ListBox1.Items.Add(FLib.Cells[i].Name);
  PopulateBiasLayerCombo;
  Label1.Text := Format('Loaded %d cell(s) from %s',
    [FLib.Cells.Count, ExtractFileName(FLefFile)]);
  UpdateUI;
end;

procedure TForm1.SetCellFolderPath(const Path: string; AShowErrors: Boolean);
var
  Cell: TCell;
  CellsWithMatches, TotalFiles: Integer;
begin
  FCellFolder := Path;
  if FLib = nil then
    Exit;

  if not TDirectory.Exists(FCellFolder) then
  begin
    Label1.Text := 'Cell folder no longer exists.';
    if AShowErrors then
      ShowMessage(Label1.Text);
    Exit;
  end;

  FLib.FindCellSourceFiles(FCellFolder);

  CellsWithMatches := 0;
  TotalFiles := 0;
  for Cell in FLib.Cells do
    if Cell.SourceFiles.Count > 0 then
    begin
      Inc(CellsWithMatches);
      Inc(TotalFiles, Cell.SourceFiles.Count);
    end;

  Label1.Text := Format('Found %d linked file(s) for %d of %d cells. Double-click a cell to view it.',
    [TotalFiles, CellsWithMatches, FLib.Cells.Count]);
  UpdateUI;
end;

procedure TForm1.LoadNetlistFromFile(const Path: string; AShowErrors: Boolean);
var
  Errors: TStringList;
begin
  if FLib = nil then
    Exit;

  if not TFile.Exists(Path) then
  begin
    Label1.Text := 'BLIF file not found: ' + Path;
    if AShowErrors then
      ShowMessage(Label1.Text);
    Exit;
  end;

  FBlifFile := Path;
  FModel.Free; // a new BLIF file invalidates the previously parsed netlist
  FModel := nil;
  FSplittersInserted := False;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  UpdateLimitLabels;
  FCellDelays.Clear;
  Memo1.Lines.Clear;
  Label1.Text := 'Parsing: ' + ExtractFileName(FBlifFile);

  Errors := TStringList.Create;
  try
    try
      FModel := ParseBlif(FBlifFile, FLib, Errors);
    except
      on E: Exception do
      begin
        Label1.Text := 'Failed to parse BLIF file.';
        if AShowErrors then
          ShowMessage('Failed to parse BLIF file:' + sLineBreak + sLineBreak + E.Message);
        UpdateUI;
        Exit;
      end;
    end;

    CheckNetConnectivity(FModel, Errors);

    ComputeClockLevels(FModel, Errors);

    RenderNetlist(FModel, Errors);
    Label1.Text := Format('Loaded netlist "%s": %d gate(s), %d net(s), %d error(s)',
      [FModel.Name, FModel.Gates.Count, FModel.Nets.Count, Errors.Count]);
  finally
    Errors.Free;
  end;
  UpdateUI;
end;

procedure TForm1.UpdateUI;
var
  LibReady: Boolean;
begin
  LibReady := (FLib <> nil) and (FCellFolder <> '');
  Button3.Enabled := (FLib <> nil);
  Button5.Enabled := (FLib <> nil);
  ListBox1.Enabled := LibReady;
  MemoLayers.Enabled := LibReady;
  if LibReady then
  begin
    ListBox1.Opacity := 1.0;
    MemoLayers.Opacity := 1.0;
  end
  else
  begin
    ListBox1.Opacity := 0.5;
    MemoLayers.Opacity := 0.5;
  end;
  ButtonBack.Enabled := (TabControl1.TabIndex > 0);
  ButtonNext.Enabled := (FLib <> nil) and
    (TabControl1.TabIndex < TabControl1.TabCount - 1);
  if TabControl1.TabIndex = TabComponents then
    ButtonNext.Enabled := ButtonNext.Enabled and
      (FSplitterNames.Count > 0) and (FFlipFlopNames.Count > 0) and
      (FBufferNames.Count > 0);
  if TabControl1.TabIndex = TabNetlist then
    ButtonNext.Enabled := ButtonNext.Enabled and (FModel <> nil);
  if TabControl1.TabIndex = TabPlacement then
    ButtonNext.Enabled := ButtonNext.Enabled and FPlacementInitialized and
      (FPlacementErrorCount = 0);
  if TabControl1.TabIndex = TabFloorplan then
  begin
    // The bias expansion is a one-shot latch: enabled only once the placement
    // has been optimised and the floorplan is valid; disabled again once run.
    // Progress past the floorplan requires the expansion to have been run.
    ButtonExpandBias.Enabled := FPlacementOptimized and FFloorplanValid and
      (not FBiasExpansionDone);
    ButtonNext.Enabled := ButtonNext.Enabled and
      (FFloorplanErrorCount = 0) and (FPlacementErrorCount = 0) and
      FPlacementOptimized and FBiasExpansionDone;
  end
  else
    ButtonExpandBias.Enabled := False;
  // Routing page: validation is only available once routing has succeeded, and
  // the user is locked out of re-routing until the validation loop has run to
  // completion (so a new wire-length state is never routed over an unverified
  // one).
  ButtonRunRouting.Enabled := (not FRoutingSucceeded) or FRoutingValidated;
  ButtonValidateRouting.Enabled := FRoutingSucceeded and (not FRoutingValidated);
end;

procedure TForm1.UpdateRecentList;
var
  i: Integer;
begin
  ListBoxRecent.Clear;
  for i := 0 to FRecent.Count - 1 do
    ListBoxRecent.Items.Add(FRecent[i]);
end;

procedure TForm1.RemoveRecentProject(const Path: string);
var
  Idx: Integer;
begin
  Idx := FRecent.IndexOf(Path);
  if Idx < 0 then
    Exit;
  FRecent.Delete(Idx);
  try
    SaveRecentProjects('', FRecent);
  except
  end;
  UpdateRecentList;
end;

function GcdOf(const A, B: Double): Double;
var
  AA, BB, R: Double;
begin
  AA := Abs(A);
  BB := Abs(B);
  if BB = 0 then
    Exit(AA);
  while BB > 1e-9 do
  begin
    R := AA - Trunc(AA / BB) * BB;
    AA := BB;
    BB := R;
  end;
  Result := AA;
end;

function IsMultipleOf(const A, B: Double): Boolean;
begin
  if B = 0 then
    Result := False
  else
    Result := Abs(A / B - Round(A / B)) < 1e-6;
end;

function DimToStr(const V: Double): string;
begin
  if Abs(V - Round(V)) < 1e-6 then
    Result := IntToStr(Round(V))
  else
    Result := FloatToStr(V);
end;

function TryDimParse(const S: string; out V: Double): Boolean;
begin
  V := 0;
  if Trim(S) = '' then
    Exit(False);
  Result := TryStrToFloat(S, V, TFormatSettings.Invariant);
end;

function FormatDim2(const V: Double): string;
begin
  Result := FormatFloat('0.00', V);
end;

procedure TForm1.InitializePlacementConfig;
var
  G, ModeH: Double;
  Cell: TCell;
  Key, BestKey, BestCount: Integer;
  Tally: TDictionary<Integer, Integer>;
  i: Integer;
begin
  G := 0;
  ModeH := 0;
  if (FLib <> nil) and (FLib.Cells.Count > 0) then
  begin
    for Cell in FLib.Cells do
      if Cell.Width > 0 then
        G := GcdOf(G, Cell.Width);

    // Mode of all cell heights (most common value), keyed on thousandths
    // so simple decimal sizes (0.5, 1.0, ...) group cleanly.
    Tally := TDictionary<Integer, Integer>.Create;
    try
      for Cell in FLib.Cells do
        if Cell.Height > 0 then
        begin
          Key := Round(Cell.Height * 1000);
          if Tally.ContainsKey(Key) then
            Tally[Key] := Tally[Key] + 1
          else
            Tally.Add(Key, 1);
        end;
      BestKey := -1;
      BestCount := 0;
      for Key in Tally.Keys do
        if Tally[Key] > BestCount then
        begin
          BestCount := Tally[Key];
          BestKey := Key;
        end;
      if BestKey >= 0 then
        ModeH := BestKey / 1000;
    finally
      Tally.Free;
    end;
  end;

  // Setting these fires OnChange, but the initial-guard flag is still off.
  EditCoreSize.Text := DimToStr(G);
  EditRowHeight.Text := DimToStr(ModeH);
  // Default die area to a single core block (G x G) as a starting point.
  EditDieW.Text := DimToStr(G);
  EditDieH.Text := DimToStr(G);
  // Placement budget defaults.
  EditUtilization.Text := '60';
  EditBiasCurrent.Text := '5';
  EditPTLLength.Text := '550';
  EditFreqGHz.Text := '10';
  EditPTLDelay.Text := '10';
  // Bias-routing layer: default to the first masterslice layer (the usual
  // choice for the bias rail, since it is not a signal-routing layer); leave
  // the current selection if one was already made.
  if ComboBiasLayer.ItemIndex < 0 then
  begin
    ComboBiasLayer.ItemIndex := 0;
    if FLib <> nil then
      for i := 0 to FLib.Layers.Count - 1 do
        if FLib.Layers[i].LayerType = ltMasterslice then
        begin
          ComboBiasLayer.ItemIndex := i;
          Break;
        end;
  end;
  FBiasLayer := '';
  if ComboBiasLayer.ItemIndex >= 0 then
    FBiasLayer := ComboBiasLayer.Items[ComboBiasLayer.ItemIndex];
  FPlacementInitialized := True;
  FormatPlacementFields;
  ValidatePlacement;
end;

procedure TForm1.FormatPlacementFields;
var
  Core, RowH, DieW, DieH: Double;
begin
  // Suppress OnChange while we rewrite the text boxes programmatically.
  FFormattingPlacement := True;
  try
    Core := -1;
    if TryDimParse(EditCoreSize.Text, Core) then
      EditCoreSize.Text := FormatDim2(Core);
    if TryDimParse(EditRowHeight.Text, RowH) then
      EditRowHeight.Text := FormatDim2(RowH);
    if TryDimParse(EditDieW.Text, DieW) then
      EditDieW.Text := FormatDim2(DieW);
    if TryDimParse(EditDieH.Text, DieH) then
      EditDieH.Text := FormatDim2(DieH);
    if TryDimParse(EditUtilization.Text, Core) then
      EditUtilization.Text := FormatDim2(Core);
    if TryDimParse(EditBiasCurrent.Text, Core) then
      EditBiasCurrent.Text := FormatDim2(Core);
    if TryDimParse(EditPTLLength.Text, Core) then
      EditPTLLength.Text := FormatDim2(Core);
    if TryDimParse(EditFreqGHz.Text, Core) then
      EditFreqGHz.Text := FormatDim2(Core);
    if TryDimParse(EditPTLDelay.Text, Core) then
      EditPTLDelay.Text := FormatDim2(Core);
  finally
    FFormattingPlacement := False;
  end;

  // Labels only update from the last successfully parsed values.
  if TryDimParse(EditCoreSize.Text, Core) then
    LabelCoreDim.Text := ' x ' + FormatDim2(Core) + ' um';
  if (Core > 0) and TryDimParse(EditRowHeight.Text, RowH) then
    LabelRowCells.Text := ' - ' + IntToStr(Round(RowH / Core)) + ' cells';
  if TryDimParse(EditDieW.Text, DieW) and TryDimParse(EditDieH.Text, DieH) then
    LabelDieAreaText.Text := FormatDim2(DieW * DieH) + ' um2';
end;

procedure TForm1.ValidatePlacement;
var
  Core, RowH, CellH, DieW, DieH, Util, Bias, PTL: Double;
  Cell: TCell;
  Used: Boolean;
  UsedNames: TDictionary<string, Boolean>;
  Gate: TGateInstance;
  ErrMsgs, WarnMsgs: TStringList;
  i: Integer;
begin
  ListBoxPlacementErrors.Clear;
  FPlacementErrorCount := 0;
  // Restore the default text colors before re-flagging invalid fields.
  EditRowHeight.StyledSettings := EditRowHeight.StyledSettings + [TStyledSetting.FontColor];
  EditDieW.StyledSettings := EditDieW.StyledSettings + [TStyledSetting.FontColor];
  EditDieH.StyledSettings := EditDieH.StyledSettings + [TStyledSetting.FontColor];
  EditUtilization.StyledSettings := EditUtilization.StyledSettings + [TStyledSetting.FontColor];

  if not TryDimParse(EditCoreSize.Text, Core) or not TryDimParse(EditRowHeight.Text, RowH) then
  begin
    AddPlacementMsg('Core block size and row height must be valid numbers.', $FFFF0000, True);
    Exit;
  end;
  if (Core <= 0) or (RowH <= 0) then
  begin
    AddPlacementMsg('Core block size and row height must be positive numbers.', $FFFF0000, True);
    Exit;
  end;

  // Error 1: the row height must be a multiple of the core block.
  if not IsMultipleOf(RowH, Core) then
  begin
    EditRowHeight.StyledSettings := EditRowHeight.StyledSettings - [TStyledSetting.FontColor];
    EditRowHeight.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Row height must be a multiple of the core block size (row height %s is not a multiple of %s).',
      [DimToStr(RowH), DimToStr(Core)]), $FFFF0000, True);
  end;

  // Die area dimensions must also tile the core grid.
  if TryDimParse(EditDieW.Text, DieW) and (DieW > 0) and
     (not IsMultipleOf(DieW, Core)) then
  begin
    EditDieW.StyledSettings := EditDieW.StyledSettings - [TStyledSetting.FontColor];
    EditDieW.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Die width must be a multiple of the core block size (die width %s is not a multiple of %s).',
      [DimToStr(DieW), DimToStr(Core)]), $FFFF0000, True);
  end;
  if TryDimParse(EditDieH.Text, DieH) and (DieH > 0) and
     (not IsMultipleOf(DieH, Core)) then
  begin
    EditDieH.StyledSettings := EditDieH.StyledSettings - [TStyledSetting.FontColor];
    EditDieH.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Die height must be a multiple of the core block size (die height %s is not a multiple of %s).',
      [DimToStr(DieH), DimToStr(Core)]), $FFFF0000, True);
  end;

  // Target utilization must stay within [0, 100]%.
  if TryDimParse(EditUtilization.Text, Util) and ((Util < 0) or (Util > 100)) then
  begin
    EditUtilization.StyledSettings := EditUtilization.StyledSettings - [TStyledSetting.FontColor];
    EditUtilization.TextSettings.FontColor := TAlphaColorRec.Red;
    AddPlacementMsg(Format('Target utilization must be between 0 and 100%% (value is %s).',
      [DimToStr(Util)]), $FFFF0000, True);
  end;

  // Every remaining text box must contain a valid number.
  if not TryDimParse(EditDieW.Text, DieW) then
    AddPlacementMsg('Die width must be a valid number.', $FFFF0000, True);
  if not TryDimParse(EditDieH.Text, DieH) then
    AddPlacementMsg('Die height must be a valid number.', $FFFF0000, True);
  if not TryDimParse(EditUtilization.Text, Util) then
    AddPlacementMsg('Target utilization must be a valid number.', $FFFF0000, True);
  if not TryDimParse(EditBiasCurrent.Text, Bias) then
    AddPlacementMsg('Max bias current must be a valid number.', $FFFF0000, True);
  if not TryDimParse(EditPTLLength.Text, PTL) then
    AddPlacementMsg('Max PTL length must be a valid number.', $FFFF0000, True);
  if not TryDimParse(EditFreqGHz.Text, Bias) then
    AddPlacementMsg('Operating frequency must be a valid number.', $FFFF0000, True)
  else if Bias <= 0 then
    AddPlacementMsg('Operating frequency must be positive.', $FFFF0000, True);
  if not TryDimParse(EditPTLDelay.Text, PTL) then
    AddPlacementMsg('PTL propagation delay must be a valid number.', $FFFF0000, True)
  else if PTL <= 0 then
    AddPlacementMsg('PTL propagation delay must be positive.', $FFFF0000, True);

  // The bias-routing layer must be a valid selection from the library.
  if FBiasLayer = '' then
    AddPlacementMsg('Select a bias routing layer.', $FFFF0000, True);

  // Which cells actually appear in the parsed netlist?
  UsedNames := nil;
  if FModel <> nil then
  begin
    UsedNames := TDictionary<string, Boolean>.Create;
    for Gate in FModel.Gates do
      if Gate.CellName <> '' then
        UsedNames.AddOrSetValue(Gate.CellName, True);
  end;
  ErrMsgs := TStringList.Create;
  WarnMsgs := TStringList.Create;
  try
    if FLib <> nil then
      for Cell in FLib.Cells do
      begin
        Used := (UsedNames <> nil) and UsedNames.ContainsKey(Cell.Name);

        // Width must tile the core grid: report each cell that fails.
        if (Cell.Width > 0) and (not IsMultipleOf(Cell.Width, Core)) then
        begin
          if Used then
            ErrMsgs.Add(Format('Cell "%s" width %s is not a multiple of the block and cell is used in the netlist.',
              [Cell.Name, DimToStr(Cell.Width)]))
          else
            WarnMsgs.Add(Format('Cell "%s" width %s is not a multiple of the block but cell isn''t used.',
              [Cell.Name, DimToStr(Cell.Width)]));
        end;

        CellH := Cell.Height;
        if CellH <= 0 then
          Continue;
        // A cell whose height does not match the configured row height
        // cannot be placed in a row and is excluded by the height check.
        if Abs(CellH - RowH) > 1e-6 then
        begin
          if Used then
            ErrMsgs.Add(Format('Cell "%s" will not fit in a row, and cell is used in the netlist.',
              [Cell.Name]))
          else
            WarnMsgs.Add(Format('Cell "%s" will not fit in a row, but is not used in this netlist.',
              [Cell.Name]));
        end;
      end;

    // Order: the row-multiple error was added first, then all other errors
    // (used in netlist), then all warnings (not used in netlist).
    for i := 0 to ErrMsgs.Count - 1 do
      AddPlacementMsg(ErrMsgs[i], $FFFF0000, True);
    for i := 0 to WarnMsgs.Count - 1 do
      AddPlacementMsg(WarnMsgs[i], $FFFF8C00, False);
  finally
    ErrMsgs.Free;
    WarnMsgs.Free;
    UsedNames.Free;
  end;
end;

procedure TForm1.AddPlacementMsg(const Text: string; Color: TAlphaColor;
  IsError: Boolean);
var
  Item: TListBoxItem;
begin
  Item := TListBoxItem.Create(ListBoxPlacementErrors);
  Item.Parent := ListBoxPlacementErrors;
  if IsError then
  begin
    Inc(FPlacementErrorCount);
    Item.Text := '[ERROR] ' + Text;
  end
  else
    Item.Text := '[WARNING] ' + Text;
  Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
  Item.TextSettings.FontColor := Color;
end;

procedure TForm1.EditPlacementChanged(Sender: TObject);
begin
  if FPlacementInitialized and (not FFormattingPlacement) then
  begin
    ValidatePlacement;
    UpdateUI;
  end;
end;

procedure TForm1.ComboBiasLayerChange(Sender: TObject);
begin
  if ComboBiasLayer.ItemIndex >= 0 then
    FBiasLayer := ComboBiasLayer.Items[ComboBiasLayer.ItemIndex]
  else
    FBiasLayer := '';
  if FPlacementInitialized and (not FFormattingPlacement) then
  begin
    ValidatePlacement;
    UpdateUI;
  end;
end;

// Fills the bias-routing-layer dropdown from the parsed library's layer stack,
// preserving the current selection if it is still present.
procedure TForm1.PopulateBiasLayerCombo;
var
  i: Integer;
  Sel: string;
begin
  if ComboBiasLayer = nil then
    Exit;
  Sel := FBiasLayer;
  ComboBiasLayer.Items.BeginUpdate;
  try
    ComboBiasLayer.Items.Clear;
    if FLib <> nil then
      for i := 0 to FLib.Layers.Count - 1 do
        ComboBiasLayer.Items.Add(FLib.Layers[i].Name);
  finally
    ComboBiasLayer.Items.EndUpdate;
  end;
  if Sel <> '' then
  begin
    i := ComboBiasLayer.Items.IndexOf(Sel);
    if i >= 0 then
      ComboBiasLayer.ItemIndex := i;
  end;
end;

procedure TForm1.EditPlacementKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    Key := 0;
    if FPlacementInitialized then
    begin
      FormatPlacementFields;
      ValidatePlacement;
      UpdateUI;
    end;
  end;
end;

procedure TForm1.SaveProjectState;
begin
  if FProjectPath = '' then
  begin
    UpdateUI;
    Exit;
  end;
  // While a project is being opened, the form state is only partially
  // restored; do not let intermediate loader saves clobber the loaded data.
  if FLoadingProject then
  begin
    UpdateUI;
    Exit;
  end;
  FProject.LefFile := FLefFile;
  FProject.CellFolder := FCellFolder;
  FProject.BlifFile := FBlifFile;
  FProject.Splitters.Assign(FSplitterNames);
  FProject.Buffers.Assign(FBufferNames);
  if FFlipFlopNames.Count > 0 then
    FProject.FlipFlop := FFlipFlopNames[0]
  else
    FProject.FlipFlop := '';
  FProject.SplittersInserted := FSplittersInserted;
  FProject.LastTab := TabControl1.TabIndex;
  FProject.SliderPos := FSliderPos;
  // Placement configuration: store the raw text so even invalid entries
  // (and their error states) are preserved across sessions.
  FProject.CoreSize := EditCoreSize.Text;
  FProject.RowHeight := EditRowHeight.Text;
  FProject.DieW := EditDieW.Text;
  FProject.DieH := EditDieH.Text;
  FProject.Utilization := EditUtilization.Text;
  FProject.BiasCurrent := EditBiasCurrent.Text;
  FProject.PTLLength := EditPTLLength.Text;
  FProject.FreqGHz := EditFreqGHz.Text;
  FProject.PTLDelay := EditPTLDelay.Text;
  FProject.BiasLayer := FBiasLayer;
  try
    FProject.SaveToFile(FProjectPath);
  except
    on E: Exception do
      ShowMessage('Failed to save project:' + sLineBreak + E.Message);
  end;
  if FRecent.IndexOf(FProjectPath) < 0 then
  begin
    FRecent.Insert(0, FProjectPath);
    while FRecent.Count > MaxRecentProjects do
      FRecent.Delete(FRecent.Count - 1);
    try
      SaveRecentProjects(FProjectPath, FRecent);
    except
    end;
    UpdateRecentList;
  end;
  UpdateUI;
end;

procedure TForm1.SaveProjectFileAs;
begin
  if FBlifFile <> '' then
    SaveDialog1.InitialDir := ExtractFilePath(FBlifFile);
  SaveDialog1.FileName := 'Project';
  if not SaveDialog1.Execute then
    Exit;
  FProjectPath := SaveDialog1.FileName;
  SaveProjectState;
  Label1.Text := 'Project saved: ' + ExtractFileName(FProjectPath);
end;

procedure TForm1.ApplyProjectSettings;
var
  i: Integer;
begin
  if FProject.LefFile <> '' then
    LoadLibraryFromFile(FProject.LefFile, False);
  if FProject.CellFolder <> '' then
    SetCellFolderPath(FProject.CellFolder, False);
  if (FLib <> nil) and (FProject.BlifFile <> '') then
    LoadNetlistFromFile(FProject.BlifFile, False);

  // Restore component selections (valid even if some files failed to load).
  FSplitterNames.Assign(FProject.Splitters);
  FFlipFlopNames.Clear;
  if FProject.FlipFlop <> '' then
    FFlipFlopNames.Add(FProject.FlipFlop);
  FBufferNames.Assign(FProject.Buffers);

  // Restore the pipeline slider so the DFF-insertion mode (compact vs
  // delay-levelized) matches what the user chose.
  FSliderPos := FProject.SliderPos;
  if FSliderPos < 0 then
    FSliderPos := 0;
  if FSliderPos > 100 then
    FSliderPos := 100;

  // Restore the placement configuration verbatim (raw text, so invalid
  // entries and the resulting errors come back too). Marking the page as
  // already-initialized stops the GCD/mode derivation from overwriting the
  // saved values; re-entry then just re-validates.
  if FProject.CoreSize <> '' then
  begin
    EditCoreSize.Text := FProject.CoreSize;
    EditRowHeight.Text := FProject.RowHeight;
    EditDieW.Text := FProject.DieW;
    EditDieH.Text := FProject.DieH;
    EditUtilization.Text := FProject.Utilization;
    EditBiasCurrent.Text := FProject.BiasCurrent;
    EditPTLLength.Text := FProject.PTLLength;
    EditFreqGHz.Text := FProject.FreqGHz;
    EditPTLDelay.Text := FProject.PTLDelay;
    // Older projects have no frequency/delay fields; give them defaults so
    // the new fields validate instead of appearing empty.
    if EditFreqGHz.Text = '' then
      EditFreqGHz.Text := '10';
    if EditPTLDelay.Text = '' then
      EditPTLDelay.Text := '10';
    FBiasLayer := FProject.BiasLayer;
    if ComboBiasLayer <> nil then
    begin
      i := ComboBiasLayer.Items.IndexOf(FBiasLayer);
      if i >= 0 then
        ComboBiasLayer.ItemIndex := i
      else
        ComboBiasLayer.ItemIndex := 0;
    end;
    FPlacementInitialized := True;
    FormatPlacementFields; // refresh the derived labels from saved values
  end;

  // Reproduce the splitter-inserted netlist if the project had reached it.
  if (FModel <> nil) and FProject.SplittersInserted then
  begin
    RunSplitterInsertion;
    FSplittersInserted := True;
  end;
end;

procedure TForm1.OpenProjectFile(const Path: string);
begin
  if not TFile.Exists(Path) then
  begin
    ShowMessage('Project file not found:' + sLineBreak + Path);
    RemoveRecentProject(Path);
    Exit;
  end;
  try
    FProject.LoadFromFile(Path);
  except
    on E: Exception do
    begin
      ShowMessage('Failed to read project:' + sLineBreak + E.Message);
      Exit;
    end;
  end;
  FProjectPath := Path;
  FLoadingProject := True;
  try
    ResetWorkspace;
    ApplyProjectSettings;
  finally
    FLoadingProject := False;
  end;
  UpdateRecentList;
  if FProject.LastTab < 0 then
    FProject.LastTab := 0;
  if FProject.LastTab > TabControl1.TabCount - 1 then
    FProject.LastTab := TabControl1.TabCount - 1;
  if FModel <> nil then
    TabControl1.TabIndex := FProject.LastTab
  else if FLib <> nil then
    TabControl1.TabIndex := TabLibrary
  else
    TabControl1.TabIndex := TabStart;
  UpdateUI;
  SaveProjectState;
end;

procedure TForm1.ButtonNewProjectClick(Sender: TObject);
begin
  ResetWorkspace;
  FProjectPath := '';
  FProject.Clear;
  UpdateUI;
  TabControl1.TabIndex := TabLibrary;
  Label1.Text := 'New project. Load a LEF file to begin.';
end;

procedure TForm1.ButtonOpenProjectClick(Sender: TObject);
begin
  OpenDialog1.Filter := 'FluxRoute projects (*.fluxroute)|*.fluxroute|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;
  OpenProjectFile(OpenDialog1.FileName);
end;

procedure TForm1.ListBoxRecentDblClick(Sender: TObject);
var
  Item: TListBoxItem;
begin
  if ListBoxRecent.ItemIndex < 0 then
    Exit;
  Item := ListBoxRecent.ItemByIndex(ListBoxRecent.ItemIndex);
  if Item = nil then
    Exit;
  OpenProjectFile(Item.Text);
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FSplitterNames := TStringList.Create;
  FCandidateCells := TList<TCell>.Create;
  FCellDelays := TDictionary<string, Double>.Create;
  FGatePlacement := TDictionary<TGateInstance, TPoint>.Create;
  FPadMap := TDictionary<string, TPoint>.Create;
  FRoutingLayers := TStringList.Create;
  FRoutingLayerEnabled := TDictionary<string, Boolean>.Create;
  FValidationBlocked := TStringList.Create;
  FFlipFlopNames := TStringList.Create;
  FFlipFlopCandidates := TList<TCell>.Create;
  FBufferNames := TStringList.Create;
  FBufferCandidates := TList<TCell>.Create;
  ListBox1.OnDblClick := ListBox1DblClick;
  ListBoxRecent.OnDblClick := ListBoxRecentDblClick;
  ListBoxSplitters.OnDblClick := ListBoxSplittersDblClick;
  ListBoxDFF.OnDblClick := ListBoxDFFDblClick;
  ListBoxBuffers.OnDblClick := ListBoxBuffersDblClick;
  ListBoxSelected.OnDblClick := ListBoxSelectedDblClick;
  // Placement configuration edits: bind live + Enter re-validation directly
  // so the page recalculates regardless of the .fmx event bindings.
  EditCoreSize.OnChange := EditPlacementChanged;
  EditRowHeight.OnChange := EditPlacementChanged;
  EditCoreSize.OnKeyDown := EditPlacementKeyDown;
  EditRowHeight.OnKeyDown := EditPlacementKeyDown;
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
  FSliderPos := 0;
  FSliderTimer := TTimer.Create(Self);
  FSliderTimer.Interval := 200;
  FSliderTimer.Enabled := False;
  FSliderTimer.OnTimer := SliderTimerTimer;
  FProject := TProjectFile.Create;
  FRecent := TStringList.Create;
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
    if FProjectPath = '' then
      SaveProjectFileAs
    else
    begin
      SaveProjectState;
      Label1.Text := 'Project saved: ' + ExtractFileName(FProjectPath);
    end;
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
  FSplitterNames.Free;
  FCandidateCells.Free;
  FCellDelays.Free;
  FGatePlacement.Free;
  FPadMap.Free;
  FRoutingLayers.Free;
  FRoutingLayerEnabled.Free;
  FValidationBlocked.Free;
  FFlipFlopNames.Free;
  FFlipFlopCandidates.Free;
  FBufferNames.Free;
  FBufferCandidates.Free;
  FSliderTimer.Free;
  FProject.Free;
  FRecent.Free;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  FreeLib;
end;

procedure TForm1.Button1Click(Sender: TObject);
begin
  OpenDialog1.Filter := 'LEF files (*.lef)|*.lef|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;
  LoadLibraryFromFile(OpenDialog1.FileName);
end;

procedure TForm1.Button3Click(Sender: TObject);
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

procedure TForm1.Button5Click(Sender: TObject);
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
    Item.TextSettings.FontColor := $FF00C853;
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
    Item.TextSettings.FontColor := $FFD50000;
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
    Item.TextSettings.FontColor := $FF81D4FA;
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

procedure TForm1.FreePipelineRows;
var
  i: Integer;
begin
  for i := 0 to High(FPipelineRows) do
    FPipelineRows[i].Free;
  FPipelineRows := nil;
end;

procedure TForm1.BuildPipelineRows(const AModel: TBlifModel);
var
  Gate: TGateInstance;
  i, MaxLevel: Integer;
begin
  FreePipelineRows;
  if (AModel = nil) or (AModel.Gates.Count = 0) then
    Exit;
  MaxLevel := -1;
  for Gate in AModel.Gates do
    if (Gate.ClockLevel >= 0) and (Gate.ClockLevel > MaxLevel) then
      MaxLevel := Gate.ClockLevel;
  if MaxLevel < 0 then
    Exit;
  SetLength(FPipelineRows, MaxLevel + 1);
  for i := 0 to MaxLevel do
    FPipelineRows[i] := TList<TGateInstance>.Create;
  for Gate in AModel.Gates do
    if Gate.ClockLevel >= 0 then
      FPipelineRows[Gate.ClockLevel].Add(Gate);
end;

procedure TForm1.PaintPipeline(Sender: TObject; Canvas: TCanvas);
var
  R, NoteR: TRectF;
  i, j, k: Integer;
  ClipState: TCanvasSaveState;
  Gate, Src: TGateInstance;
  MaxRows, MaxOutputLevel: Integer;
  Square, HGap, VGap, Left, X, Y: Single;
  Color: TAlphaColor;
  ActiveModel: TBlifModel;
  Note: string;
  GateCenters: TDictionary<TGateInstance, TPointF>;
  InputPositions: TDictionary<string, TPointF>;
  OutputPositions: TDictionary<string, TPointF>;
  SrcPt, DstPt: TPointF;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  InputNets: TStringList;
  OutputNets: TStringList;
  OutputLevels: TList<Integer>;
  OutColCount: TDictionary<Integer, Integer>;
  OutName: string;
  OutLevel: Integer;
  LevelDelay, MaxLevelDelay, TotalArea, GateArea: Double;
  LevelIdx, TotalLevels: Integer;
  StatsText: string;
  StatsR: TRectF;
  DelayMemo: TDictionary<TGateInstance, Double>;
  GateGridPos: TDictionary<TGateInstance, TPoint>;
  InputCol: TDictionary<string, Integer>;
  LevelMaxDepth, LevelYOffset: TList<Integer>;
  Placed: TDictionary<TGateInstance, Boolean>;
  LevelCols: TList<Integer>;
  MaxDepth, MaxCol, GridCol, GridRow, YOff: Integer;
  HasParent: Boolean;
  GatePair: TPair<TGateInstance, TPoint>;

  function DelayToOutput(G: TGateInstance): Double;
  var
    MaxIn, Dly: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC: TNetConnection;
  begin
    if DelayMemo.TryGetValue(G, Result) then
      Exit;
    if CellHasClock(G.Cell) then
    begin
      // Starting clocked component: its clock-to-output delay is
      // counted. It ends the path, so we do not recurse into it.
      Dly := CellDelayPs(G.Cell);
      if Dly < 0 then Dly := 0;
      Result := Dly;
      DelayMemo.Add(G, Result);
      Exit;
    end;
    MaxIn := 0;
    for m := 0 to G.Connections.Count - 1 do
    begin
      C := G.Connections[m];
      if C.Port.Direction <> pdInput then Continue;
      if IsClockPinName(C.Port.Name) then Continue;
      if ActiveModel.Nets.TryGetValue(C.NetName, N) then
        for NC in N.Connections do
          if NC.IsDriver then
          begin
            Dly := DelayToOutput(NC.Gate);
            if Dly > MaxIn then
              MaxIn := Dly;
          end;
    end;
    Dly := CellDelayPs(G.Cell);
    if Dly < 0 then Dly := 0;
    Result := MaxIn + Dly;
    DelayMemo.Add(G, Result);
  end;

  procedure DFSLayout(Gate: TGateInstance; Depth, BaseCol: Integer);
  var
    C: TPinConnection;
    N: TNet;
    NCC: TNetConnection;
    ParentCol: Integer;
  begin
    if Placed.ContainsKey(Gate) then
      Exit;
    while LevelCols.Count <= Depth do
      LevelCols.Add(0);
    if LevelCols[Depth] < BaseCol then
      LevelCols[Depth] := BaseCol;
    ParentCol := LevelCols[Depth];
    GateGridPos.Add(Gate, TPoint.Create(ParentCol, Depth));
    Placed.Add(Gate, True);
    LevelCols[Depth] := ParentCol + 1;
    for C in Gate.Connections do
    begin
      if C.Port.Direction <> pdOutput then
        Continue;
      if not ActiveModel.Nets.TryGetValue(C.NetName, N) then
        Continue;
      for NCC in N.Connections do
        if (not NCC.IsDriver) and (NCC.Gate.ClockLevel = Gate.ClockLevel) then
          DFSLayout(NCC.Gate, Depth + 1, ParentCol);
    end;
    if Depth + 1 < LevelCols.Count then
      if LevelCols[Depth] < LevelCols[Depth + 1] then
        LevelCols[Depth] := LevelCols[Depth + 1];
  end;

  // True if G has a non-clock data input on the given net.
  function GateUsesNet(G: TGateInstance; const ANetName: string): Boolean;
  var
    kk: Integer;
    CC: TPinConnection;
  begin
    Result := False;
    for kk := 0 to G.Connections.Count - 1 do
    begin
      CC := G.Connections[kk];
      if CC.Port.Direction <> pdInput then
        Continue;
      if IsClockPinName(CC.Port.Name) then
        Continue;
      if SameText(CC.NetName, ANetName) then
        Exit(True);
    end;
  end;

begin
  R := TRectF.Create(0, 0, PaintBox1.Width, PaintBox1.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  ActiveModel := FModel;
  if FPipelineModel <> nil then
    ActiveModel := FPipelineModel;

  Note := '';
  if (ActiveModel <> nil) and (FFlipFlopNames.Count = 0) then
    Note := 'No flip-flop cells selected on the Flip-flops page.';

  // Mask everything outside the paint box so nothing bleeds over the
  // slider above or the tab edges. The D2D canvas only honors
  // IntersectClipRect while a save state is active, so bracket all
  // drawing with SaveState/RestoreState.
  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if ActiveModel = nil then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No netlist loaded.', False, 1.0, [],
        TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    BuildPipelineRows(ActiveModel);

    if Note <> '' then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      NoteR := TRectF.Create(4, 4, PaintBox1.Width - 4, 24);
      Canvas.FillText(NoteR, Note, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
    end;

  InputNets := TStringList.Create;
  OutputNets := TStringList.Create;
  OutputLevels := TList<Integer>.Create;
  InputPositions := TDictionary<string, TPointF>.Create;
  OutputPositions := TDictionary<string, TPointF>.Create;
  GateCenters := TDictionary<TGateInstance, TPointF>.Create;
  try
    // Collect primary inputs (level 0), skipping the clock net.
    for i := 0 to ActiveModel.Inputs.Count - 1 do
      if not SameText(ActiveModel.Inputs[i], 'clk') then
        InputNets.Add(ActiveModel.Inputs[i]);

    // Collect primary outputs with their clock level (driver level + 1).
    MaxOutputLevel := 0;
    for i := 0 to ActiveModel.Outputs.Count - 1 do
    begin
      OutName := ActiveModel.Outputs[i];
      if ActiveModel.Nets.TryGetValue(OutName, Net) then
      begin
        OutLevel := 0;
        for NC in Net.Connections do
          if NC.IsDriver then
          begin
            OutLevel := NC.Gate.ClockLevel + 1;
            Break;
          end;
        OutputNets.Add(OutName);
        OutputLevels.Add(OutLevel);
        if OutLevel > MaxOutputLevel then
          MaxOutputLevel := OutLevel;
      end;
    end;

    HGap := 4 * FZoom;
    VGap := 4 * FZoom;
    Left := 40 * FZoom;
    Square := 18 * FZoom;

    MaxRows := Length(FPipelineRows);
    if MaxOutputLevel >= MaxRows then
      MaxRows := MaxOutputLevel + 1;
    if MaxRows = 0 then
      MaxRows := 1;

    GateGridPos := TDictionary<TGateInstance, TPoint>.Create;
    InputCol := TDictionary<string, Integer>.Create;
    LevelMaxDepth := TList<Integer>.Create;
    LevelYOffset := TList<Integer>.Create;
    Placed := TDictionary<TGateInstance, Boolean>.Create;
    try
      LevelCols := TList<Integer>.Create;
      try
        // Compute tree layout within each clock level.
        for i := 0 to High(FPipelineRows) do
        begin
          LevelCols.Clear;
          LevelCols.Add(0);
          Placed.Clear;

          // Level 0: primary inputs are the roots in the top row. Each input
          // claims a column from the row-0 counter and its gates hang below;
          // the counter then pushes the next input right, exactly like the
          // general tree layout used by every other level.
          if (i = 0) and (InputNets.Count > 0) then
          begin
            for j := 0 to InputNets.Count - 1 do
            begin
              GridCol := LevelCols[0];
              InputCol.AddOrSetValue(InputNets[j], GridCol);
              LevelCols[0] := LevelCols[0] + 1;
              for k := 0 to FPipelineRows[i].Count - 1 do
              begin
                Gate := FPipelineRows[i][k];
                if Placed.ContainsKey(Gate) then
                  Continue;
                if not GateUsesNet(Gate, InputNets[j]) then
                  Continue;
                HasParent := False;
                for Conn in Gate.Connections do
                begin
                  if Conn.Port.Direction <> pdInput then
                    Continue;
                  if IsClockPinName(Conn.Port.Name) then
                    Continue;
                  if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
                    Continue;
                  for NC in Net.Connections do
                    if NC.IsDriver and (NC.Gate.ClockLevel = i) then
                    begin
                      HasParent := True;
                      Break;
                    end;
                  if HasParent then
                    Break;
                end;
                if HasParent then
                  Continue;
                DFSLayout(Gate, 1, GridCol);
              end;
              // Push the input row right to cover the subtree just placed,
              // mirroring the push-up the tree layout applies to its roots.
              if LevelCols.Count > 1 then
                if LevelCols[0] < LevelCols[1] then
                  LevelCols[0] := LevelCols[1];
            end;
            // Remaining level-0 gates (cycles or disconnected).
            for k := 0 to FPipelineRows[i].Count - 1 do
            begin
              Gate := FPipelineRows[i][k];
              if not Placed.ContainsKey(Gate) then
                DFSLayout(Gate, 1, LevelCols[0]);
            end;
          end
          else
          begin
            // Other levels: ordinary roots at the level's top row.
            for j := 0 to FPipelineRows[i].Count - 1 do
            begin
              Gate := FPipelineRows[i][j];
              if Placed.ContainsKey(Gate) then
                Continue;
              HasParent := False;
              for Conn in Gate.Connections do
              begin
                if Conn.Port.Direction <> pdInput then
                  Continue;
                if IsClockPinName(Conn.Port.Name) then
                  Continue;
                if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
                  Continue;
                for NC in Net.Connections do
                  if NC.IsDriver and (NC.Gate.ClockLevel = i) then
                  begin
                    HasParent := True;
                    Break;
                  end;
                if HasParent then
                  Break;
              end;
              if not HasParent then
                DFSLayout(Gate, 0, 0);
            end;
            // Remaining gates (cycles or disconnected).
            for j := 0 to FPipelineRows[i].Count - 1 do
            begin
              Gate := FPipelineRows[i][j];
              if not Placed.ContainsKey(Gate) then
                DFSLayout(Gate, 0, 0);
            end;
          end;

          // Find max depth for this level.
          MaxDepth := 0;
          for j := 0 to FPipelineRows[i].Count - 1 do
          begin
            Gate := FPipelineRows[i][j];
            if GateGridPos.ContainsKey(Gate) then
            begin
              GridRow := GateGridPos[Gate].Y;
              if GridRow > MaxDepth then
                MaxDepth := GridRow;
            end;
          end;
          LevelMaxDepth.Add(MaxDepth + 1);
        end;

        // Compute cumulative Y offsets per level with a gap between levels.
        while LevelMaxDepth.Count < MaxRows do
          LevelMaxDepth.Add(1);
        YOff := 0;
        for i := 0 to LevelMaxDepth.Count - 1 do
        begin
          LevelYOffset.Add(YOff);
          Inc(YOff, LevelMaxDepth[i] + 1);
        end;

        // Draw level labels to the left of each level's first row.
        for i := 0 to LevelMaxDepth.Count - 1 do
        begin
          Y := FPanY + 4 * FZoom + LevelYOffset[i] * (Square + VGap);
          Canvas.Fill.Color := TAlphaColorRec.Dimgray;
          Canvas.FillText(TRectF.Create(FPanX, Y, FPanX + Left - 6 * FZoom, Y + Square),
            IntToStr(i), False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
        end;

        // Draw primary inputs at level 0, at the columns the layout assigned
        // them (pushed right by their subtrees, like the other roots).
        Y := FPanY + 4 * FZoom;
        for j := 0 to InputNets.Count - 1 do
        begin
          GridCol := 0;
          if not InputCol.TryGetValue(InputNets[j], GridCol) then
            GridCol := j;
          X := FPanX + Left + GridCol * (Square + HGap);
          Canvas.Fill.Color := $FFFFEB3B;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          InputPositions.AddOrSetValue(InputNets[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Draw gates at their tree positions.
        for i := 0 to ActiveModel.Gates.Count - 1 do
        begin
          Gate := ActiveModel.Gates[i];
          if Gate.ClockLevel < 0 then
            Continue;
          if not GateGridPos.ContainsKey(Gate) then
            Continue;
          GridCol := GateGridPos[Gate].X;
          GridRow := GateGridPos[Gate].Y;
          X := FPanX + Left + GridCol * (Square + HGap);
          if Gate.ClockLevel < LevelYOffset.Count then
            Y := FPanY + 4 * FZoom + (LevelYOffset[Gate.ClockLevel] + GridRow) * (Square + VGap)
          else
            Y := FPanY + 4 * FZoom + Gate.ClockLevel * (Square + VGap);
          if FSplitterNames.IndexOf(Gate.Cell.Name) >= 0 then
            Color := $FF00C853
          else if FFlipFlopNames.IndexOf(Gate.Cell.Name) >= 0 then
            Color := $FFD50000
          else if CellHasClock(Gate.Cell) then
            Color := $FF1565C0
          else
            Color := $FF81D4FA;
          Canvas.Fill.Color := Color;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          GateCenters.AddOrSetValue(Gate,
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Draw primary outputs at their driver's level + 1, each in its own
        // column to the right of that level's gates.
        OutColCount := TDictionary<Integer, Integer>.Create;
        try
          for j := 0 to OutputLevels.Count - 1 do
          begin
            OutLevel := OutputLevels[j];
            MaxCol := 0;
            for GatePair in GateGridPos do
              if GatePair.Key.ClockLevel = OutLevel then
              begin
                GridCol := GatePair.Value.X;
                if GridCol + 1 > MaxCol then
                  MaxCol := GridCol + 1;
              end;
            if OutColCount.TryGetValue(OutLevel, i) then
              GridCol := MaxCol + i
            else
              GridCol := MaxCol;
            OutColCount.AddOrSetValue(OutLevel, GridCol - MaxCol + 1);
            X := FPanX + Left + GridCol * (Square + HGap);
            Y := FPanY + 4 * FZoom + LevelYOffset[OutLevel] * (Square + VGap);
            Canvas.Fill.Color := $FF9C27B0;
            Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
            OutputPositions.AddOrSetValue(OutputNets[j],
              TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
          end;
        finally
          OutColCount.Free;
        end;

      finally
        LevelCols.Free;
      end;

    finally
      GateGridPos.Free;
      InputCol.Free;
      LevelMaxDepth.Free;
      LevelYOffset.Free;
      Placed.Free;
    end;

    // Draw connection lines.
    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Stroke.Color := $60000000;
    Canvas.Stroke.Thickness := 1;

    // Gate-to-gate.
    for i := 0 to ActiveModel.Gates.Count - 1 do
    begin
      Src := ActiveModel.Gates[i];
      if not GateCenters.TryGetValue(Src, SrcPt) then
        Continue;
      for j := 0 to Src.Connections.Count - 1 do
      begin
        Conn := Src.Connections[j];
        if Conn.Port.Direction <> pdOutput then
          Continue;
        if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
          Continue;
        for NC in Net.Connections do
          if (not NC.IsDriver) and GateCenters.TryGetValue(NC.Gate, DstPt) then
            Canvas.DrawLine(SrcPt, DstPt, 1.0);
      end;
    end;

    // Input-to-gate.
    for i := 0 to InputNets.Count - 1 do
    begin
      if not InputPositions.TryGetValue(InputNets[i], SrcPt) then
        Continue;
      if not ActiveModel.Nets.TryGetValue(InputNets[i], Net) then
        Continue;
      for NC in Net.Connections do
        if (not NC.IsDriver) and GateCenters.TryGetValue(NC.Gate, DstPt) then
          Canvas.DrawLine(SrcPt, DstPt, 1.0);
    end;

    // Gate-to-output.
    for i := 0 to OutputNets.Count - 1 do
    begin
      if not OutputPositions.TryGetValue(OutputNets[i], DstPt) then
        Continue;
      if not ActiveModel.Nets.TryGetValue(OutputNets[i], Net) then
        Continue;
      for NC in Net.Connections do
        if NC.IsDriver and GateCenters.TryGetValue(NC.Gate, SrcPt) then
          Canvas.DrawLine(SrcPt, DstPt, 1.0);
    end;

    // --- Heuristics panel ---
    MaxLevelDelay := 0;
    TotalArea := 0;
    TotalLevels := MaxRows;

    DelayMemo := TDictionary<TGateInstance, Double>.Create;
    try
      // Accumulate area from all gates.
      for LevelIdx := 0 to MaxRows - 1 do
        if LevelIdx <= High(FPipelineRows) then
          for j := 0 to FPipelineRows[LevelIdx].Count - 1 do
            TotalArea := TotalArea +
              FPipelineRows[LevelIdx][j].Cell.Width *
              FPipelineRows[LevelIdx][j].Cell.Height;

      // Per-level worst-case path delay: longest combinational path
      // from a clocked component (source register) at level L through
      // non-clocked components to the next clocked component (receiver
      // register). The source register's clock-to-output delay is
      // counted; the receiver register's delay is not.
      for LevelIdx := 0 to MaxRows - 1 do
      begin
        LevelDelay := 0;
        if LevelIdx <= High(FPipelineRows) then
          for j := 0 to FPipelineRows[LevelIdx].Count - 1 do
          begin
            Gate := FPipelineRows[LevelIdx][j];
            GateArea := DelayToOutput(Gate);
            if GateArea > LevelDelay then
              LevelDelay := GateArea;
          end;
        if LevelDelay > MaxLevelDelay then
          MaxLevelDelay := LevelDelay;
      end;
    finally
      DelayMemo.Free;
    end;

    if MaxLevelDelay > 0 then
    begin
      StatsText := Format(
        'Levels: %d  |  Worst path/level: %.1f ps  |  Fmax: %.1f GHz  |  Area: %.1f um2',
        [TotalLevels, MaxLevelDelay,
         1000.0 / MaxLevelDelay,
         TotalArea]);
    end
    else
      StatsText := Format(
        'Levels: %d  |  Worst path/level: (no timing)  |  Area: %.1f um2',
        [TotalLevels, TotalArea]);

    StatsR := TRectF.Create(4, PaintBox1.Height - 22, PaintBox1.Width - 4, PaintBox1.Height - 2);
    // White shelf along the bottom so the text stays readable over gate
    // squares.
    Canvas.Fill.Color := TAlphaColorRec.White;
    Canvas.FillRect(TRectF.Create(0, PaintBox1.Height - 26, PaintBox1.Width,
      PaintBox1.Height), 0, 0, [], 0.8);
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(StatsR, StatsText, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);

  finally
    InputNets.Free;
    OutputNets.Free;
    OutputLevels.Free;
    InputPositions.Free;
    OutputPositions.Free;
    GateCenters.Free;
  end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

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
      Slot := NearestPadSlot(FPadDragX, N, FPlanXRight + FPlanLane0W + FPlanTrunkW);
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
function TForm1.BandIndexOfY(Y: Integer): Integer;
var
  b: Integer;
begin
  Result := -1;
  for b := 0 to High(FPlanBandStarts) do
    if (b < Length(FPlanBandHeight)) and
       (Y >= FPlanBandStarts[b]) and
       (Y < FPlanBandStarts[b] + FPlanBandHeight[b]) then
    begin
      Result := b;
      Exit;
    end;
end;

// Height of a band's top bias row: base 1 plus any extra current-capacity rows.
function TForm1.BandTopBiasH(Band: Integer): Integer;
begin
  Result := 1;
  if (Band >= 0) and (Band < Length(FBiasRowH)) and
     (Length(FBiasRowH[Band]) > 0) then
    Inc(Result, FBiasRowH[Band][0]);
end;

// Height of a band's middle bias row (the one above the clock row).
function TForm1.BandMidBiasH(Band: Integer): Integer;
begin
  Result := 1;
  if (Band >= 0) and (Band < Length(FBiasRowH)) and
     (Length(FBiasRowH[Band]) > 1) then
    Inc(Result, FBiasRowH[Band][1]);
end;

// Top Y of a band's logic row (below the band's top bias row).
function TForm1.BandLogicRowY(Band: Integer): Integer;
begin
  Result := FPlanBandStarts[Band] + BandTopBiasH(Band);
end;

// Top Y of a band's clock row (below the logic row, its extras, and the
// middle bias row).
function TForm1.BandClockRowY(Band: Integer): Integer;
begin
  Result := BandLogicRowY(Band) + FPlanRowHBlocks + BandMidBiasH(Band);
  if (Band >= 0) and (Band < Length(FLogicRowExtra)) then
    Inc(Result, FLogicRowExtra[Band]);
end;

procedure TForm1.OrderLayer(L: Integer; CrossOnly: Boolean);
var
  Items, Order, CellBand, PlacedX, BandUsed: TArray<Integer>;
  BaryX, BaryY, NbrX: TArray<Double>;
  i, j, k, Idx, TmpIdx, BandStartIdx, BandEndIdx, BandIdx, X, RowY: Integer;
  Pref, d, cand: Integer;
  W, DL, NextLeft: Integer;
  SumX, SumY, TmpX, Dist, BestDist: Double;
  Count, Wb, Hb: Integer;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  Pt, PadPt: TPoint;
  Changed: Boolean;
begin
  // Collect this layer's placed component indices.
  SetLength(Items, 0);
  for Idx := 0 to High(FPlacedComponents) do
    if FPlacedComponents[Idx].ClockLevel = FPlanLevels[L] then
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Idx;
    end;
  if Length(Items) = 0 then
    Exit;

  // (X,Y) barycentres from placed neighbours (clock pins excluded).
  SetLength(BaryX, Length(Items));
  SetLength(BaryY, Length(Items));
  for i := 0 to High(Items) do
  begin
    SumX := 0;
    SumY := 0;
    Count := 0;
    if CrossOnly then
      SetLength(NbrX, 0);
    if FPlacedComponents[Items[i]].Gate <> nil then
      for Conn in FPlacedComponents[Items[i]].Gate.Connections do
      begin
        if IsClockPinName(Conn.PinName) then
          Continue;
        if (FPlacementModel = nil) or
           (not FPlacementModel.Nets.TryGetValue(Conn.NetName, Net)) then
          Continue;
        // Immobile I/O anchor: a primary input/output net on this pin is pinned
        // to its pad at the die edge, so it counts as a fixed neighbour in the
        // barycentre (anchors the layout so it cannot float freely).
        if GetPad(Conn.NetName, PadPt) then
        begin
          if CrossOnly then
          begin
            SetLength(NbrX, Length(NbrX) + 1);
            NbrX[High(NbrX)] := PadPt.X + 0.5;
          end;
          SumX := SumX + (PadPt.X + 0.5);
          SumY := SumY + (PadPt.Y + 0.5);
          Inc(Count);
        end;
        for NC in Net.Connections do
        begin
          if NC.Gate = FPlacedComponents[Items[i]].Gate then
            Continue;
          if not FGatePlacement.TryGetValue(NC.Gate, Pt) then
            Continue;
          // CrossOnly orders cells by their neighbours on OTHER layers only, so
          // layer-to-layer wires align and stop crossing; same-layer neighbours
          // are ignored during this phase.
          if CrossOnly and
             (NC.Gate.ClockLevel = FPlacedComponents[Items[i]].ClockLevel) then
            Continue;
          Wb := 1;
          Hb := 1;
          if NC.Gate.Cell <> nil then
          begin
            Wb := Round(NC.Gate.Cell.Width / FPlanCore);
            Hb := Round(NC.Gate.Cell.Height / FPlanCore);
            if Wb < 1 then
              Wb := 1;
            if Hb < 1 then
              Hb := 1;
          end;
          if CrossOnly then
          begin
            SetLength(NbrX, Length(NbrX) + 1);
            NbrX[High(NbrX)] := Pt.X + Wb / 2;
          end;
          SumX := SumX + (Pt.X + Wb / 2);
          SumY := SumY + (Pt.Y + Hb / 2);
          Inc(Count);
        end;
      end;
    if Count > 0 then
    begin
      if CrossOnly then
      begin
        // Median of the cross-layer neighbour X-centres - the classic robust
        // ordering key for crossing minimisation (outliers don't dominate).
        for k := 1 to High(NbrX) do
        begin
          TmpX := NbrX[k];
          j := k - 1;
          while (j >= 0) and (NbrX[j] > TmpX) do
          begin
            NbrX[j + 1] := NbrX[j];
            Dec(j);
          end;
          NbrX[j + 1] := TmpX;
        end;
        BaryX[i] := NbrX[Length(NbrX) div 2];
      end
      else
        BaryX[i] := SumX / Count;
      BaryY[i] := SumY / Count;
    end
    else
    begin
      // No neighbours: keep the current centre so isolated cells stay put.
      BaryX[i] := FPlacedComponents[Items[i]].X +
        FPlacedComponents[Items[i]].W / 2;
      BaryY[i] := FPlacedComponents[Items[i]].Y +
        FPlacedComponents[Items[i]].H / 2;
    end;
  end;

  // Sort cell indices by X barycentre (stable insertion sort).
  SetLength(Order, Length(Items));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 1 to High(Order) do
  begin
    TmpIdx := Order[i];
    j := i - 1;
    while (j >= 0) and (BaryX[Order[j]] > BaryX[TmpIdx]) do
    begin
      Order[j + 1] := Order[j];
      Dec(j);
    end;
    Order[j + 1] := TmpIdx;
  end;

  // Band assignment: each cell prefers the band whose row centre is closest to
  // its Y barycentre (this is what lets cells migrate between rows). Capacity
  // is enforced by spilling each cell to the nearest band with room - a
  // deterministic, one-shot decision, so there is no oscillation or drift.
  BandStartIdx := FPlanLevelFirstBand[L];
  BandEndIdx := BandStartIdx + FPlanLevelBandCount[L];
  SetLength(CellBand, Length(Order));
  SetLength(PlacedX, Length(Order));
  SetLength(BandUsed, BandEndIdx - BandStartIdx);
  for BandIdx := 0 to High(BandUsed) do
    BandUsed[BandIdx] := 0;

  for i := 0 to High(Order) do
  begin
    Idx := Items[Order[i]];
    // Preferred band: the row centre closest to the Y barycentre, so cells are
    // free to migrate between rows in both phases (only the X-ordering key
    // differs) - moving a cell toward its connections' rows shortens wires.
    Pref := BandStartIdx;
    BestDist := MaxSingle;
    for BandIdx := BandStartIdx to BandEndIdx - 1 do
    begin
      Dist := Abs((FPlanBandStarts[BandIdx] + FPlanRowHBlocks / 2) -
        BaryY[Order[i]]);
      if Dist < BestDist then
      begin
        BestDist := Dist;
        Pref := BandIdx;
      end;
    end;
    // Nearest band (from Pref outward) that can still fit this cell.
    CellBand[i] := -1;
    for d := 0 to BandEndIdx - BandStartIdx - 1 do
    begin
      cand := Pref + d;
      if (cand >= BandStartIdx) and (cand < BandEndIdx) and
         (BandUsed[cand - BandStartIdx] +
          FPlacedComponents[Idx].W <= FPlanXRight - FPlanXLeft) then
      begin
        CellBand[i] := cand;
        Break;
      end;
      cand := Pref - d;
      if (d > 0) and (cand >= BandStartIdx) and (cand < BandEndIdx) and
         (BandUsed[cand - BandStartIdx] +
          FPlacedComponents[Idx].W <= FPlanXRight - FPlanXLeft) then
      begin
        CellBand[i] := cand;
        Break;
      end;
    end;
    if CellBand[i] < 0 then
      Break; // no band has room left for this layer
    BandUsed[CellBand[i] - BandStartIdx] :=
      BandUsed[CellBand[i] - BandStartIdx] +
      FPlacedComponents[Idx].W + 1; // width + one-cell gap
  end;

  // Spread each band's cells across the row at their barycentre targets (order
  // preserved): each cell sits where its connections pull it instead of being
  // densely packed, which shortens wires. Overlaps are resolved by a forward
  // push and a backward release, so nothing drifts or runs off the die.
  Changed := False;
  for BandIdx := BandStartIdx to BandEndIdx - 1 do
  begin
    // Forward pass: place each cell at its target left, but not before the
    // previous cell's right edge + gap.
    X := FPlanXLeft;
    for i := 0 to High(Order) do
    begin
      if CellBand[i] <> BandIdx then
        Continue;
      Idx := Items[Order[i]];
      W := FPlacedComponents[Idx].W;
      DL := Round(BaryX[Order[i]] - W / 2);
      if DL < FPlanXLeft then
        DL := FPlanXLeft;
      if DL > FPlanXRight - W then
        DL := FPlanXRight - W;
      if DL < X then
        DL := X;
      PlacedX[i] := DL;
      X := DL + W + 1; // width + one-cell gap
    end;
    // Backward pass: clamp to the row's right edge and release any forward
    // push where there is room to the left (prevents accumulation/drift).
    NextLeft := FPlanXRight;
    for i := High(Order) downto 0 do
    begin
      if CellBand[i] <> BandIdx then
        Continue;
      Idx := Items[Order[i]];
      W := FPlacedComponents[Idx].W;
      if PlacedX[i] + W > FPlanXRight then
        PlacedX[i] := FPlanXRight - W;
      if PlacedX[i] + W + 1 > NextLeft then
        PlacedX[i] := NextLeft - W - 1;
      if PlacedX[i] < FPlanXLeft then
        PlacedX[i] := FPlanXLeft;
      NextLeft := PlacedX[i];
    end;
  end;

  // Write the final positions.
  for i := 0 to High(Order) do
  begin
    if (CellBand[i] < BandStartIdx) or (CellBand[i] >= BandEndIdx) then
      Continue;
    Idx := Items[Order[i]];
    RowY := BandLogicRowY(CellBand[i]) +
      ((FPlanRowHBlocks - FPlacedComponents[Idx].H) div 2);
    if (FPlacedComponents[Idx].X <> PlacedX[i]) or
       (FPlacedComponents[Idx].Y <> RowY) then
      Changed := True;
    FPlacedComponents[Idx].X := PlacedX[i];
    FPlacedComponents[Idx].Y := RowY;
    FGatePlacement.AddOrSetValue(FPlacedComponents[Idx].Gate,
      TPoint.Create(PlacedX[i], RowY));
  end;

  if Changed then
    FOrderChanged := True;
end;

procedure TForm1.ButtonOptimizeClick(Sender: TObject);
begin
  // Latching behavior: if the bias expansion has already run, this re-optimizes
  // from a clean slate - reset the bias expansion state so the floorplan is
  // built with base-width bias lines again, then optimise.
  if FBiasExpansionDone then
  begin
    FBiasRowH := nil;
    FBottomBiasH := 0;
    FBiasLaneW := nil;
    FPlanMaxRowW := 0;
    FBiasExpansionDone := False;
    BuildFloorplan;
  end;
  OptimizePlacement;
  // The user must have successfully optimised the placement before the bias
  // expansion (and hence the routing page) becomes available.
  if (FFloorplanErrorCount = 0) and (FPlacementErrorCount = 0) then
    FPlacementOptimized := True;
  UpdateUI;
end;

// Returns True if the configured max bias current (EditBiasCurrent) is greater
// than the largest single-port current drawn by any cell in the netlist. This
// guards the expansion: a per-line limit smaller than a port's own current can
// never be satisfied, which made rows never grow and columns over-grow.
function TForm1.MaxUaGreaterThanLargestPort: Boolean;
var
  MaxUa, Largest: Double;
  Gate: TGateInstance;
  Port: TPort;
  Shape: TPortShape;
begin
  Result := False;
  if FLib = nil then
    Exit;
  if not TryDimParse(EditBiasCurrent.Text, MaxUa) then
    Exit;
  Largest := 0;
  // Scan the gates actually in the netlist (the placement model's gates), not
  // the whole library, so unused cells with large ports don't block expansion.
  if FPlacementModel <> nil then
    for Gate in FPlacementModel.Gates do
      if (Gate <> nil) and (Gate.Cell <> nil) then
        for Port in Gate.Cell.PowerPorts do
          for Shape in Port.Shapes do
            if Shape.CurrentUa > Largest then
              Largest := Shape.CurrentUa;
  Result := MaxUa > Largest;
end;

// Expands the bias lines to carry the routed currents: for every horizontal
// bias channel between two cell rows, and for the two vertical bias lanes
// flanking the clock trunk, it sums the current each channel must carry and
// grows the channel to hold that many parallel tracks (each track carries up
// to the user's max bias current, EditBiasCurrent). Also adds the clock trunk
// cells' own power current to the topmost/bottommost rows and the flanking
// lanes. Only one expansion is allowed per optimized placement (latching).
procedure TForm1.ButtonExpandBiasClick(Sender: TObject);
var
  MaxUa: Double;
  NumBands, Band, GLeft, GRight: Integer;
  b, Upper: Integer;
  Extra: Integer;
  LogicTop, LogicBot, ClockTop, ClockBot: TArray<Integer>; // tracks per band
  LogicTopP, LogicBotP, ClockTopP, ClockBotP: TArray<TArray<TBiasPort>>;
  Above, Below, TrunkPorts: TArray<TBiasPort>;

  // Collects all edge ports of a band's logic cells (placed in its logic row).
  procedure CollectLogic(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    k: Integer;
  begin
    SetLength(APorts, 0);
    for k := 0 to High(FPlacedComponents) do
      if BandIndexOfY(FPlacedComponents[k].Y) = Band then
        CollectCellPorts(FPlacedComponents[k].Gate, FPlacedComponents[k].X,
          FPlacedComponents[k].Y, AEdge, APorts);
  end;

  // Collects all edge ports of a band's clock-row cells (subtree interiors).
  procedure CollectClock(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    lv, c2: Integer;
  begin
    SetLength(APorts, 0);
    for lv := 0 to High(FClockSubtree) do
      for c2 := 0 to High(FClockSubtree[lv]) do
        if (not FClockSubtree[lv][c2].IsLeaf) and
           (BandIndexOfY(FClockSubtree[lv][c2].Y) = Band) then
          CollectCellPorts(FClockSubtree[lv][c2].Gate, FClockSubtree[lv][c2].X,
            FClockSubtree[lv][c2].Y, AEdge, APorts);
  end;

  // Number of tracks a channel needs: partition the above and below sides into
  // current groups; each group is one track. The final-group merge edge case
  // (the rightmost groups' combined current <= MaxUa) saves one track.
  function SharedTracks(const AAbove, ABelow: TArray<TBiasPort>): Integer;
  var
    GA, GB: TArray<TBiasGroup>;
  begin
    GA := PartitionBiasPorts(AAbove, MaxUa);
    GB := PartitionBiasPorts(ABelow, MaxUa);
    Result := Length(GA) + Length(GB);
    if (Length(GA) > 0) and (Length(GB) > 0) then
      if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
        Dec(Result);
  end;

begin
  if not FFloorplanValid then
    Exit;
  if not TryDimParse(EditBiasCurrent.Text, MaxUa) or (MaxUa <= 0) then
  begin
    AddFloorplanError('Max bias current must be positive before expanding bias lines.');
    Exit;
  end;
  // Guard: the per-line limit must be able to carry the largest single port
  // current in the netlist, otherwise even one channel is under-sized.
  if not MaxUaGreaterThanLargestPort then
  begin
    AddFloorplanError('Max bias current is smaller than a cell''s largest port current; increase it.');
    Exit;
  end;
  NumBands := Length(FPlanBandStarts);
  if NumBands < 1 then
    Exit;
  if Length(FBiasRowH) < NumBands then
  begin
    SetLength(FBiasRowH, NumBands);
    for b := 0 to NumBands - 1 do
    begin
      SetLength(FBiasRowH[b], 2);
      FBiasRowH[b][0] := 0;
      FBiasRowH[b][1] := 0;
    end;
  end;
  if Length(FBiasLaneW) <> 2 then
  begin
    SetLength(FBiasLaneW, 2);
    FBiasLaneW[0] := 1;
    FBiasLaneW[1] := 1;
  end;

  // Clock bias groups: the trunk's left ("top") ports top-to-bottom and right
  // ("bottom") ports bottom-to-top. Each group needs one vertical lane track and
  // one horizontal turn row in the topmost/bottommost full-width bias row.
  CollectTrunkPorts(True, TrunkPorts);
  GLeft := Length(PartitionTrunkPorts(TrunkPorts, MaxUa, False));
  CollectTrunkPorts(False, TrunkPorts);
  GRight := Length(PartitionTrunkPorts(TrunkPorts, MaxUa, True));

  // Partition each row side's ports into current groups. The number of groups
  // IS the number of horizontal tracks the channel needs (a partition
  // guideline, not a ceil of the summed current).
  SetLength(LogicTopP, NumBands);
  SetLength(LogicBotP, NumBands);
  SetLength(ClockTopP, NumBands);
  SetLength(ClockBotP, NumBands);
  SetLength(LogicTop, NumBands);
  SetLength(LogicBot, NumBands);
  SetLength(ClockTop, NumBands);
  SetLength(ClockBot, NumBands);
  for b := 0 to NumBands - 1 do
  begin
    CollectLogic(b, peTop, LogicTopP[b]);
    CollectLogic(b, peBottom, LogicBotP[b]);
    CollectClock(b, peTop, ClockTopP[b]);
    CollectClock(b, peBottom, ClockBotP[b]);
    LogicTop[b] := Length(PartitionBiasPorts(LogicTopP[b], MaxUa));
    LogicBot[b] := Length(PartitionBiasPorts(LogicBotP[b], MaxUa));
    ClockTop[b] := Length(PartitionBiasPorts(ClockTopP[b], MaxUa));
    ClockBot[b] := Length(PartitionBiasPorts(ClockBotP[b], MaxUa));
  end;

  // --- Horizontal channels (bias rows) ---
  // Topmost full-width row (band 0's top): carries the top logic row's top
  // ports as horizontal tracks (bottom of the row) plus the clock trunk's left
  // turn rows (top of the row). The height must hold BOTH: LogicTop[0] + GLeft.
  Extra := (LogicTop[0] + GLeft) - BandTopBiasH(0);
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseTopBottomBiasRow(True, Extra);
  // Bottommost full-width row: the last band's clock-row bottom ports
  // (ClockBot[last] tracks) plus the clock trunk's right turn rows (GRight).
  Extra := (ClockBot[NumBands - 1] + GRight) - (1 + FBottomBiasH);
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseTopBottomBiasRow(False, Extra);
  // Interior channels. Each band's MIDDLE bias row sits between that band's
  // logic row (above) and clock row (below). Each band's TOP bias row (band>0)
  // sits between the previous band's clock row (above) and this band's logic
  // row (below). A channel between two rows powers both: bottom ports of the
  // upper row + top ports of the lower row.
  for Band := 0 to NumBands - 1 do
  begin
    // Middle bias row: logic (above) + clock (below).
    Above := LogicBotP[Band];
    Below := ClockTopP[Band];
    Extra := SharedTracks(Above, Below) - 1; // base-1 floor
    if Extra < 0 then
      Extra := 0;
    if Extra > 0 then
      IncreaseBiasRowHeight(Band, 1, Extra);
    // Top bias row (skip band 0: it is the topmost full-width row).
    if Band > 0 then
    begin
      Upper := Band - 1;
      Above := ClockBotP[Upper];
      Below := LogicTopP[Band];
      Extra := SharedTracks(Above, Below) - 1; // base-1 floor
      if Extra < 0 then
        Extra := 0;
      if Extra > 0 then
        IncreaseBiasRowHeight(Band, 0, Extra);
    end;
  end;

  // --- Clock bias lanes (flanking the clock trunk) ---
  // Each clock group becomes one vertical track, so the lane width = the number
  // of groups (the same grouping logic the logic rows use, not ceil(total/max)).
  // GLeft/GRight were computed above; the topmost/bottommost rows already grew
  // to hold the corresponding turn rows.
  Extra := GLeft - 1;
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseClockTrunkColumn(0, Extra);
  Extra := GRight - 1;
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseClockTrunkColumn(1, Extra);

  FBiasExpansionDone := True;
  UpdateUI;
  RepaintFloorplanPage;
end;

// Runs the barycentre relaxation (cross-only ordering first to untangle
// layer-to-layer wires, then the full optimisation alternating the sweep
// direction), then guarantees no overlaps and rebuilds the clock placements.
procedure TForm1.OptimizePlacement;
const
  MaxCrossPasses = 40;
  MaxOrderPasses = 100;
var
  Pass, L: Integer;
begin
  if not FFloorplanValid then
    Exit;
  if Length(FPlacedComponents) = 0 then
    Exit;
  // Clear the previous diagnostics so the listbox shows only the CURRENT
  // (post-optimize) overlaps/coverage, not the ones from the initial build.
  ListBoxFloorplanErrors.Clear;
  FFloorplanErrorCount := 0;
  FManhattanItem := nil;
  // Phase 1 - untangle: order cells only by their neighbours on other layers,
  // alternating the sweep direction, so layer-to-layer wires align and stop
  // crossing before the full optimisation runs.
  for Pass := 0 to MaxCrossPasses - 1 do
  begin
    FOrderChanged := False;
    if Pass mod 2 = 0 then
      for L := 0 to FPlanNumLayers - 1 do
        OrderLayer(L, True)
    else
      for L := FPlanNumLayers - 1 downto 0 do
        OrderLayer(L, True);
    if not FOrderChanged then
      Break; // converged
  end;
  // Phase 2 - full barycentre optimisation (all neighbours, X and Y),
  // alternating the sweep direction so the Gauss-Seidel bias cancels.
  for Pass := 0 to MaxOrderPasses - 1 do
  begin
    FOrderChanged := False;
    if Pass mod 2 = 0 then
      for L := 0 to FPlanNumLayers - 1 do
        OrderLayer(L, False)
    else
      for L := FPlanNumLayers - 1 downto 0 do
        OrderLayer(L, False);
    if not FOrderChanged then
      Break; // converged
  end;
  ResolvePlacementOverlaps; // guarantee cells never overlap
  BuildClockSubtreePlacements; // rebuild the balanced clock subtrees
  BuildSpinePlacement;
  ValidateFloorplanLayout;
  UpdateManhattanDiagnostic;
  RepaintFloorplanPage;
end;

// Rebuilds the floorplan geometry (band heights, lane widths) without
// reshuffling the placed cells. The current placement's horizontal positions
// are snapshotted (offset from each row's left edge), BuildFloorplan rebuilds
// the bias geometry and recomputes every cell's correct row Y for the new band
// layout, then the optimized X arrangement is restored. Rows that no longer fit
// (because a bias lane grew) are uniformly shifted left, preserving the row's
// shape. This is what the bias-expansion helpers use instead of a plain
// BuildFloorplan.
procedure TForm1.RebuildFloorplanPreserve;
var
  LogicSnap, ClockSnap: TDictionary<TGateInstance, TPlaceSnapshot>;
  CloneToPlace: TDictionary<TGateInstance, TGateInstance>;
  S: TPlaceSnapshot;
  i, L, ci, band: Integer;
  RowCells: TArray<Integer>;
  j, MaxRight, Shift: Integer;
  Pt: TPoint;
  PGate: TGateInstance;
begin
  if not FFloorplanValid then
  begin
    BuildFloorplan;
    Exit;
  end;
  LogicSnap := TDictionary<TGateInstance, TPlaceSnapshot>.Create;
  ClockSnap := TDictionary<TGateInstance, TPlaceSnapshot>.Create;
  CloneToPlace := TDictionary<TGateInstance, TGateInstance>.Create;
  try
    // Logic cells: snapshot the horizontal offset from the row's left edge.
    // (The vertical position is recomputed by BuildFloorplan for the new band
    // geometry, so only the optimized X arrangement is preserved.)
    for i := 0 to High(FPlacedComponents) do
    begin
      S.Gate := FPlacedComponents[i].Gate;
      S.X := FPlacedComponents[i].X - FPlanXLeft;
      LogicSnap.AddOrSetValue(S.Gate, S);
    end;
    // Clock tree interior nodes: same - keep the horizontal offset, let the
    // rebuilt clock placement set the row Y.
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if not FClockSubtree[L][ci].IsLeaf then
        begin
          S.Gate := FClockSubtree[L][ci].Gate;
          S.X := FClockSubtree[L][ci].X - FPlanXLeft;
          ClockSnap.AddOrSetValue(S.Gate, S);
        end;

    BuildFloorplan;

    // Restore logic cells' X (keeps the optimized horizontal row layout). The
    // Y is left as BuildFloorplan computed it for the current band geometry.
    for i := 0 to High(FPlacedComponents) do
      if LogicSnap.TryGetValue(FPlacedComponents[i].Gate, S) then
      begin
        FPlacedComponents[i].X := FPlanXLeft + S.X;
        FGatePlacement.AddOrSetValue(FPlacedComponents[i].Gate,
          TPoint.Create(FPlacedComponents[i].X, FPlacedComponents[i].Y));
      end;
    // Restore clock tree interior nodes' X.
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if (not FClockSubtree[L][ci].IsLeaf) and
           ClockSnap.TryGetValue(FClockSubtree[L][ci].Gate, S) then
          FClockSubtree[L][ci].X := FPlanXLeft + S.X;

    // A grown bias lane narrows the rows: uniformly shift each band's cells left
    // so they fit (this keeps the band's shape, per the user). Both the logic
    // cells and the clock-row interior nodes move together by the same amount,
    // so the row's cells stay with their row.
    for band := 0 to High(FPlanBandStarts) do
    begin
      SetLength(RowCells, 0);
      for i := 0 to High(FPlacedComponents) do
        if BandIndexOfY(FPlacedComponents[i].Y) = band then
        begin
          SetLength(RowCells, Length(RowCells) + 1);
          RowCells[High(RowCells)] := i;
        end;
      MaxRight := FPlanXLeft - 1;
      for j := 0 to High(RowCells) do
        if FPlacedComponents[RowCells[j]].X +
           FPlacedComponents[RowCells[j]].W > MaxRight then
          MaxRight := FPlacedComponents[RowCells[j]].X +
            FPlacedComponents[RowCells[j]].W;
      // Include the clock-row interior nodes of the same band: they sit in the
      // same row region and must move with it.
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if (not FClockSubtree[L][ci].IsLeaf) and
             (BandIndexOfY(FClockSubtree[L][ci].Y) = band) then
            if FClockSubtree[L][ci].X + FClockSubtree[L][ci].W > MaxRight then
              MaxRight := FClockSubtree[L][ci].X + FClockSubtree[L][ci].W;
      if MaxRight > FPlanXRight then
      begin
        Shift := MaxRight - FPlanXRight;
        for j := 0 to High(RowCells) do
        begin
          FPlacedComponents[RowCells[j]].X :=
            FPlacedComponents[RowCells[j]].X - Shift;
          if FPlacedComponents[RowCells[j]].X < FPlanXLeft then
            FPlacedComponents[RowCells[j]].X := FPlanXLeft;
          FGatePlacement.AddOrSetValue(FPlacedComponents[RowCells[j]].Gate,
            TPoint.Create(FPlacedComponents[RowCells[j]].X,
              FPlacedComponents[RowCells[j]].Y));
        end;
        // Shift the clock-row interior nodes by the same amount.
        for L := 0 to High(FClockSubtree) do
          for ci := 0 to High(FClockSubtree[L]) do
            if (not FClockSubtree[L][ci].IsLeaf) and
               (BandIndexOfY(FClockSubtree[L][ci].Y) = band) then
            begin
              FClockSubtree[L][ci].X := FClockSubtree[L][ci].X - Shift;
              if FClockSubtree[L][ci].X < FPlanXLeft then
                FClockSubtree[L][ci].X := FPlanXLeft;
            end;
      end;
    end;

    // Re-sync clocked leaves after the uniform shift: they mirror their logic
    // cells, which may have just been moved left. The subtree gates are
    // clock-model clones, so map each back to its placement-model gate by
    // index (the clone preserves gate order) before looking up FGatePlacement.
    if (FPlacementModel <> nil) and (FClockBufferedModel <> nil) and
       (FClockBufferedModel.Gates.Count > 0) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < FClockBufferedModel.Gates.Count) and
           (not CloneToPlace.ContainsKey(FClockBufferedModel.Gates[i])) then
          CloneToPlace.Add(FClockBufferedModel.Gates[i], FPlacementModel.Gates[i]);
    if (FPlacementModel <> nil) and (FClockModel <> nil) and
       (FClockModel.Gates.Count > 0) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < FClockModel.Gates.Count) and
           (not CloneToPlace.ContainsKey(FClockModel.Gates[i])) then
          CloneToPlace.Add(FClockModel.Gates[i], FPlacementModel.Gates[i]);
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if FClockSubtree[L][ci].IsLeaf and
           CloneToPlace.TryGetValue(FClockSubtree[L][ci].Gate, PGate) and
           FGatePlacement.TryGetValue(PGate, Pt) then
        begin
          FClockSubtree[L][ci].X := Pt.X;
          FClockSubtree[L][ci].Y := Pt.Y;
        end;

    ValidateFloorplanLayout;
    UpdateManhattanDiagnostic;
  finally
    LogicSnap.Free;
    ClockSnap.Free;
    CloneToPlace.Free;
  end;
  RepaintFloorplanPage;
end;

procedure TForm1.CheckBoxToggleChange(Sender: TObject);
begin
  if TabControl1.TabIndex = TabFloorplan then
    RepaintFloorplanPage;
end;

procedure TForm1.ResolvePlacementOverlaps;
var
  MaxBand, BandIdx, i, j, Idx, Tmp, MinX: Integer;
  Items: TArray<Integer>;
begin
  if Length(FPlacedComponents) = 0 then
    Exit;
  MaxBand := 0;
  for i := 0 to High(FPlacedComponents) do
  begin
    BandIdx := BandIndexOfY(FPlacedComponents[i].Y);
    if BandIdx > MaxBand then
      MaxBand := BandIdx;
  end;
  for BandIdx := 0 to MaxBand do
  begin
    // Collect the band's cells, then order them by X.
    SetLength(Items, 0);
    for i := 0 to High(FPlacedComponents) do
      if BandIndexOfY(FPlacedComponents[i].Y) = BandIdx then
      begin
        SetLength(Items, Length(Items) + 1);
        Items[High(Items)] := i;
      end;
    if Length(Items) < 2 then
      Continue;
    for i := 1 to High(Items) do
    begin
      Tmp := Items[i];
      j := i - 1;
      while (j >= 0) and (FPlacedComponents[Items[j]].X > FPlacedComponents[Tmp].X) do
      begin
        Items[j + 1] := Items[j];
        Dec(j);
      end;
      Items[j + 1] := Tmp;
    end;
    // Enforce the 1-cell gap so cells can never overlap, and clamp within the
    // row so nothing runs off the die.
    for i := 1 to High(Items) do
    begin
      MinX := FPlacedComponents[Items[i - 1]].X +
        FPlacedComponents[Items[i - 1]].W + 1;
      Idx := Items[i];
      if FPlacedComponents[Idx].X < MinX then
        FPlacedComponents[Idx].X := MinX;
      if FPlacedComponents[Idx].X + FPlacedComponents[Idx].W > FPlanXRight then
        FPlacedComponents[Idx].X := FPlanXRight - FPlacedComponents[Idx].W;
      if FPlacedComponents[Idx].X < FPlanXLeft then
        FPlacedComponents[Idx].X := FPlanXLeft;
      FGatePlacement.AddOrSetValue(FPlacedComponents[Idx].Gate,
        TPoint.Create(FPlacedComponents[Idx].X, FPlacedComponents[Idx].Y));
    end;
  end;
end;

procedure TForm1.AddFloorplanError(const Text: string);
var
  Item: TListBoxItem;
begin
  Item := TListBoxItem.Create(ListBoxFloorplanErrors);
  Item.Parent := ListBoxFloorplanErrors;
  Item.Text := '[ERROR] ' + Text;
  Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
  Item.TextSettings.FontColor := $FFFF0000;
  Inc(FFloorplanErrorCount);
end;

// World-space (um) centre of a placed gate. Mirrors PlacedCenter but in the
// placement's real coordinate system instead of screen pixels.
function TForm1.CellCenterUm(G: TGateInstance; Core: Double;
  var UX, UY: Double): Boolean;
var
  Pt: TPoint;
  Wb, Hb: Double;
begin
  Result := (G <> nil) and FGatePlacement.TryGetValue(G, Pt);
  if not Result then
    Exit;
  Wb := 1;
  Hb := 1;
  if G.Cell <> nil then
  begin
    Wb := G.Cell.Width / Core;
    Hb := G.Cell.Height / Core;
    if Wb < 1 then
      Wb := 1;
    if Hb < 1 then
      Hb := 1;
  end;
  UX := (Pt.X + Wb / 2) * Core;
  UY := (Pt.Y + Hb / 2) * Core;
end;

// Manhattan wire length (um) of one net: its placed, non-clock driver to each
// of its placed, non-clock loads. Clock pins and unplaced gates are ignored,
// exactly like the debug wire rendering.
function TForm1.NetManhattan(Net: TNet): Double;
var
  NC: TNetConnection;
  Driver, Load: TGateInstance;
  Core, SX1, SY1, SX2, SY2: Double;
begin
  Result := 0;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  Driver := nil;
  for NC in Net.Connections do
    if NC.IsDriver and (not IsClockPinName(NC.PinName)) and
       FGatePlacement.ContainsKey(NC.Gate) then
    begin
      Driver := NC.Gate;
      Break;
    end;
  if Driver = nil then
    Exit;
  if not CellCenterUm(Driver, Core, SX1, SY1) then
    Exit;
  for NC in Net.Connections do
  begin
    if NC.IsDriver then
      Continue;
    if IsClockPinName(NC.PinName) then
      Continue;
    Load := NC.Gate;
    if not CellCenterUm(Load, Core, SX2, SY2) then
      Continue;
    Result := Result + Abs(SX1 - SX2) + Abs(SY1 - SY2);
  end;
end;

// Sum of Manhattan distances (in um) of every data connection the debug wires
// draw - the total of all nets' driver->load lengths.
function TForm1.TotalManhattanDistance: Double;
var
  Pair: TPair<string, TNet>;
begin
  Result := 0;
  if (FPlacementModel = nil) or (FPlacementModel.Nets = nil) then
    Exit;
  for Pair in FPlacementModel.Nets do
    Result := Result + NetManhattan(Pair.Value);
end;

procedure TForm1.UpdateManhattanDiagnostic;
var
  Total: Double;
begin
  if ListBoxFloorplanErrors = nil then
    Exit;
  Total := TotalManhattanDistance;
  if FManhattanItem = nil then
  begin
    FManhattanItem := TListBoxItem.Create(ListBoxFloorplanErrors);
    FManhattanItem.Parent := ListBoxFloorplanErrors;
  end;
  FManhattanItem.Text := Format('Total wire length (Manhattan): %.0f um', [Total]);
end;

// Clock-tree balancing diagnostic: for each layer, compute the arrival time at
// every clocked leaf (sum of splitter/buffer delays plus estimated wire delay
// from the placed geometry) and report the skew (max - min) and total wire.
// Small per-layer skew means the geometric balancing is working.
// Returns the immobile pad position for a primary input/output net, if any.
function TForm1.GetPad(const ANetName: string; var P: TPoint): Boolean;
begin
  Result := (FPadMap <> nil) and FPadMap.TryGetValue(ANetName, P);
end;

// X (grid blocks) of display slot k in a row of N pads, evenly spaced from
// the left edge to Right (Right = row right for inputs, clock trunk right for
// outputs).
function TForm1.PadSlotX(k, N, Right: Integer): Single;
begin
  Result := FPlanXLeft + (k + 0.5) * (Right - FPlanXLeft - 1) / Max(1, N);
end;

// The slot (0..N-1) whose X is closest to DragX within [FPlanXLeft, Right).
function TForm1.NearestPadSlot(DragX: Single; N, Right: Integer): Integer;
var
  k: Integer;
  BestD, D: Single;
begin
  Result := 0;
  BestD := Abs(PadSlotX(0, N, Right) - DragX);
  for k := 1 to N - 1 do
  begin
    D := Abs(PadSlotX(k, N, Right) - DragX);
    if D < BestD then
    begin
      BestD := D;
      Result := k;
    end;
  end;
end;

// Copy of the order array with DragIdx moved to display Slot (others shift).
function TForm1.PreviewPadOrder(const Ord: TArray<Integer>;
  DragIdx, Slot: Integer): TArray<Integer>;
var
  i, k: Integer;
begin
  Result := Copy(Ord);
  k := -1;
  for i := 0 to High(Result) do
    if Result[i] = DragIdx then
    begin
      k := i;
      Break;
    end;
  if k < 0 then
    Exit;
  for i := k to High(Result) - 1 do
    Result[i] := Result[i + 1];
  SetLength(Result, Length(Result) - 1);
  SetLength(Result, Length(Result) + 1);
  for i := High(Result) downto Slot + 1 do
    Result[i] := Result[i - 1];
  Result[Slot] := DragIdx;
end;

// Recomputes every pad's X position and FPadMap from the display orders.
procedure TForm1.ReapplyPadOrder;
var
  N, M, k, Idx, X: Integer;
begin
  N := Length(FPadOrderInput);
  M := Length(FPadOrderOutput);
  for k := 0 to N - 1 do
  begin
    Idx := FPadOrderInput[k];
    if (Idx >= 0) and (Idx < Length(FPads)) then
    begin
      X := Round(PadSlotX(k, N, FPlanXRight));
      FPads[Idx].X := X;
      FPadMap.AddOrSetValue(FPads[Idx].NetName, TPoint.Create(X, FPads[Idx].Y));
    end;
  end;
  for k := 0 to M - 1 do
  begin
    Idx := FPadOrderOutput[k];
    if (Idx >= 0) and (Idx < Length(FPads)) then
    begin
      X := Round(PadSlotX(k, M, FPlanXRight + FPlanLane0W + FPlanTrunkW));
      FPads[Idx].X := X;
      FPadMap.AddOrSetValue(FPads[Idx].NetName, TPoint.Create(X, FPads[Idx].Y));
    end;
  end;
end;

// The X (grid blocks) at which a pad should be drawn. During a drag the dragged
// pad follows the mouse and the rest of its set shift to the preview slots.
function TForm1.PadDisplayX(Idx: Integer): Integer;
var
  N, k, Slot, Right: Integer;
  Order: TArray<Integer>;
begin
  if not FPadDragging then
    Exit(FPads[Idx].X);
  if Idx = FPadDragIdx then
    Exit(Round(FPadDragX));
  if FPads[Idx].IsInput then
  begin
    N := Length(FPadOrderInput);
    Right := FPlanXRight;
    Slot := NearestPadSlot(FPadDragX, N, Right);
    Order := PreviewPadOrder(FPadOrderInput, FPadDragIdx, Slot);
    for k := 0 to High(Order) do
      if Order[k] = Idx then
        Exit(Round(PadSlotX(k, N, Right)));
  end
  else
  begin
    N := Length(FPadOrderOutput);
    Right := FPlanXRight + FPlanLane0W + FPlanTrunkW;
    Slot := NearestPadSlot(FPadDragX, N, Right);
    Order := PreviewPadOrder(FPadOrderOutput, FPadDragIdx, Slot);
    for k := 0 to High(Order) do
      if Order[k] = Idx then
        Exit(Round(PadSlotX(k, N, Right)));
  end;
  Result := FPads[Idx].X;
end;

procedure TForm1.SetPlanCell(X, Y: Integer; Kind: TFloorplanCell; ALayer: Integer);
begin
  if (X >= 0) and (X < FFloorplanW) and (Y >= 0) and (Y < FFloorplanH) then
  begin
    FFloorplan[Y * FFloorplanW + X] := Kind;
    FFloorplanLayer[Y * FFloorplanW + X] := ALayer;
  end;
end;

function TForm1.GetPlanCell(X, Y: Integer): TFloorplanCell;
begin
  if (X >= 0) and (X < FFloorplanW) and (Y >= 0) and (Y < FFloorplanH) then
    Result := FFloorplan[Y * FFloorplanW + X]
  else
    Result := fcEmpty;
end;

procedure TForm1.FillPlanRect(X0, Y0, X1, Y1: Integer; Kind: TFloorplanCell;
  ALayer: Integer);
var
  x, y: Integer;
begin
  for y := Y0 to Y1 - 1 do
    for x := X0 to X1 - 1 do
      SetPlanCell(x, y, Kind, ALayer);
end;

procedure TForm1.BuildFloorplan;

  // Walks a row's clock distribution tree (from its tap net) and returns the
  // total width of all subtree components. Trunk spine elements are excluded;
  // clocked cells are leaves (counted, but their data outputs are not walked).
  function CollectTreeWidth(const ANetName: string;
    Visited: TDictionary<TGateInstance, Boolean>): Double;
  var
    Net: TNet;
    NC: TNetConnection;
    Conn: TPinConnection;
  begin
    Result := 0;
    if FClockModel = nil then
      Exit;
    if not FClockModel.Nets.TryGetValue(ANetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);
      if NC.Gate.ClockTrunk then
        Continue; // spine element, not part of the subtree
      if NC.Gate.Cell <> nil then
        Result := Result + NC.Gate.Cell.Width;
      if not CellHasClock(NC.Gate.Cell) then
        // Interior node (splitter/buffer): keep walking its output nets.
        for Conn in NC.Gate.Connections do
          if Conn.Port.Direction = pdOutput then
            Result := Result + CollectTreeWidth(Conn.NetName, Visited);
    end;
  end;

var
  Core, DieW, DieH, RowH, Util: Double;
  DieWBlocks, DieHBlocks, RowHBlocks: Integer;
  Levels: TList<Integer>;
  Gate: TGateInstance;
  L, i, NumLayers: Integer;
  WidthSum, AllocBlocks, ClkWidth, ClkBlocks: Double;
  PadRec: TPadConnection;
  ClockNetName: string;
  ClockIsInput: Boolean;
  InputPadIdx, OutputPadIdx: TArray<Integer>;
  RowNetName: string;
  Visited: TDictionary<TGateInstance, Boolean>;
  RowWidths: TArray<Integer>;
  TotalH, TotalW, XRight, BandStart, CursorY: Integer;
  MaxRowW, BodyW, LeftPad, XLeft: Integer;
  TopPad: Integer;
  AvailableWidth, TotalBands, Band, C, ChunkCount, ChunkWidth: Integer;
  LevelBandCount, LevelFirstBand, BandStarts: TArray<Integer>;
  NewExtra: TArray<Integer>;
  NewBias: TArray<TArray<Integer>>;
  NewLane: TArray<Integer>;
  OldFirst, OldCount: Integer;
  TrunkW, Lane0W, Lane1W: Integer;
  CurChunk, CurX: TArray<Integer>;
  Idx: Integer;
  P: TPlacedComponent;
  RowY, BandIndex: Integer;
  RowY0, RowY1: Integer;
begin
  // Reset the view; the die is fitted to the canvas on the next paint.
  FPlanPanX := 0;
  FPlanPanY := 0;
  FPlanZoom := 1.0;
  FPlanNeedsFit := True;
  ListBoxFloorplanErrors.Clear;
  FManhattanItem := nil; // cleared listbox invalidates the diagnostic item
  FFloorplanErrorCount := 0;
  // Place the wave-pipelined (post-DFF) netlist; fall back to the splitter-
  // inserted netlist if the pipeline has not been built yet.
  FPlacementModel := FPipelineModel;
  if FPlacementModel = nil then
  begin
    // A freshly loaded project has no pipeline model yet; build it (using the
    // restored slider) so the post-DFF netlist is used, as on the Pipeline page.
    if (FModel <> nil) and (FLib <> nil) and (FFlipFlopNames.Count > 0) then
      BuildPipelineModel;
    FPlacementModel := FPipelineModel;
    if FPlacementModel = nil then
      FPlacementModel := FModel;
  end;
  FFloorplan := nil;
  FFloorplanW := 0;
  FFloorplanH := 0;
  FFloorplanValid := False;

  if not (TryDimParse(EditCoreSize.Text, Core) and
          TryDimParse(EditDieW.Text, DieW) and
          TryDimParse(EditDieH.Text, DieH) and
          TryDimParse(EditRowHeight.Text, RowH)) or
     (Core <= 0) or (DieW <= 0) or (DieH <= 0) or (RowH <= 0) then
  begin
    AddFloorplanError('Placement configuration is incomplete or invalid; go back and fix it.');
    RepaintFloorplanPage;
    Exit;
  end;
  if not TryDimParse(EditUtilization.Text, Util) or (Util <= 0) then
    Util := 60;

  DieWBlocks := Round(DieW / Core);
  DieHBlocks := Round(DieH / Core);
  RowHBlocks := Round(RowH / Core);
  if RowHBlocks < 1 then
    RowHBlocks := 1;
  if DieWBlocks < 1 then
    DieWBlocks := 1;
  if DieHBlocks < 1 then
    DieHBlocks := 1;
  // Guard against absurd grid sizes.
  if DieWBlocks > 4096 then
  begin
    AddFloorplanError(Format('Die width of %d blocks is too large to visualise (capped at 4096).', [DieWBlocks]));
    DieWBlocks := 4096;
  end;
  if DieHBlocks > 4096 then
  begin
    AddFloorplanError(Format('Die height of %d blocks is too large to visualise (capped at 4096).', [DieHBlocks]));
    DieHBlocks := 4096;
  end;

  Levels := TList<Integer>.Create;
  try
    // All distinct clock levels (>= 0) present in the main netlist.
    if FPlacementModel <> nil then
      for Gate in FPlacementModel.Gates do
        if (Gate.ClockLevel >= 0) and (Levels.IndexOf(Gate.ClockLevel) < 0) then
          Levels.Add(Gate.ClockLevel);
    Levels.Sort;
    NumLayers := Levels.Count;

    if NumLayers = 0 then
    begin
      AddFloorplanError('No clock layers found in the netlist; load a BLIF first.');
      RepaintFloorplanPage;
      Exit;
    end;

    // Per-layer row width, calc1: sum of gate widths at that level, buffered by
    // the utilization.
    SetLength(RowWidths, NumLayers);
    for L := 0 to NumLayers - 1 do
    begin
      WidthSum := 0;
      for Gate in FPlacementModel.Gates do
        if Gate.ClockLevel = Levels[L] then
          if Gate.Cell <> nil then
            WidthSum := WidthSum + Gate.Cell.Width;
      AllocBlocks := Ceil(WidthSum / (Util / 100) / Core);
      RowWidths[L] := Round(AllocBlocks);
      if RowWidths[L] < 1 then
        RowWidths[L] := 1;
    end;

    // Per-layer row width, calc2: the clock subtree at that level (trunk
    // components excluded), buffered the same way. The allocated width is
    // the maximum of the two calculations.
    for L := 0 to NumLayers - 1 do
    begin
      ClkWidth := 0;
      if (FClockModel <> nil) and (FClockNet <> nil) and
         (FClockNet.Rows.IndexOf(Levels[L]) >= 0) then
      begin
        RowNetName := Format('clk_row_%d', [Levels[L]]);
        Visited := TDictionary<TGateInstance, Boolean>.Create;
        try
          ClkWidth := CollectTreeWidth(RowNetName, Visited);
        finally
          Visited.Free;
        end;
      end;
      ClkBlocks := Ceil(ClkWidth / (Util / 100) / Core);
      if Round(ClkBlocks) > RowWidths[L] then
        RowWidths[L] := Round(ClkBlocks);
    end;

    // Horizontal: far-left bias trunk (1), rows, the left feed bias lane
    // (FBiasLaneW[0], immediately left of the clock trunk), the clock trunk
    // (RowHBlocks - the green column, not a bias zone), then the far-right
    // bias lane (FBiasLaneW[1]). The rows are sized to their content: the
    // widest row calculated (clipped to the die's allocatable space; wider rows
    // wrap into chunks). The whole floorplan is then centered horizontally and
    // vertically in the die.
    // Bias lanes flanking the clock trunk: ensure two entries, base width 1.
    if Length(FBiasLaneW) <> 2 then
    begin
      NewLane := nil;
      SetLength(NewLane, 2);
      NewLane[0] := 1;
      NewLane[1] := 1;
      if Length(FBiasLaneW) >= 1 then
      begin
        if FBiasLaneW[0] >= 1 then
          NewLane[0] := FBiasLaneW[0];
        if Length(FBiasLaneW) >= 2 then
          if FBiasLaneW[1] >= 1 then
            NewLane[1] := FBiasLaneW[1];
      end;
      FBiasLaneW := NewLane;
    end;
    Lane0W := FBiasLaneW[0];
    Lane1W := FBiasLaneW[1];
    TrunkW := RowHBlocks; // the clock trunk is always RowHBlocks wide
    AvailableWidth := DieWBlocks - 1 - Lane0W - TrunkW - Lane1W;
    if AvailableWidth < 1 then
    begin
      AddFloorplanError(Format('Die is too narrow: at least %d blocks are needed for the bias lanes and clock trunk.',
        [1 + Lane0W + TrunkW + Lane1W]));
      RepaintFloorplanPage;
      Exit;
    end;
    MaxRowW := 0;
    for L := 0 to NumLayers - 1 do
      if RowWidths[L] > MaxRowW then
        MaxRowW := RowWidths[L];
    if MaxRowW > AvailableWidth then
      MaxRowW := AvailableWidth; // clip to the die's allocatable row width
    // The congestion helpers may have nudged the rows tighter (column
    // expansion recovered space from the utilization slack).
    if FPlanMaxRowW > 0 then
      if FPlanMaxRowW < MaxRowW then
        MaxRowW := FPlanMaxRowW;
    BodyW := MaxRowW + 1 + Lane0W + TrunkW + Lane1W;
    if BodyW > DieWBlocks then
    begin
      AddFloorplanError(Format('Not enough width: floorplan needs %d blocks, die has %d.',
        [BodyW, DieWBlocks]));
      BodyW := DieWBlocks;
    end;
    // Center the floorplan horizontally (rows + trunks) in the die; a floorplan
    // that fills the die gets no padding. The far-left bias lane and far-right
    // bias lane sit at the two edges of the allocated block.
    LeftPad := (DieWBlocks - BodyW) div 2;
    if LeftPad < 0 then
      LeftPad := 0;
    XLeft := LeftPad + 1;                 // left edge of the rows
    XRight := XLeft + MaxRowW;            // common right edge of the rows
    TotalW := LeftPad + BodyW;            // far-right edge of the bias lane
    FPlanXLeft := XLeft;
    FPlanXRight := XRight;

    // Allocate the die-sized grid and its per-cell layer tags.
    FFloorplanW := DieWBlocks;
    FFloorplanH := DieHBlocks;
    SetLength(FFloorplan, FFloorplanW * FFloorplanH);
    SetLength(FFloorplanLayer, FFloorplanW * FFloorplanH);
    for i := 0 to High(FFloorplan) do
    begin
      FFloorplan[i] := fcEmpty;
      FFloorplanLayer[i] := -1;
    end;

    // Lay out the bands, wrapping any row wider than the die so it continues
    // underneath in its own bias/logic/bias/clock band. The chunk layout per
    // layer is computed first so the congestion extra rows can be remapped by
    // (layer, chunk) identity when wrapping changes the band indexing.
    SetLength(LevelBandCount, NumLayers);
    SetLength(LevelFirstBand, NumLayers);
    TotalBands := 0;
    for L := 0 to NumLayers - 1 do
    begin
      LevelFirstBand[L] := TotalBands;
      LevelBandCount[L] := Max(1, Ceil(RowWidths[L] / AvailableWidth));
      TotalBands := TotalBands + LevelBandCount[L];
    end;
    // Remap the accumulated per-row extra rows by (layer, chunk): the old
    // layout is still in FPlanLevelFirstBand/FPlanLevelBandCount from the last
    // build. Chunks that existed before keep their rows; new chunks start at 0.
    if Length(FLogicRowExtra) > 0 then
    begin
      NewExtra := nil;
      SetLength(NewExtra, TotalBands);
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FLogicRowExtra)) then
            NewExtra[LevelFirstBand[L] + Band] := FLogicRowExtra[OldFirst + Band];
      end;
      FLogicRowExtra := NewExtra;
    end
    else
      SetLength(FLogicRowExtra, TotalBands);
    if Length(FClockRowExtra) > 0 then
    begin
      NewExtra := nil;
      SetLength(NewExtra, TotalBands);
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FClockRowExtra)) then
            NewExtra[LevelFirstBand[L] + Band] := FClockRowExtra[OldFirst + Band];
      end;
      FClockRowExtra := NewExtra;
    end
    else
      SetLength(FClockRowExtra, TotalBands);
    // Remap the per-band bias-row extras (top/middle) by (layer, chunk).
    if Length(FBiasRowH) > 0 then
    begin
      NewBias := nil;
      SetLength(NewBias, TotalBands);
      for Band := 0 to TotalBands - 1 do
      begin
        SetLength(NewBias[Band], 2);
        NewBias[Band][0] := 0;
        NewBias[Band][1] := 0;
      end;
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FBiasRowH)) and
             (Length(FBiasRowH[OldFirst + Band]) >= 2) then
          begin
            NewBias[LevelFirstBand[L] + Band][0] :=
              FBiasRowH[OldFirst + Band][0];
            NewBias[LevelFirstBand[L] + Band][1] :=
              FBiasRowH[OldFirst + Band][1];
          end;
      end;
      FBiasRowH := NewBias;
    end
    else
    begin
      SetLength(FBiasRowH, TotalBands);
      for Band := 0 to TotalBands - 1 do
      begin
        SetLength(FBiasRowH[Band], 2);
        FBiasRowH[Band][0] := 0;
        FBiasRowH[Band][1] := 0;
      end;
    end;
    // Default: the topmost (band 0's top) and the bottommost full-width bias
    // rows start 2 cells thick (base 1 + one default extra cell), which is
    // needed to route the bias lines. The expansion helpers grow them further.
    if Length(FBiasRowH) > 0 then
      if Length(FBiasRowH[0]) > 0 then
        if FBiasRowH[0][0] < 1 then
          FBiasRowH[0][0] := 1;
    if FBottomBiasH < 1 then
      FBottomBiasH := 1;
    // Total height = sum of per-band heights (top bias + logic row + its extras
    // + middle bias + clock row + its extras) + the bottom-most bias line.
    SetLength(FPlanBandHeight, TotalBands);
    TotalH := 0;
    for Band := 0 to TotalBands - 1 do
    begin
      FPlanBandHeight[Band] := BandTopBiasH(Band) + RowHBlocks +
        FLogicRowExtra[Band] + BandMidBiasH(Band) + RowHBlocks +
        FClockRowExtra[Band];
      if FPlanBandHeight[Band] < 1 then
        FPlanBandHeight[Band] := 1;
      TotalH := TotalH + FPlanBandHeight[Band];
    end;
    Inc(TotalH, 1 + FBottomBiasH);

    // Failure checks - report and keep whatever fits. Two extra rows are reserved
    // for the I/O pads (top inputs, bottom outputs); the bias trunk and the
    // far-right bias lane need one column each side of the rows.
    if TotalH + 2 > DieHBlocks then
      AddFloorplanError(Format('Not enough height: floorplan needs %d blocks (plus 2 pad rows), die has %d.',
        [TotalH, DieHBlocks]));
    if TotalW > DieWBlocks then
      AddFloorplanError(Format('Not enough width: floorplan needs %d blocks, die has %d.',
        [TotalW, DieWBlocks]));

    // Vertically center the stack in the die: the same number of reserved rows
    // above (input pads + routing) and below (output pads + routing), instead
    // of hugging the top edge with a single pad row.
    TopPad := (DieHBlocks - TotalH) div 2;
    if TopPad < 1 then
      TopPad := 1;

    // Bias trunk (red) on the far left, and the vertical bias lanes (red)
    // flanking the clock trunk, all spanning the stack height (the reserved
    // rows above and below stay clear for the I/O pads).
    FillPlanRect(LeftPad, TopPad, LeftPad + 1, TopPad + TotalH, fcBias, -1);
    // Left feed bias lane (width Lane0W), immediately left of the clock trunk.
    FillPlanRect(XRight, TopPad, XRight + Lane0W, TopPad + TotalH, fcBias, -1);
    // Clock trunk (green), spanning the stack height. It is enclosed by bias:
    // the two flanking lanes on its sides, and the full-width topmost and
    // bottom-most bias rows above and below it.
    FillPlanRect(XRight + Lane0W, TopPad,
      XRight + Lane0W + TrunkW, TopPad + TotalH, fcClock, -1);
    // Far-right bias lane (width Lane1W), spanning the stack height; the
    // top-right corner (the input-pin row) stays empty.
    FillPlanRect(XRight + Lane0W + TrunkW, TopPad, TotalW, TopPad + TotalH, fcBias, -1);

    // Bands, top to bottom; a layer may wrap into several bands. The bands are
    // shifted down by one row so the top row is reserved for input pads.
    SetLength(BandStarts, TotalBands);
    Band := 0;
    CursorY := TopPad; // running Y cursor: bands have per-band heights now
    for L := 0 to NumLayers - 1 do
    begin
      ChunkCount := LevelBandCount[L];
      for C := 0 to ChunkCount - 1 do
      begin
        ChunkWidth := RowWidths[L] - C * AvailableWidth;
        if ChunkWidth > AvailableWidth then
          ChunkWidth := AvailableWidth;
        if ChunkWidth < 1 then
          ChunkWidth := 1;
        BandStart := CursorY;
        BandStarts[Band] := BandStart;
        // Bias line spanning from the bias trunk to the common right edge. The
        // topmost one (band 0) runs the full floorplan width, reaching the
        // far-right bias lane so it encloses the top of the clock trunk.
        if Band = 0 then
          FillPlanRect(LeftPad, BandStart, TotalW,
            BandStart + BandTopBiasH(Band), fcBias, Levels[L])
        else
          FillPlanRect(LeftPad, BandStart, XRight,
            BandStart + BandTopBiasH(Band), fcBias, Levels[L]);
        // Logic row (blue), as wide as its chunk, left-aligned from the bias
        // trunk. Extra logic-row rows extend the logic row downward (they are
        // routing space between logic and clock). Computed locally (BandStart,
        // RowHBlocks) because the FPlan* snapshots are only written later.
        RowY0 := BandStart + BandTopBiasH(Band);
        RowY1 := RowY0 + RowHBlocks + FLogicRowExtra[Band] + BandMidBiasH(Band);
        FillPlanRect(XLeft, RowY0,
          XLeft + ChunkWidth, RowY0 + RowHBlocks, fcLogic, Levels[L]);
        if FLogicRowExtra[Band] > 0 then
          FillPlanRect(XLeft, RowY0 + RowHBlocks,
            XLeft + ChunkWidth, RowY0 + RowHBlocks + FLogicRowExtra[Band],
            fcLogicFill, Levels[L]);
        // Bias line above the clock row.
        FillPlanRect(LeftPad, RowY1 - BandMidBiasH(Band),
          XRight, RowY1, fcBias, Levels[L]);
        // Clock row (green), as wide as its chunk, left-aligned. Extra clock-
        // row rows extend the clock row downward.
        FillPlanRect(XLeft, RowY1,
          XLeft + ChunkWidth, RowY1 + RowHBlocks, fcClock, Levels[L]);
        if FClockRowExtra[Band] > 0 then
          FillPlanRect(XLeft, RowY1 + RowHBlocks,
            XLeft + ChunkWidth, RowY1 + RowHBlocks +
            FClockRowExtra[Band], fcClockFill, Levels[L]);
        Inc(Band);
        CursorY := CursorY + FPlanBandHeight[Band - 1];
      end;
    end;

    // Bias line below the very bottom cell row (the last band's clock row),
    // stretching the full floorplan width left to right, unbroken, so it
    // encloses the bottom of the clock trunk.
    FillPlanRect(LeftPad, TopPad + TotalH - 1 - FBottomBiasH,
      TotalW, TopPad + TotalH, fcBias, -1);

    // Snapshot the layout for the ordering animation.
    FPlanCore := Core;
    FPlanLevels := Levels.ToArray;
    FPlanNumLayers := NumLayers;
    FPlanLevelFirstBand := LevelFirstBand;
    FPlanLevelBandCount := LevelBandCount;
    FPlanBandStarts := BandStarts;
    FPlanRowHBlocks := RowHBlocks;
    FPlanTrunkW := TrunkW;
    FPlanLane0W := Lane0W;
    FPlanLane1W := Lane1W;
    FPlanLastTotalH := TotalH;

    // Build the immobile I/O anchor pads. Inputs go on the top row; the clock
    // input is placed on its own at the bottom of the die, in the middle of the
    // clock trunk, where it feeds the base of the clock tree. Outputs go on the
    // bottom row, spaced from the left edge to the clock trunk's right edge.
    SetLength(FPads, 0);
    FPadMap.Clear;
    FClockPadIdx := -1;
    if FPlacementModel <> nil then
    begin
      ClockNetName := '';
      if FClockNet <> nil then
        ClockNetName := FClockNet.SourceNet;
      if ClockNetName = '' then
        ClockNetName := ClockNetFor(FPlacementModel);
      ClockIsInput := (ClockNetName <> '') and
        (FPlacementModel.Inputs.IndexOf(ClockNetName) >= 0);

      // Inputs (top row, Y = 0), excluding the clock input.
      SetLength(InputPadIdx, 0);
      for i := 0 to FPlacementModel.Inputs.Count - 1 do
      begin
        if ClockIsInput and
           SameText(FPlacementModel.Inputs[i], ClockNetName) then
          Continue;
        PadRec.NetName := FPlacementModel.Inputs[i];
        PadRec.X := 0;
        PadRec.Y := 0;
        PadRec.IsInput := True;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        SetLength(InputPadIdx, Length(InputPadIdx) + 1);
        InputPadIdx[High(InputPadIdx)] := High(FPads);
      end;
      // Outputs (bottom row, Y = last row of the die).
      SetLength(OutputPadIdx, 0);
      for i := 0 to FPlacementModel.Outputs.Count - 1 do
      begin
        PadRec.NetName := FPlacementModel.Outputs[i];
        PadRec.X := 0;
        PadRec.Y := DieHBlocks - 1;
        PadRec.IsInput := False;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        SetLength(OutputPadIdx, Length(OutputPadIdx) + 1);
        OutputPadIdx[High(OutputPadIdx)] := High(FPads);
      end;
      // The clock input: bottom of the die, middle of the clock trunk.
      if ClockIsInput then
      begin
        PadRec.NetName := ClockNetName;
        PadRec.X := XRight + FPlanLane0W + FPlanTrunkW div 2;
        PadRec.Y := DieHBlocks - 1;
        PadRec.IsInput := True;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        FPadMap.AddOrSetValue(PadRec.NetName,
          TPoint.Create(PadRec.X, PadRec.Y));
        FClockPadIdx := High(FPads);
      end;
      // Initialize/preserve the display orders (FPads indices). A user
      // reordering persists across rebuilds and optimise.
      if Length(FPadOrderInput) <> Length(InputPadIdx) then
      begin
        SetLength(FPadOrderInput, Length(InputPadIdx));
        for i := 0 to High(FPadOrderInput) do
          FPadOrderInput[i] := InputPadIdx[i];
      end;
      if Length(FPadOrderOutput) <> Length(OutputPadIdx) then
      begin
        SetLength(FPadOrderOutput, Length(OutputPadIdx));
        for i := 0 to High(FPadOrderOutput) do
          FPadOrderOutput[i] := OutputPadIdx[i];
      end;
      ReapplyPadOrder;
    end;

    // Place logic gates (netlist order) into their layer's logic rows, one
    // component per cell with a one-cell gap. Clock placement and bias
    // connections are ignored for now.
    FDroppedCells := 0;
    SetLength(FPlacedComponents, 0);
    FGatePlacement.Clear;
    SetLength(CurChunk, NumLayers);
    SetLength(CurX, NumLayers);
    for L := 0 to NumLayers - 1 do
    begin
      CurChunk[L] := 0;
      CurX[L] := XLeft; // fill the row (from the bias trunk rightwards)
    end;
    if FPlacementModel <> nil then
      for Idx := 0 to FPlacementModel.Gates.Count - 1 do
      begin
        Gate := FPlacementModel.Gates[Idx];
        L := Levels.IndexOf(Gate.ClockLevel);
        if L < 0 then
          Continue; // unleveled / not a floorplan layer
        if Gate.Cell = nil then
          Continue;
        // Component footprint in grid cells (widths/heights are multiples of
        // the core block, as guaranteed by the configuration page).
        P.W := Round(Gate.Cell.Width / Core);
        if P.W < 1 then
          P.W := 1;
        P.H := Round(Gate.Cell.Height / Core);
        if P.H < 1 then
          P.H := 1;
        // Advance to the next chunk of this level if the current one cannot
        // fit the component (component + one-cell gap).
        while (CurChunk[L] < LevelBandCount[L]) and
              (CurX[L] + P.W > XRight) do
        begin
          Inc(CurChunk[L]);
          if CurChunk[L] < LevelBandCount[L] then
            CurX[L] := XLeft
          else
            CurX[L] := High(Integer);
        end;
        if CurChunk[L] >= LevelBandCount[L] then
        begin
          Inc(FDroppedCells);
          Continue; // no more room for this layer
        end;
        BandIndex := LevelFirstBand[L] + CurChunk[L];
        RowY := BandLogicRowY(BandIndex) + ((RowHBlocks - P.H) div 2);
        P.Gate := Gate;
        P.InstanceName := Format('%s_%d', [Gate.CellName, Idx + 1]);
        P.CellName := Gate.CellName;
        P.ClockLevel := Gate.ClockLevel;
        P.X := CurX[L];
        P.Y := RowY;
        SetLength(FPlacedComponents, Length(FPlacedComponents) + 1);
        FPlacedComponents[High(FPlacedComponents)] := P;
        FGatePlacement.Add(Gate, TPoint.Create(P.X, P.Y));
        CurX[L] := CurX[L] + P.W + 1; // component + one-cell gap
      end;

    FFloorplanValid := True;
  finally
    Levels.Free;
  end;

  BuildClockSubtreePlacements;
  BuildSpinePlacement;
  ValidateFloorplanLayout;
  UpdateManhattanDiagnostic;
  RepaintFloorplanPage;
end;

// Walks the REAL clock distribution tree of each layer (from its tap net in the
// buffered clock model) and places every actual cell: interior splitter/buffer
// nodes sit in the layer's clock row, horizontally balanced between their
// children; clocked leaves stay at their placed positions. This is the real
// netlist structure, not a virtual reconstruction.
procedure TForm1.BuildClockSubtreePlacements;
var
  L, i: Integer;
  Visited: TDictionary<TGateInstance, Boolean>;
  ClockPlacement: TDictionary<TGateInstance, TPoint>;
  MapPt: TPoint;
  TreeModel: TBlifModel;
  HasClkCell: Boolean;
  Interior: TArray<Integer>;
  Tmp, j, Idx, W, MinX, NextLeft, BandCount, s, e: Integer;
  RootNode: Integer;

  function WalkNet(const ANetName: string; ClkY: Integer): Integer;
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    Node, SubIdx: Integer;
    SumX: Double;
    Cnt: Integer;
    Pt: TPoint;
  begin
    Result := -1;
    if (TreeModel = nil) or
       (not TreeModel.Nets.TryGetValue(ANetName, Net)) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);

      SetLength(FClockSubtree[L], Length(FClockSubtree[L]) + 1);
      Node := High(FClockSubtree[L]);
      FClockSubtree[L][Node].Gate := NC.Gate;

      // Real cell footprint.
      FClockSubtree[L][Node].W := 1;
      FClockSubtree[L][Node].H := 1;
      if NC.Gate.Cell <> nil then
      begin
        FClockSubtree[L][Node].W := Round(NC.Gate.Cell.Width / FPlanCore);
        FClockSubtree[L][Node].H := Round(NC.Gate.Cell.Height / FPlanCore);
        if FClockSubtree[L][Node].W < 1 then
          FClockSubtree[L][Node].W := 1;
        if FClockSubtree[L][Node].H < 1 then
          FClockSubtree[L][Node].H := 1;
      end;

      if CellHasClock(NC.Gate.Cell) then
      begin
        // Leaf: keep its placed position.
        FClockSubtree[L][Node].IsLeaf := True;
        if ClockPlacement.TryGetValue(NC.Gate, Pt) then
        begin
          FClockSubtree[L][Node].X := Pt.X;
          FClockSubtree[L][Node].Y := Pt.Y;
        end
        else
        begin
          FClockSubtree[L][Node].X := (FPlanXLeft + FPlanXRight) div 2;
          FClockSubtree[L][Node].Y := ClkY;
        end;
      end
      else
      begin
        // Interior splitter/buffer: balanced between its children.
        FClockSubtree[L][Node].IsLeaf := False;
        SumX := 0;
        Cnt := 0;
        for OutConn in NC.Gate.Connections do
          if OutConn.Port.Direction = pdOutput then
          begin
            SubIdx := WalkNet(OutConn.NetName, ClkY);
            if SubIdx >= 0 then
            begin
              SetLength(FClockSubtree[L][Node].Children,
                Length(FClockSubtree[L][Node].Children) + 1);
              FClockSubtree[L][Node].Children[
                High(FClockSubtree[L][Node].Children)] := SubIdx;
              SumX := SumX + (FClockSubtree[L][SubIdx].X +
                FClockSubtree[L][SubIdx].W / 2);
              Inc(Cnt);
            end;
          end;
        if Cnt > 0 then
        begin
          FClockSubtree[L][Node].X :=
            Round(SumX / Cnt - FClockSubtree[L][Node].W / 2);
          if FClockSubtree[L][Node].X < FPlanXLeft then
            FClockSubtree[L][Node].X := FPlanXLeft;
          if FClockSubtree[L][Node].X + FClockSubtree[L][Node].W > FPlanXRight then
            FClockSubtree[L][Node].X := FPlanXRight - FClockSubtree[L][Node].W;
          FClockSubtree[L][Node].Y := ClkY - FClockSubtree[L][Node].H div 2;
          if FClockSubtree[L][Node].Y < 0 then
            FClockSubtree[L][Node].Y := 0;
        end
        else
        begin
          FClockSubtree[L][Node].X := (FPlanXLeft + FPlanXRight) div 2;
          FClockSubtree[L][Node].Y := ClkY - FClockSubtree[L][Node].H div 2;
        end;
      end;

      if Result < 0 then
        Result := Node;
    end;
  end;

  // Bottom-up band assignment: each interior node joins the band holding the
  // majority of its descendant clocked leaves, and sits in that band's clock
  // row (spreading a level's network across its wrapped bands). Returns the
  // per-band descendant-leaf counts.
  function AssignBands(NodeIdx: Integer): TArray<Integer>;
  var
    k, Band, Child, BestBand: Integer;
    Counts, ChildCounts: TArray<Integer>;
  begin
    SetLength(Counts, BandCount);
    if FClockSubtree[L][NodeIdx].IsLeaf then
    begin
      Band := BandIndexOfY(FClockSubtree[L][NodeIdx].Y) - FPlanLevelFirstBand[L];
      if Band < 0 then
        Band := 0;
      if Band >= BandCount then
        Band := BandCount - 1;
      FClockSubtree[L][NodeIdx].Band := Band;
      Counts[Band] := 1;
      Result := Counts;
      Exit;
    end;
    for k := 0 to High(FClockSubtree[L][NodeIdx].Children) do
    begin
      Child := FClockSubtree[L][NodeIdx].Children[k];
      ChildCounts := AssignBands(Child);
      for Band := 0 to BandCount - 1 do
        Counts[Band] := Counts[Band] + ChildCounts[Band];
    end;
    BestBand := 0;
    for Band := 1 to BandCount - 1 do
      if Counts[Band] > Counts[BestBand] then
        BestBand := Band;
    FClockSubtree[L][NodeIdx].Band := BestBand;
    FClockSubtree[L][NodeIdx].Y := BandClockRowY(
      FPlanLevelFirstBand[L] + BestBand) +
      FPlanRowHBlocks div 2 - FClockSubtree[L][NodeIdx].H div 2;
    if FClockSubtree[L][NodeIdx].Y < 0 then
      FClockSubtree[L][NodeIdx].Y := 0;
    Result := Counts;
  end;

begin
  // On a freshly loaded project the clock network may not exist yet (it is
  // normally created when visiting the clock tab); build it on demand so the
  // subtrees appear without a manual round-trip.
  if FClockModel = nil then
    BuildClockModel;
  SetLength(FClockSubtree, FPlanNumLayers);
  // Prefer the delay-replaced (buffered) model; fall back to the original
  // clock model so the row trees still show if the buffered copy was dropped
  // by a stale pipeline rebuild.
  TreeModel := FClockBufferedModel;
  if TreeModel = nil then
    TreeModel := FClockModel;
  Visited := TDictionary<TGateInstance, Boolean>.Create;
  ClockPlacement := TDictionary<TGateInstance, TPoint>.Create;
  try
    if TreeModel = nil then
      AddFloorplanError('Clock tree: no clock model available (rebuild the clock network).')
    else if FClockBufferedModel = nil then
      AddFloorplanError('Clock tree: using original model (buffered copy absent).');
    if FPlacementModel = nil then
      AddFloorplanError('Clock tree: placement model is nil.');
    // The clock model is a deep clone, so its gate objects differ from the
    // placement model's. The clone preserves gate order, so gate i of the
    // clock model corresponds to gate i of the placement model (for i within
    // the original netlist). Map those to their placed positions.
    if (FPlacementModel <> nil) and (TreeModel <> nil) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < TreeModel.Gates.Count) and
           FGatePlacement.TryGetValue(FPlacementModel.Gates[i], MapPt) then
          ClockPlacement.AddOrSetValue(TreeModel.Gates[i], MapPt);

    for L := 0 to FPlanNumLayers - 1 do
    begin
      SetLength(FClockSubtree[L], 0);
      Visited.Clear;
      // Level 0 (and any level with no clocked cells) legitimately has no
      // clock tree; only flag a missing tap when clocked cells exist there.
      HasClkCell := False;
      for i := 0 to High(FPlacedComponents) do
        if (FPlacedComponents[i].ClockLevel = FPlanLevels[L]) and
           (FPlacedComponents[i].Gate <> nil) and
           CellHasClock(FPlacedComponents[i].Gate.Cell) then
        begin
          HasClkCell := True;
          Break;
        end;
      if HasClkCell and (TreeModel <> nil) and
         (not TreeModel.Nets.ContainsKey(Format('clk_row_%d', [FPlanLevels[L]]))) then
        AddFloorplanError(Format('Clock tree: tap net "clk_row_%d" missing.',
          [FPlanLevels[L]]));
      RootNode := WalkNet(Format('clk_row_%d', [FPlanLevels[L]]),
        BandClockRowY(FPlanLevelFirstBand[L]) + FPlanRowHBlocks div 2);
      // Spread the level's network across its wrapped bands: assign each node
      // to the band holding the majority of its descendant leaves, and place
      // interior nodes in that band's clock row. WalkNet appends the root
      // first, so the tree root is its returned value, not the last index.
      if RootNode >= 0 then
      begin
        BandCount := FPlanLevelBandCount[L];
        if BandCount < 1 then
          BandCount := 1;
        AssignBands(RootNode);
      end;
    end;

    // Enforce a one-cell gap between the interior nodes of each layer. They all
    // share the layer's clock row, so without this a chain whose leaves cluster
    // (e.g. a small test circuit) piles its splitters on top of each other.
    // Nodes in different bands (different Y) cannot collide, so each same-Y
    // group is resolved independently.
    for L := 0 to High(FClockSubtree) do
    begin
      SetLength(Interior, 0);
      for i := 0 to High(FClockSubtree[L]) do
        if not FClockSubtree[L][i].IsLeaf then
        begin
          SetLength(Interior, Length(Interior) + 1);
          Interior[High(Interior)] := i;
        end;
      if Length(Interior) < 2 then
        Continue;
      // Stable sort by (Y, X) so each band's row is a contiguous run.
      for i := 1 to High(Interior) do
      begin
        Tmp := Interior[i];
        j := i - 1;
        while (j >= 0) and
              ((FClockSubtree[L][Interior[j]].Y > FClockSubtree[L][Tmp].Y) or
               ((FClockSubtree[L][Interior[j]].Y = FClockSubtree[L][Tmp].Y) and
                (FClockSubtree[L][Interior[j]].X > FClockSubtree[L][Tmp].X))) do
        begin
          Interior[j + 1] := Interior[j];
          Dec(j);
        end;
        Interior[j + 1] := Tmp;
      end;
      s := 0;
      while s < Length(Interior) do
      begin
        e := s;
        while (e < Length(Interior)) and
              (FClockSubtree[L][Interior[e]].Y = FClockSubtree[L][Interior[s]].Y) do
          Inc(e);
        if e - s >= 2 then
        begin
          // Forward pass: keep a one-cell gap, clamped within the row.
          MinX := FPlanXLeft;
          for i := s to e - 1 do
          begin
            Idx := Interior[i];
            W := FClockSubtree[L][Idx].W;
            if FClockSubtree[L][Idx].X < MinX then
              FClockSubtree[L][Idx].X := MinX;
            if FClockSubtree[L][Idx].X + W > FPlanXRight then
              FClockSubtree[L][Idx].X := FPlanXRight - W;
            if FClockSubtree[L][Idx].X < FPlanXLeft then
              FClockSubtree[L][Idx].X := FPlanXLeft;
            MinX := FClockSubtree[L][Idx].X + W + 1;
          end;
          // Backward pass: release any forward push where there is room.
          NextLeft := FPlanXRight;
          for i := e - 1 downto s do
          begin
            Idx := Interior[i];
            W := FClockSubtree[L][Idx].W;
            if FClockSubtree[L][Idx].X + W > FPlanXRight then
              FClockSubtree[L][Idx].X := FPlanXRight - W;
            if FClockSubtree[L][Idx].X + W + 1 > NextLeft then
              FClockSubtree[L][Idx].X := NextLeft - W - 1;
            if FClockSubtree[L][Idx].X < FPlanXLeft then
              FClockSubtree[L][Idx].X := FPlanXLeft;
            NextLeft := FClockSubtree[L][Idx].X;
          end;
        end;
        s := e;
      end;
    end;
  finally
    ClockPlacement.Free;
    Visited.Free;
  end;
end;

// Places the clock trunk (spine): junction splitters at the base (bottom) of
// each layer's trunk segment, and each stage's buffer chain stacked upward in
// the trunk. If a buffer would collide with the next junction it overflows to
// the closest band's clock row. Trunk cells are recorded as rotated 90 deg CCW
// (cell top faces the bias line), so the placed footprint swaps width/height.
procedure TForm1.BuildSpinePlacement;
const
  Gap = 1;
var
  TreeModel: TBlifModel;
  CurNet: string;
  i, j, k, L, Lv, NextJ, Cursor, BufY, BestB, TrunkX, LastB: Integer;
  Net: TNet;
  NC: TNetConnection;
  Conn: TPinConnection;
  Gate: TGateInstance;
  Comp: TSpineComponent;
  SegBottom, ClkY, BestD, D: Double;
begin
  SetLength(FSpine, 0);
  TreeModel := FClockBufferedModel;
  if TreeModel = nil then
    TreeModel := FClockModel;
  if (TreeModel = nil) or (FClockNet = nil) then
    Exit;

  // ---- Collect the spine in order: junction, stage buffers, next junction ----
  CurNet := FClockNet.SourceNet;
  while True do
  begin
    Gate := nil;
    if TreeModel.Nets.TryGetValue(CurNet, Net) then
      for NC in Net.Connections do
        if (not NC.IsDriver) and NC.Gate.ClockTrunk then
        begin
          Gate := NC.Gate;
          Break;
        end;
    if Gate = nil then
      Break; // end of the spine (a row tree net, no junction)

    Comp.Gate := Gate;
    Comp.IsJunction := True;
    Comp.Rotated := True;
    Comp.Band := -1;
    Comp.W := 1;
    Comp.H := 1;
    if Gate.Cell <> nil then
    begin
      Comp.W := Round(Gate.Cell.Height / FPlanCore); // rotated: W = height
      Comp.H := Round(Gate.Cell.Width / FPlanCore);
      if Comp.W < 1 then Comp.W := 1;
      if Comp.H < 1 then Comp.H := 1;
    end;
    SetLength(FSpine, Length(FSpine) + 1);
    FSpine[High(FSpine)] := Comp;

    // The delay output net (the junction's output that is not a row tree).
    CurNet := '';
    for Conn in Gate.Connections do
      if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) and
         (not SameText(Copy(Conn.NetName, 1, 8), 'clk_row_')) then
      begin
        CurNet := Conn.NetName;
        Break;
      end;
    if CurNet = '' then
      Break;

    // Walk the stage buffer chain.
    while True do
    begin
      if SameText(Copy(CurNet, 1, 8), 'clk_row_') then
        Break; // reached the final row's tree
      Gate := nil;
      if TreeModel.Nets.TryGetValue(CurNet, Net) then
        for NC in Net.Connections do
          if (not NC.IsDriver) and (not NC.Gate.ClockTrunk) and
             (not CellHasClock(NC.Gate.Cell)) then
          begin
            Gate := NC.Gate;
            Break;
          end;
      if Gate = nil then
        Break; // no more buffers on this spine net
      Comp.Gate := Gate;
      Comp.IsJunction := False;
      Comp.Rotated := True;
      Comp.Band := -1;
      Comp.W := 1;
      Comp.H := 1;
      if Gate.Cell <> nil then
      begin
        Comp.W := Round(Gate.Cell.Height / FPlanCore);
        Comp.H := Round(Gate.Cell.Width / FPlanCore);
        if Comp.W < 1 then Comp.W := 1;
        if Comp.H < 1 then Comp.H := 1;
      end;
      SetLength(FSpine, Length(FSpine) + 1);
      FSpine[High(FSpine)] := Comp;
      CurNet := '';
      for Conn in Gate.Connections do
        if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
        begin
          CurNet := Conn.NetName;
          Break;
        end;
      if CurNet = '' then
        Break;
    end;
  end;

  // ---- Place the junctions at the base of their layers. ---------------------
  // The clock trunk sits between the two flanking bias lanes: its left edge is
  // after the left feed lane (FPlanXRight + FPlanLane0W), so the trunk cells
  // move right with the lane when it is widened.
  TrunkX := FPlanXRight + FPlanLane0W;
  for i := 0 to High(FSpine) do
    if FSpine[i].IsJunction then
    begin
      Lv := FSpine[i].Gate.ClockLevel;
      L := -1;
      for j := 0 to High(FPlanLevels) do
        if FPlanLevels[j] = Lv then
        begin
          L := j;
          Break;
        end;
      if L < 0 then
        Continue;
      LastB := FPlanLevelFirstBand[L] + FPlanLevelBandCount[L] - 1;
      SegBottom := BandClockRowY(LastB) + FPlanRowHBlocks;
      FSpine[i].Y := Round(SegBottom - FSpine[i].H);
      FSpine[i].X := TrunkX + (FPlanRowHBlocks - FSpine[i].W) div 2;
      if FSpine[i].X < TrunkX then
        FSpine[i].X := TrunkX;
    end;

  // ---- Place the stage buffers, stacked upward; overflow on collision. ------
  i := 0;
  while i <= High(FSpine) do
  begin
    if not FSpine[i].IsJunction then
    begin
      Inc(i);
      Continue;
    end;
    NextJ := -1;
    for j := i + 1 to High(FSpine) do
      if FSpine[j].IsJunction then
      begin
        NextJ := j;
        Break;
      end;
    Cursor := FSpine[i].Y; // buffers go up from the junction's top
    for j := i + 1 to High(FSpine) do
    begin
      if FSpine[j].IsJunction then
        Break;
      BufY := Cursor - FSpine[j].H - Gap;
      if (NextJ >= 0) and
         (BufY < FSpine[NextJ].Y + FSpine[NextJ].H) then
      begin
        // Overflow to the closest band's clock row (unrotated).
        BestB := 0;
        BestD := MaxSingle;
        for k := 0 to High(FPlanBandStarts) do
        begin
          ClkY := BandClockRowY(k) + FPlanRowHBlocks / 2;
          D := Abs(ClkY - BufY);
          if D < BestD then
          begin
            BestD := D;
            BestB := k;
          end;
        end;
        FSpine[j].Rotated := False;
        FSpine[j].Band := BestB;
        FSpine[j].W := 1;
        FSpine[j].H := 1;
        if (FSpine[j].Gate <> nil) and (FSpine[j].Gate.Cell <> nil) then
        begin
          FSpine[j].W := Round(FSpine[j].Gate.Cell.Width / FPlanCore);
          FSpine[j].H := Round(FSpine[j].Gate.Cell.Height / FPlanCore);
          if FSpine[j].W < 1 then FSpine[j].W := 1;
          if FSpine[j].H < 1 then FSpine[j].H := 1;
        end;
        FSpine[j].X := FPlanXRight - FSpine[j].W;
        FSpine[j].Y := BandClockRowY(BestB) +
          (FPlanRowHBlocks - FSpine[j].H) div 2;
      end
      else
      begin
        FSpine[j].Y := BufY;
        FSpine[j].X := TrunkX + (FPlanRowHBlocks - FSpine[j].W) div 2;
        if FSpine[j].X < TrunkX then
          FSpine[j].X := TrunkX;
        Cursor := BufY;
      end;
    end;
    if NextJ < 0 then
      Break;
    i := NextJ;
  end;
end;

// Validates the finished placement: reports cross-set overlaps (logic cells,
// clock cells, trunk cells, pads), dropped logic cells, and clock-tree
// coverage gaps (clocked cells the placed tree failed to reach).
procedure TForm1.ValidateFloorplanLayout;
var
  Occ: TDictionary<Int64, string>;
  i, ClkL, ClkIdx, OverlapCount: Integer;
  Expected, Actual: Integer;
  Label_: string;

  procedure MarkRect(X, Y, W, H: Integer; const ALabel: string);
  var
    dx, dy: Integer;
    Key: Int64;
  begin
    for dy := 0 to H - 1 do
      for dx := 0 to W - 1 do
      begin
        Key := Int64(Y + dy) * FFloorplanW + (X + dx);
        if Occ.ContainsKey(Key) then
        begin
          Inc(OverlapCount);
          if OverlapCount <= 8 then
            AddFloorplanError(Format('Placement overlap: %s vs %s at (%d,%d).',
              [Occ[Key], ALabel, X + dx, Y + dy]));
        end
        else
          Occ.Add(Key, ALabel);
      end;
  end;

begin
  if (not FFloorplanValid) or (FFloorplanW <= 0) then
    Exit;
  Occ := TDictionary<Int64, string>.Create;
  try
    OverlapCount := 0;

    // Logic cells.
    for i := 0 to High(FPlacedComponents) do
      MarkRect(FPlacedComponents[i].X, FPlacedComponents[i].Y,
        FPlacedComponents[i].W, FPlacedComponents[i].H,
        'logic ' + FPlacedComponents[i].InstanceName);
    // Clock subtree cells (interior only; leaves are the logic cells).
    for ClkL := 0 to High(FClockSubtree) do
      for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        if not FClockSubtree[ClkL][ClkIdx].IsLeaf then
          MarkRect(FClockSubtree[ClkL][ClkIdx].X, FClockSubtree[ClkL][ClkIdx].Y,
            FClockSubtree[ClkL][ClkIdx].W, FClockSubtree[ClkL][ClkIdx].H,
            'clock cell');
    // Trunk (spine) cells.
    for i := 0 to High(FSpine) do
    begin
      if FSpine[i].IsJunction then
        Label_ := 'junction'
      else
        Label_ := 'buffer';
      MarkRect(FSpine[i].X, FSpine[i].Y, FSpine[i].W, FSpine[i].H, Label_);
    end;
    // Pads.
    for i := 0 to High(FPads) do
      MarkRect(FPads[i].X, FPads[i].Y, 1, 1, 'pad ' + FPads[i].NetName);

    if OverlapCount > 0 then
      AddFloorplanError(Format('Placement: %d overlapping grid cell(s).',
        [OverlapCount]));

    // Clock-tree coverage: every clocked cell in the model must be a leaf of
    // the placed tree.
    for ClkL := 0 to High(FClockSubtree) do
    begin
      Expected := 0;
      if FPlacementModel <> nil then
        for i := 0 to FPlacementModel.Gates.Count - 1 do
          if (FPlacementModel.Gates[i].ClockLevel = FPlanLevels[ClkL]) and
             CellHasClock(FPlacementModel.Gates[i].Cell) then
            Inc(Expected);
      Actual := 0;
      for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        if FClockSubtree[ClkL][ClkIdx].IsLeaf then
          Inc(Actual);
      if Actual < Expected then
        AddFloorplanError(Format(
          'Clock tree L%d: only %d of %d clocked cells covered by the tree.',
          [FPlanLevels[ClkL], Actual, Expected]));
    end;

    // Dropped logic cells (could not fit their layer's rows).
    if FDroppedCells > 0 then
      AddFloorplanError(Format(
        'Placement: %d logic cell(s) did not fit and were dropped.',
        [FDroppedCells]));
  finally
    Occ.Free;
  end;
end;

procedure TForm1.RepaintFloorplanPage;
var
  i: Integer;
begin
  if TabControl1.TabIndex <> TabFloorplan then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.PaintFloorplan(Sender: TObject; Canvas: TCanvas);
const
  GridHalf = 0.75;    // half-thickness (px) of the block grid lines
  BorderHalf = 1.5;   // half-thickness (px) of the die boundary
  MinBlockPx = 3.0;   // below this on-screen block size, skip the grid
  DrawDebugNets = True; // temporary: draw data connections between placements
var
  R: TRectF;
  ClipState: TCanvasSaveState;
  DieW, DieH, Core: Double;
  Cols, Rows, i: Integer;
  X, Y: Single;
  BlockPx, WorldX0, WorldX1, WorldY0, WorldY1: Single;
  I0, I1, J0, J1: Integer;
  BX0, BX1, BY0, BY1, RunStart, RowIdx: Integer;
  PadPx, PadPy: Integer;
  ClkL, ClkIdx, ClkChild, Ci: Integer;
  ClkNode: TPlacedClockNode;
  SpineComp: TSpineComponent;
  SpineL: Integer;
  Kind: TFloorplanCell;
  P: TPlacedComponent;
  Net: TNet;
  NC2: TNetConnection;
  Pair: TPair<string, TNet>;
  Driver: TGateInstance;
  SX1, SY1, SX2, SY2: Single;

  function WX(AValue: Single): Single;
  begin
    Result := FPlanPanX + AValue * FPlanZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FPlanPanY + AValue * FPlanZoom;
  end;

  // Screen centre of a placed gate (world centre transformed to screen).
  function PlacedCenter(G: TGateInstance; out SX, SY: Single): Boolean;
  var
    Pt: TPoint;
    Wb, Hb: Integer;
  begin
    Result := (G <> nil) and FGatePlacement.TryGetValue(G, Pt);
    if not Result then
      Exit;
    Wb := 1;
    Hb := 1;
    if G.Cell <> nil then
    begin
      Wb := Round(G.Cell.Width / Core);
      Hb := Round(G.Cell.Height / Core);
      if Wb < 1 then
        Wb := 1;
      if Hb < 1 then
        Hb := 1;
    end;
    SX := WX((Pt.X + Wb / 2) * Core);
    SY := WY((Pt.Y + Hb / 2) * Core);
  end;

begin
  R := TRectF.Create(0, 0, PaintBox3.Width, PaintBox3.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  // Mask everything outside the paint box (D2D needs the clip while a save
  // state is active, otherwise drawing bleeds onto the buttons).
  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if not (TryDimParse(EditCoreSize.Text, Core) and
            TryDimParse(EditDieW.Text, DieW) and
            TryDimParse(EditDieH.Text, DieH)) or
       (Core <= 0) or (DieW <= 0) or (DieH <= 0) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No valid floorplan - check the Placement Configuration tab.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Cols := Round(DieW / Core);
    Rows := Round(DieH / Core);

    // Fit the whole die into the canvas the first time we paint with a real
    // size; this is also the most zoomed-out the user can go.
    if FPlanNeedsFit and (PaintBox3.Width > 20) and (PaintBox3.Height > 20) then
    begin
      FPlanZoom := (Min(PaintBox3.Width, PaintBox3.Height) - 20) / Max(DieW, DieH);
      FPlanPanX := (PaintBox3.Width - DieW * FPlanZoom) / 2;
      FPlanPanY := (PaintBox3.Height - DieH * FPlanZoom) / 2;
      FPlanNeedsFit := False;
    end;

    // Die body.
    Canvas.Fill.Color := $FFF2F2F2;
    Canvas.FillRect(TRectF.Create(WX(0), WY(0), WX(DieW), WY(DieH)), 0, 0, [], 1.0);

    // Floorplan allocation (blue logic, green clock, red bias), run-merged
    // per row so large uniform regions draw as few rectangles. Hidden when the
    // 'Floorplan' toggle is off.
    if FFloorplanValid and (FPlanZoom > 0) then
    begin
      BX0 := Trunc((0 - FPlanPanX) / FPlanZoom / Core);
      if BX0 < 0 then
        BX0 := 0;
      BX1 := Trunc((PaintBox3.Width - FPlanPanX) / FPlanZoom / Core) + 1;
      if BX1 > FFloorplanW then
        BX1 := FFloorplanW;
      BY0 := Trunc((0 - FPlanPanY) / FPlanZoom / Core);
      if BY0 < 0 then
        BY0 := 0;
      BY1 := Trunc((PaintBox3.Height - FPlanPanY) / FPlanZoom / Core) + 1;
      if BY1 > FFloorplanH then
        BY1 := FFloorplanH;

      // Region fills, hidden when the 'Floorplan' toggle is off. The cells,
      // names, and pads below still draw (gated by their own toggles).
      if CheckBoxShowFloorplan.IsChecked then
      begin
        for RowIdx := BY0 to BY1 - 1 do
        begin
          i := BX0;
          while i < BX1 do
          begin
            Kind := GetPlanCell(i, RowIdx);
            if Kind = fcEmpty then
            begin
              Inc(i);
              Continue;
            end;
            RunStart := i;
            while (i < BX1) and (GetPlanCell(i, RowIdx) = Kind) do
              Inc(i);
            case Kind of
              fcLogic: Canvas.Fill.Color := $FF2563C4;
              fcClock: Canvas.Fill.Color := $FF6BA839;
              fcBias:  Canvas.Fill.Color := $FFFF6251;
              fcLogicFill: Canvas.Fill.Color := $FFE8F0FF;
              fcClockFill: Canvas.Fill.Color := $FFF0F7E8;
            end;
            Canvas.FillRect(TRectF.Create(WX(RunStart * Core), WY(RowIdx * Core),
              WX(i * Core), WY((RowIdx + 1) * Core)), 0, 0, [], 1.0);
          end;
        end;
      end;

      // Placed logic components (teal), culled to the visible range; hidden when the
      // 'Cells' toggle is off.
      if CheckBoxShowCells.IsChecked then
        for i := 0 to High(FPlacedComponents) do
        begin
          P := FPlacedComponents[i];
          if (P.X + P.W <= BX0) or (P.X >= BX1) or
             (P.Y + P.H <= BY0) or (P.Y >= BY1) then
            Continue;
          Canvas.Fill.Color := $FF3A88FE;
          Canvas.FillRect(TRectF.Create(WX(P.X * Core), WY(P.Y * Core),
            WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)), 0, 0, [], 1.0);
        end;

      // Cell names (when enabled): overlay each component's instance name.
      if CheckBoxShowNames.IsChecked then
      begin
        Canvas.Fill.Color := TAlphaColorRec.Black;
        Canvas.Font.Size := 8;
        for i := 0 to High(FPlacedComponents) do
        begin
          P := FPlacedComponents[i];
          if (P.X + P.W <= BX0) or (P.X >= BX1) or
             (P.Y + P.H <= BY0) or (P.Y >= BY1) then
            Continue;
          Canvas.FillText(TRectF.Create(
            WX(P.X * Core), WY(P.Y * Core),
            WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)),
            P.InstanceName, False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
        end;
      end;

      // Clock cells (dark green), drawn with the logic cells so the grid
      // overlays them (hidden with the 'Cells' toggle). Their names show when
      // the 'Cell names' toggle is on.
      if CheckBoxShowCells.IsChecked then
      begin
        Canvas.Fill.Color := $FF96D35F;
        for ClkL := 0 to High(FClockSubtree) do
          for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          begin
            ClkNode := FClockSubtree[ClkL][ClkIdx];
            if ClkNode.IsLeaf then
              Continue;
            Canvas.FillRect(TRectF.Create(
              WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
              WX((ClkNode.X + ClkNode.W) * Core),
              WY((ClkNode.Y + ClkNode.H) * Core)), 0, 0, [], 1.0);
          end;
        for i := 0 to High(FSpine) do
        begin
          SpineComp := FSpine[i];
          Canvas.FillRect(TRectF.Create(
            WX(SpineComp.X * Core), WY(SpineComp.Y * Core),
            WX((SpineComp.X + SpineComp.W) * Core),
            WY((SpineComp.Y + SpineComp.H) * Core)), 0, 0, [], 1.0);
        end;
      end;
      if CheckBoxShowNames.IsChecked then
      begin
        Canvas.Fill.Color := TAlphaColorRec.Black;
        Canvas.Font.Size := 8;
        for ClkL := 0 to High(FClockSubtree) do
          for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          begin
            ClkNode := FClockSubtree[ClkL][ClkIdx];
            if ClkNode.IsLeaf then
              Continue;
            if ClkNode.Gate <> nil then
              Canvas.FillText(TRectF.Create(
                WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
                WX((ClkNode.X + ClkNode.W) * Core),
                WY((ClkNode.Y + ClkNode.H) * Core)),
                ClkNode.Gate.CellName, False, 1.0, [],
                TTextAlign.Center, TTextAlign.Center);
          end;
        for i := 0 to High(FSpine) do
          if FSpine[i].Gate <> nil then
            Canvas.FillText(TRectF.Create(
              WX(FSpine[i].X * Core), WY(FSpine[i].Y * Core),
              WX((FSpine[i].X + FSpine[i].W) * Core),
              WY((FSpine[i].Y + FSpine[i].H) * Core)),
              FSpine[i].Gate.CellName, False, 1.0, [],
              TTextAlign.Center, TTextAlign.Center);
      end;

      // Immobile I/O anchor pads (dark) with their port names. During a drag the
      // dragged pad follows the mouse and its set shifts to the preview slots.
      for i := 0 to High(FPads) do
      begin
        PadPx := PadDisplayX(i);
        PadPy := FPads[i].Y;
        if (PadPx + 1 <= BX0) or (PadPx >= BX1) or
           (PadPy + 1 <= BY0) or (PadPy >= BY1) then
          Continue;
        Canvas.Fill.Color := $FF455A64;
        Canvas.FillRect(TRectF.Create(WX(PadPx * Core), WY(PadPy * Core),
          WX((PadPx + 1) * Core), WY((PadPy + 1) * Core)), 0, 0, [], 1.0);
        Canvas.Fill.Color := TAlphaColorRec.Black;
        // Input labels sit above the block, output labels below it.
        if FPads[i].IsInput then
          Canvas.FillText(TRectF.Create(
            WX(PadPx * Core) + 2, WY(PadPy * Core) - 16,
            WX(PadPx * Core) + 130, WY(PadPy * Core) - 2),
            FPads[i].NetName, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center)
        else
          Canvas.FillText(TRectF.Create(
            WX(PadPx * Core) + 2, WY((PadPy + 1) * Core) + 2,
            WX(PadPx * Core) + 130, WY((PadPy + 1) * Core) + 16),
            FPads[i].NetName, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
      end;
    end;

    // Grid of core-block-sized squares, drawn as thin filled rectangles
    // (stroke rendering is unreliable on this canvas backend). Only drawn
    // when blocks are large enough on screen, and culled to the visible
    // area so huge dies still show cell borders when zoomed in.
    BlockPx := Core * FPlanZoom;
    if (BlockPx >= MinBlockPx) and (FPlanZoom > 0) then
    begin
      WorldX0 := (0 - FPlanPanX) / FPlanZoom;
      WorldX1 := (PaintBox3.Width - FPlanPanX) / FPlanZoom;
      WorldY0 := (0 - FPlanPanY) / FPlanZoom;
      WorldY1 := (PaintBox3.Height - FPlanPanY) / FPlanZoom;

      I0 := Trunc(WorldX0 / Core);
      if I0 < 0 then I0 := 0;
      I1 := Trunc(WorldX1 / Core) + 1;
      if I1 > Cols then I1 := Cols;
      J0 := Trunc(WorldY0 / Core);
      if J0 < 0 then J0 := 0;
      J1 := Trunc(WorldY1 / Core) + 1;
      if J1 > Rows then J1 := Rows;

      Canvas.Fill.Color := $FF909090;
      for i := I0 to I1 do
      begin
        X := WX(i * Core);
        Canvas.FillRect(TRectF.Create(X - GridHalf, WY(0), X + GridHalf, WY(DieH)),
          0, 0, [], 1.0);
      end;
      for i := J0 to J1 do
      begin
        Y := WY(i * Core);
        Canvas.FillRect(TRectF.Create(WX(0), Y - GridHalf, WX(DieW), Y + GridHalf),
          0, 0, [], 1.0);
      end;
    end;

    // Die boundary, drawn as four filled bars (thicker than the grid).
    Canvas.Fill.Color := $FF404040;
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
      WX(DieW) + BorderHalf, WY(0) + BorderHalf), 0, 0, [], 1.0); // top
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(DieH) - BorderHalf,
      WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // bottom
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
      WX(0) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // left
    Canvas.FillRect(TRectF.Create(WX(DieW) - BorderHalf, WY(0) - BorderHalf,
      WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // right

    // DEBUG: temporary net connections between placed components. Clock pins
    // are skipped (the clock network is not placed yet). Remove with the
    // DrawDebugNets flag; hidden when the 'Logic connections' toggle is off.
    if DrawDebugNets and CheckBoxShowLogicWires.IsChecked and (FPlacementModel <> nil) then
    begin
      Canvas.Stroke.Kind := TBrushKind.Solid;
      Canvas.Stroke.Color := $FF7BA8FF;
      Canvas.Stroke.Thickness := 2;
      for Pair in FPlacementModel.Nets do
      begin
        Net := Pair.Value;
        Driver := nil;
        for NC2 in Net.Connections do
          if NC2.IsDriver and (not IsClockPinName(NC2.PinName)) and
             FGatePlacement.ContainsKey(NC2.Gate) then
          begin
            Driver := NC2.Gate;
            Break;
          end;
        if Driver = nil then
          Continue;
        if not PlacedCenter(Driver, SX1, SY1) then
          Continue;
        for NC2 in Net.Connections do
        begin
          if NC2.IsDriver then
            Continue;
          if IsClockPinName(NC2.PinName) then
            Continue;
          if not FGatePlacement.ContainsKey(NC2.Gate) then
            Continue;
          // Show the real connectivity (incl. short-path arcs) so no cell
          // looks dangling; wave-pipelined adjacency needs the DFF model.
          if PlacedCenter(NC2.Gate, SX2, SY2) then
            Canvas.DrawLine(TPointF.Create(SX1, SY1), TPointF.Create(SX2, SY2), 1.0);
        end;
      end;
      // Pad wires: connect every data input/output pad to its net's gates (the
      // clock input pad is drawn with the clock wires instead).
      for i := 0 to High(FPads) do
      begin
        if i = FClockPadIdx then
          Continue;
        if not FPlacementModel.Nets.TryGetValue(FPads[i].NetName, Net) then
          Continue;
        SX1 := WX((FPads[i].X + 0.5) * Core);
        SY1 := WY((FPads[i].Y + 0.5) * Core);
        if FPads[i].IsInput then
        begin
          for NC2 in Net.Connections do
            if (not NC2.IsDriver) and
               FGatePlacement.ContainsKey(NC2.Gate) and
               PlacedCenter(NC2.Gate, SX2, SY2) then
              Canvas.DrawLine(TPointF.Create(SX1, SY1),
                TPointF.Create(SX2, SY2), 1.0);
        end
        else
        begin
          for NC2 in Net.Connections do
            if NC2.IsDriver and
               FGatePlacement.ContainsKey(NC2.Gate) and
               PlacedCenter(NC2.Gate, SX2, SY2) then
              Canvas.DrawLine(TPointF.Create(SX1, SY1),
                TPointF.Create(SX2, SY2), 1.0);
        end;
      end;
    end;

    // Clock connections (white) drawn on top; hidden by the 'Clock connections'
    // toggle. The clock cells themselves are drawn earlier, under the grid,
    // together with the logic cells.
    if CheckBoxShowClockWires.IsChecked then
    begin
      Canvas.Stroke.Kind := TBrushKind.Solid;
      Canvas.Stroke.Color := $FFB8E68E;
      Canvas.Stroke.Thickness := 1.5;
      // Subtree wires.
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          for ClkChild := 0 to High(FClockSubtree[ClkL][ClkIdx].Children) do
          begin
            Ci := FClockSubtree[ClkL][ClkIdx].Children[ClkChild];
            Canvas.DrawLine(
              TPointF.Create(WX((FClockSubtree[ClkL][ClkIdx].X +
                FClockSubtree[ClkL][ClkIdx].W div 2) * Core),
                WY((FClockSubtree[ClkL][ClkIdx].Y +
                  FClockSubtree[ClkL][ClkIdx].H div 2) * Core)),
              TPointF.Create(WX((FClockSubtree[ClkL][Ci].X +
                FClockSubtree[ClkL][Ci].W div 2) * Core),
                WY((FClockSubtree[ClkL][Ci].Y +
                  FClockSubtree[ClkL][Ci].H div 2) * Core)), 1.0);
          end;
      // Trunk spine chain: junction -> buffers -> junction.
      for i := 0 to High(FSpine) - 1 do
        Canvas.DrawLine(
          TPointF.Create(WX((FSpine[i].X + FSpine[i].W div 2) * Core),
            WY((FSpine[i].Y + FSpine[i].H div 2) * Core)),
          TPointF.Create(WX((FSpine[i + 1].X + FSpine[i + 1].W div 2) * Core),
            WY((FSpine[i + 1].Y + FSpine[i + 1].H div 2) * Core)), 1.0);
      // Each junction's tap to its layer's subtree root.
      for i := 0 to High(FSpine) do
        if FSpine[i].IsJunction then
        begin
          SpineL := -1;
          for ClkIdx := 0 to High(FPlanLevels) do
            if FPlanLevels[ClkIdx] = FSpine[i].Gate.ClockLevel then
            begin
              SpineL := ClkIdx;
              Break;
            end;
          if (SpineL >= 0) and (Length(FClockSubtree[SpineL]) > 0) then
            Canvas.DrawLine(
              TPointF.Create(WX((FSpine[i].X + FSpine[i].W div 2) * Core),
                WY((FSpine[i].Y + FSpine[i].H div 2) * Core)),
              TPointF.Create(WX((FClockSubtree[SpineL][0].X +
                FClockSubtree[SpineL][0].W div 2) * Core),
                WY((FClockSubtree[SpineL][0].Y +
                  FClockSubtree[SpineL][0].H div 2) * Core)), 1.0);
        end;
      // Final tap: the lowest clock layer (level 1) has no junction - it is fed
      // directly by the end of the spine.
      if High(FSpine) >= 0 then
      begin
        SpineL := -1;
        for ClkIdx := 0 to High(FPlanLevels) do
          if FPlanLevels[ClkIdx] >= 1 then
          begin
            SpineL := ClkIdx;
            Break; // lowest clock layer
          end;
        if (SpineL >= 0) and (Length(FClockSubtree[SpineL]) > 0) then
          Canvas.DrawLine(
            TPointF.Create(WX((FSpine[High(FSpine)].X +
              FSpine[High(FSpine)].W div 2) * Core),
              WY((FSpine[High(FSpine)].Y + FSpine[High(FSpine)].H div 2) * Core)),
            TPointF.Create(WX((FClockSubtree[SpineL][0].X +
              FClockSubtree[SpineL][0].W div 2) * Core),
              WY((FClockSubtree[SpineL][0].Y +
                FClockSubtree[SpineL][0].H div 2) * Core)), 1.0);
      end;
      // Clock input pad: connect it to the base of the clock tree (the first
      // spine cell), where it feeds the counter-flow network.
      if (FClockPadIdx >= 0) and (High(FSpine) >= 0) then
        Canvas.DrawLine(
          TPointF.Create(WX((FPads[FClockPadIdx].X + 0.5) * Core),
            WY((FPads[FClockPadIdx].Y + 0.5) * Core)),
          TPointF.Create(WX((FSpine[0].X + FSpine[0].W div 2) * Core),
            WY((FSpine[0].Y + FSpine[0].H div 2) * Core)), 1.0);
    end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.RepaintRoutingPage;
var
  i: Integer;
begin
  if TabControl1.TabIndex <> TabRouting then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.PaintRouting(Sender: TObject; Canvas: TCanvas);
const
  GridHalf = 0.75;    // half-thickness (px) of the block grid lines
  BorderHalf = 1.5;   // half-thickness (px) of the die boundary
  MinBlockPx = 3.0;   // below this on-screen block size, skip the grid
  CellAlpha = $50;   // placed cells: semi-transparent grey
  PortAlpha = 0.55;   // port shapes: semi-transparent
  BaseHue = 216.0;    // starting hue for the first layer
  HueShift = 222.0;   // hue step between successive layers (mod 360)
var
  R: TRectF;
  ClipState: TCanvasSaveState;
  DieW, DieH, Core: Double;
  Cols, Rows, i, j: Integer;
  X, Y: Single;
  BlockPx, WorldX0, WorldX1, WorldY0, WorldY1: Single;
  I0, I1, J0, J1: Integer;
  P: TPlacedComponent;
  ClkL, ClkIdx: Integer;
  ClkNode: TPlacedClockNode;
  Sp: TSpineComponent;

  function WX(AValue: Single): Single;
  begin
    Result := FRoutePanX + AValue * FRouteZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FRoutePanY + AValue * FRouteZoom;
  end;

  // HSV -> TAlphaColor. H in degrees [0..360], S/L/A in [0..1]. The FMX
  // TAlphaColorF.CreateHSL helper is not available on this toolchain, so the
  // conversion is done by hand.
  function HslColor(H, S, L, A: Single): TAlphaColor;
  begin
    Result := HslToColor(H, S, L, A);
  end;

  // Per-layer colour from HSV: a constant hue shift per layer, keyed by the
  // layer's position in the parsed-library order (FRoutingLayers), so colours
  // are stable and the legend matches what is drawn.
  function LayerColor(const ALayer: string; AAlpha: Single): TAlphaColor;
  var
    k: Integer;
  begin
    k := FRoutingLayers.IndexOf(ALayer);
    if k < 0 then
      k := 0;
    Result := HslColor(BaseHue + k * HueShift, 0.65, 0.55, AAlpha);
  end;

  // Draws every port shape of one cell, translated to its placed origin (and
  // rotated 90 deg CCW for trunk cells). AWidth/AHeight are the cell's own
  // dimensions in um; AX/AY are the placed top-left grid cell.
  procedure DrawCellPorts(ACell: TCell; AX, AY: Integer;
    AWidth, AHeight: Double; Rotated: Boolean);
  var
    Port: TPort;
    Shape: TPortShape;
    Wx1, Wy1, Wx2, Wy2: Double;
  begin
    if ACell = nil then
      Exit;
    for Port in ACell.Ports do
      for Shape in Port.Shapes do
      begin
        if not RoutingLayerEnabled(Shape.Layer) then
          Continue;
        Canvas.Fill.Color := LayerColor(Shape.Layer, PortAlpha);
        if Rotated then
        begin
          Wx1 := AX * Core + (AHeight - Shape.y2);
          Wx2 := AX * Core + (AHeight - Shape.y1);
          Wy1 := AY * Core + Shape.x1;
          Wy2 := AY * Core + Shape.x2;
        end
        else
        begin
          // Canvas Y runs down while LEF Y runs up: flip (AHeight - y).
          Wx1 := AX * Core + Shape.x1;
          Wx2 := AX * Core + Shape.x2;
          Wy1 := AY * Core + (AHeight - Shape.y2);
          Wy2 := AY * Core + (AHeight - Shape.y1);
        end;
        Canvas.FillRect(TRectF.Create(WX(Wx1), WY(Wy1), WX(Wx2), WY(Wy2)),
          0, 0, [], 1.0);
      end;
    for Port in ACell.PowerPorts do
      for Shape in Port.Shapes do
      begin
        if not RoutingLayerEnabled(Shape.Layer) then
          Continue;
        Canvas.Fill.Color := LayerColor(Shape.Layer, PortAlpha);
        if Rotated then
        begin
          Wx1 := AX * Core + (AHeight - Shape.y2);
          Wx2 := AX * Core + (AHeight - Shape.y1);
          Wy1 := AY * Core + Shape.x1;
          Wy2 := AY * Core + Shape.x2;
        end
        else
        begin
          // Canvas Y runs down while LEF Y runs up: flip (AHeight - y).
          Wx1 := AX * Core + Shape.x1;
          Wx2 := AX * Core + Shape.x2;
          Wy1 := AY * Core + (AHeight - Shape.y2);
          Wy2 := AY * Core + (AHeight - Shape.y1);
        end;
        Canvas.FillRect(TRectF.Create(WX(Wx1), WY(Wy1), WX(Wx2), WY(Wy2)),
          0, 0, [], 1.0);
      end;
  end;

begin
  R := TRectF.Create(0, 0, PaintBox4.Width, PaintBox4.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if not (TryDimParse(EditCoreSize.Text, Core) and
            TryDimParse(EditDieW.Text, DieW) and
            TryDimParse(EditDieH.Text, DieH)) or
       (Core <= 0) or (DieW <= 0) or (DieH <= 0) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No valid placement - check the Placement Configuration tab.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Cols := Round(DieW / Core);
    Rows := Round(DieH / Core);

    if FRouteNeedsFit and (PaintBox4.Width > 20) and (PaintBox4.Height > 20) then
    begin
      FRouteZoom := (Min(PaintBox4.Width, PaintBox4.Height) - 20) / Max(DieW, DieH);
      FRoutePanX := (PaintBox4.Width - DieW * FRouteZoom) / 2;
      FRoutePanY := (PaintBox4.Height - DieH * FRouteZoom) / 2;
      FRouteNeedsFit := False;
    end;

    // Die body.
    Canvas.Fill.Color := $FFF2F2F2;
    Canvas.FillRect(TRectF.Create(WX(0), WY(0), WX(DieW), WY(DieH)), 0, 0, [], 1.0);

      // Placed logic cells (semi-transparent grey), then their ports.
Canvas.Fill.Color := HslColor(0, 0, 0.6, CellAlpha / 255);
      for i := 0 to High(FPlacedComponents) do
      begin
        P := FPlacedComponents[i];
        Canvas.FillRect(TRectF.Create(WX(P.X * Core), WY(P.Y * Core),
          WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)), 0, 0, [], 1.0);
      end;
      for i := 0 to High(FPlacedComponents) do
      begin
        P := FPlacedComponents[i];
        if (P.Gate <> nil) and (P.Gate.Cell <> nil) then
          DrawCellPorts(P.Gate.Cell, P.X, P.Y,
            P.Gate.Cell.Width, P.Gate.Cell.Height, False);
      end;

      // Clock tree cells (interior nodes), unrotated.
Canvas.Fill.Color := HslColor(0, 0, 0.6, CellAlpha / 255);
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        begin
          ClkNode := FClockSubtree[ClkL][ClkIdx];
          if ClkNode.IsLeaf then
            Continue;
          Canvas.FillRect(TRectF.Create(WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
            WX((ClkNode.X + ClkNode.W) * Core),
            WY((ClkNode.Y + ClkNode.H) * Core)), 0, 0, [], 1.0);
        end;
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        begin
          ClkNode := FClockSubtree[ClkL][ClkIdx];
          if ClkNode.IsLeaf or (ClkNode.Gate = nil) or (ClkNode.Gate.Cell = nil) then
            Continue;
          DrawCellPorts(ClkNode.Gate.Cell, ClkNode.X, ClkNode.Y,
            ClkNode.Gate.Cell.Width, ClkNode.Gate.Cell.Height, False);
        end;

      // Trunk spine cells; trunk cells are rotated 90 deg CCW.
Canvas.Fill.Color := HslColor(0, 0, 0.6, CellAlpha / 255);
      for i := 0 to High(FSpine) do
      begin
        Sp := FSpine[i];
        Canvas.FillRect(TRectF.Create(WX(Sp.X * Core), WY(Sp.Y * Core),
          WX((Sp.X + Sp.W) * Core), WY((Sp.Y + Sp.H) * Core)), 0, 0, [], 1.0);
      end;
      for i := 0 to High(FSpine) do
      begin
        Sp := FSpine[i];
        if (Sp.Gate <> nil) and (Sp.Gate.Cell <> nil) then
          DrawCellPorts(Sp.Gate.Cell, Sp.X, Sp.Y,
            Sp.Gate.Cell.Width, Sp.Gate.Cell.Height, Sp.Rotated);
      end;

      // Routed traces (on the signal layer), drawn under the grid.
      DrawRoutedTraces(Canvas);

      // Grid of core-block-sized squares (culled to the visible area).
      BlockPx := Core * FRouteZoom;
      if (BlockPx >= MinBlockPx) and (FRouteZoom > 0) then
      begin
        WorldX0 := (0 - FRoutePanX) / FRouteZoom;
        WorldX1 := (PaintBox4.Width - FRoutePanX) / FRouteZoom;
        WorldY0 := (0 - FRoutePanY) / FRouteZoom;
        WorldY1 := (PaintBox4.Height - FRoutePanY) / FRouteZoom;

        I0 := Trunc(WorldX0 / Core);
        if I0 < 0 then I0 := 0;
        I1 := Trunc(WorldX1 / Core) + 1;
        if I1 > Cols then I1 := Cols;
        J0 := Trunc(WorldY0 / Core);
        if J0 < 0 then J0 := 0;
        J1 := Trunc(WorldY1 / Core) + 1;
        if J1 > Rows then J1 := Rows;

        Canvas.Fill.Color := $FF909090;
        for i := I0 to I1 do
        begin
          X := WX(i * Core);
          Canvas.FillRect(TRectF.Create(X - GridHalf, WY(0), X + GridHalf, WY(DieH)),
            0, 0, [], 1.0);
        end;
        for i := J0 to J1 do
        begin
          Y := WY(i * Core);
          Canvas.FillRect(TRectF.Create(WX(0), Y - GridHalf, WX(DieW), Y + GridHalf),
            0, 0, [], 1.0);
        end;
      end;

      // Die boundary.
      Canvas.Fill.Color := $FF404040;
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
        WX(DieW) + BorderHalf, WY(0) + BorderHalf), 0, 0, [], 1.0); // top
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(DieH) - BorderHalf,
        WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // bottom
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
        WX(0) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // left
      Canvas.FillRect(TRectF.Create(WX(DieW) - BorderHalf, WY(0) - BorderHalf,
        WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // right

      // Interactive layer legend, fixed to the top-right of the canvas (screen
      // space, independent of pan/zoom). One row per used layer in library
      // order: a colour box + the layer name. Clicking the box toggles whether
      // that layer's ports are drawn (filled = enabled, outlined = hidden).
      if FRoutingLayers.Count > 0 then
        DrawRoutingLegend(Canvas);
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.PaintBox4MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
const
  LegendPad = 8;    // must match DrawRoutingLegend
  RowH = 18;
  BoxSize = 12;
  PanelW = 70;
var
  PanelX, PanelY: Single;
  i: Integer;
  BoxLeft, BoxTop: Single;
begin
  if Button <> TMouseButton.mbLeft then
    Exit;
  // Hit-test the top-right layer legend first; clicking a colour box toggles
  // that layer (or the length-colour toggle) instead of starting a pan.
  if FRoutingLayers.Count > 0 then
  begin
    PanelX := PaintBox4.Width - PanelW - LegendPad;
    PanelY := LegendPad;
    for i := 0 to FRoutingLayers.Count - 1 do
    begin
      BoxLeft := PanelX + LegendPad;
      BoxTop := PanelY + LegendPad + i * RowH + (RowH - BoxSize) / 2;
      if (X >= BoxLeft) and (X <= BoxLeft + BoxSize) and
         (Y >= BoxTop) and (Y <= BoxTop + BoxSize) then
      begin
        ToggleRoutingLayer(FRoutingLayers[i]);
        Exit;
      end;
    end;
    // The length-colour toggle row (one past the layers).
    BoxLeft := PanelX + LegendPad;
    BoxTop := PanelY + LegendPad + FRoutingLayers.Count * RowH + (RowH - BoxSize) / 2;
    if (X >= BoxLeft) and (X <= BoxLeft + BoxSize) and
       (Y >= BoxTop) and (Y <= BoxTop + BoxSize) then
    begin
      FRouteLengthColor := not FRouteLengthColor;
      RepaintRoutingPage;
      Exit;
    end;
  end;
  FRouteDragging := True;
  FRouteDragX := X;
  FRouteDragY := Y;
end;

procedure TForm1.PaintBox4MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FRouteDragging then
  begin
    FRoutePanX := FRoutePanX + (X - FRouteDragX);
    FRoutePanY := FRoutePanY + (Y - FRouteDragY);
    FRouteDragX := X;
    FRouteDragY := Y;
    RepaintRoutingPage;
  end;
end;

procedure TForm1.PaintBox4MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FRouteDragging := False;
end;

// Rebuilds the ordered list of layers shown for routing. Only the layers
// labelled as routing in the parsed library are listed, plus the user-chosen
// bias-routing layer (FBiasLayer), which is not a signal-routing layer but
// still needs to be visible. Independent of which pins happen to be used.
procedure TForm1.BuildRoutingLayers;
var
  i: Integer;
begin
  if FRoutingLayers = nil then
    FRoutingLayers := TStringList.Create;
  FRoutingLayers.Clear;
  if FLib <> nil then
    for i := 0 to FLib.Layers.Count - 1 do
      if FLib.Layers[i].LayerType = ltRouting then
        FRoutingLayers.Add(FLib.Layers[i].Name);
  if (FBiasLayer <> '') and (FRoutingLayers.IndexOf(FBiasLayer) < 0) then
    FRoutingLayers.Add(FBiasLayer);
  // Newly-seen layers default to enabled.
  for i := 0 to FRoutingLayers.Count - 1 do
    if not FRoutingLayerEnabled.ContainsKey(FRoutingLayers[i]) then
      FRoutingLayerEnabled.Add(FRoutingLayers[i], True);
end;

function TForm1.RoutingLayerEnabled(const ALayer: string): Boolean;
begin
  Result := True;
  if FRoutingLayerEnabled <> nil then
    FRoutingLayerEnabled.TryGetValue(ALayer, Result);
end;

procedure TForm1.ToggleRoutingLayer(const ALayer: string);
var
  B: Boolean;
begin
  B := RoutingLayerEnabled(ALayer);
  if FRoutingLayerEnabled <> nil then
    FRoutingLayerEnabled.AddOrSetValue(ALayer, not B);
  RepaintRoutingPage;
end;

// HSV -> TAlphaColor. H in degrees [0..360], S/L/A in [0..1].
function TForm1.HslToColor(H, S, L, A: Single): TAlphaColor;
var
  C, X, M: Single;
  R, G, B: Single;
  Hh: Single;
begin
  if S <= 0 then
  begin
    R := L;
    G := L;
    B := L;
  end
  else
  begin
    Hh := H / 360.0;
    C := (1 - Abs(2 * L - 1)) * S;
    X := C * (1 - Abs(Frac(Hh * 6.0) * 2 - 1));
    M := L - C / 2;
    case Trunc(Hh * 6.0) mod 6 of
      0: begin R := C; G := X; B := 0; end;
      1: begin R := X; G := C; B := 0; end;
      2: begin R := 0; G := C; B := X; end;
      3: begin R := 0; G := X; B := C; end;
      4: begin R := X; G := 0; B := C; end;
    else
      begin R := C; G := 0; B := X; end;
    end;
    R := R + M;
    G := G + M;
    B := B + M;
  end;
  Result := TAlphaColorF.Create(R, G, B, A).ToAlphaColor;
end;

// The legend/port colour for a layer, keyed by its position in the parsed
// library order, with a base hue of 216 and a 222-degree step per layer
// (modulo 360), matching the draw code.
function TForm1.RoutingLayerColor(const ALayer: string): TAlphaColor;
var
  k: Integer;
begin
  k := FRoutingLayers.IndexOf(ALayer);
  if k < 0 then
    k := 0;
  Result := HslToColor(216.0 + k * 222.0, 0.65, 0.55, 1.0);
end;

// The 'spectrogram' colour scale for wire length: blue - cyan - green - yellow
// - red. T is clamped to [0..1]; 0 = shortest (blue), 1 = at/over the scale cap
// (red). Piecewise-linear interpolation between the stops.
function TForm1.LengthColor(T: Double): TAlphaColor;
const
  Stops: array[0..4] of record P: Double; R, G, B: Byte; end = (
    (P: 0.00; R: 0;   G: 0;    B: 255),
    (P: 0.25; R: 0;   G: 255;  B: 255),
    (P: 0.50; R: 0;   G: 255;  B: 0),
    (P: 0.75; R: 255; G: 255;  B: 0),
    (P: 1.00; R: 255; G: 0;    B: 0));
var
  i: Integer;
  Frac, R, G, B: Double;
begin
  if T <= 0 then
    Result := $FF0000FF
  else if T >= 1 then
    Result := $FFFF0000
  else
  begin
    i := 0;
    while (i < 4) and (T > Stops[i + 1].P) do
      Inc(i);
    if Stops[i + 1].P = Stops[i].P then
      Frac := 0
    else
      Frac := (T - Stops[i].P) / (Stops[i + 1].P - Stops[i].P);
    R := Stops[i].R + (Stops[i + 1].R - Stops[i].R) * Frac;
    G := Stops[i].G + (Stops[i + 1].G - Stops[i].G) * Frac;
    B := Stops[i].B + (Stops[i + 1].B - Stops[i].B) * Frac;
    Result := $FF000000 or (Round(R) shl 16) or (Round(G) shl 8) or Round(B);
  end;
end;

// Draws the fixed top-right layer legend. Row order = FRoutingLayers order; a
// filled colour box means the layer is enabled, an outlined box means hidden.
// A final 'Length' row toggles length-based (temperature) trace colouring.
procedure TForm1.DrawRoutingLegend(Canvas: TCanvas);
const
  LegendPad = 8;       // margin from the canvas top-right corner
  RowH = 18;           // per-row height
  BoxSize = 12;        // colour-box side length
  TextX = 26;          // text left offset within a row
  PanelW = 70;         // legend panel width (names are short)
var
  PanelX, PanelY, PanelH: Single;
  i, x: Integer;
  BoxLeft, BoxTop: Single;
  Enabled: Boolean;
begin
  PanelH := LegendPad * 2 + (FRoutingLayers.Count + 1) * RowH;
  PanelX := PaintBox4.Width - PanelW - LegendPad;
  PanelY := LegendPad;
  // Panel background (semi-transparent) so the grid underneath stays readable.
  Canvas.Fill.Color := $E6FFFFFF;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW, PanelY + PanelH),
    0, 0, [], 1.0);
  Canvas.Fill.Color := $FF404040;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW, PanelY + 1), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY + PanelH - 1, PanelX + PanelW, PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + 1, PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX + PanelW - 1, PanelY, PanelX + PanelW, PanelY + PanelH), 0, 0, [], 1.0);

  Canvas.Font.Size := 10;
  for i := 0 to FRoutingLayers.Count - 1 do
  begin
    BoxLeft := PanelX + LegendPad;
    BoxTop := PanelY + LegendPad + i * RowH + (RowH - BoxSize) / 2;
    Enabled := RoutingLayerEnabled(FRoutingLayers[i]);
    if Enabled then
    begin
      Canvas.Fill.Color := RoutingLayerColor(FRoutingLayers[i]);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
        0, 0, [], 1.0);
    end
    else
    begin
      Canvas.Fill.Color := $FFFFFFFF;
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
        0, 0, [], 1.0);
      Canvas.Fill.Color := $FF606060;
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + 1), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop + BoxSize - 1, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft + BoxSize - 1, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
    end;
    Canvas.Fill.Color := TAlphaColorRec.Black;
    Canvas.FillText(TRectF.Create(PanelX + TextX, BoxTop - 4,
      PanelX + PanelW - LegendPad, BoxTop + 14),
      FRoutingLayers[i], False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
  end;

  // Separator above the length-colour toggle.
  BoxTop := PanelY + LegendPad + FRoutingLayers.Count * RowH;
  Canvas.Fill.Color := $FF909090;
  Canvas.FillRect(TRectF.Create(PanelX + LegendPad, BoxTop,
    PanelX + PanelW - LegendPad, BoxTop + 1), 0, 0, [], 1.0);

  // Length toggle row: gradient box (black->yellow) filled when active, and the
  // 'Length' caption.
  BoxLeft := PanelX + LegendPad;
  BoxTop := PanelY + LegendPad + FRoutingLayers.Count * RowH + (RowH - BoxSize) / 2;
  if FRouteLengthColor then
  begin
    // A mini horizontal temperature gradient.
    for x := 0 to BoxSize - 1 do
    begin
      Canvas.Fill.Color := LengthColor(x / (BoxSize - 1));
      Canvas.FillRect(TRectF.Create(BoxLeft + x, BoxTop,
        BoxLeft + x + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
    end;
  end
  else
  begin
    Canvas.Fill.Color := $FFFFFFFF;
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
      0, 0, [], 1.0);
    Canvas.Fill.Color := $FF606060;
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + 1), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop + BoxSize - 1, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft + BoxSize - 1, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
  end;
  Canvas.Fill.Color := TAlphaColorRec.Black;
  Canvas.FillText(TRectF.Create(PanelX + TextX, BoxTop - 4,
    PanelX + PanelW - LegendPad, BoxTop + 14),
    'Length', False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
end;

// Maze-routes every signal net and clock link. All nets first try the first
// routing layer alone (Lee wavefront, no vias); the ones that fail move on to
// the next layer, one layer at a time, and the still-unrouted nets finally get
// a multi-layer search with vias. Each wire is blocked on its layer as soon as
// it is routed, so later nets on that layer route around it.
procedure TForm1.RunRouting;
var
  Core: Double;
  Path: TArray<TPoint>;
  PathLayers: TArray<Integer>;
  NC: TNetConnection;
  Net: TNet;
  Pair: TPair<string, TNet>;
  Driver, Load: TGateInstance;
  DriverPin, LoadPin: string;
  Failed: Integer;
  Trace: TRoutedTrace;
  i, j, k, L, ci: Integer;
  Jobs: TRouteJobArray;
  Job: TRouteJob;
  Order: TArray<Integer>;
  TmpIdx: Integer;
  Pt: TPoint;
  SigRouted, ClkRouted: Integer;
  TreeModel: TBlifModel;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  GatePos, DriverPos: TPoint;
  UseClkPad: Boolean;
  PassRouted, PassFailed: Integer;

  // Marks a routed path's cells as hard obstacles on the layers they use, so
  // later nets on those layers route around them (classic sequential maze).
  procedure BlockPath(Pth: TArray<TPoint>; PL: TArray<Integer>);
  var
    ii: Integer;
  begin
    for ii := 0 to High(Pth) do
    begin
      Pt := Pth[ii];
      if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
         (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
        Continue;
      if (PL[ii] >= 0) and (PL[ii] <= High(FRouteObstacles)) then
        FRouteObstacles[PL[ii]][Pt.Y * FRouteObstaclesW + Pt.X] := True;
    end;
  end;

  // Appends a routed job's path to FRouteTraces and repaints immediately, so
  // each wire appears on screen as soon as it is routed.
  procedure PublishTrace(const AJob: TRouteJob);
  var
    jj: Integer;
  begin
    if not AJob.Routed or (Length(AJob.Path) = 0) then
      Exit;
    Trace.NetName := AJob.NetName;
    Trace.Points := AJob.Path;
    SetLength(Trace.Layers, Length(AJob.PathLayers));
    for jj := 0 to High(AJob.PathLayers) do
      Trace.Layers[jj] := FRouteLayers[AJob.PathLayers[jj]];
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Trace;
    PaintBox4.Repaint;
    Application.ProcessMessages;
  end;

  // Builds one TRouteJob for a signal net (from the placement model) or for a
  // single clock link (one driver -> load branch of a clock net's fan-out).
  procedure PushJob(ANetName: string; AKind: TRouteJobKind;
    ADriver: TGateInstance; ADriverPin: string;
    ALoad: TGateInstance; ALoadPin: string);
  var
    SJ: TRouteJob;
  begin
    SJ.NetName := ANetName;
    SJ.Kind := AKind;
    SJ.Driver := ADriver;
    SJ.DriverPin := ADriverPin;
    SJ.Load := ALoad;
    SJ.LoadPin := ALoadPin;
    SJ.Routed := False;
    SJ.Path := nil;
    SJ.PathLayers := nil;
    SJ.StartValid := False;
    SJ.GoalValid := False;
    SJ.Dist := High(Integer) div 2;
    if ADriver = nil then
    begin
      if GetPad(ANetName, SJ.Start) then
        SJ.StartValid := True;
    end
    else if GatePinBlock(ADriver, ADriverPin, 0, SJ.Start) then
      SJ.StartValid := True;
    if ALoad = nil then
    begin
      if GetPad(ANetName, SJ.Goal) then
        SJ.GoalValid := True;
    end
    else if GatePinBlock(ALoad, ALoadPin, 0, SJ.Goal) then
      SJ.GoalValid := True;
    if SJ.StartValid and SJ.GoalValid then
      SJ.Dist := Abs(SJ.Start.X - SJ.Goal.X) + Abs(SJ.Start.Y - SJ.Goal.Y);
    SetLength(Jobs, Length(Jobs) + 1);
    Jobs[High(Jobs)] := SJ;
  end;

begin
  MemoRouting.Lines.Clear;
  FRoutingSucceeded := False;
  FRoutingValidated := False;
  if FPlacementModel = nil then
  begin
    MemoRouting.Lines.Add('No placement model to route.');
    Exit;
  end;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
  begin
    MemoRouting.Lines.Add('Core block size is invalid.');
    Exit;
  end;
  if FLib = nil then
  begin
    MemoRouting.Lines.Add('No library loaded.');
    Exit;
  end;

    // All routing layers, in library order. The first is the primary layer;
    // subsequent layers are used one at a time for the nets the earlier layer
    // could not route.
    SetLength(FRouteLayers, 0);
    for i := 0 to FLib.Layers.Count - 1 do
      if FLib.Layers[i].LayerType = ltRouting then
      begin
        SetLength(FRouteLayers, Length(FRouteLayers) + 1);
        FRouteLayers[High(FRouteLayers)] := FLib.Layers[i].Name;
      end;
    FRouteSignalLayer := '';
    if Length(FRouteLayers) > 0 then
      FRouteSignalLayer := FRouteLayers[0];
    if FRouteSignalLayer = '' then
    begin
      MemoRouting.Lines.Add('No routing layer defined in the library.');
      Exit;
    end;

    BuildRoutingObstacles;

    SetLength(FRouteTraces, 0);
    Failed := 0;
    SetLength(Jobs, 0);

    // Collect signal nets (non-clock pins, placed gates only).
    for Pair in FPlacementModel.Nets do
    begin
      Net := Pair.Value;
      // Clock-network nets (the 'clk' root, 'clk_*', and balancing-buffer
      // outputs '<Leaf>__clkbuf_<n>') are routed by the clock pass below; their
      // only connections here are clock pins, so treat them as clock nets, not
      // as skipped signals.
      if StartsText('clk', Net.Name) or
         (Pos('__clkbuf_', Net.Name) > 0) then
        Continue;
      Driver := nil;
      DriverPin := '';
      Load := nil;
      LoadPin := '';
      for NC in Net.Connections do
      begin
        if IsClockPinName(NC.PinName) then
          Continue;
        if not FGatePlacement.ContainsKey(NC.Gate) then
          Continue;
        if NC.IsDriver then
        begin
          Driver := NC.Gate;
          DriverPin := NC.PinName;
        end
        else
        begin
          Load := NC.Gate;
          LoadPin := NC.PinName;
        end;
      end;
      if (Driver = nil) and (Load = nil) then
        Continue;
      PushJob(Net.Name, rkSignal, Driver, DriverPin, Load, LoadPin);
    end;

    // Collect clock links from the buffered clock tree (driver -> each load).
    TreeModel := FClockBufferedModel;
    if TreeModel = nil then
      TreeModel := FClockModel;
    if (TreeModel <> nil) and (Length(FPlanLevels) > 0) then
    begin
      ClkPos := TDictionary<TGateInstance, TPoint>.Create;
      ClkRot := TDictionary<TGateInstance, Boolean>.Create;
      try
        for i := 0 to High(FSpine) do
        begin
          Sp := FSpine[i];
          if Sp.Gate <> nil then
          begin
            ClkPos.AddOrSetValue(Sp.Gate, TPoint.Create(Sp.X, Sp.Y));
            ClkRot.AddOrSetValue(Sp.Gate, Sp.Rotated);
          end;
        end;
        for L := 0 to High(FClockSubtree) do
          for ci := 0 to High(FClockSubtree[L]) do
          begin
            Node := FClockSubtree[L][ci];
            if Node.Gate <> nil then
            begin
              ClkPos.AddOrSetValue(Node.Gate, TPoint.Create(Node.X, Node.Y));
              ClkRot.AddOrSetValue(Node.Gate, False);
            end;
          end;
        for Pair in TreeModel.Nets do
        begin
          Net := Pair.Value;
          // A clock-network net: the root 'clk', the row/spine/delay nets
          // ('clk_*'), or a balancing buffer's output net. The latter are named
          // after the leaf they feed ('<Leaf>__clkbuf_<n>'), so they do NOT
          // start with 'clk' - only the '__clkbuf_' marker identifies them.
          // The buffered model also holds every signal net (it is a clone of the
          // pipeline model); those are not part of the clock tree and are simply
          // ignored here, not counted as skipped.
          if not (StartsText('clk', Net.Name) or
                  (Pos('__clkbuf_', Net.Name) > 0)) then
            Continue;
          Driver := nil;
          DriverPin := '';
          UseClkPad := False;
          for NC in Net.Connections do
            if NC.IsDriver and ClkPos.ContainsKey(NC.Gate) then
            begin
              Driver := NC.Gate;
              DriverPin := NC.PinName;
              Break;
            end;
          if (Driver = nil) and SameText(Net.Name, 'clk') and
             (FClockPadIdx >= 0) then
            UseClkPad := True;
          if (Driver = nil) and (not UseClkPad) then
          begin
            Continue;
          end;
          if UseClkPad then
            DriverPos := TPoint.Create(FPads[FClockPadIdx].X, FPads[FClockPadIdx].Y)
          else if not GatePinBlockAt(Driver, DriverPin, 0,
            ClkPos[Driver].X, ClkPos[Driver].Y, ClkRot[Driver], DriverPos) then
          begin
            Continue;
          end;
          // Each non-driver connection is a point-to-point link.
          for NC in Net.Connections do
          begin
            if NC.IsDriver then
              Continue;
            if NC.Gate = nil then
            begin
              Continue;
            end;
            if not ClkPos.TryGetValue(NC.Gate, GatePos) then
            begin
              Continue;
            end;
            if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
              GatePos.X, GatePos.Y, ClkRot[NC.Gate], Pt) then
            begin
              Continue;
            end;
            Job.NetName := Net.Name;
            Job.Kind := rkClock;
            Job.Driver := nil; // clock links use the pre-resolved DriverPos
            Job.DriverPin := '';
            Job.Load := NC.Gate;
            Job.LoadPin := NC.PinName;
            Job.Routed := False;
            Job.Path := nil;
            Job.PathLayers := nil;
            Job.Start := DriverPos;
            Job.Goal := Pt;
            Job.StartValid := True;
            Job.GoalValid := True;
            Job.Dist := Abs(Job.Start.X - Job.Goal.X) +
              Abs(Job.Start.Y - Job.Goal.Y);
            SetLength(Jobs, Length(Jobs) + 1);
            Jobs[High(Jobs)] := Job;
          end;
        end;
      finally
        ClkPos.Free;
        ClkRot.Free;
      end;
    end;

    // Shortest links first (stable insertion order for ties). A short wire is
    // easy to place first, leaving the longer ones the remaining space.
    SetLength(Order, Length(Jobs));
    for i := 0 to High(Jobs) do
      Order[i] := i;
    for i := 0 to High(Order) - 1 do
      for j := i + 1 to High(Order) do
        if Jobs[Order[j]].Dist < Jobs[Order[i]].Dist then
        begin
          TmpIdx := Order[i];
          Order[i] := Order[j];
          Order[j] := TmpIdx;
        end;

    // ---- Sequential Lee maze routing ----
    // Every net first tries the first routing layer alone. The nets that fail
    // try the second layer alone, and so on through the library's routing
    // layers. Finally the still-unrouted nets get a multi-layer search where a
    // via (layer switch) is allowed at any block. A wire is blocked on its
    // layer as soon as it is routed, so later nets on that layer route around
    // it instead of overlapping.
    for L := 0 to High(FRouteLayers) do
    begin
      PassRouted := 0;
      PassFailed := 0;
      for k := 0 to High(Order) do
      begin
        Job := Jobs[Order[k]];
        if Job.Routed then
          Continue;
        if Job.StartValid and Job.GoalValid and
           LeeRoute(Job.Start, Job.Goal, L, Path, PathLayers) then
        begin
          Job.Routed := True;
          Job.Path := Path;
          Job.PathLayers := PathLayers;
          BlockPath(Path, PathLayers);
          Inc(PassRouted);
          PublishTrace(Job);
        end
        else
        begin
          Job.Routed := False;
          Inc(PassFailed);
        end;
        Jobs[Order[k]] := Job;
      end;
      MemoRouting.Lines.Add(Format(
        'Layer %d (%s): %d routed, %d failed.',
        [L, FRouteLayers[L], PassRouted, PassFailed]));
    end;

    // Final pass: vias allowed across all layers, for everything still
    // unrouted. (This is the only pass that may switch layers mid-wire.)
    PassRouted := 0;
    PassFailed := 0;
    for k := 0 to High(Order) do
    begin
      Job := Jobs[Order[k]];
      if Job.Routed then
        Continue;
      if Job.StartValid and Job.GoalValid and
         LeeRoute(Job.Start, Job.Goal, -1, Path, PathLayers) then
      begin
        Job.Routed := True;
        Job.Path := Path;
        Job.PathLayers := PathLayers;
        BlockPath(Path, PathLayers);
        Inc(PassRouted);
        PublishTrace(Job);
      end
      else
      begin
        Job.Routed := False;
        Inc(PassFailed);
      end;
      Jobs[Order[k]] := Job;
    end;
    MemoRouting.Lines.Add(Format(
      'Via pass: %d routed, %d failed.', [PassRouted, PassFailed]));

    // Final report.
    Failed := 0;
    SigRouted := 0;
    ClkRouted := 0;
    for i := 0 to High(Jobs) do
    begin
      Job := Jobs[i];
      if not Job.Routed or (Length(Job.Path) = 0) then
      begin
        Inc(Failed);
        Continue;
      end;
      if Job.Kind = rkSignal then
        Inc(SigRouted)
      else
        Inc(ClkRouted);
    end;

    MemoRouting.Lines.Add(Format(
      'Routed %d signal net(s) + %d clock link(s) on %d routing layer(s).',
      [SigRouted, ClkRouted, Length(FRouteLayers)]));
    if Failed > 0 then
      MemoRouting.Lines.Add(Format('%d link(s) could not be routed.',
        [Failed]));
  FRoutingSucceeded := (Failed = 0);
  RepaintRoutingPage;
end;

// Builds the per-block obstacle maps for every routing layer: any block covered
// by pin geometry (logic OR clock cells) on that layer is blocked. Cell
// footprints are NOT blocked (they lie on other layers), matching the chosen
// model. Clock gates are placed in FSpine / FClockSubtree and are marked with
// the same rotation handling as the port drawing.
procedure TForm1.BuildRoutingObstacles;
var
  Core, DieW, DieH: Double;
  W, H: Integer;
  i, j: Integer;
  P: TPlacedComponent;
  BX0, BY0, BX1, BY1: Integer;
  Swp: Integer;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  L, ci: Integer;

  // Marks every pin shape of one gate, placed at (AX, AY) (grid cells, with
  // optional 90 deg CCW rotation), on the routing layer it belongs to.
  procedure MarkGatePins(G: TGateInstance; AX, AY: Integer; Rotated: Boolean);
  var
    k, x, y: Integer;
    Port2: TPort;
    Shape2: TPortShape;
    CellH: Double;
  begin
    if (G = nil) or (G.Cell = nil) then
      Exit;
    for k := 0 to High(FRouteLayers) do
    begin
      for Port2 in G.Cell.Ports do
        for Shape2 in Port2.Shapes do
          if SameText(Shape2.Layer, FRouteLayers[k]) then
          begin
            if Rotated then
            begin
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + (CellH - Shape2.y2)) / Core);
              BY0 := Trunc((AY * Core + Shape2.x1) / Core);
              BX1 := Trunc((AX * Core + (CellH - Shape2.y1)) / Core);
              BY1 := Trunc((AY * Core + Shape2.x2) / Core);
            end
            else
            begin
              // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + Shape2.x1) / Core);
              BY0 := Trunc((AY * Core + (CellH - Shape2.y2)) / Core);
              BX1 := Trunc((AX * Core + Shape2.x2) / Core);
              BY1 := Trunc((AY * Core + (CellH - Shape2.y1)) / Core);
            end;
            if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
            if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
            for x := BX0 to BX1 do
              for y := BY0 to BY1 do
                if (x >= 0) and (x < W) and (y >= 0) and (y < H) then
                  FRouteObstacles[k][y * W + x] := True;
          end;
      for Port2 in G.Cell.PowerPorts do
        for Shape2 in Port2.Shapes do
          if SameText(Shape2.Layer, FRouteLayers[k]) then
          begin
            if Rotated then
            begin
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + (CellH - Shape2.y2)) / Core);
              BY0 := Trunc((AY * Core + Shape2.x1) / Core);
              BX1 := Trunc((AX * Core + (CellH - Shape2.y1)) / Core);
              BY1 := Trunc((AY * Core + Shape2.x2) / Core);
            end
            else
            begin
              // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + Shape2.x1) / Core);
              BY0 := Trunc((AY * Core + (CellH - Shape2.y2)) / Core);
              BX1 := Trunc((AX * Core + Shape2.x2) / Core);
              BY1 := Trunc((AY * Core + (CellH - Shape2.y1)) / Core);
            end;
            if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
            if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
            for x := BX0 to BX1 do
              for y := BY0 to BY1 do
                if (x >= 0) and (x < W) and (y >= 0) and (y < H) then
                  FRouteObstacles[k][y * W + x] := True;
          end;
    end;
  end;

begin
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  W := 0;
  H := 0;
  if TryDimParse(EditDieW.Text, DieW) then
    W := Round(DieW / Core);
  if TryDimParse(EditDieH.Text, DieH) then
    H := Round(DieH / Core);
  if (W <= 0) or (H <= 0) then
    Exit;

  FRouteObstaclesW := W;
  FRouteObstaclesH := H;
  // One obstacle map per routing layer.
  SetLength(FRouteObstacles, Length(FRouteLayers));
  for j := 0 to High(FRouteLayers) do
  begin
    SetLength(FRouteObstacles[j], W * H);
    for i := 0 to W * H - 1 do
      FRouteObstacles[j][i] := False;
  end;

  // Logic cells (in FPlacedComponents), unrotated.
  for i := 0 to High(FPlacedComponents) do
  begin
    P := FPlacedComponents[i];
    if (P.Gate <> nil) and (P.Gate.Cell <> nil) then
      MarkGatePins(P.Gate, P.X, P.Y, False);
  end;
  // Clock trunk (spine) cells - trunk cells are rotated 90 deg CCW.
  for i := 0 to High(FSpine) do
  begin
    Sp := FSpine[i];
    if (Sp.Gate <> nil) and (Sp.Gate.Cell <> nil) then
      MarkGatePins(Sp.Gate, Sp.X, Sp.Y, Sp.Rotated);
  end;
  // Clock tree cells (subtree interior + leaves), unrotated.
  for L := 0 to High(FClockSubtree) do
    for ci := 0 to High(FClockSubtree[L]) do
    begin
      Node := FClockSubtree[L][ci];
      if (Node.Gate <> nil) and (Node.Gate.Cell <> nil) then
        MarkGatePins(Node.Gate, Node.X, Node.Y, False);
    end;
end;

// Converts the final congestion map into bias-row expansions. No sideways
// spacing: for the worst ~20% of overused blocks, a bias row is grown at the
// row that holds the block - the band's middle bias row for logic-row blocks,
// or the bias row below the clock cells for clock-row blocks. The growth goes
// through the same IncreaseBiasRowHeight/IncreaseTopBottomBiasRow helpers the
// 'Expand Bias Lines' button uses. Blocks whose row already received an
// insertion this pass are ignored (many offenders on the same row collapse to
// one row insertion). AChanged reports whether any row grew, so the caller can
// rebuild and reroute.
// Increase the height of a band's TOP (Which=0) or MIDDLE (Which=1) bias row by
// ByRows cells. Reports 'not enough space for the bias lines' and leaves the
// layout unchanged if the die has no room for the taller row.
function TForm1.IncreaseBiasRowHeight(Band, Which, ByRows: Integer): Boolean;
var
  DieHBlocks: Integer;
begin
  Result := False;
  if (Band < 0) or (Band >= Length(FBiasRowH)) or (Which < 0) or (Which > 1) or
     (ByRows < 1) then
    Exit;
  if FFloorplanH > 0 then
    DieHBlocks := FFloorplanH
  else
    Exit;
  if FPlanLastTotalH + ByRows + 2 > DieHBlocks then
  begin
    AddFloorplanError('not enough space for the bias lines');
    Exit;
  end;
  FBiasRowH[Band][Which] := FBiasRowH[Band][Which] + ByRows;
  RebuildFloorplanPreserve;
  Result := True;
end;

// Increase the height of the topmost (IsTop=True, band 0's top bias row) or the
// bottommost full-width bias row by ByRows cells. Same height error handling.
function TForm1.IncreaseTopBottomBiasRow(IsTop: Boolean;
  ByRows: Integer): Boolean;
var
  DieHBlocks: Integer;
begin
  Result := False;
  if ByRows < 1 then
    Exit;
  if FFloorplanH > 0 then
    DieHBlocks := FFloorplanH
  else
    Exit;
  if FPlanLastTotalH + ByRows + 2 > DieHBlocks then
  begin
    AddFloorplanError('not enough space for the bias lines');
    Exit;
  end;
  if IsTop then
  begin
    if (Length(FBiasRowH) > 0) and (Length(FBiasRowH[0]) > 0) then
    begin
      FBiasRowH[0][0] := FBiasRowH[0][0] + ByRows;
      RebuildFloorplanPreserve;
      Result := True;
    end;
  end
  else
  begin
    FBottomBiasH := FBottomBiasH + ByRows;
    RebuildFloorplanPreserve;
    Result := True;
  end;
end;

// Increase the width of a vertical BIAS lane by ByCols cells: ColIdx 0 = the
// left feed lane immediately before the clock trunk, ColIdx 1 = the far-right
// lane. The green clock trunk itself is not a bias zone and is never widened.
// If the die has no spare width, first tries to recover space by packing
// (nudging) every row's cells to the left (knock-on) and shrinking the row
// allocation with the
// recovered columns; only if that is impossible reports 'no space for clock
// bias lines' and leaves the layout unchanged.
function TForm1.IncreaseClockTrunkColumn(ColIdx, ByCols: Integer): Boolean;
var
  DieWBlocks, MaxRowW, NewLaneW, Need: Integer;
  TightMax, PrevRight, X: Integer;
  b, i, Ci, n: Integer;
  RowCells: TArray<Integer>;
  Tmp: Integer;
  NewLane: TArray<Integer>;

  // Sorts the band's logic-row cell indices by X (insertion sort, stable).
  procedure SortRowByX;
  var
    a, b2: Integer;
  begin
    for a := 1 to n - 1 do
    begin
      Tmp := RowCells[a];
      b2 := a - 1;
      while (b2 >= 0) and
            (FPlacedComponents[RowCells[b2]].X > FPlacedComponents[Tmp].X) do
      begin
        RowCells[b2 + 1] := RowCells[b2];
        Dec(b2);
      end;
      RowCells[b2 + 1] := Tmp;
    end;
  end;

begin
  Result := False;
  // ColIdx: 0 = left feed bias lane, 1 = far-right bias lane.
  if (ColIdx < 0) or (ColIdx > 1) or (ByCols < 1) then
    Exit;
  if Length(FBiasLaneW) <> 2 then
  begin
    NewLane := nil;
    SetLength(NewLane, 2);
    NewLane[0] := 1;
    NewLane[1] := 1;
    if Length(FBiasLaneW) >= 1 then
    begin
      if FBiasLaneW[0] >= 1 then
        NewLane[0] := FBiasLaneW[0];
      if Length(FBiasLaneW) >= 2 then
        if FBiasLaneW[1] >= 1 then
          NewLane[1] := FBiasLaneW[1];
    end;
    FBiasLaneW := NewLane;
  end;
  if FFloorplanW > 0 then
    DieWBlocks := FFloorplanW
  else
    Exit;
  MaxRowW := FPlanXRight - FPlanXLeft;
  if MaxRowW < 1 then
    MaxRowW := 1;
  NewLaneW := FPlanLane0W + FPlanLane1W + ByCols; // widened lane adds ByCols
  // Fits outright (far-left trunk 1 + rows + lane0 + trunk + lane1)?
  if MaxRowW + 1 + NewLaneW + FPlanTrunkW <= DieWBlocks then
  begin
    FBiasLaneW[ColIdx] := FBiasLaneW[ColIdx] + ByCols;
    RebuildFloorplanPreserve;
    Result := True;
    Exit;
  end;
  // Need to recover columns from the rows: pack each logic row's cells to the
  // left (knock-on nudge) and compute the tightest row width.
  Need := (MaxRowW + 1 + NewLaneW + FPlanTrunkW) - DieWBlocks;
  if Need < 1 then
    Need := 1;
  TightMax := 0;
  for b := 0 to High(FPlanBandStarts) do
  begin
    SetLength(RowCells, 0);
    for i := 0 to High(FPlacedComponents) do
      if (BandIndexOfY(FPlacedComponents[i].Y) = b) and
         (FPlacedComponents[i].Y >= BandLogicRowY(b)) and
         (FPlacedComponents[i].Y < BandLogicRowY(b) + FPlanRowHBlocks) then
      begin
        SetLength(RowCells, Length(RowCells) + 1);
        RowCells[High(RowCells)] := i;
      end;
    n := Length(RowCells);
    if n = 0 then
      Continue;
    SortRowByX;
    // Knock-on: pack left from XLeft with one-cell gaps.
    PrevRight := FPlanXLeft - 1;
    for Ci := 0 to n - 1 do
    begin
      X := FPlanXLeft;
      if PrevRight + 1 > X then
        X := PrevRight + 1;
      if FPlacedComponents[RowCells[Ci]].X > X then
        FPlacedComponents[RowCells[Ci]].X := X;
      FGatePlacement.AddOrSetValue(FPlacedComponents[RowCells[Ci]].Gate,
        TPoint.Create(FPlacedComponents[RowCells[Ci]].X,
          FPlacedComponents[RowCells[Ci]].Y));
      PrevRight := FPlacedComponents[RowCells[Ci]].X +
        FPlacedComponents[RowCells[Ci]].W;
    end;
    if PrevRight - FPlanXLeft + 1 > TightMax then
      TightMax := PrevRight - FPlanXLeft + 1;
  end;
  if MaxRowW - TightMax >= Need then
  begin
    // Recovered enough: shrink the row allocation, widen the lane, rebuild.
    FPlanMaxRowW := MaxRowW - Need;
    FBiasLaneW[ColIdx] := FBiasLaneW[ColIdx] + ByCols;
    RebuildFloorplanPreserve;
    Result := True;
  end
  else
  begin
    // Could not recover enough width. Rebuild so the (nudged) cell positions
    // match the floorplan grid, then report the failure.
    RebuildFloorplanPreserve;
    AddFloorplanError('no space for clock bias lines');
  end;
end;

// Collects the power ports of one placed cell that sit on AEdge (top/bottom),
// as TBiasPort records with their grid-block position and current. Used to
// partition a row's bias demand into current groups. Ports use the cell's local
// shape geometry mapped to the die via the placed origin (AX, AY).
procedure TForm1.CollectCellPorts(G: TGateInstance; AX, AY: Integer;
  AEdge: TPortEdge; var Ports: TArray<TBiasPort>);
var
  Port: TPort;
  Shape: TPortShape;
  BP: TBiasPort;
  Core, CellH: Double;
  BX0, BX1, HBlocks: Integer;
  Swp: Integer;
begin
  if (G = nil) or (G.Cell = nil) then
    Exit;
  Core := FPlanCore;
  if Core <= 0 then
    Exit;
  CellH := G.Cell.Height;
  if CellH <= 0 then
    CellH := Core;
  HBlocks := Max(1, Round(CellH / Core));
  for Port in G.Cell.PowerPorts do
    for Shape in Port.Shapes do
      if Shape.Edge = AEdge then
      begin
        BP.Gate := G;
        BP.Edge := AEdge;
        // Horizontal port block from the parsed shape geometry (X is not
        // affected by the Y-axis flip).
        BX0 := Trunc((AX * Core + Shape.x1) / Core);
        BX1 := Trunc((AX * Core + Shape.x2) / Core);
        if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
        BP.X := (BX0 + BX1) div 2;
        // The bias line must NOT enter the cell: the offshoot terminates at the
        // cell's edge row, so the connection reads as a T touching the cell.
        // Top-edge ports touch the cell's top row, bottom-edge ports its bottom
        // row - read from the port's edge and the placed cell, no hard-coding.
        if AEdge = peTop then
          BP.Y := AY
        else
          BP.Y := AY + HBlocks - 1;
        BP.CurrentUa := Shape.CurrentUa;
        SetLength(Ports, Length(Ports) + 1);
        Ports[High(Ports)] := BP;
      end;
end;

// Partitions a side's ports (in placement order, i.e. by X) into groups each
// carrying at most AMaxUa. Each group becomes one horizontal bias track. Ports
// with no current are skipped; a group never splits a single port (the caller
// guarantees AMaxUa >= every port's current).
function TForm1.PartitionBiasPorts(const Ports: TArray<TBiasPort>;
  AMaxUa: Double): TArray<TBiasGroup>;
var
  Sorted: TArray<TBiasPort>;
  Order: TArray<Integer>;
  i, j, Tmp: Integer;
  G: TBiasGroup;
  GroupStart: Integer;
begin
  Result := nil;
  if AMaxUa <= 0 then
    Exit;
  // Keep only ports with current, ordered by X (placement order).
  SetLength(Sorted, 0);
  for i := 0 to High(Ports) do
    if Ports[i].CurrentUa > 0 then
    begin
      SetLength(Sorted, Length(Sorted) + 1);
      Sorted[High(Sorted)] := Ports[i];
    end;
  if Length(Sorted) = 0 then
    Exit;
  SetLength(Order, Length(Sorted));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 0 to High(Order) - 1 do
    for j := i + 1 to High(Order) do
      if Sorted[Order[j]].X < Sorted[Order[i]].X then
      begin
        Tmp := Order[i];
        Order[i] := Order[j];
        Order[j] := Tmp;
      end;
  // Greedy partition: fill a group until adding the next port would exceed the
  // limit, then start a new group.
  GroupStart := 0;
  G.TotalUa := 0;
  G.Ports := nil;
  for i := 0 to High(Order) do
  begin
    if (i > GroupStart) and
       (G.TotalUa + Sorted[Order[i]].CurrentUa > AMaxUa) then
    begin
      // Close the current group.
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := G;
      G.Ports := nil;
      G.TotalUa := 0;
      GroupStart := i;
    end;
    SetLength(G.Ports, Length(G.Ports) + 1);
    G.Ports[High(G.Ports)] := Sorted[Order[i]];
    G.TotalUa := G.TotalUa + Sorted[Order[i]].CurrentUa;
  end;
  if Length(G.Ports) > 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := G;
  end;
end;

// Collects the power ports of the clock-trunk (spine) cells on one side. The
// trunk cells are rotated 90 deg CCW, so their LEF "top" ports face LEFT and
// their "bottom" ports face RIGHT. The port block is mapped with the same
// rotation used by the obstacle builder: local (x, y) -> (CellH - y, x).
// IsLeft selects the left ("top") or right ("bottom") ports.
procedure TForm1.CollectTrunkPorts(IsLeft: Boolean; var Ports: TArray<TBiasPort>);
var
  i, BX0, BX1, BY0, BY1, Swp, W: Integer;
  Port: TPort;
  Shape: TPortShape;
  BP: TBiasPort;
  Core, CellH: Double;
  AEdge: TPortEdge;
begin
  SetLength(Ports, 0);
  Core := FPlanCore;
  if Core <= 0 then
    Exit;
  if IsLeft then
    AEdge := peTop
  else
    AEdge := peBottom;
  for i := 0 to High(FSpine) do
  begin
    if (FSpine[i].Gate = nil) or (FSpine[i].Gate.Cell = nil) then
      Continue;
    CellH := FSpine[i].Gate.Cell.Height;
    if CellH <= 0 then
      CellH := Core;
    W := Max(1, Round(CellH / Core)); // placed width of the rotated cell
    for Port in FSpine[i].Gate.Cell.PowerPorts do
      for Shape in Port.Shapes do
        if Shape.Edge = AEdge then
        begin
          // Rotated 90 deg CCW: local (x, y) -> (CellH - y, x).
          BX0 := FSpine[i].X + Trunc((CellH - Shape.y2) / Core);
          BX1 := FSpine[i].X + Trunc((CellH - Shape.y1) / Core);
          BY0 := FSpine[i].Y + Trunc(Shape.x1 / Core);
          BY1 := FSpine[i].Y + Trunc(Shape.x2 / Core);
          if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
          if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
          BP.Gate := FSpine[i].Gate;
          BP.Edge := AEdge;
          // Left ports hug the trunk's left edge, right ports its right edge.
          // Clamp to the cell's own columns so the tap always reaches the cell
          // edge (an edge-hugging right port maps one block past the cell).
          if IsLeft then
            BP.X := BX0
          else
            BP.X := BX1;
          if BP.X < FSpine[i].X then
            BP.X := FSpine[i].X;
          if BP.X > FSpine[i].X + W - 1 then
            BP.X := FSpine[i].X + W - 1;
          BP.Y := (BY0 + BY1) div 2;
          BP.CurrentUa := Shape.CurrentUa;
          SetLength(Ports, Length(Ports) + 1);
          Ports[High(Ports)] := BP;
        end;
  end;
end;

// Partitions the trunk side's ports into groups each carrying at most AMaxUa,
// ordered by Y (ascending = top-to-bottom for the left side, descending =
// bottom-to-top for the right). Each group becomes one vertical track.
function TForm1.PartitionTrunkPorts(const Ports: TArray<TBiasPort>;
  AMaxUa: Double; Descending: Boolean): TArray<TBiasGroup>;
var
  Sorted: TArray<TBiasPort>;
  Order: TArray<Integer>;
  i, j, Tmp: Integer;
  G: TBiasGroup;
  GroupStart: Integer;
begin
  Result := nil;
  if AMaxUa <= 0 then
    Exit;
  SetLength(Sorted, 0);
  for i := 0 to High(Ports) do
    if Ports[i].CurrentUa > 0 then
    begin
      SetLength(Sorted, Length(Sorted) + 1);
      Sorted[High(Sorted)] := Ports[i];
    end;
  if Length(Sorted) = 0 then
    Exit;
  SetLength(Order, Length(Sorted));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 0 to High(Order) - 1 do
    for j := i + 1 to High(Order) do
      if (not Descending and (Sorted[Order[j]].Y < Sorted[Order[i]].Y)) or
         (Descending and (Sorted[Order[j]].Y > Sorted[Order[i]].Y)) then
      begin
        Tmp := Order[i];
        Order[i] := Order[j];
        Order[j] := Tmp;
      end;
  // Greedy partition: fill a group until adding the next port would exceed.
  GroupStart := 0;
  G.TotalUa := 0;
  G.Ports := nil;
  for i := 0 to High(Order) do
  begin
    if (i > GroupStart) and
       (G.TotalUa + Sorted[Order[i]].CurrentUa > AMaxUa) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := G;
      G.Ports := nil;
      G.TotalUa := 0;
      GroupStart := i;
    end;
    SetLength(G.Ports, Length(G.Ports) + 1);
    G.Ports[High(G.Ports)] := Sorted[Order[i]];
    G.TotalUa := G.TotalUa + Sorted[Order[i]].CurrentUa;
  end;
  if Length(G.Ports) > 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := G;
  end;
end;

// Routes the horizontal bias lines for every channel (topmost, bottommost, and
// each band's middle/top bias rows). Runs after the main circuit routing. Each
// partition group becomes one track: a horizontal wire at its own Y that runs
// left to the far-left bias trunk, with vertical offshoots dropping to each port
// in the group. Group 1 hugs the cells; group g is g-1 rows further up (top
// ports) or further down (bottom ports). In a shared channel the two sides'
// tracks grow inward from their own cell rows and meet in the middle; the
// final-group merge edge case shares one track. The trunk itself is left for a
// later step, so no trunk connections are drawn yet.
procedure TForm1.RouteBiasLines;
var
  MaxUa: Double;
  NumBands, Band, g: Integer;
  LogicTopP, LogicBotP, ClockTopP, ClockBotP: TArray<TArray<TBiasPort>>;
  GA, GB: TArray<TBiasGroup>;
  Above, Below: TArray<TBiasPort>;
  Merged: Boolean;
  ChanY0, ChanY1: Integer; // channel row extent (top row .. bottom row+1)
  TrackY: Integer;
  Tr: TRoutedTrace;
  BiasLayer: string;
  TrunkPorts: TArray<TBiasPort>;
  TrackX, TurnY, ToX, TrunkL, TrunkR, TopRow, BotRow: Integer;

  procedure CollectLogic(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    k: Integer;
  begin
    SetLength(APorts, 0);
    for k := 0 to High(FPlacedComponents) do
      if BandIndexOfY(FPlacedComponents[k].Y) = Band then
        CollectCellPorts(FPlacedComponents[k].Gate, FPlacedComponents[k].X,
          FPlacedComponents[k].Y, AEdge, APorts);
  end;

  procedure CollectClock(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    L, ci: Integer;
  begin
    SetLength(APorts, 0);
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if (not FClockSubtree[L][ci].IsLeaf) and
           (BandIndexOfY(FClockSubtree[L][ci].Y) = Band) then
          CollectCellPorts(FClockSubtree[L][ci].Gate, FClockSubtree[L][ci].X,
            FClockSubtree[L][ci].Y, AEdge, APorts);
  end;

  // Emits one group's track. ATrackY is the track's grid row; the group's ports
  // are on AEdge (their offshoots drop up/down to the track). Ports are given
  // left to right. The wire runs from the far-left trunk to the rightmost port:
  // a horizontal run along the track with a vertical offshoot to each port.
  procedure EmitGroup(const AGrp: TBiasGroup; ATrackY: Integer;
    const ANetName: string);
  var
    k, px, py: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // Start at the far-left bias trunk column (FPlanXLeft-1), on the track.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, ATrackY);
    for k := 0 to High(AGrp.Ports) do
    begin
      px := AGrp.Ports[k].X;
      py := AGrp.Ports[k].Y;
      // Horizontal to the port's X, then the vertical offshoot to the port, then
      // back up onto the track (so the polyline stays on the track between ports).
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(px, ATrackY);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(px, ATrackY);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

  // Emits the merged edge-case as ONE bias line: a single horizontal run from
  // the far-left trunk to the farthest-right port of the two groups, at the top
  // group's track. Every port (top and bottom) simply branches off that one line
  // with a short vertical stub - no separate bus + connector. ASharedY = the
  // shared line row (top group's track).
  procedure EmitMergedT(const ATopGrp, ABottomGrp: TBiasGroup;
    ASharedY: Integer; const ANetName: string);
  var
    Combined: TArray<TBiasPort>;
    k, j, px, py: Integer;
    Tmp: TBiasPort;
  begin
    // Combine both groups' ports into one list, ordered left to right so the
    // line never doubles back.
    SetLength(Combined, 0);
    for k := 0 to High(ATopGrp.Ports) do
    begin
      SetLength(Combined, Length(Combined) + 1);
      Combined[High(Combined)] := ATopGrp.Ports[k];
    end;
    for k := 0 to High(ABottomGrp.Ports) do
    begin
      SetLength(Combined, Length(Combined) + 1);
      Combined[High(Combined)] := ABottomGrp.Ports[k];
    end;
    if Length(Combined) = 0 then
      Exit;
    for k := 1 to High(Combined) do
    begin
      Tmp := Combined[k];
      j := k - 1;
      while (j >= 0) and (Combined[j].X > Tmp.X) do
      begin
        Combined[j + 1] := Combined[j];
        Dec(j);
      end;
      Combined[j + 1] := Tmp;
    end;
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // One line from the far-left trunk to the farthest-right port.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, ASharedY);
    for k := 0 to High(Combined) do
    begin
      px := Combined[k].X;
      py := Combined[k].Y;
      // Branch to each port (down for top ports, up for bottom ports) and back.
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(px, ASharedY);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(px, ASharedY);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

  // Emits one clock-bias group as a vertical track: a vertical run at ATrackX
  // from the turn row ATurnY down/up to each port, tapping horizontally into
  // each port, plus a horizontal run from the track all the way left to AToX
  // (the far-left bias trunk), which it joins. Ports are ordered along the track
  // (top-to-bottom for the left side, bottom-to-top for the right).
  procedure EmitClockGroup(const AGrp: TBiasGroup; ATrackX, ATurnY, AToX: Integer;
    const ANetName: string);
  var
    k, px, py: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // Start at the merge point on the full-width bias row, run to the track.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(AToX, ATurnY);
    SetLength(Tr.Points, Length(Tr.Points) + 1);
    Tr.Points[High(Tr.Points)] := TPoint.Create(ATrackX, ATurnY);
    // Walk the vertical track, tapping into each port.
    for k := 0 to High(AGrp.Ports) do
    begin
      px := AGrp.Ports[k].X;
      py := AGrp.Ports[k].Y;
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(ATrackX, py);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(ATrackX, py);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

begin
  if not FFloorplanValid then
    Exit;
  if not TryDimParse(EditBiasCurrent.Text, MaxUa) or (MaxUa <= 0) then
    Exit;
  // The bias lines are drawn on the user-chosen bias layer (set on the
  // placement-config page), which BuildRoutingLayers adds to FRoutingLayers so
  // it gets the standard per-layer colour and toggle. Fall back to the primary
  // signal layer if it was never set.
  BuildRoutingLayers;
  BiasLayer := FBiasLayer;
  if BiasLayer = '' then
    BiasLayer := FRouteSignalLayer;
  if BiasLayer = '' then
    Exit;
  NumBands := Length(FPlanBandStarts);
  if NumBands < 1 then
    Exit;
  // Collect each side's ports once.
  SetLength(LogicTopP, NumBands);
  SetLength(LogicBotP, NumBands);
  SetLength(ClockTopP, NumBands);
  SetLength(ClockBotP, NumBands);
  for Band := 0 to NumBands - 1 do
  begin
    CollectLogic(Band, peTop, LogicTopP[Band]);
    CollectLogic(Band, peBottom, LogicBotP[Band]);
    CollectClock(Band, peTop, ClockTopP[Band]);
    CollectClock(Band, peBottom, ClockBotP[Band]);
  end;

  // Topmost full-width row: band 0's logic row top ports, tracks stepping UP
  // from the cells. Channel rows: [FPlanBandStarts[0], BandLogicRowY(0)).
  GA := PartitionBiasPorts(LogicTopP[0], MaxUa);
  ChanY1 := BandLogicRowY(0);
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY1 - 1 - g; // group 1 hugs the cells, then steps up
    EmitGroup(GA[g], TrackY, Format('bias_topmost_g%d', [g + 1]));
  end;

  // Bottommost full-width row: the last band's clock row bottom ports, tracks
  // stepping DOWN from the cells. Channel rows: [end of last clock row, +1+FBottomBiasH).
  GA := PartitionBiasPorts(ClockBotP[NumBands - 1], MaxUa);
  ChanY0 := BandClockRowY(NumBands - 1) + FPlanRowHBlocks;
  if NumBands - 1 < Length(FClockRowExtra) then
    ChanY0 := ChanY0 + FClockRowExtra[NumBands - 1];
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY0 + g; // group 1 hugs the cells, then steps down
    EmitGroup(GA[g], TrackY, Format('bias_bottom_g%d', [g + 1]));
  end;

  // Interior channels.
  for Band := 0 to NumBands - 1 do
  begin
    // MIDDLE bias row: logic bottom (above) + clock top (below). The channel
    // occupies [BandLogicRowY+RowH, BandClockRowY). Tracks from the logic side
    // step down from the logic cells; tracks from the clock side step up from
    // the clock cells; they meet in the middle.
    Above := LogicBotP[Band];
    Below := ClockTopP[Band];
    GA := PartitionBiasPorts(Above, MaxUa);
    GB := PartitionBiasPorts(Below, MaxUa);
    Merged := False;
    if (Length(GA) > 0) and (Length(GB) > 0) then
      if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
        Merged := True;
    ChanY0 := BandClockRowY(Band) - BandMidBiasH(Band);
    ChanY1 := BandClockRowY(Band);
    // Logic side: group g is g-1 rows below the logic cells. The last group is
    // the shared line when the edge case merges it with the clock side's last.
    for g := 0 to High(GA) do
    begin
      if Merged and (g = High(GA)) then
        Continue; // emitted with the T below
      TrackY := ChanY0 + g;
      EmitGroup(GA[g], TrackY, Format('bias_b%d_mid_lg%d', [Band, g + 1]));
    end;
    // Clock side: group g is g-1 rows above the clock cells.
    for g := 0 to High(GB) do
    begin
      if Merged and (g = High(GB)) then
        Continue; // emitted with the T below
      TrackY := ChanY1 - 1 - g;
      EmitGroup(GB[g], TrackY, Format('bias_b%d_mid_cl%d', [Band, g + 1]));
    end;
    // Merged edge case: one bias line at the top (logic) group's last track,
    // with both groups' ports branching off it.
    if Merged then
      EmitMergedT(GA[High(GA)], GB[High(GB)], ChanY0 + High(GA),
        Format('bias_b%d_mid_merged', [Band]));

    // TOP bias row (band > 0): previous band's clock bottom (above) + this
    // band's logic top (below). Channel rows: [FPlanBandStarts[Band], BandLogicRowY(Band)).
    if Band > 0 then
    begin
      Above := ClockBotP[Band - 1];
      Below := LogicTopP[Band];
      GA := PartitionBiasPorts(Above, MaxUa);
      GB := PartitionBiasPorts(Below, MaxUa);
      Merged := False;
      if (Length(GA) > 0) and (Length(GB) > 0) then
        if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
          Merged := True;
      ChanY0 := FPlanBandStarts[Band];
      ChanY1 := BandLogicRowY(Band);
      // Clock side above: group g is g-1 rows below the previous clock row.
      for g := 0 to High(GA) do
      begin
        if Merged and (g = High(GA)) then
          Continue; // emitted with the T below
        TrackY := ChanY0 + g;
        EmitGroup(GA[g], TrackY, Format('bias_b%d_top_cl%d', [Band, g + 1]));
      end;
      // Logic side below: group g is g-1 rows above this logic row.
      for g := 0 to High(GB) do
      begin
        if Merged and (g = High(GB)) then
          Continue; // emitted with the T below
        TrackY := ChanY1 - 1 - g;
        EmitGroup(GB[g], TrackY, Format('bias_b%d_top_lg%d', [Band, g + 1]));
      end;
      // Merged edge case: one bias line at the top (clock) group's last track,
      // with both groups' ports branching off it.
      if Merged then
        EmitMergedT(GA[High(GA)], GB[High(GB)], ChanY0 + High(GA),
          Format('bias_b%d_top_merged', [Band]));
    end;
  end;

  // --- Clock bias lines (vertical) ---
  // The trunk cells are rotated 90 deg CCW, so their "top" ports face left and
  // "bottom" ports face right. Left ports are grouped top-to-bottom, right ports
  // bottom-to-top. Each group is one vertical track in the flanking bias lane
  // (group 1 nearest the green trunk, stepping outward); the track runs to a
  // stacked turn row (group 1 at the very top / bottom) then turns outward into
  // the topmost / bottommost full-width bias row. The turn rows stack so there
  // is always room for the corner.
  TrunkL := FPlanXRight + FPlanLane0W;                 // green trunk left edge
  TrunkR := FPlanXRight + FPlanLane0W + FPlanTrunkW;   // green trunk right edge
  TopRow := FPlanBandStarts[0];                        // very top of the stack
  BotRow := FPlanBandStarts[NumBands - 1] +
    FPlanBandHeight[NumBands - 1] + FBottomBiasH;      // bottom of bottom bias row
  // Left side: top-to-bottom groups, tracks step left, turn rows step down.
  CollectTrunkPorts(True, TrunkPorts);
  GA := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GA) do
  begin
    TrackX := TrunkL - 1 - g;   // group 1 hugs the trunk, then steps left
    TurnY := TopRow + g;        // group 1 at the very top, then one lower
    ToX := FPlanXLeft - 1;      // run left to the far-left bias trunk
    EmitClockGroup(GA[g], TrackX, TurnY, ToX, Format('bias_clkL_g%d', [g + 1]));
  end;
  // Right side: TOP-to-bottom groups so the topmost group turns at the LOWEST
  // point (BotRow) and later groups turn one higher. The tracks step LEFT toward
  // the trunk with group index: the group turning lowest sits farthest from the
  // trunk, so a later group's higher run never crosses an earlier track.
  CollectTrunkPorts(False, TrunkPorts);
  GB := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GB) do
  begin
    TrackX := TrunkR + (High(GB) - g); // topmost group farthest right, stepping left
    TurnY := BotRow - g;               // group 1 (topmost) at the very bottom, then one higher
    ToX := FPlanXLeft - 1;             // run left to the far-left bias trunk
    EmitClockGroup(GB[g], TrackX, TurnY, ToX, Format('bias_clkR_g%d', [g + 1]));
  end;

  // The far-left bias trunk itself: a single vertical wire on the trunk column
  // (FPlanXLeft-1) that every bias line branches from. It spans the full stack,
  // from the topmost bias row to the bottom of the bottom-most bias row.
  SetLength(Tr.Points, 2);
  Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, FPlanBandStarts[0]);
  Tr.Points[1] := TPoint.Create(FPlanXLeft - 1,
    FPlanBandStarts[NumBands - 1] + FPlanBandHeight[NumBands - 1] +
    1 + FBottomBiasH);
  SetLength(Tr.Layers, 2);
  Tr.Layers[0] := BiasLayer;
  Tr.Layers[1] := BiasLayer;
  Tr.NetName := 'bias_trunk';
  SetLength(FRouteTraces, Length(FRouteTraces) + 1);
  FRouteTraces[High(FRouteTraces)] := Tr;

  RepaintRoutingPage;
end;

// Total routed length of one trace, in um: the sum of Manhattan distances
// between consecutive grid blocks, scaled by the core block size. Consecutive
// points are adjacent (or a via hop), so this is the wire's real length.
function TForm1.TraceLengthUm(const ATr: TRoutedTrace; Core: Double): Double;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(ATr.Points) - 1 do
    Result := Result + (Abs(ATr.Points[k + 1].X - ATr.Points[k].X) +
      Abs(ATr.Points[k + 1].Y - ATr.Points[k].Y)) * Core;
end;

// A bias trace is a constant-voltage distribution line (net name 'bias_*'), not
// a PTL: it has no timing or propagation constraints, so it is excluded from
// the PTL validation (length limit, weighted scale, dashing).
function TForm1.IsBiasTrace(const ATr: TRoutedTrace): Boolean;
begin
  Result := StartsText('bias_', ATr.NetName);
end;

// Total length of a raw grid-block polyline, in um (used while re-routing).
function TForm1.PathLengthUm(const Pts: TArray<TPoint>; Core: Double): Double;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(Pts) - 1 do
    Result := Result + (Abs(Pts[k + 1].X - Pts[k].X) +
      Abs(Pts[k + 1].Y - Pts[k].Y)) * Core;
end;

// Marks one trace's cells as obstacles on their layers (like RunRouting's
// BlockPath, but reusable). Layers holds layer NAMES.
procedure TForm1.BlockTrace(ATraceIdx: Integer);
var
  ii, L: Integer;
  Pt: TPoint;
begin
  for ii := 0 to High(FRouteTraces[ATraceIdx].Points) do
  begin
    Pt := FRouteTraces[ATraceIdx].Points[ii];
    if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
       (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
      Continue;
    if ii <= High(FRouteTraces[ATraceIdx].Layers) then
    begin
      L := FRoutingLayers.IndexOf(FRouteTraces[ATraceIdx].Layers[ii]);
      if (L >= 0) and (L <= High(FRouteObstacles)) then
        FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := True;
    end;
  end;
end;

// Removes one trace's cells from the obstacle maps (the inverse of BlockTrace),
// freeing the space so a re-route can use it.
procedure TForm1.UnblockTrace(ATraceIdx: Integer);
var
  ii, L: Integer;
  Pt: TPoint;
begin
  for ii := 0 to High(FRouteTraces[ATraceIdx].Points) do
  begin
    Pt := FRouteTraces[ATraceIdx].Points[ii];
    if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
       (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
      Continue;
    if ii <= High(FRouteTraces[ATraceIdx].Layers) then
    begin
      L := FRoutingLayers.IndexOf(FRouteTraces[ATraceIdx].Layers[ii]);
      if (L >= 0) and (L <= High(FRouteObstacles)) then
        FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := False;
    end;
  end;
end;

// Rips up one trace and re-routes it between the same endpoints through the
// usual passes (layer 0, layer 1, ..., then vias), keeping the shortest route
// found. Returns True if that route is under the PTL length limit; otherwise
// the (shorter) route is still applied and False is returned so the caller
// proceeds to buffer insertion. If nothing routes at all, the original trace
// and its blocking are restored.
function TForm1.RerouteTrace(ATraceIdx: Integer): Boolean;
var
  Core, Limit, Len, BestLen: Double;
  Start, Goal: TPoint;
  L, i: Integer;
  Path, BestPath: TArray<TPoint>;
  Layers, BestLayers: TArray<Integer>;
  FoundAny: Boolean;
begin
  Result := False;
  if (ATraceIdx < 0) or (ATraceIdx > High(FRouteTraces)) then
    Exit;
  if Length(FRouteTraces[ATraceIdx].Points) < 2 then
    Exit;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  if not (TryDimParse(EditPTLLength.Text, Limit) and (Limit > 0)) then
    Exit;
  Start := FRouteTraces[ATraceIdx].Points[0];
  Goal := FRouteTraces[ATraceIdx].Points[High(FRouteTraces[ATraceIdx].Points)];
  UnblockTrace(ATraceIdx); // free the current wire's space for the search
  FoundAny := False;
  BestLen := MaxDouble;
  BestPath := nil;
  BestLayers := nil;
  for L := 0 to High(FRouteLayers) do
    if LeeRoute(Start, Goal, L, Path, Layers) then
    begin
      FoundAny := True;
      Len := PathLengthUm(Path, Core);
      if Len < BestLen then
      begin
        BestLen := Len;
        BestPath := Path;
        BestLayers := Layers;
      end;
    end;
  if LeeRoute(Start, Goal, -1, Path, Layers) then
  begin
    FoundAny := True;
    Len := PathLengthUm(Path, Core);
    if Len < BestLen then
    begin
      BestLen := Len;
      BestPath := Path;
      BestLayers := Layers;
    end;
  end;
  if FoundAny then
  begin
    FRouteTraces[ATraceIdx].Points := BestPath;
    SetLength(FRouteTraces[ATraceIdx].Layers, Length(BestLayers));
    for i := 0 to High(BestLayers) do
      FRouteTraces[ATraceIdx].Layers[i] := FRouteLayers[BestLayers[i]];
    BlockTrace(ATraceIdx);
    Result := BestLen <= Limit;
  end
  else
    BlockTrace(ATraceIdx); // nothing routed: put the original wire back
end;

// The buffer type to use for length-breaking: the user's buffer list, choosing
// the cell with the smallest propagation delay.
function TForm1.FindMinDelayBufferCell: TCell;
var
  i: Integer;
  Cell, Best, First: TCell;
  Delay, BestDelay: Double;
begin
  Result := nil;
  Best := nil;
  First := nil;
  BestDelay := MaxDouble;
  if FLib = nil then
    Exit;
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if Cell = nil then
      Continue;
    if First = nil then
      First := Cell;
    Delay := CellDelayPs(Cell);
    if (Delay >= 0) and (Delay < BestDelay) then
    begin
      BestDelay := Delay;
      Best := Cell;
    end;
  end;
  if Best = nil then
    Best := First;
  Result := Best;
end;

// Re-applies every validation buffer's chosen slot after a floorplan rebuild
// wiped the placement. Signal buffers (logic cells) go back into
// FPlacedComponents/FGatePlacement; clock-link buffers are located in
// FClockSubtree (where BuildClockSubtreePlacements placed them) and moved to
// their slot. The row Y is recomputed for the current band geometry; X is
// clamped to the current row span.
procedure TForm1.ReapplyValidationBuffers;
var
  i, i2, W, H, Y, X: Integer;
  VB: TValidationBuffer;
  P: TPlacedComponent;
  L, ci: Integer;
  Found: Boolean;
begin
  if Length(FPlanBandStarts) = 0 then
    Exit;
  for i := 0 to High(FValidationBuffers) do
  begin
    VB := FValidationBuffers[i];
    if (VB.Gate = nil) or (VB.Gate.Cell = nil) then
      Continue;
    W := Round(VB.Gate.Cell.Width / FPlanCore);
    if W < 1 then
      W := 1;
    H := Round(VB.Gate.Cell.Height / FPlanCore);
    if H < 1 then
      H := 1;
    if VB.RowType = 0 then
      Y := BandLogicRowY(VB.Band) + ((FPlanRowHBlocks - H) div 2)
    else if VB.RowType = 1 then
      Y := BandClockRowY(VB.Band) + ((FPlanRowHBlocks - H) div 2)
    else
      Y := VB.Y;
    X := VB.X;
    if VB.RowType = 2 then
    begin
      // Clock trunk column: recompute the current trunk position and clamp X/Y
      // to the trunk's column / the full stack.
      if X < FPlanXRight + FPlanLane0W then
        X := FPlanXRight + FPlanLane0W;
      if X + W > FPlanXRight + FPlanLane0W + FPlanRowHBlocks then
        X := FPlanXRight + FPlanLane0W + FPlanRowHBlocks - W;
      if Length(FPlanBandStarts) > 0 then
      begin
        if Y < FPlanBandStarts[0] then
          Y := FPlanBandStarts[0];
        if Y + H > FPlanBandStarts[High(FPlanBandStarts)] +
           FPlanBandHeight[High(FPlanBandStarts)] + FBottomBiasH then
          Y := FPlanBandStarts[High(FPlanBandStarts)] +
            FPlanBandHeight[High(FPlanBandStarts)] + FBottomBiasH - H;
      end;
    end
    else
    begin
      if X < FPlanXLeft then
        X := FPlanXLeft;
      if X + W > FPlanXRight then
        X := FPlanXRight - W;
      if X < FPlanXLeft then
        X := FPlanXLeft;
    end;
    VB.X := X;
    VB.Y := Y;
    FValidationBuffers[i] := VB;

    if VB.IsClock then
    begin
      Found := False;
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if FClockSubtree[L][ci].Gate = VB.Gate then
          begin
            FClockSubtree[L][ci].X := X;
            FClockSubtree[L][ci].Y := Y;
            Found := True;
            Break;
          end;
      if Found then
        FGatePlacement.AddOrSetValue(VB.Gate, TPoint.Create(X, Y));
    end
    else
    begin
      Found := False;
      for i2 := 0 to High(FPlacedComponents) do
        if FPlacedComponents[i2].Gate = VB.Gate then
        begin
          FPlacedComponents[i2].X := X;
          FPlacedComponents[i2].Y := Y;
          Found := True;
          Break;
        end;
      if not Found then
      begin
        P.Gate := VB.Gate;
        P.InstanceName := Format('%s_vb', [VB.Gate.CellName]);
        P.CellName := VB.Gate.CellName;
        P.ClockLevel := -1;
        P.X := X;
        P.Y := Y;
        P.W := W;
        P.H := H;
        SetLength(FPlacedComponents, Length(FPlacedComponents) + 1);
        FPlacedComponents[High(FPlacedComponents)] := P;
      end;
      FGatePlacement.AddOrSetValue(VB.Gate, TPoint.Create(X, Y));
    end;
  end;
end;

// Re-runs the bias expansion (rows/lanes grown for the current port set) and
// the routing after a buffer insertion. Re-applies the validation buffers in
// the new geometry first. RunRouting clears the memo, so the validation log is
// preserved and the routing's own report is appended to it.
procedure TForm1.RunBiasExpansionAndRouting;
var
  Saved, Report: TStringList;
begin
  ButtonExpandBiasClick(nil);
  ReapplyValidationBuffers;
  Saved := TStringList.Create;
  Report := TStringList.Create;
  try
    Saved.Assign(MemoRouting.Lines);
    RunRouting;
    Report.Assign(MemoRouting.Lines);
    MemoRouting.Lines.Assign(Saved);
    MemoRouting.Lines.AddStrings(Report);
  finally
    Saved.Free;
    Report.Free;
  end;
  // Bias lines after the main routing (RunRouting clears FRouteTraces, so the
  // bias traces must be appended afterwards, as in ButtonRunRoutingClick).
  RouteBiasLines;
end;

// Attempts to insert a minimum-delay buffer that splits NetName (whose load is
// Load at LoadPin) so the two new PTLs are each under the length limit. The
// buffer is added to the placement (or clock) model's netlist, placed at the
// given slot, and the bias expansion + routing are re-run. If the circuit fails
// to route with the buffer there, the netlist is reverted and False returned so
// the caller can mark the slot unusable and try another.
function TForm1.TryInsertBuffer(IsClock: Boolean; const NetName: string;
  Driver, Load: TGateInstance; const DriverPin, LoadPin: string;
  APadLoad: Boolean;
  BufCell: TCell; const InPin, OutPin: string;
  ABand, ARowType, AX, AY: Integer): Boolean;
var
  Model: TBlifModel;
  Net: TNet;
  OrigConn: TList<TNetConnection>;
  NewNetName: string;
  NewNet: TNet;
  NC: TNetConnection;
  BufGate: TGateInstance;
  Conn: TPinConnection;
  VB: TValidationBuffer;
  InPort, OutPort: TPort;
  InNetName, OutNetName: string;
begin
  Result := False;
  if IsClock then
  begin
    Model := FClockBufferedModel;
    if Model = nil then
      Model := FClockModel;
  end
  else
    Model := FPlacementModel;
  if (Model = nil) or (BufCell = nil) then
    Exit;
  // A pad-terminated (output) net has no gate load; only normal nets need one.
  if (not APadLoad) and (Load = nil) then
    Exit;
  if not Model.Nets.TryGetValue(NetName, Net) then
    Exit;
  OrigConn := TList<TNetConnection>.Create;
  try
    OrigConn.AddRange(Net.Connections);

    // Build the buffer gate and split the net around it (see the pad/normal
    // branches below for which side keeps the original net name).
    BufGate := TGateInstance.Create;
    BufGate.CellName := BufCell.Name;
    BufGate.Cell := BufCell;
    BufGate.ClockLevel := -1;
    InPort := BufCell.FindPort(InPin);
    OutPort := BufCell.FindPort(OutPin);
    // A net name unique in the model (buffers from earlier validation runs may
    // already occupy some suffixes).
    repeat
      NewNetName := Format('%s__vbuf_%d', [NetName, FValidationBufIdx]);
      Inc(FValidationBufIdx);
    until not Model.Nets.ContainsKey(NewNetName);

    // The buffer's input/output net names depend on which side keeps the
    // original net: for a normal net the input joins the original net and the
    // output drives a fresh net; for an output net (pad load) the pad is keyed
    // to the original net NAME, so the output stays on it and the driver side
    // moves to the fresh net.
    if APadLoad then
    begin
      InNetName := NewNetName;
      OutNetName := NetName;
    end
    else
    begin
      InNetName := NetName;
      OutNetName := NewNetName;
    end;

    Net.Connections.Clear;
    if APadLoad then
    begin
      // Output net: the buffer's OUTPUT drives the original (pad) net; the
      // original driver gate moves onto the fresh net with the buffer's input.
      for NC in OrigConn do
        if not ((NC.Gate = Driver) and (NC.PinName = DriverPin)) then
          Net.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := OutPin;
      NC.IsDriver := True;
      Net.Connections.Add(NC);
      NewNet := Model.FindOrCreateNet(NewNetName);
      NC.Gate := Driver;
      NC.PinName := DriverPin;
      NC.IsDriver := True;
      NewNet.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := InPin;
      NC.IsDriver := False;
      NewNet.Connections.Add(NC);
    end
    else
    begin
      // Normal net: the buffer's input joins the original net, its output
      // drives a fresh net to the original load.
      for NC in OrigConn do
        if not ((NC.Gate = Load) and (NC.PinName = LoadPin)) then
          Net.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := InPin;
      NC.IsDriver := False;
      Net.Connections.Add(NC);
      NewNet := Model.FindOrCreateNet(NewNetName);
      NC.Gate := BufGate;
      NC.PinName := OutPin;
      NC.IsDriver := True;
      NewNet.Connections.Add(NC);
      NC.Gate := Load;
      NC.PinName := LoadPin;
      NC.IsDriver := False;
      NewNet.Connections.Add(NC);
    end;

    Conn := TPinConnection.Create;
    Conn.PinName := InPin;
    Conn.NetName := InNetName;
    Conn.Port := InPort;
    BufGate.Connections.Add(Conn);
    Conn := TPinConnection.Create;
    Conn.PinName := OutPin;
    Conn.NetName := OutNetName;
    Conn.Port := OutPort;
    BufGate.Connections.Add(Conn);
    Model.Gates.Add(BufGate);

    // Record the slot so ReapplyValidationBuffers keeps it across rebuilds.
    VB.Gate := BufGate;
    VB.NetName := NetName;
    VB.IsClock := IsClock;
    VB.Band := ABand;
    VB.RowType := ARowType;
    VB.X := AX;
    VB.Y := AY;
    SetLength(FValidationBuffers, Length(FValidationBuffers) + 1);
    FValidationBuffers[High(FValidationBuffers)] := VB;

    RunBiasExpansionAndRouting;
    if FRoutingSucceeded then
    begin
      MemoRouting.Lines.Add(Format(
        '  buffer %s inserted on %s (band %d, row %d, x %d, y %d).',
        [BufCell.Name, NetName, ABand, ARowType, AX, AY]));
      Result := True;
      Exit;
    end;

    // The circuit no longer routes with the buffer there: revert the netlist.
    Model.Gates.Remove(BufGate);
    BufGate.Free;
    Model.Nets.Remove(NewNetName);
    Net.Connections.Clear;
    Net.Connections.AddRange(OrigConn);
    SetLength(FValidationBuffers, Length(FValidationBuffers) - 1);
    RunBiasExpansionAndRouting; // restore the clean derived state
  finally
    OrigConn.Free;
  end;
end;

// Inserts a buffer to break up the over-limit trace at ATraceIdx. Resolves the
// trace's net/driver/load (signal net in the placement model, or clock link in
// the clock model), searches every free logic/clock-row/trunk slot, and tries
// the slots in score order. Returns True if a buffer was successfully placed
// and the circuit re-routed; False if no usable location exists.
function TForm1.InsertBufferForTrace(ATraceIdx: Integer): Boolean;
const
  MaxReachLeeway = 0.1; // max-reach packing target = Limit * (1 - leeway)
type
  TCand = record
    Band, RowType, X, Y: Integer;
    Score: Double;
  end;
var
  Core, Limit, R1u, R2u, MaxR, MinR, Score, CurLen, Cap: Double;
  UseBalanced: Boolean;
  NetName: string;
  IsClock: Boolean;
  TreeModel: TBlifModel;
  Net: TNet;
  NC: TNetConnection;
  Driver, Load: TGateInstance;
  DriverPin, LoadPin: string;
  IsPadLoad: Boolean;
  BufCell: TCell;
  InPort, OutPort: TPort;
  InPin, OutPin: string;
  Src, Dst, Pt: TPoint;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  L, ci, k: Integer;
  NumBands, Band, RowType, X, Y, W, H, Bx, By: Integer;
  TrunkX0, StackTop, StackBottom: Integer;
  Cands: TArray<TCand>;
  C, TmpC: TCand;
  a, b: Integer;
  Key: string;
  Overlap: Boolean;
  i2: Integer;

  function RectOverlap(X1, Y1, W1, H1, X2, Y2, W2, H2: Integer): Boolean;
  begin
    Result := (X1 < X2 + W2) and (X2 < X1 + W1) and
              (Y1 < Y2 + H2) and (Y2 < Y1 + H1);
  end;

  // Evaluates one slot (X, Y) for the current (Band, RowType): rejects it if it
  // overlaps a placed cell (pure floorplan geometry - routed wires are ignored,
  // everything is re-routed after insertion) or sits on an endpoint pin, else
  // records it with a residual-reach score.
  procedure Consider(X, Y: Integer);
  var
    i2, L, ci, k: Integer;
  begin
    Bx := X + W div 2;
    By := Y + H div 2;
    R1u := (Abs(Src.X - Bx) + Abs(Src.Y - By)) * Core;
    R2u := (Abs(Bx - Dst.X) + Abs(By - Dst.Y)) * Core;
    if R1u > R2u then
    begin
      MaxR := R1u;
      MinR := R2u;
    end
    else
    begin
      MaxR := R2u;
      MinR := R1u;
    end;
    if MinR <= 0 then
      Exit;
    // Dual-mode scoring: for a wire that only needs one more buffer, minimise
    // the LONGER residual (balanced split - short segments, little detour,
    // shorter total). For a long wire needing several buffers, pack to the
    // max-reach target (buffer ~Cap from the nearer end) so each covers as much
    // wire as possible and the count stays near-optimal.
    if UseBalanced then
      Score := -(MaxR * 10.0 + (R1u + R2u))
    else
      Score := Cap - Abs(MinR - Cap);
    Key := Format('%d:%d:%d:%d', [Band, RowType, X, Y]);
    if FValidationBlocked.IndexOf(Key) >= 0 then
      Exit;
    Overlap := False;
    for i2 := 0 to High(FPlacedComponents) do
      if RectOverlap(X, Y, W, H, FPlacedComponents[i2].X,
        FPlacedComponents[i2].Y, FPlacedComponents[i2].W,
        FPlacedComponents[i2].H) then
      begin
        Overlap := True;
        Break;
      end;
    if not Overlap then
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if (not FClockSubtree[L][ci].IsLeaf) and
             RectOverlap(X, Y, W, H, FClockSubtree[L][ci].X,
               FClockSubtree[L][ci].Y, FClockSubtree[L][ci].W,
               FClockSubtree[L][ci].H) then
          begin
            Overlap := True;
            Break;
          end;
    if not Overlap then
      for k := 0 to High(FSpine) do
        if RectOverlap(X, Y, W, H, FSpine[k].X, FSpine[k].Y,
          FSpine[k].W, FSpine[k].H) then
        begin
          Overlap := True;
          Break;
        end;
    if Overlap then
      Exit;
    SetLength(Cands, Length(Cands) + 1);
    Cands[High(Cands)].Band := Band;
    Cands[High(Cands)].RowType := RowType;
    Cands[High(Cands)].X := X;
    Cands[High(Cands)].Y := Y;
    Cands[High(Cands)].Score := Score;
  end;

begin
  Result := False;
  if (ATraceIdx < 0) or (ATraceIdx > High(FRouteTraces)) then
    Exit;
  if Length(FRouteTraces[ATraceIdx].Points) < 2 then
    Exit;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  if not (TryDimParse(EditPTLLength.Text, Limit) and (Limit > 0)) then
    Exit;

  // Dual-mode placement. If the current wire needs only ONE more buffer to be
  // under the limit (length <= 2*Limit), split it evenly - short segments, good
  // margin, short total wire. If it needs several, pack the segments to the
  // max-reach target so the buffer count stays near the optimum (over-inserting
  // buffers is costly for clock performance).
  CurLen := TraceLengthUm(FRouteTraces[ATraceIdx], Core);
  UseBalanced := CurLen <= 2 * Limit;
  Cap := Limit * (1 - MaxReachLeeway);

  BufCell := FindMinDelayBufferCell;
  if BufCell = nil then
  begin
    MemoRouting.Lines.Add('  no usable buffer cell in the library.');
    Exit;
  end;
  InPort := nil;
  OutPort := nil;
  for k := 0 to BufCell.Ports.Count - 1 do
    if BufCell.Ports[k].Direction = pdOutput then
      OutPort := BufCell.Ports[k]
    else if BufCell.Ports[k].Direction = pdInput then
      InPort := BufCell.Ports[k];
  if (InPort = nil) or (OutPort = nil) then
  begin
    MemoRouting.Lines.Add(Format('  buffer %s has no single input/output pin.',
      [BufCell.Name]));
    Exit;
  end;
  InPin := InPort.Name;
  OutPin := OutPort.Name;

  NetName := FRouteTraces[ATraceIdx].NetName;
  IsClock := StartsText('clk', NetName) or (Pos('__clkbuf_', NetName) > 0);
  Src := FRouteTraces[ATraceIdx].Points[0];
  Dst := FRouteTraces[ATraceIdx].Points[High(FRouteTraces[ATraceIdx].Points)];
  Driver := nil;
  Load := nil;
  DriverPin := '';
  LoadPin := '';
  IsPadLoad := False;

  if IsClock then
  begin
    TreeModel := FClockBufferedModel;
    if TreeModel = nil then
      TreeModel := FClockModel;
    if TreeModel = nil then
      Exit;
    if not TreeModel.Nets.TryGetValue(NetName, Net) then
      Exit;
    ClkPos := TDictionary<TGateInstance, TPoint>.Create;
    ClkRot := TDictionary<TGateInstance, Boolean>.Create;
    try
      for k := 0 to High(FSpine) do
      begin
        Sp := FSpine[k];
        if Sp.Gate <> nil then
        begin
          ClkPos.AddOrSetValue(Sp.Gate, TPoint.Create(Sp.X, Sp.Y));
          ClkRot.AddOrSetValue(Sp.Gate, Sp.Rotated);
        end;
      end;
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
        begin
          Node := FClockSubtree[L][ci];
          if Node.Gate <> nil then
          begin
            ClkPos.AddOrSetValue(Node.Gate, TPoint.Create(Node.X, Node.Y));
            ClkRot.AddOrSetValue(Node.Gate, False);
          end;
        end;
      for NC in Net.Connections do
      begin
        if NC.IsDriver then
          Continue;
        if not ClkPos.ContainsKey(NC.Gate) then
          Continue;
        if GatePinBlockAt(NC.Gate, NC.PinName, 0,
          ClkPos[NC.Gate].X, ClkPos[NC.Gate].Y, ClkRot[NC.Gate], Pt) and
           (Pt.X = Dst.X) and (Pt.Y = Dst.Y) then
        begin
          Load := NC.Gate;
          LoadPin := NC.PinName;
          Break;
        end;
      end;
    finally
      ClkPos.Free;
      ClkRot.Free;
    end;
  end
  else
  begin
    if (FPlacementModel = nil) or
       (not FPlacementModel.Nets.TryGetValue(NetName, Net)) then
      Exit;
    for NC in Net.Connections do
      if NC.IsDriver and FGatePlacement.ContainsKey(NC.Gate) then
      begin
        Driver := NC.Gate;
        DriverPin := NC.PinName;
        Break;
      end;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if not FGatePlacement.ContainsKey(NC.Gate) then
        Continue;
      if GatePinBlock(NC.Gate, NC.PinName, 0, Pt) and
         (Pt.X = Dst.X) and (Pt.Y = Dst.Y) then
      begin
        Load := NC.Gate;
        LoadPin := NC.PinName;
        Break;
      end;
    end;
  end;
  if Load = nil then
  begin
    // A primary output net has no gate load: its load is the output pad, which
    // RunRouting reaches via GetPad(NetName). Support it by keeping the original
    // net name on the buffer->pad side (so the pad stays keyed to it) and moving
    // the driver gate onto a fresh net with the buffer's input.
    if (not IsClock) and FPadMap.ContainsKey(NetName) and (Driver <> nil) then
      IsPadLoad := True
    else
    begin
      MemoRouting.Lines.Add(Format('  cannot resolve %s load pin.', [NetName]));
      Exit;
    end;
  end;

  // Buffer footprint in grid cells.
  W := Round(BufCell.Width / Core);
  if W < 1 then
    W := 1;
  H := Round(BufCell.Height / Core);
  if H < 1 then
    H := 1;

  // Enumerate every free slot and score it by residual reach: logic rows,
  // clock rows, and the clock trunk column (the only region that may still have
  // space when the rows are packed). Routed wires are deliberately ignored -
  // the check is pure floorplan geometry, since everything is re-routed.
  NumBands := Length(FPlanBandStarts);
  TrunkX0 := FPlanXRight + FPlanLane0W;
  StackTop := 0;
  StackBottom := 0;
  if NumBands > 0 then
  begin
    StackTop := FPlanBandStarts[0];
    StackBottom := FPlanBandStarts[NumBands - 1] +
      FPlanBandHeight[NumBands - 1] + FBottomBiasH;
  end;
  SetLength(Cands, 0);
  for Band := 0 to NumBands - 1 do
  begin
    // Logic rows.
    if H <= FPlanRowHBlocks then
    begin
      RowType := 0;
      for X := FPlanXLeft to FPlanXRight - W do
        Consider(X, BandLogicRowY(Band) + ((FPlanRowHBlocks - H) div 2));
    end;
    // Clock rows.
    if H <= FPlanRowHBlocks then
    begin
      RowType := 1;
      for X := FPlanXLeft to FPlanXRight - W do
        Consider(X, BandClockRowY(Band) + ((FPlanRowHBlocks - H) div 2));
    end;
  end;
  // Clock trunk column: the trunk cells are rotated and centred in a column of
  // width FPlanRowHBlocks, so free space remains beside them; the buffer's
  // width (unrotated) must fit the column and its height the stack.
  if (W <= FPlanRowHBlocks) and (H <= StackBottom - StackTop) then
  begin
    Band := -1;
    RowType := 2;
    for X := TrunkX0 to TrunkX0 + FPlanRowHBlocks - W do
      for Y := StackTop to StackBottom - H do
        Consider(X, Y);
  end;

  if Length(Cands) = 0 then
  begin
    MemoRouting.Lines.Add(Format(
      '  no free buffer slot satisfies the length split for %s.', [NetName]));
    Exit;
  end;

  // Sort by score descending (best split per the current mode: balanced for
  // short wires, max-reach packing for long ones).
  for a := 1 to High(Cands) do
  begin
    TmpC := Cands[a];
    b := a - 1;
    while (b >= 0) and (Cands[b].Score < TmpC.Score) do
    begin
      Cands[b + 1] := Cands[b];
      Dec(b);
    end;
    Cands[b + 1] := TmpC;
  end;

  for a := 0 to High(Cands) do
  begin
    C := Cands[a];
    if TryInsertBuffer(IsClock, NetName, Driver, Load, DriverPin, LoadPin,
      IsPadLoad, BufCell, InPin, OutPin, C.Band, C.RowType, C.X, C.Y) then
    begin
      Result := True;
      Exit;
    end;
    FValidationBlocked.Add(Format('%d:%d:%d:%d', [C.Band, C.RowType, C.X, C.Y]));
  end;
  MemoRouting.Lines.Add(Format(
    '  every buffer slot for %s made the circuit unroutable.', [NetName]));
end;

// Routing validation loop: repeatedly find the longest PTL over the length
// limit and fix it. A wire whose length is much longer than its endpoints'
// Manhattan span is ripped up and re-routed (layer passes, then vias - same as
// the routing stage); if that cannot get it under the limit, or the wire is
// simply long (no detour), a minimum-delay buffer is inserted to break the run
// into two shorter PTLs. Buffers are inserted into the layout AND the netlist,
// then the bias expansion and routing are re-run; a location that makes the
// circuit unroutable is marked unusable and the next candidate tried. The loop
// ends when every PTL is within the limit, or fails when no buffer location is
// available (the rows do not span the die, so a slot may simply not exist).
procedure TForm1.RunRoutingValidation;
var
  Core, Limit, Len, Man, BestLen: Double;
  i, BestIdx: Integer;
  Pt0, Pt1: TPoint;
begin
  if Length(FRouteTraces) = 0 then
  begin
    MemoRouting.Lines.Add('No routed traces to validate.');
    FRoutingValidated := True;
    Exit;
  end;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  if not (TryDimParse(EditPTLLength.Text, Limit) and (Limit > 0)) then
  begin
    MemoRouting.Lines.Add('Set a PTL length limit before validating.');
    FRoutingValidated := True;
    Exit;
  end;
  // A fresh validation session: the buffers inserted on a previous run stay in
  // the netlist (they are now part of the circuit) but are re-applied fresh.
  FValidationBuffers := nil;
  FValidationBlocked.Clear;
  MemoRouting.Lines.Add('--- Routing validation ---');
  MemoRouting.Lines.Add(Format('PTL length limit: %s um', [EditPTLLength.Text]));

  repeat
    // The longest over-limit PTL is fixed first (most impactful).
    BestIdx := -1;
    BestLen := 0;
    for i := 0 to High(FRouteTraces) do
    begin
      if IsBiasTrace(FRouteTraces[i]) then
        Continue;
      Len := TraceLengthUm(FRouteTraces[i], Core);
      if (Len > Limit) and (Len > BestLen) then
      begin
        BestLen := Len;
        BestIdx := i;
      end;
    end;
    if BestIdx < 0 then
      Break; // every PTL is within the limit

    Pt0 := FRouteTraces[BestIdx].Points[0];
    Pt1 := FRouteTraces[BestIdx].Points[High(FRouteTraces[BestIdx].Points)];
    Man := (Abs(Pt1.X - Pt0.X) + Abs(Pt1.Y - Pt0.Y)) * Core;
    MemoRouting.Lines.Add(Format('  %s: %.2f um (Manhattan span %.2f um)',
      [FRouteTraces[BestIdx].NetName, BestLen, Man]));

    // The routed length exceeding the Manhattan span means the wire took a
    // detour; rip it up and re-route through the usual passes (a straight line
    // is always at least worth attempting - the router may find a shorter one).
    if (Man > 0) and (BestLen > Man) then
    begin
      MemoRouting.Lines.Add('    detour: ripping up and re-routing...');
      if RerouteTrace(BestIdx) then
      begin
        MemoRouting.Lines.Add('    re-routed under the limit.');
        RepaintRoutingPage;
        Continue; // re-scan; other over-limit wires are fixed next
      end
      else
        MemoRouting.Lines.Add('    re-route did not reach the limit; inserting a buffer.');
    end;

    if not InsertBufferForTrace(BestIdx) then
    begin
      MemoRouting.Lines.Add(Format(
        'VALIDATION FAILED: no usable buffer location on %s.',
        [FRouteTraces[BestIdx].NetName]));
      FRoutingValidated := True;
      RepaintRoutingPage;
      Exit;
    end;
    // InsertBufferForTrace re-ran the bias expansion + routing; re-scan.
    RepaintRoutingPage;
  until False;

  MemoRouting.Lines.Add('All PTL lengths are within the limit.');
  FRoutingValidated := True;
  RepaintRoutingPage;
end;

// Draws the routed traces as a polyline through the block centres. With the
// length-colour toggle off, each trace uses its layer's colour; with it on,
// PTL wires are coloured on the blue-to-red spectrogram scale, capped at the
// user-specified PTL length limit (falling back to the longest wire if no
// limit is set), and dashed past the limit. Bias (constant-voltage) lines are
// always drawn in their layer colour, solid, and never affect the scale.
procedure TForm1.DrawRoutedTraces(Canvas: TCanvas);
const
  TraceThick = 2.0; // fixed trace width (visibility, not length, is encoded)
var
  Core: Double;
  Limit: Double;
  ScaleCap: Double;
  i, k: Integer;
  Clr: TAlphaColor;
  X1, Y1, X2, Y2: Single;
  Len, MaxLen, t: Double;
  Found: Boolean;
begin
  if Length(FRouteTraces) = 0 then
    Exit;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  if not (TryDimParse(EditPTLLength.Text, Limit) and (Limit > 0)) then
    Limit := 0;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Thickness := TraceThick;

  // Fallback scale cap: the longest PTL trace (only used when no limit is set).
  MaxLen := 0;
  Found := False;
  for i := 0 to High(FRouteTraces) do
  begin
    if IsBiasTrace(FRouteTraces[i]) then
      Continue;
    Found := True;
    Len := TraceLengthUm(FRouteTraces[i], Core);
    if Len > MaxLen then MaxLen := Len;
  end;
  if not Found then
    MaxLen := 1;
  if MaxLen <= 0 then
    MaxLen := 1;
  if Limit > 0 then
    ScaleCap := Limit
  else
    ScaleCap := MaxLen;

  for i := 0 to High(FRouteTraces) do
  begin
    if Length(FRouteTraces[i].Layers) <= 1 then
      Continue;
    if IsBiasTrace(FRouteTraces[i]) then
    begin
      // Constant-voltage lines: layer colour, always solid.
      Canvas.Stroke.Dash := TStrokeDash.Solid;
    end
    else if FRouteLengthColor then
    begin
      Len := TraceLengthUm(FRouteTraces[i], Core);
      // Spectrogram scale, capped at the PTL length limit (max colour).
      t := Len / ScaleCap;
      if t < 0 then t := 0;
      if t > 1 then t := 1;
      // Past the PTL length limit: draw dashed (length mode only).
      if (Limit > 0) and (Len > Limit) then
        Canvas.Stroke.Dash := TStrokeDash.Dash
      else
        Canvas.Stroke.Dash := TStrokeDash.Solid;
    end
    else
      Canvas.Stroke.Dash := TStrokeDash.Solid;
    // Draw each segment; via cells are the point where the layer changes
    // (both colours join there).
    for k := 0 to High(FRouteTraces[i].Points) - 1 do
    begin
      if not RoutingLayerEnabled(FRouteTraces[i].Layers[k]) then
        Continue;
      if IsBiasTrace(FRouteTraces[i]) or (not FRouteLengthColor) then
        Clr := RoutingLayerColor(FRouteTraces[i].Layers[k])
      else
      begin
        Len := TraceLengthUm(FRouteTraces[i], Core);
        t := Len / ScaleCap;
        if t < 0 then t := 0;
        if t > 1 then t := 1;
        Clr := LengthColor(t);
      end;
      // Keep the trace opaque against the pale die body.
      Clr := (Clr and $FFFFFF) or $FF000000;
      Canvas.Stroke.Color := Clr;
      X1 := FRoutePanX + (FRouteTraces[i].Points[k].X + 0.5) * Core * FRouteZoom;
      Y1 := FRoutePanY + (FRouteTraces[i].Points[k].Y + 0.5) * Core * FRouteZoom;
      X2 := FRoutePanX + (FRouteTraces[i].Points[k + 1].X + 0.5) * Core * FRouteZoom;
      Y2 := FRoutePanY + (FRouteTraces[i].Points[k + 1].Y + 0.5) * Core * FRouteZoom;
      Canvas.DrawLine(TPointF.Create(X1, Y1), TPointF.Create(X2, Y2), 1.0);
    end;
  end;
  Canvas.Stroke.Dash := TStrokeDash.Solid;
end;

// Returns the grid block of a gate's pin on a specific routing layer (ALayer
// indexes FRouteLayers). The gate is placed in FGatePlacement (its origin is
// read from there). Uses the pin's geometry on that layer; falls back to the
// first shape, then to the cell centre. The returned block is always one
// actually covered by that geometry (an occupied cell), so the trace connects
// onto the pin rather than to a floating point.
function TForm1.GatePinBlock(G: TGateInstance; const PinName: string;
  ALayer: Integer; var P: TPoint): Boolean;
var
  Pt: TPoint;
begin
  Result := False;
  if (G = nil) or (G.Cell = nil) then
    Exit;
  if not FGatePlacement.TryGetValue(G, Pt) then
    Exit;
  Result := GatePinBlockAt(G, PinName, ALayer, Pt.X, Pt.Y, False, P);
end;

// Like GatePinBlock, but the gate's placed top-left grid cell is given
// explicitly (AX, AY) - used for clock gates, which are placed in FSpine /
// FClockSubtree rather than FGatePlacement. Rotated cells (trunk cells) have
// their footprint swapped (W = cell height, H = cell width) and their pin
// shapes rotated 90 deg CCW, exactly like DrawCellPorts.
function TForm1.GatePinBlockAt(G: TGateInstance; const PinName: string;
  ALayer, AX, AY: Integer; Rotated: Boolean; var P: TPoint): Boolean;
var
  Core: Double;
  Port: TPort;
  Shape: TPortShape;
  CellW, CellH: Double;
  BX0, BY0, BX1, BY1: Integer;
begin
  Result := False;
  if (G = nil) or (G.Cell = nil) then
    Exit;
  if not (TryDimParse(EditCoreSize.Text, Core) and (Core > 0)) then
    Core := FPlanCore;
  // The pin's own geometry: prefer a shape on the requested layer.
  Port := G.Cell.FindPort(PinName);
  Shape := nil;
  if Port <> nil then
  begin
    for Shape in Port.Shapes do
      if (ALayer >= 0) and (ALayer < Length(FRouteLayers)) and
         SameText(Shape.Layer, FRouteLayers[ALayer]) then
        Break;
    if (Shape = nil) and (Port.Shapes.Count > 0) then
      Shape := Port.Shapes[0];
  end;
  if Shape <> nil then
  begin
    // The occupied cell: the range of blocks covered by the (possibly
    // rotated) shape.
    if Rotated then
    begin
      CellH := G.Cell.Height;
      if CellH <= 0 then
        CellH := Core;
      // 90 deg CCW: local (x, y) -> (cellH - y, x).
      BX0 := Trunc((AX * Core + (CellH - Shape.y2)) / Core);
      BY0 := Trunc((AY * Core + Shape.x1) / Core);
      BX1 := Trunc((AX * Core + (CellH - Shape.y1)) / Core);
      BY1 := Trunc((AY * Core + Shape.x2) / Core);
    end
    else
    begin
      // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
      CellH := G.Cell.Height;
      if CellH <= 0 then
        CellH := Core;
      BX0 := Trunc((AX * Core + Shape.x1) / Core);
      BY0 := Trunc((AY * Core + (CellH - Shape.y2)) / Core);
      BX1 := Trunc((AX * Core + Shape.x2) / Core);
      BY1 := Trunc((AY * Core + (CellH - Shape.y1)) / Core);
    end;
    if BX1 < BX0 then BX0 := BX1;
    if BY1 < BY0 then BY0 := BY1;
    // The cell nearest the shape centre, guaranteed inside the covered range.
    P.X := BX0 + ((BX1 - BX0) div 2);
    P.Y := BY0 + ((BY1 - BY0) div 2);
    // Clamp into the die grid: cells sitting at the very edge (e.g. a spine
    // buffer stacked to the trunk top, or an overflow buffer hugging the right
    // die edge) can resolve a pin block one past the boundary, which would make
    // the Lee router bail out on its bounds check.
    if FRouteObstaclesW > 0 then
    begin
      if P.X < 0 then P.X := 0;
      if P.X >= FRouteObstaclesW then P.X := FRouteObstaclesW - 1;
    end;
    if FRouteObstaclesH > 0 then
    begin
      if P.Y < 0 then P.Y := 0;
      if P.Y >= FRouteObstaclesH then P.Y := FRouteObstaclesH - 1;
    end;
    Result := True;
    Exit;
  end;
  // Fallback: the centre of the placed cell footprint.
  CellW := G.Cell.Width;
  CellH := G.Cell.Height;
  if CellW <= 0 then
    CellW := Core;
  if CellH <= 0 then
    CellH := Core;
  if Rotated then
  begin
    // Footprint is swapped: W = cell height, H = cell width.
    P.X := Trunc((AX * Core + CellH / 2) / Core);
    P.Y := Trunc((AY * Core + CellW / 2) / Core);
  end
  else
  begin
    P.X := Trunc((AX * Core + CellW / 2) / Core);
    P.Y := Trunc((AY * Core + CellH / 2) / Core);
  end;
  // Clamp into the die grid (see the shape path above).
  if FRouteObstaclesW > 0 then
  begin
    if P.X < 0 then P.X := 0;
    if P.X >= FRouteObstaclesW then P.X := FRouteObstaclesW - 1;
  end;
  if FRouteObstaclesH > 0 then
  begin
    if P.Y < 0 then P.Y := 0;
    if P.Y >= FRouteObstaclesH then P.Y := FRouteObstaclesH - 1;
  end;
  Result := True;
end;

// A* maze router between two grid blocks. When UseLayer >= 0 the search is
// confined to that single routing layer (no vias); when UseLayer < 0 it
// searches over all routing layers, with a via allowed at every cell (a layer
// switch on the same block). Pin-geometry blocks are hard obstacles; only the
// goal cell is exempt so a wire can always reach its pin.
// The heuristic is Manhattan distance to the goal (admissible: every step
// costs at least 1). Moving straight costs 1 per block; turning costs an extra
// TurnPenalty, so A* prefers straight runs over wiggly ones. A via costs
// ViaPenalty.
// The search is confined to a window around the two terminals (Start..Goal
// plus a margin that grows with the Manhattan distance), so short nets only
// touch a small part of the die. Ties in the open heap are broken toward the
// goal (smaller h), and a hard expansion budget aborts hopeless searches.
// Returns the path (inclusive of start and goal) in OutPath and each point's
// routing-layer index in OutLayers.
function TForm1.LeeRoute(Start, Goal: TPoint; UseLayer: Integer;
  var OutPath: TArray<TPoint>; var OutLayers: TArray<Integer>): Boolean;
const
  DirDx: array[0..3] of Integer = (1, -1, 0, 0);
  DirDy: array[0..3] of Integer = (0, 0, 1, -1);
  TurnPenalty = 3; // extra cost for a turn (vs. going straight)
  ViaPenalty = 8;  // extra cost for a via (layer switch)
  DirCount = 5;    // states per cell-layer: Dir+1 in 0..4 (0 = no direction)
  MinMargin = 16;  // minimum window margin in blocks
  MaxMargin = 128; // maximum window margin in blocks
  MarginDiv = 3;   // margin = max(MinMargin, dist div MarginDiv)
var
  W, H, NumLayers, MaxLayer, TotalStates: Integer;
  WinX0, WinY0, WinX1, WinY1, WinW, WinH: Integer;
  Margin, Dist: Integer;
  gScore: TArray<Integer>;
  Parent: TArray<Integer>;
  Closed: TArray<Boolean>;
  Heap: TArray<Integer>;
  HeapCount: Integer;
  S, NS: Integer;
  CurLayer, EffLayer, CurX, CurY: Integer;
  CurDir, Nx, Ny, d, L, i: Integer;
  NewG, TurnCost: Integer;
  Expanded, ExpansionLimit: Integer;
  lx, ly: Integer;
  Swp: TPoint;
  SwpLayer: Integer;

  // State id over the WINDOW-local grid: ((ly*WinW+lx)*MaxLayer+Layer)*DirCount
  // + (Dir+1), Dir in -1..3. lx = X - WinX0, ly = Y - WinY0.
  function StateId(lx, ly, Layer, Dir: Integer): Integer;
  begin
    Result := (((ly * WinW + lx) * MaxLayer + Layer) * DirCount) + (Dir + 1);
  end;

  // Manhattan distance from the state's cell to the goal (global coords).
  function Heuristic(S: Integer): Integer;
  var
    cell, hx, hy: Integer;
  begin
    cell := (S div DirCount) div MaxLayer;
    hy := cell div WinW;
    hx := cell mod WinW;
    Result := Abs((hx + WinX0) - Goal.X) + Abs((hy + WinY0) - Goal.Y);
  end;

  // A is preferred over B when its f (= g+h) is lower; on equal f the one
  // closer to the goal (smaller h) is popped first, pushing the search toward
  // the goal instead of flaring sideways.
  function LessThan(A, B: Integer): Boolean;
  var
    fA, fB, hA, hB: Integer;
  begin
    fA := gScore[A] + Heuristic(A);
    fB := gScore[B] + Heuristic(B);
    hA := Heuristic(A);
    hB := Heuristic(B);
    Result := (fA < fB) or ((fA = fB) and (hA < hB));
  end;

  procedure HeapPush(S: Integer);
  var
    idx, par, Tmp: Integer;
  begin
    idx := HeapCount;
    Inc(HeapCount);
    if idx >= Length(Heap) then
      SetLength(Heap, HeapCount + 64);
    Heap[idx] := S;
    while idx > 0 do
    begin
      par := (idx - 1) div 2;
      if not LessThan(S, Heap[par]) then
        Break;
      Tmp := Heap[idx];
      Heap[idx] := Heap[par];
      Heap[par] := Tmp;
      idx := par;
    end;
  end;

  function HeapPop: Integer;
  var
    idx, child, other, Tmp: Integer;
  begin
    Result := Heap[0];
    Dec(HeapCount);
    if HeapCount > 0 then
    begin
      Heap[0] := Heap[HeapCount];
      idx := 0;
      while True do
      begin
        child := idx * 2 + 1;
        if child >= HeapCount then
          Break;
        other := child + 1;
        if (other < HeapCount) and LessThan(Heap[other], Heap[child]) then
          child := other;
        if not LessThan(Heap[child], Heap[idx]) then
          Break;
        Tmp := Heap[idx];
        Heap[idx] := Heap[child];
        Heap[child] := Tmp;
        idx := child;
      end;
    end;
  end;

begin
  Result := False;
  W := FRouteObstaclesW;
  H := FRouteObstaclesH;
  NumLayers := Length(FRouteLayers);
  if (W <= 0) or (H <= 0) or (NumLayers <= 0) then
    Exit;
  if (Start.X < 0) or (Start.X >= W) or (Start.Y < 0) or (Start.Y >= H) or
     (Goal.X < 0) or (Goal.X >= W) or (Goal.Y < 0) or (Goal.Y >= H) then
    Exit;
  if UseLayer >= NumLayers then
    Exit;
  if (Start.X = Goal.X) and (Start.Y = Goal.Y) then
  begin
    SetLength(OutPath, 1);
    OutPath[0] := Start;
    SetLength(OutLayers, 1);
    OutLayers[0] := 0;
    if UseLayer >= 0 then
      OutLayers[0] := UseLayer;
    Result := True;
    Exit;
  end;

  if UseLayer >= 0 then
    MaxLayer := 1
  else
    MaxLayer := NumLayers;

  // Search window: the terminal bounding box plus a margin that scales with the
  // Manhattan distance, clamped to the die. A shortest path never needs to leave
  // a comfortable box around its terminals, so this bounds the state space.
  Dist := Abs(Goal.X - Start.X) + Abs(Goal.Y - Start.Y);
  Margin := Dist div MarginDiv;
  if Margin < MinMargin then
    Margin := MinMargin;
  if Margin > MaxMargin then
    Margin := MaxMargin;
  WinX0 := Start.X;
  if Goal.X < WinX0 then
    WinX0 := Goal.X;
  WinX1 := Start.X;
  if Goal.X > WinX1 then
    WinX1 := Goal.X;
  WinY0 := Start.Y;
  if Goal.Y < WinY0 then
    WinY0 := Goal.Y;
  WinY1 := Start.Y;
  if Goal.Y > WinY1 then
    WinY1 := Goal.Y;
  Dec(WinX0, Margin);
  if WinX0 < 0 then
    WinX0 := 0;
  Inc(WinX1, Margin);
  if WinX1 >= W then
    WinX1 := W - 1;
  Dec(WinY0, Margin);
  if WinY0 < 0 then
    WinY0 := 0;
  Inc(WinY1, Margin);
  if WinY1 >= H then
    WinY1 := H - 1;
  WinW := WinX1 - WinX0 + 1;
  WinH := WinY1 - WinY0 + 1;

  TotalStates := WinW * WinH * MaxLayer * DirCount;
  SetLength(gScore, TotalStates);
  SetLength(Parent, TotalStates);
  SetLength(Closed, TotalStates);
  SetLength(Heap, 128);
  for i := 0 to TotalStates - 1 do
  begin
    gScore[i] := High(Integer) div 4;
    Closed[i] := False;
  end;
  HeapCount := 0;

  // Expansion budget: a few passes over the window's cells. Since the window
  // already bounds the search, this only aborts genuinely hopeless cases.
  ExpansionLimit := WinW * WinH * MaxLayer * 3;
  if ExpansionLimit < 512 then
    ExpansionLimit := 512;
  Expanded := 0;

  // Seed the start on the layer(s) the search is allowed to use. The start
  // cell is not obstacle-checked (it is a pin block), and it has no incoming
  // direction (Dir = -1), so a turn away from it is not penalised.
  if UseLayer >= 0 then
  begin
    S := StateId(Start.X - WinX0, Start.Y - WinY0, 0, -1);
    gScore[S] := 0;
    Parent[S] := -1;
    HeapPush(S);
  end
  else
    for L := 0 to NumLayers - 1 do
    begin
      S := StateId(Start.X - WinX0, Start.Y - WinY0, L, -1);
      gScore[S] := 0;
      Parent[S] := -1;
      HeapPush(S);
    end;

  while HeapCount > 0 do
  begin
    S := HeapPop;
    if Closed[S] then
      Continue;
    Closed[S] := True;
    Inc(Expanded);
    if Expanded > ExpansionLimit then
      Exit; // budget exceeded: give up on this route
    CurLayer := (S div DirCount) mod MaxLayer;
    lx := ((S div DirCount) div MaxLayer) mod WinW;
    ly := ((S div DirCount) div MaxLayer) div WinW;
    CurX := lx + WinX0;
    CurY := ly + WinY0;
    CurDir := (S mod DirCount) - 1;
    // In single-layer mode MaxLayer = 1, so the state's layer is always 0; the
    // obstacles to consult are on UseLayer. In multi-layer mode the state layer
    // is the real layer.
    if UseLayer >= 0 then
      EffLayer := UseLayer
    else
      EffLayer := CurLayer;

    if (CurX = Goal.X) and (CurY = Goal.Y) then
    begin
      // Reconstruct the path by walking parents back to the start.
      SetLength(OutPath, 0);
      SetLength(OutLayers, 0);
      NS := S;
      while NS >= 0 do
      begin
        CurLayer := (NS div DirCount) mod MaxLayer;
        lx := ((NS div DirCount) div MaxLayer) mod WinW;
        ly := ((NS div DirCount) div MaxLayer) div WinW;
        SetLength(OutPath, Length(OutPath) + 1);
        OutPath[High(OutPath)] :=
          TPoint.Create(lx + WinX0, ly + WinY0);
        SetLength(OutLayers, Length(OutLayers) + 1);
        if UseLayer >= 0 then
          OutLayers[High(OutLayers)] := UseLayer
        else
          OutLayers[High(OutLayers)] := CurLayer;
        NS := Parent[NS];
      end;
      // Reverse both arrays so the path runs start -> goal.
      for i := 0 to (Length(OutPath) div 2) - 1 do
      begin
        Swp := OutPath[i];
        OutPath[i] := OutPath[High(OutPath) - i];
        OutPath[High(OutPath) - i] := Swp;
        SwpLayer := OutLayers[i];
        OutLayers[i] := OutLayers[High(OutLayers) - i];
        OutLayers[High(OutLayers) - i] := SwpLayer;
      end;
      Result := True;
      Exit;
    end;

    // Same-layer 4-directional moves. A move that keeps the current heading
    // costs 1; changing heading adds TurnPenalty. Moves stay inside the window.
    for d := 0 to 3 do
    begin
      Nx := CurX + DirDx[d];
      Ny := CurY + DirDy[d];
      if (Nx < WinX0) or (Nx > WinX1) or (Ny < WinY0) or (Ny > WinY1) then
        Continue;
      if FRouteObstacles[EffLayer][Ny * W + Nx] and
         not ((Nx = Goal.X) and (Ny = Goal.Y)) then
        Continue;
      TurnCost := 0;
      if CurDir >= 0 then
        if CurDir <> d then
          TurnCost := TurnPenalty;
      NewG := gScore[S] + 1 + TurnCost;
      NS := StateId(Nx - WinX0, Ny - WinY0, CurLayer, d);
      if (not Closed[NS]) and (NewG < gScore[NS]) then
      begin
        gScore[NS] := NewG;
        Parent[NS] := S;
        HeapPush(NS);
      end;
    end;

    // Via transitions (multi-layer search only): switch layers on the spot.
    // The heading is unchanged, so no turn penalty applies.
    if UseLayer < 0 then
      for L := 0 to NumLayers - 1 do
      begin
        if L = CurLayer then
          Continue;
        if FRouteObstacles[L][CurY * W + CurX] and
           not ((CurX = Goal.X) and (CurY = Goal.Y)) then
          Continue;
        NewG := gScore[S] + ViaPenalty;
        NS := StateId(CurX - WinX0, CurY - WinY0, L, CurDir);
        if (not Closed[NS]) and (NewG < gScore[NS]) then
        begin
          gScore[NS] := NewG;
          Parent[NS] := S;
          HeapPush(NS);
        end;
      end;
  end;
end;

procedure TForm1.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
var
  Core, DieW, DieH: Double;
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
    if TryDimParse(EditCoreSize.Text, Core) and
       TryDimParse(EditDieW.Text, DieW) and TryDimParse(EditDieH.Text, DieH) and
       (Core > 0) and (DieW > 0) and (DieH > 0) and (PaintBox3.Height > 20) then
    begin
      MinZ := (Min(PaintBox3.Width, PaintBox3.Height) - 20) / Max(DieW, DieH);
      MaxZ := (Max(PaintBox3.Width, PaintBox3.Height) - 20) / Core;
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
    if TryDimParse(EditCoreSize.Text, Core) and
       TryDimParse(EditDieW.Text, DieW) and TryDimParse(EditDieH.Text, DieH) and
       (Core > 0) and (DieW > 0) and (DieH > 0) and (PaintBox4.Height > 20) then
    begin
      MinZ := (Min(PaintBox4.Width, PaintBox4.Height) - 20) / Max(DieW, DieH);
      MaxZ := (Max(PaintBox4.Width, PaintBox4.Height) - 20) / Core;
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

procedure TForm1.FreePipelineModel;
begin
  FPipelineModel.Free;
  FPipelineModel := nil;
end;

procedure TForm1.BuildPipelineModel;
var
  PM: TBlifModel;
  Dummy: TStringList;
  MaxClockedDelay, MaxUnclockedDelay, FFDelay: Double;
  Delay: Double;
  Gate: TGateInstance;
  i, k: Integer;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  DelayMemo: TDictionary<TGateInstance, Double>;
  FFCell: TCell;
  LevelDelay, GateArea: Double;
  Cmp: TBlifModel;
  CDummy: TStringList;

  function DelayToOutput(G: TGateInstance): Double;
  var
    MaxIn, Dly: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC2: TNetConnection;
  begin
    if DelayMemo.TryGetValue(G, Result) then
      Exit;
    if CellHasClock(G.Cell) then
    begin
      // Starting clocked component: its clock-to-output delay is
      // counted. It ends the path, so we do not recurse into it.
      Dly := CellDelayPs(G.Cell);
      if Dly < 0 then Dly := 0;
      Result := Dly;
      DelayMemo.Add(G, Result);
      Exit;
    end;
    MaxIn := 0;
    for m := 0 to G.Connections.Count - 1 do
    begin
      C := G.Connections[m];
      if C.Port.Direction <> pdInput then Continue;
      if IsClockPinName(C.Port.Name) then Continue;
      if PM.Nets.TryGetValue(C.NetName, N) then
        for NC2 in N.Connections do
          if NC2.IsDriver then
          begin
            Dly := DelayToOutput(NC2.Gate);
            if Dly > MaxIn then
              MaxIn := Dly;
          end;
    end;
    Dly := CellDelayPs(G.Cell);
    if Dly < 0 then Dly := 0;
    Result := MaxIn + Dly;
    DelayMemo.Add(G, Result);
  end;

  // Same measure the stats bar shows: worst DelayToOutput over all gates
  // of an already-built model (clocked gates count their clk-to-q only).
  function WorstLevelDelayOf(AModel: TBlifModel): Double;
  var
    Memo: TDictionary<TGateInstance, Double>;
    AG: TGateInstance;

    function DlyToOut(G: TGateInstance): Double;
    var
      MaxIn, Dly: Double;
      m: Integer;
      C: TPinConnection;
      N: TNet;
      NC2: TNetConnection;
    begin
      if Memo.TryGetValue(G, Result) then
        Exit;
      if CellHasClock(G.Cell) then
        Dly := CellDelayPs(G.Cell)
      else
      begin
        MaxIn := 0;
        for m := 0 to G.Connections.Count - 1 do
        begin
          C := G.Connections[m];
          if C.Port.Direction <> pdInput then Continue;
          if IsClockPinName(C.Port.Name) then Continue;
          if AModel.Nets.TryGetValue(C.NetName, N) then
            for NC2 in N.Connections do
              if NC2.IsDriver then
              begin
                Dly := DlyToOut(NC2.Gate);
                if Dly > MaxIn then MaxIn := Dly;
              end;
        end;
        Dly := MaxIn + CellDelayPs(G.Cell);
      end;
      if Dly < 0 then Dly := 0;
      Result := Dly;
      Memo.Add(G, Result);
    end;

  begin
    Memo := TDictionary<TGateInstance, Double>.Create;
    try
      Result := 0;
      for AG in AModel.Gates do
      begin
        GateArea := DlyToOut(AG);
        if GateArea > Result then
          Result := GateArea;
      end;
    finally
      Memo.Free;
    end;
  end;

begin
  FreePipelineModel;
  FThreshold := 0;
  if FModel = nil then
    Exit;
  PM := FModel.Clone;
  try
    if (FLib <> nil) and (FFlipFlopNames.Count > 0) then
    begin
      // Worst combinational path between clocked boundaries on the pristine
      // clone (before any insertion).
      DelayMemo := TDictionary<TGateInstance, Double>.Create;
      try
        FMaxWorstPath := 1;
        for i := 0 to PM.Gates.Count - 1 do
        begin
          Gate := PM.Gates[i];
          LevelDelay := 0;
          for k := 0 to Gate.Connections.Count - 1 do
          begin
            Conn := Gate.Connections[k];
            if Conn.Port.Direction <> pdInput then Continue;
            if IsClockPinName(Conn.Port.Name) then Continue;
            if PM.Nets.TryGetValue(Conn.NetName, Net) then
              for NC in Net.Connections do
                if NC.IsDriver then
                begin
                  GateArea := DelayToOutput(NC.Gate);
                  if GateArea > LevelDelay then
                    LevelDelay := GateArea;
                end;
          end;
          if LevelDelay > FMaxWorstPath then
            FMaxWorstPath := LevelDelay;
        end;
      finally
        DelayMemo.Free;
      end;

      // Fastest possible circuit: the slower of the slowest clocked
      // component (its own level) or the slowest unclocked component plus
      // a flip-flop.
      FMaxWorstPath := Max(1, FMaxWorstPath);
      MaxClockedDelay := 0;
      MaxUnclockedDelay := 1;
      for Gate in PM.Gates do
      begin
        Delay := CellDelayPs(Gate.Cell);
        if Delay <= 0 then Continue;
        if CellHasClock(Gate.Cell) then
        begin
          if Delay > MaxClockedDelay then
            MaxClockedDelay := Delay;
        end
        else if Delay > MaxUnclockedDelay then
          MaxUnclockedDelay := Delay;
      end;
      FFCell := FLib.FindCell(FFlipFlopNames[0]);
      FFDelay := 0;
      if FFCell <> nil then
      begin
        FFDelay := CellDelayPs(FFCell);
        if FFDelay < 0 then
          FFDelay := 0;
      end;
      FMinDelay := MaxClockedDelay;
      if MaxUnclockedDelay + FFDelay > FMinDelay then
        FMinDelay := MaxUnclockedDelay + FFDelay;
      if FMinDelay < 1 then
        FMinDelay := 1;

      Dummy := TStringList.Create;
      try
        // Output alignment for both modes: every gate on the highest clock
        // level feeds its loads through a flip-flop, so all output signals
        // are clocked out on the same clock edge.
        InsertTopLevelFFs(PM, FLib, FFlipFlopNames[0]);
        if FSliderPos = 0 then
        begin
          // Compact mode at the far-left slider position.
          InsertCompactFlipFlops(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
          PadOutputFFs(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
        end
        else
        begin
          // Delay-levelized: the threshold interpolates from the worst path
          // down to the fastest possible single level as the slider moves
          // right.
          if FMaxWorstPath > FMinDelay then
            FThreshold := FMaxWorstPath - (FMaxWorstPath - FMinDelay) * (FSliderPos / 100)
          else
            FThreshold := FMinDelay;
          InsertDelayLevelizedFFs(PM, FLib, FFlipFlopNames[0], FThreshold);
          PadOutputFFs(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
        end;

        // Left slider endpoint: measure compact mode's worst path/level so
        // the label matches what the stats bar shows in compact mode.
        if FSliderPos = 0 then
          FCompactWorstDelay := WorstLevelDelayOf(PM)
        else
        begin
          Cmp := FModel.Clone;
          try
            CDummy := TStringList.Create;
            try
              InsertTopLevelFFs(Cmp, FLib, FFlipFlopNames[0]);
              InsertCompactFlipFlops(Cmp, FLib, FFlipFlopNames[0]);
              ComputeClockLevels(Cmp, CDummy);
              PadOutputFFs(Cmp, FLib, FFlipFlopNames[0]);
              ComputeClockLevels(Cmp, CDummy);
            finally
              CDummy.Free;
            end;
            FCompactWorstDelay := WorstLevelDelayOf(Cmp);
          finally
            Cmp.Free;
          end;
        end;
      finally
        Dummy.Free;
      end;
    end
    else
    begin
      // No flip-flop selected: keep the plain clone, just label the levels.
      FMaxWorstPath := 1;
      FMinDelay := 1;
      Dummy := TStringList.Create;
      try
        ComputeClockLevels(PM, Dummy);
      finally
        Dummy.Free;
      end;
    end;
    FPipelineModel := PM;
    PM := nil;
  finally
    PM.Free;
  end;
end;

procedure TForm1.TrackBar1Change(Sender: TObject);
begin
  if FSliderUpdating then
    Exit;
  FSliderUpdating := True;
  try
    FSliderPos := Round(TrackBar1.Value);
    if FSliderPos < 0 then FSliderPos := 0;
    if FSliderPos > 100 then FSliderPos := 100;
  finally
    FSliderUpdating := False;
  end;
  // Update the constraint shown live in the heuristics label without
  // rebuilding the circuit; the build happens once the slider is released.
  if FMaxWorstPath > FMinDelay then
    FThreshold := FMaxWorstPath - (FMaxWorstPath - FMinDelay) * (FSliderPos / 100)
  else
    FThreshold := FMinDelay;
  UpdateModeLabel;
  RepaintPipelinePage;
  FSliderTimer.Enabled := False;
  FSliderTimer.Enabled := True;
end;

procedure TForm1.SliderTimerTimer(Sender: TObject);
begin
  FSliderTimer.Enabled := False;
  if TabControl1.TabIndex <> TabPipeline then
    Exit;
  BuildPipelineModel;
  UpdateModeLabel;
  RepaintPipelinePage;
end;

procedure TForm1.UpdateModeLabel;
begin
  if FSliderPos = 0 then
    LabelMode.Text := 'Mode: compact'
  else
    LabelMode.Text := Format('Mode: max delay <=%.1f ps', [FThreshold]);
end;

procedure TForm1.UpdateLimitLabels;
begin
  // Slider end frequencies: the compact mode worst path (left) and the
  // fastest possible level (right). Delays are in ps, so invert for GHz.
  if (FModel <> nil) and (FFlipFlopNames.Count > 0) then
  begin
    // Left end: compact mode's real worst path/level, matching the stats
    // bar; falls back to the pristine worst path before the first build.
    if FCompactWorstDelay > 0 then
      LabelFreqLeft.Text := Format('%.2f GHz', [1000.0 / FCompactWorstDelay])
    else
      LabelFreqLeft.Text := Format('%.2f GHz', [1000.0 / FMaxWorstPath]);
    LabelFreqRight.Text := Format('%.2f GHz', [1000.0 / FMinDelay]);
  end
  else
  begin
    LabelFreqLeft.Text := '-';
    LabelFreqRight.Text := '-';
  end;
end;

procedure TForm1.RepaintPipelinePage;
var
  i: Integer;
begin
  // Partial redraws around the clipped canvas corrupt neighbouring
  // controls (labels, slider, buttons) until those are included in the
  // redraw pass. The form itself has no Repaint (it is not a TControl),
  // so invalidate every direct child of the form.
  if TabControl1.TabIndex <> TabPipeline then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.RepaintClockPage;
begin
  if TabControl1.TabIndex <> TabClock then
    Exit;
  // Repaint the tab control and buttons to ensure everything is refreshed
  TabControl1.Repaint;
  ButtonBack.Repaint;
  ButtonNext.Repaint;
end;

procedure TForm1.FreeClockModel;
begin
  FClockNet.Free;
  FClockNet := nil;
  FClockBufferedModel.Free;
  FClockBufferedModel := nil;
  FClockModel.Free;
  FClockModel := nil;
end;

procedure TForm1.BuildClockModel;
var
  Types: TArray<TSplitterType>;
  BufTypes: TArray<TBufferType>;
  Errors: TStringList;
  i, n, BufN: Integer;
  Cell: TCell;
  Delay: Double;
  NumOutputs: Integer;
  InPin, OutPin: string;
begin
  FreeClockModel;
  if (FPipelineModel = nil) or (FLib = nil) or (FFlipFlopNames.Count = 0) then
    Exit;

  // Work on a deep copy: the pipeline view keeps showing the pure DFF view.
  FClockModel := FPipelineModel.Clone;

  // Every splitter candidate in the library (generic sizes), with timing.
  n := 0;
  SetLength(Types, FLib.Cells.Count);
  for i := 0 to FLib.Cells.Count - 1 do
  begin
    Cell := FLib.Cells[i];
    if not IsSplitterCandidate(Cell, NumOutputs) then
      Continue;
    Delay := CellDelayPs(Cell);
    if Delay < 0 then
      Continue;
    Types[n].CellName := Cell.Name;
    Types[n].OutputCount := NumOutputs;
    Types[n].DelayPs := Delay;
    Inc(n);
  end;
  SetLength(Types, n);

  // The selected buffer cells, with timing, for tree balancing.
  BufN := 0;
  SetLength(BufTypes, FBufferNames.Count);
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if (Cell = nil) or not IsBufferCandidate(Cell, InPin, OutPin) then
      Continue;
    Delay := CellDelayPs(Cell);
    if Delay < 0 then
      Continue;
    BufTypes[BufN].CellName := Cell.Name;
    BufTypes[BufN].DelayPs := Delay;
    BufTypes[BufN].InputPin := InPin;
    BufTypes[BufN].OutputPin := OutPin;
    Inc(BufN);
  end;
  SetLength(BufTypes, BufN);

  Errors := TStringList.Create;
  try
    FClockNet := BuildClockNetwork(FClockModel, FLib, Types, BufTypes, Errors);
    // Keep the original clock network (with its synthetic delay blocks) intact
    // for the clock view; build a separate copy with the delay blocks replaced
    // by real buffer chains, to be used by the clock placement later.
    if FClockNet <> nil then
    begin
      FClockBufferedModel := FClockModel.Clone;
      ReplaceClockDelaysWithBuffers(FClockBufferedModel, FLib, BufTypes, Errors);
    end;
    Memo1.Lines.AddStrings(Errors); // diagnostics incl. per-stage seeds
  finally
    Errors.Free;
  end;
end;

// One node of a row's clock distribution tree: either a splitter (interior)
// or a terminating clocked component (leaf). Built fresh per paint.
type
  TClockTreeNode = class
  public
    Gate: TGateInstance;
    IsLeaf: Boolean;
    Depth: Integer;
    X, Y: Single;
    Children: TObjectList<TClockTreeNode>;
    constructor Create(AGate: TGateInstance; AIsLeaf: Boolean; ADepth: Integer);
    destructor Destroy; override;
  end;

constructor TClockTreeNode.Create(AGate: TGateInstance; AIsLeaf: Boolean;
  ADepth: Integer);
begin
  Gate := AGate;
  IsLeaf := AIsLeaf;
  Depth := ADepth;
  Children := TObjectList<TClockTreeNode>.Create(True);
end;

destructor TClockTreeNode.Destroy;
begin
  Children.Free;
  inherited;
end;

procedure TForm1.PaintClockNetwork(Sender: TObject; Canvas: TCanvas);
var
  Visited: TDictionary<TGateInstance, Boolean>;

  // Builds one row's distribution tree from its tap net. Interior nodes are
  // splitters; leaves are terminating clocked components (drawn without any
  // of their own children).
  procedure BuildTree(const ANetName: string; Depth: Integer;
    Parent: TClockTreeNode; var MaxDepth: Integer);
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    Node: TClockTreeNode;
  begin
    // The spine's delay/buffer chain (clk_delay_*) belongs to no row tree.
    if (Length(ANetName) >= 10) and
       SameText(Copy(ANetName, 1, 10), 'clk_delay_') then
      Exit;
    if not FClockModel.Nets.TryGetValue(ANetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);
      if IsClockDelayGate(NC.Gate) then
        Continue; // spine element, not part of this row's tree
      Node := TClockTreeNode.Create(NC.Gate, CellHasClock(NC.Gate.Cell),
        Depth);
      if Node.Depth > MaxDepth then
        MaxDepth := Node.Depth;
      Parent.Children.Add(Node);
      if not Node.IsLeaf then
        for OutConn in NC.Gate.Connections do
          if OutConn.Port.Direction = pdOutput then
            BuildTree(OutConn.NetName, Depth + 1, Node, MaxDepth);
    end;
  end;

  function CountLeaves(Node: TClockTreeNode): Integer;
  var
    i: Integer;
  begin
    if Node.Children.Count = 0 then
      Result := 1
    else
    begin
      Result := 0;
      for i := 0 to Node.Children.Count - 1 do
        Result := Result + CountLeaves(Node.Children[i]);
    end;
  end;

var
  R: TRectF;
  rIdx, MaxDepth, i: Integer;
  TrunkX, TreeX0, ColGap, LayerStep, Sq, RootY, YMid, StageDelay: Single;
  TapNetName, DelayTxt, LevelTxt: string;
  Roots: TObjectList<TClockTreeNode>;
  RootYs: TArray<Single>;
  RowHeights: TArray<Single>;
  MaxDepths: TArray<Integer>;
  Node, TrunkNode: TClockTreeNode;
  ClipState: TCanvasSaveState;
  LevelCols: TList<Integer>;
  ClkY: Single;
  ClkLbl: string;

  // World -> screen transforms (pan + zoom), mirroring PaintPipeline.
  // Declared before the draw helpers so they can reference them.
  function WX(AValue: Single): Single;
  begin
    Result := FClockPanX + AValue * FClockZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FClockPanY + AValue * FClockZoom;
  end;

  function WLen(AValue: Single): Single;
  begin
    Result := AValue * FClockZoom;
  end;

  // Left-aligned tree layout matching PaintPipeline's DFSLayout:
  // - A child sits directly above its parent, or up-and-to-the-right -
  //   never left of it (BaseCol floors the column at the parent's).
  // - Subsequent siblings claim the next free columns to the right.
  procedure LayoutSubtree(Node: TClockTreeNode; Depth: Integer;
    BaseCol: Integer; BaseY: Single);
  var
    i: Integer;
    ParentCol: Integer;
  begin
    Node.Y := BaseY - Node.Depth * LayerStep;

    // Ensure we have a column counter for this depth
    while LevelCols.Count <= Depth do
      LevelCols.Add(0);

    // Never left of the parent, never left of an earlier sibling subtree.
    if LevelCols[Depth] < BaseCol then
      LevelCols[Depth] := BaseCol;
    ParentCol := LevelCols[Depth];

    // Position this node
    Node.X := TreeX0 + ParentCol * ColGap;

    // Reserve next column for this depth
    LevelCols[Depth] := ParentCol + 1;

    // Lay out children recursively, floored at this node's column
    for i := 0 to Node.Children.Count - 1 do
      LayoutSubtree(Node.Children[i], Depth + 1, ParentCol, BaseY);

    // After laying out children, ensure the next node at this depth is at
    // least as far right as the rightmost child
    if Depth + 1 < LevelCols.Count then
      if LevelCols[Depth] < LevelCols[Depth + 1] then
        LevelCols[Depth] := LevelCols[Depth + 1];
  end;

  // Filled-segment connector: bypasses stroke rendering entirely (fills
  // demonstrably render in this view). Handles vertical, horizontal and
  // diagonal hops.
  procedure DrawSeg(X1, Y1, X2, Y2: Single);
  begin
    Canvas.DrawLine(TPointF.Create(WX(X1), WY(Y1)),
      TPointF.Create(WX(X2), WY(Y2)), 1.0);
  end;

  // Returns this gate's clock input pin name using the configured clock
  // prefixes (same generic resolution the DFF insertion relies on).
  function ClockPinNameOf(Gate: TGateInstance): string;
  var
    P: TPort;
  begin
    Result := 'clk';
    if Gate = nil then
      Exit;
    for P in Gate.Cell.Ports do
      if (P.Direction = pdInput) and IsClockPinName(P.Name) then
        Exit(P.Name);
  end;

  // Thin connector lines: parent centre -> child centre.
  procedure DrawEdges(Node: TClockTreeNode);
  var
    i: Integer;
  begin
    for i := 0 to Node.Children.Count - 1 do
    begin
      DrawSeg(Node.X, Node.Y,
        Node.Children[i].X, Node.Children[i].Y);
      DrawEdges(Node.Children[i]);
    end;
  end;

  procedure DrawNodes(Node: TClockTreeNode);
  var
    i: Integer;
    Clr: TAlphaColor;
    NumOutputs: Integer;
  begin
    if Node.IsLeaf then
    begin
      if FSplitterNames.IndexOf(Node.Gate.Cell.Name) >= 0 then
        Clr := $FF00C853
      else if FFlipFlopNames.IndexOf(Node.Gate.Cell.Name) >= 0 then
        Clr := $FFD50000
      else
        Clr := $FF1565C0;
      Canvas.Fill.Color := Clr;
      Canvas.FillRect(TRectF.Create(
        WX(Node.X) - WLen(Sq) / 2, WY(Node.Y) - WLen(Sq) / 2,
        WX(Node.X) + WLen(Sq) / 2, WY(Node.Y) + WLen(Sq) / 2), 0, 0, [], 1.0);
    end
    else
    begin
      // Interior tree node. Splitters stay green (the exception); buffers
      // and any other unclocked cell use the light-blue general colour.
      if IsSplitterCandidate(Node.Gate.Cell, NumOutputs) then
        Canvas.Fill.Color := $FF00C853
      else
        Canvas.Fill.Color := $FF81D4FA;
      Canvas.FillRect(TRectF.Create(
        WX(Node.X) - WLen(Sq) / 2, WY(Node.Y) - WLen(Sq) / 2,
        WX(Node.X) + WLen(Sq) / 2, WY(Node.Y) + WLen(Sq) / 2), 0, 0, [], 1.0);
    end;
    for i := 0 to Node.Children.Count - 1 do
      DrawNodes(Node.Children[i]);
  end;

begin
  R := TRectF.Create(0, 0, PaintBox2.Width, PaintBox2.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  // Mask everything outside the paint box. The D2D canvas only honors
  // IntersectClipRect while a save state is active - without this the
  // drawing bleeds over the Back/Next buttons.
  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if (FClockModel = nil) or (FClockNet = nil) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No clock network built - complete the previous steps.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Roots := TObjectList<TClockTreeNode>.Create(True);
    Visited := TDictionary<TGateInstance, Boolean>.Create;
    try
    // Build one tree per row; row 0 is the highest clock level (the clock
    // source end of the counter-flow spine, drawn at the bottom).
    SetLength(RootYs, FClockNet.Rows.Count);
    SetLength(RowHeights, FClockNet.Rows.Count);
    SetLength(MaxDepths, FClockNet.Rows.Count);
    for rIdx := 0 to FClockNet.Rows.Count - 1 do
    begin
      if rIdx = 0 then
        TapNetName := FClockNet.SourceNet // spine_0 == clk: source junction
      else if rIdx <= FClockNet.Rows.Count - 2 then
        TapNetName := Format('clk_spine_%d', [rIdx]) // feeds junction S<rIdx>
      else
        // Topmost band (level 1): fed directly by the final delay - no
        // junction exists here, so walk the row net itself.
        TapNetName := Format('clk_row_%d', [FClockNet.Rows[rIdx]]);
      Node := TClockTreeNode.Create(nil, False, 0); // virtual root
      Roots.Add(Node);
      MaxDepth := 0;
      BuildTree(TapNetName, 0, Node, MaxDepth);
      MaxDepths[rIdx] := MaxDepth;
      RootYs[rIdx] := -1;
    end;

    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Stroke.Color := $FF555555;
    Canvas.Stroke.Thickness := 1.6;

    TrunkX := 110;
    TreeX0 := 210;
    Sq := 26;
    ColGap := 64;
    LayerStep := 44;

    // Assign trunk Y positions, bottom (row 0) upward. Each row claims
    // vertical space for its deepest tree level plus a gap for the delay
    // block between rows. Leave room at the very bottom for the clk input.
    RootY := PaintBox2.Height - 110;
    for rIdx := 0 to Roots.Count - 1 do
    begin
      RootYs[rIdx] := RootY;
      RowHeights[rIdx] := (MaxDepths[rIdx] + 1) * LayerStep + 34;
      RootY := RootY - RowHeights[rIdx];
    end;

    // Layout + draw each row's tree: the root splitter is pinned to the
    // trunk; its children fan upward, siblings branching right.
    LevelCols := TList<Integer>.Create;
    try
      for rIdx := 0 to Roots.Count - 1 do
      begin
        Node := Roots[rIdx];
        if Node.Children.Count > 0 then
        begin
          // The trunk (junction splitter) is tagged; everything else is
          // subtree and must sprout to the right of the trunk.
          TrunkNode := nil;
          for i := 0 to Node.Children.Count - 1 do
            if (Node.Children[i].Gate <> nil) and
               Node.Children[i].Gate.ClockTrunk then
            begin
              TrunkNode := Node.Children[i];
              Break;
            end;

          LevelCols.Clear;
          if TrunkNode <> nil then
          begin
            // Pin the trunk junction on the spine; its children (this row's
            // distribution tree) grow right from the first subtree column.
            TrunkNode.X := TrunkX;
            TrunkNode.Y := RootYs[rIdx];
            TrunkNode.Depth := 0;
            for i := 0 to TrunkNode.Children.Count - 1 do
              LayoutSubtree(TrunkNode.Children[i], 1, 0, RootYs[rIdx]);
            DrawEdges(TrunkNode);
            DrawNodes(TrunkNode);
          end
          else
          begin
            // No junction on this row (the topmost band): the whole tree is
            // subtree, so it sprouts right of the trunk from column 0.
            for i := 0 to Node.Children.Count - 1 do
            begin
              LayoutSubtree(Node.Children[i], 0, 0, RootYs[rIdx]);
              DrawEdges(Node.Children[i]);
              DrawNodes(Node.Children[i]);
            end;
          end;
        end;
      end;
    finally
      LevelCols.Free;
    end;

    // Trunk: splitter -> delay -> splitter ... straight up the left edge.
    for rIdx := 0 to Roots.Count - 2 do
    begin
      if (Roots[rIdx].Children.Count = 0) or
         (Roots[rIdx + 1].Children.Count = 0) then
        Continue;
      YMid := (RootYs[rIdx] + RootYs[rIdx + 1]) / 2;
      // vertical trunk segments into and out of the delay block
      DrawSeg(TrunkX, RootYs[rIdx], TrunkX, YMid - 15);
      DrawSeg(TrunkX, YMid + 15, TrunkX, RootYs[rIdx + 1]);

      StageDelay := FClockNet.Stages[rIdx].DelayPs;
      DelayTxt := Format('%.1f ps', [StageDelay]);

      Canvas.Fill.Color := TAlphaColorRec.Black;
      Canvas.FillRect(TRectF.Create(WX(TrunkX) - WLen(46), WY(YMid) - WLen(15),
        WX(TrunkX) + WLen(46), WY(YMid) + WLen(15)), 0, 0, [], 1.0);
      Canvas.Fill.Color := TAlphaColorRec.White;
      Canvas.FillText(TRectF.Create(WX(TrunkX) - WLen(46), WY(YMid) - WLen(15),
        WX(TrunkX) + WLen(46), WY(YMid) + WLen(15)), DelayTxt, False, 1.0,
        [], TTextAlign.Center, TTextAlign.Center);
    end;

    // Final (topmost) band has no junction splitter, so the trunk's wire
    // taps horizontally into that row's tree to the right.
    if Roots.Count > 0 then
    begin
      Node := Roots[Roots.Count - 1];
      for i := 0 to Node.Children.Count - 1 do
        if Node.Children[i].X > TrunkX then
          DrawSeg(TrunkX, Node.Children[i].Y, Node.Children[i].X, Node.Children[i].Y);
    end;

    // Layer labels: to the LEFT of each row's junction splitter.
    for rIdx := 0 to Roots.Count - 1 do
    begin
      LevelTxt := Format('L%d', [FClockNet.Rows[rIdx]]);
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(TRectF.Create(
        WX(TrunkX) - WLen(Sq) / 2 - WLen(56), WY(RootYs[rIdx]) - WLen(11),
        WX(TrunkX) - WLen(Sq) / 2 - WLen(4), WY(RootYs[rIdx]) + WLen(11)),
        LevelTxt, False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
    end;

    // Clock input: a primary-input square (same yellow as other inputs)
    // feeding the first splitter from below. Labelled with the clock pin
    // name resolved via the configured clock prefixes.
    ClkY := PaintBox2.Height - 45;
    DrawSeg(TrunkX, ClkY - Sq / 2, TrunkX, RootYs[0] + Sq / 2);
    Canvas.Fill.Color := $FFFFEB3B;
    Canvas.FillRect(TRectF.Create(WX(TrunkX) - WLen(Sq) / 2,
      WY(ClkY) - WLen(Sq) / 2, WX(TrunkX) + WLen(Sq) / 2,
      WY(ClkY) + WLen(Sq) / 2), 0, 0, [], 1.0);

    ClkLbl := ClockNetFor(FClockModel);
    if (Roots[0].Children.Count > 0) and
       (Roots[0].Children[0].Gate <> nil) then
      ClkLbl := ClockPinNameOf(Roots[0].Children[0].Gate);
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(TRectF.Create(WX(TrunkX) - WLen(40),
      WY(ClkY) + WLen(Sq) / 2, WX(TrunkX) + WLen(40),
      WY(ClkY) + WLen(Sq) / 2 + WLen(16)), ClkLbl, False, 1.0, [],
      TTextAlign.Center, TTextAlign.Center);
  finally
    Roots.Free;
    Visited.Free;
  end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.TabControl1Change(Sender: TObject);
var
  Dummy: TStringList;
begin
  // Re-entrancy guard: bouncing back from the Routing tab to the Floorplan tab
  // re-fires this handler; the Floorplan branch below does the rebuild.
  if FSwitchingTab then
    Exit;
  // The Routing tab is only reachable after the placement has been optimised
  // AND the bias lines expanded, with no placement or floorplan errors. Reject
  // the switch and bounce back to the Floorplan tab otherwise.
  if (TabControl1.TabIndex = TabRouting) and
     not (FPlacementOptimized and FBiasExpansionDone and
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
    BuildFloorplan;
  if TabControl1.TabIndex = TabRouting then
  begin
    FRoutePanX := 0;
    FRoutePanY := 0;
    FRouteZoom := 1.0;
    FRouteNeedsFit := True;
    BuildRoutingLayers;
    RepaintRoutingPage;
  end;
  if TabControl1.TabIndex = TabPipeline then
  begin
    FPanX := 0;
    FPanY := 0;
    FZoom := 1.0;
    // Prerequisite: splitter insertion must have run on this netlist.
    if (FModel <> nil) and (not FSplittersInserted) then
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
    Dummy := TStringList.Create;
    try
      RenderNetlist(FModel, Dummy);
    finally
      Dummy.Free;
    end;
  end;
  if TabControl1.TabIndex = TabClock then
  begin
    // Clock stage: always rebuild from the current DFF-inserted netlist.
    FClockPanX := 0;
    FClockPanY := 0;
    FClockZoom := 1.0;
    // Prerequisites: splitters inserted, then the pipeline (DFF-inserted)
    // model built - the clock view is derived from it.
    if (FModel <> nil) and (not FSplittersInserted) then
      RunSplitterInsertion;
    if FPipelineModel = nil then
    begin
      BuildPipelineModel;
      UpdateModeLabel;
      UpdateLimitLabels;
    end;
    BuildClockModel;
    RepaintClockPage;
    Dummy := TStringList.Create;
    try
      if FClockModel <> nil then
        RenderNetlist(FClockModel, Dummy)
      else
        RenderNetlist(FModel, Dummy);
    finally
      Dummy.Free;
    end;
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
  Inserted: Integer;
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

  Inserted := InsertSplitters(FModel, FLib, SplitterTypes);
  if Inserted > 0 then
    Label1.Text := Format('Inserted %d splitter(s) into the netlist.', [Inserted])
  else
    Label1.Text := 'No splitters needed (no net has fanout > 1).';
  // Zero inserted is still a valid outcome - nothing required splitting -
  // so allow moving on just as if splitters had been added.
  FSplittersInserted := True;

  Errors := TStringList.Create;
  try
    ComputeClockLevels(FModel, Errors);
    RenderNetlist(FModel, Errors);
  finally
    Errors.Free;
  end;
  UpdateUI;
end;

procedure TForm1.RenderNetlist(Model: TBlifModel; Errors: TStrings);
var
  Dump: TStringList;
  DumpModel: TBlifModel;
  i: Integer;
  Gate: TGateInstance;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  NetName: string;
  Line: string;
begin
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
      Line := Format('  %2d. %s  [L%d]', [i + 1, Gate.CellName, Gate.ClockLevel]);
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
      begin
        if NC.IsDriver then
          Line := Line + Format('  drive=%s.%s', [NC.Gate.CellName, NC.PinName])
        else
          Line := Line + Format('  load=%s.%s', [NC.Gate.CellName, NC.PinName]);
      end;
      Dump.Add(Line);
    end;

    Dump.Add('');
    if Errors.Count > 0 then
    begin
      Dump.Add(Format('ERRORS (%d):', [Errors.Count]));
      for i := 0 to Errors.Count - 1 do
        Dump.Add('  ' + Errors[i]);
    end
    else
      Dump.Add('No errors.');

    Memo1.Lines.Assign(Dump);
  finally
    Dump.Free;
  end;
end;

procedure TForm1.ListBox1DblClick(Sender: TObject);
var
  Cell: TCell;
  Viewer: TCellViewerForm;
begin
  if FLib = nil then Exit;
  if (ListBox1.ItemIndex < 0) or (ListBox1.ItemIndex >= FLib.Cells.Count) then
    Exit;
  Cell := FLib.Cells[ListBox1.ItemIndex];
  Viewer := TCellViewerForm.Create(nil);
  Viewer.SetCell(Cell);
  Viewer.Show;
end;

procedure TForm1.ButtonBackClick(Sender: TObject);
begin
  if TabControl1.TabIndex > 0 then
    TabControl1.TabIndex := TabControl1.TabIndex - 1;
  UpdateUI;
end;

procedure TForm1.ButtonNextClick(Sender: TObject);
begin
  // Leaving the BLIF tab runs the splitter insertion automatically.
  if (TabControl1.TabIndex = TabNetlist) and (not FSplittersInserted) then
    RunSplitterInsertion;
  if TabControl1.TabIndex < TabControl1.TabCount - 1 then
    TabControl1.TabIndex := TabControl1.TabIndex + 1;
  UpdateUI;
end;

procedure TForm1.ButtonRunRoutingClick(Sender: TObject);
begin
  // Start from a clean floorplan so every run routes the same placement.
  FLogicRowExtra := nil;
  FClockRowExtra := nil;
  BuildFloorplan;
  if FFloorplanErrorCount = 0 then
    OptimizePlacement;
  // Maze route: all nets on the first layer, then the next layer for the
  // failures, ... then a via pass. Reports its own per-layer progress.
  RunRouting;
  // Bias lines: always routable programmatically, run after the main circuit
  // routing so the floorplan is settled. Each partition group becomes one track.
  RouteBiasLines;
  MemoRouting.Lines.Add(
    'Bias lines routed from the partition groups.');
  // Validation-inserted buffers (ClockLevel -1, so BuildFloorplan skips them)
  // must be re-applied to the layout after the rebuild.
  ReapplyValidationBuffers;
  UpdateUI;
end;

procedure TForm1.ButtonValidateRoutingClick(Sender: TObject);
begin
  RunRoutingValidation;
  UpdateUI;
end;

end.

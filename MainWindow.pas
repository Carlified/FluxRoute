unit MainWindow;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.ListBox, FMX.Memo, FMX.Layouts, FMX.TabControl,
  FMX.Objects, FMX.Edit,
  System.IOUtils, System.JSON, System.Math, System.Math.Vectors,
  System.Generics.Collections, System.StrUtils,
  UGeometry, UPhysics, UColors, UNetNaming, URoutingLegend,
  PlacementTypes, UDesignConfig, UConstants,
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
    LabelStartTitle: TLabel;
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
    lblStatus: TLabel;
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
    procedure btnLoadLefClick(Sender: TObject);
    procedure btnLoadLibraryClick(Sender: TObject);
    procedure btnLoadBlifClick(Sender: TObject);
    procedure lstCellsDblClick(Sender: TObject);
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
    FOwnedPlacementModel: TBlifModel; // private clone validation mutates (nil = alias)
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
    FBiasRowH: TArray<TArray<Integer>>; // [band][0=top,1=middle] extra rows
    FBottomBiasH: Integer;              // extra rows on the bottom-most bias line
    FBiasLaneW: TArray<Integer>;        // [0]=left feed lane, [1]=right lane width (>=1)
    FPlanMaxRowW: Integer;              // row-width override for the nudge (0=auto)
    FPlanTrunkW: Integer;               // snapshot: clock trunk width (RowHBlocks)
    FPlanLane0W: Integer;               // snapshot: left feed bias lane width
    FPlanLane1W: Integer;               // snapshot: far-right bias lane width
    FPlanLastTotalH: Integer;           // snapshot: last TotalH (bias-fit checks)
    FOrderChanged: Boolean;
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
    function HasValidationBufferTraces: Boolean;
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
    procedure DrawResonancePulses(Canvas: TCanvas; Core, ScaleCap: Double);
    function GatePinBlock(G: TGateInstance; const PinName: string;
      ALayer: Integer; var P: TPoint): Boolean;
    function GatePinBlockAt(G: TGateInstance; const PinName: string;
      ALayer, AX, AY: Integer; Rotated: Boolean; var P: TPoint): Boolean;
    procedure BuildRoutingObstacles;
    // Windowed A* maze: UseLayer >= 0 pins one layer (no vias), < 0 allows all
    // layers via vias; turns cost more than straight; path/layers fill OutPath/OutLayers.
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
  i: Integer;
begin
  if not TFile.Exists(Path) then
  begin
    lblStatus.Text := 'LEF file not found: ' + Path;
    if AShowErrors then
      ShowMessage(lblStatus.Text);
    Exit;
  end;

  ResetWorkspace;
  FLefFile := Path;
  lblStatus.Text := 'Parsing: ' + ExtractFileName(FLefFile);

  try
    Lib := LoadLefLibrary(FLefFile);
  except
    on E: Exception do
    begin
      lblStatus.Text := 'Failed to parse LEF file.';
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
    lstCells.Items.Add(FLib.Cells[i].Name);
  PopulateBiasLayerCombo;
  lblStatus.Text := Format('Loaded %d cell(s) from %s',
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
    lblStatus.Text := 'Cell folder no longer exists.';
    if AShowErrors then
      ShowMessage(lblStatus.Text);
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

  lblStatus.Text := Format('Found %d linked file(s) for %d of %d cells. Double-click a cell to view it.',
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
    lblStatus.Text := 'BLIF file not found: ' + Path;
    if AShowErrors then
      ShowMessage(lblStatus.Text);
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
  lblStatus.Text := 'Parsing: ' + ExtractFileName(FBlifFile);

  Errors := TStringList.Create;
  try
    try
      FModel := ParseBlif(FBlifFile, FLib, Errors);
    except
      on E: Exception do
      begin
        lblStatus.Text := 'Failed to parse BLIF file.';
        if AShowErrors then
          ShowMessage('Failed to parse BLIF file:' + sLineBreak + sLineBreak + E.Message);
        UpdateUI;
        Exit;
      end;
    end;

    CheckNetConnectivity(FModel, Errors);

    ComputeClockLevels(FModel, Errors);

    lblStatus.Text := Format('Loaded netlist "%s": %d gate(s), %d net(s), %d error(s)',
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
  ButtonRunRouting.Enabled := (FFlowStage < fsRouted) or (FFlowStage >= fsValidated);
  ButtonValidateRouting.Enabled := (FFlowStage >= fsRouted) and (FFlowStage < fsValidated);
end;

{$I ConfigIO.inc}


procedure TForm1.ScrapValidationModel;
begin
  if FOwnedPlacementModel = nil then
    Exit;
  // The clone's gates are referenced by FValidationBuffers, so those records go
  // with it (they are meaningless once the model is gone).
  FValidationBuffers := nil;
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
    if FProjectPath = '' then
      SaveProjectFileAs
    else
    begin
      SaveProjectState;
      lblStatus.Text := 'Project saved: ' + ExtractFileName(FProjectPath);
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
{$I Placement.inc}


{$I FloorPlan.inc}


{$I Routing.inc}


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
      MinZ := (Min(PaintBox3.Width, PaintBox3.Height) - 20) / Max(FDesignConfig.DieWUm, FDesignConfig.DieHUm);
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
      MinZ := (Min(PaintBox4.Width, PaintBox4.Height) - 20) / Max(FDesignConfig.DieWUm, FDesignConfig.DieHUm);
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


procedure TForm1.TabControl1Change(Sender: TObject);
begin
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
    lblStatus.Text := Format('Inserted %d splitter(s) into the netlist.', [Inserted])
  else
    lblStatus.Text := 'No splitters needed (no net has fanout > 1).';
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
  if TabControl1.TabIndex > 0 then
    TabControl1.TabIndex := TabControl1.TabIndex - 1;
  UpdateUI;
end;

procedure TForm1.ButtonNextClick(Sender: TObject);
begin
  // Leaving the BLIF tab runs the splitter insertion automatically.
  if (TabControl1.TabIndex = TabNetlist) and (FFlowStage < fsSplitters) then
    RunSplitterInsertion;
  if TabControl1.TabIndex < TabControl1.TabCount - 1 then
    TabControl1.TabIndex := TabControl1.TabIndex + 1;
  UpdateUI;
end;

procedure TForm1.ButtonRunRoutingClick(Sender: TObject);
begin
  if FRoutingBusy then
    Exit;
  FRoutingBusy := True;
  try
    // Routing always starts from the pristine model: a committed validation
    // clone (with its buffers) is never what the router works on.
    ScrapValidationModel;
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
  finally
    FRoutingBusy := False;
  end;
end;

procedure TForm1.ButtonValidateRoutingClick(Sender: TObject);
begin
  if FRoutingBusy then
    Exit;
  FRoutingBusy := True;
  try
    RunRoutingValidation;
    UpdateUI;
  finally
    FRoutingBusy := False;
  end;
end;

end.

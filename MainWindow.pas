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
  // Placement configuration, Floorplan.
  TabStart = 0;
  TabLibrary = 1;
  TabComponents = 2; // cell selection (splitters/FF/buffers)
  TabNetlist = 3;    // BLIF loading
  TabPipeline = 4;
  TabClock = 5;
  TabPlacement = 6;  // floorplanning / placement configuration
  TabFloorplan = 7;  // floorplan visualisation

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
    ButtonExport: TButton;
    CheckBoxShowNames: TCheckBox;
    CheckBoxShowLogicWires: TCheckBox;
    CheckBoxShowClockWires: TCheckBox;
    CheckBoxShowFloorplan: TCheckBox;
    CheckBoxShowCells: TCheckBox;
    ListBoxFloorplanErrors: TListBox;
    SplitterErrors: TSplitter;
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
    procedure ButtonOptimizeClick(Sender: TObject);
    procedure ButtonExportClick(Sender: TObject);
    procedure CheckBoxToggleChange(Sender: TObject);
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
    FPlacementErrorCount: Integer;
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
    FPlanXRight: Integer;
    FPlanRowHBlocks: Integer;
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
    procedure OrderLayer(L: Integer; CrossOnly: Boolean);
    procedure ResolvePlacementOverlaps;
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
  // Show the parsed layer stack (routing metals, via cuts, overlap).
  MemoLayers.Lines.BeginUpdate;
  try
    MemoLayers.Lines.Clear;
    for i := 0 to FLib.Layers.Count - 1 do
      case FLib.Layers[i].LayerType of
        ltRouting:
          MemoLayers.Lines.Add(Format('%s: routing %s, W %.1f, P %.1f',
            [FLib.Layers[i].Name, LowerCase(FLib.Layers[i].Direction),
             FLib.Layers[i].Width, FLib.Layers[i].Pitch]));
        ltCut:
          MemoLayers.Lines.Add(Format('%s: via cut, W %.1f',
            [FLib.Layers[i].Name, FLib.Layers[i].Width]));
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
  OnMouseWheel := FormMouseWheel;
  FZoom := 1.0;
  FClockZoom := 1.0;
  FPlanZoom := 1.0;
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
    if BlockX < 1 then
      BlockX := 1;
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
      Slot := NearestPadSlot(FPadDragX, N, FPlanXRight + 1 + FPlanRowHBlocks);
      FPadOrderOutput := PreviewPadOrder(FPadOrderOutput, FPadDragIdx, Slot);
    end;
    ReapplyPadOrder;
    FPadDragging := False;
    RepaintFloorplanPage;
  end;
  FPlanDragging := False;
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
          FPlacedComponents[Idx].W <= FPlanXRight - 1) then
      begin
        CellBand[i] := cand;
        Break;
      end;
      cand := Pref - d;
      if (d > 0) and (cand >= BandStartIdx) and (cand < BandEndIdx) and
         (BandUsed[cand - BandStartIdx] +
          FPlacedComponents[Idx].W <= FPlanXRight - 1) then
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
    X := 1;
    for i := 0 to High(Order) do
    begin
      if CellBand[i] <> BandIdx then
        Continue;
      Idx := Items[Order[i]];
      W := FPlacedComponents[Idx].W;
      DL := Round(BaryX[Order[i]] - W / 2);
      if DL < 1 then
        DL := 1;
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
      if PlacedX[i] < 1 then
        PlacedX[i] := 1;
      NextLeft := PlacedX[i];
    end;
  end;

  // Write the final positions.
  for i := 0 to High(Order) do
  begin
    if (CellBand[i] < BandStartIdx) or (CellBand[i] >= BandEndIdx) then
      Continue;
    Idx := Items[Order[i]];
    RowY := FPlanBandStarts[CellBand[i]] + 1 +
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

// Debug helper: dumps the current placement (positions, barycentres, and each
// cell's placed connection targets) to placement_dump.txt in the working
// directory so the layout can be inspected numerically.
procedure TForm1.ButtonExportClick(Sender: TObject);
var
  SL: TStringList;
  Item: TListBoxItem;
  i: Integer;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  Pt: TPoint;
  Path: string;
  Bx, By, SumX, SumY: Double;
  Count, Wb, Hb: Integer;
begin
  if Length(FPlacedComponents) = 0 then
    Exit;
  SL := TStringList.Create;
  try
    SL.Add(Format('Total wire length: %.0f um', [TotalManhattanDistance]));
    SL.Add(Format('Core=%.3f  XRight=%d  Layers=%d  RowH=%d',
      [FPlanCore, FPlanXRight, FPlanNumLayers, FPlanRowHBlocks]));
    SL.Add('');
    for i := 0 to High(FPlacedComponents) do
    begin
      // Recompute the X/Y barycentre from the placed neighbours.
      SumX := 0;
      SumY := 0;
      Count := 0;
      if FPlacedComponents[i].Gate <> nil then
        for Conn in FPlacedComponents[i].Gate.Connections do
        begin
          if IsClockPinName(Conn.PinName) then
            Continue;
          if (FPlacementModel = nil) or
             (not FPlacementModel.Nets.TryGetValue(Conn.NetName, Net)) then
            Continue;
          for NC in Net.Connections do
          begin
            if NC.Gate = FPlacedComponents[i].Gate then
              Continue;
            if not FGatePlacement.TryGetValue(NC.Gate, Pt) then
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
            SumX := SumX + (Pt.X + Wb / 2);
            SumY := SumY + (Pt.Y + Hb / 2);
            Inc(Count);
          end;
        end;
      if Count > 0 then
      begin
        Bx := SumX / Count;
        By := SumY / Count;
      end
      else
      begin
        Bx := FPlacedComponents[i].X + FPlacedComponents[i].W / 2;
        By := FPlacedComponents[i].Y + FPlacedComponents[i].H / 2;
      end;
      SL.Add(Format('P%4d %-20s [L%2d] X=%4d Y=%4d W=%2d H=%2d  bary=(%6.1f,%6.1f)',
        [i, FPlacedComponents[i].InstanceName, FPlacedComponents[i].ClockLevel,
         FPlacedComponents[i].X, FPlacedComponents[i].Y,
         FPlacedComponents[i].W, FPlacedComponents[i].H, Bx, By]));
      if FPlacedComponents[i].Gate <> nil then
        for Conn in FPlacedComponents[i].Gate.Connections do
        begin
          if IsClockPinName(Conn.PinName) then
            Continue;
          if (FPlacementModel = nil) or
             (not FPlacementModel.Nets.TryGetValue(Conn.NetName, Net)) then
            Continue;
          for NC in Net.Connections do
          begin
            if NC.Gate = FPlacedComponents[i].Gate then
              Continue;
            if FGatePlacement.TryGetValue(NC.Gate, Pt) then
              SL.Add(Format('      -> %-20s [L%2d] @ (%d,%d)',
                [NC.Gate.CellName, NC.Gate.ClockLevel, Pt.X, Pt.Y]));
          end;
        end;
    end;
    Path := GetCurrentDir + '\placement_dump.txt';
    SL.SaveToFile(Path);
  finally
    SL.Free;
  end;
  Item := TListBoxItem.Create(ListBoxFloorplanErrors);
  Item.Parent := ListBoxFloorplanErrors;
  Item.Text := 'Placement dumped to ' + Path;
end;

procedure TForm1.CheckBoxToggleChange(Sender: TObject);
begin
  if TabControl1.TabIndex = TabFloorplan then
    RepaintFloorplanPage;
end;

procedure TForm1.ResolvePlacementOverlaps;
var
  BandHeight, MaxBand, BandIdx, i, j, Idx, Tmp, MinX: Integer;
  Items: TArray<Integer>;
begin
  if Length(FPlacedComponents) = 0 then
    Exit;
  BandHeight := 2 + 2 * FPlanRowHBlocks;
  if BandHeight < 1 then
    Exit;
  MaxBand := 0;
  for i := 0 to High(FPlacedComponents) do
  begin
    BandIdx := (FPlacedComponents[i].Y - 1) div BandHeight;
    if BandIdx > MaxBand then
      MaxBand := BandIdx;
  end;
  for BandIdx := 0 to MaxBand do
  begin
    // Collect the band's cells, then order them by X.
    SetLength(Items, 0);
    for i := 0 to High(FPlacedComponents) do
      if (FPlacedComponents[i].Y - 1) div BandHeight = BandIdx then
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
      if FPlacedComponents[Idx].X < 1 then
        FPlacedComponents[Idx].X := 1;
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
  Result := 1 + (k + 0.5) * (Right - 2) / Max(1, N);
end;

// The slot (0..N-1) whose X is closest to DragX within [1, Right).
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
      X := Round(PadSlotX(k, M, FPlanXRight + 1 + FPlanRowHBlocks));
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
    Right := FPlanXRight + 1 + FPlanRowHBlocks;
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
  TotalH, TotalW, XRight, BandStart: Integer;
  AvailableWidth, TotalBands, Band, C, ChunkCount, ChunkWidth: Integer;
  LevelBandCount, LevelFirstBand, BandStarts: TArray<Integer>;
  CurChunk, CurX: TArray<Integer>;
  Idx: Integer;
  P: TPlacedComponent;
  RowY, BandIndex: Integer;
begin
  // Reset the view; the die is fitted to the canvas on the next paint.
  FPlanPanX := 0;
  FPlanPanY := 0;
  FPlanZoom := 1.0;
  FPlanNeedsFit := True;
  ListBoxFloorplanErrors.Clear;
  FManhattanItem := nil; // cleared listbox invalidates the diagnostic item
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

    // Horizontal: bias trunk (1) on the far left, rows, a bias feed column (1)
    // for the clock trunk, then the clock trunk (rowH) on the far right. The
    // widest a row can be is the die width minus the trunks.
    AvailableWidth := DieWBlocks - 2 - RowHBlocks;
    if AvailableWidth < 1 then
    begin
      AddFloorplanError(Format('Die is too narrow: at least %d blocks are needed for the trunks.',
        [2 + RowHBlocks]));
      RepaintFloorplanPage;
      Exit;
    end;
    XRight := 1 + AvailableWidth;   // common right edge of the rows
    TotalW := XRight + 1 + RowHBlocks; // = DieWBlocks

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
    // underneath in its own bias/logic/bias/clock band.
    TotalBands := 0;
    for L := 0 to NumLayers - 1 do
      TotalBands := TotalBands + Max(1, Ceil(RowWidths[L] / AvailableWidth));
    TotalH := TotalBands * (2 + 2 * RowHBlocks);

    // Failure checks - report and keep whatever fits. Two extra rows are reserved
    // for the I/O pads (top inputs, bottom outputs).
    if TotalH + 2 > DieHBlocks then
      AddFloorplanError(Format('Not enough height: floorplan needs %d blocks (plus 2 pad rows), die has %d.',
        [TotalH, DieHBlocks]));
    if TotalW > DieWBlocks then
      AddFloorplanError(Format('Not enough width: floorplan needs %d blocks, die has %d.',
        [TotalW, DieWBlocks]));

    // Bias trunk (red) on the far left, full height of the rows (plus the two
    // I/O pad rows at the top and bottom).
    FillPlanRect(0, 0, 1, TotalH + 1, fcBias, -1);
    // Vertical bias feed column (red) immediately left of the clock trunk.
    FillPlanRect(XRight, 0, XRight + 1, TotalH + 1, fcBias, -1);
    // Clock trunk (green) on the far right, full height of the rows.
    FillPlanRect(XRight + 1, 0, XRight + 1 + RowHBlocks, TotalH + 1, fcClock, -1);

    // Bands, top to bottom; a layer may wrap into several bands. The bands are
    // shifted down by one row so the top row is reserved for input pads.
    SetLength(LevelBandCount, NumLayers);
    SetLength(LevelFirstBand, NumLayers);
    SetLength(BandStarts, TotalBands);
    Band := 0;
    for L := 0 to NumLayers - 1 do
    begin
      ChunkCount := Max(1, Ceil(RowWidths[L] / AvailableWidth));
      LevelFirstBand[L] := Band;
      LevelBandCount[L] := ChunkCount;
      for C := 0 to ChunkCount - 1 do
      begin
        ChunkWidth := RowWidths[L] - C * AvailableWidth;
        if ChunkWidth > AvailableWidth then
          ChunkWidth := AvailableWidth;
        if ChunkWidth < 1 then
          ChunkWidth := 1;
        BandStart := 1 + Band * (2 + 2 * RowHBlocks);
        BandStarts[Band] := BandStart;
        // Bias line spanning from the bias trunk to the common right edge.
        FillPlanRect(0, BandStart, XRight, BandStart + 1, fcBias, Levels[L]);
        // Logic row (blue), right-aligned; remaining space is filled out to
        // the bias line with a lighter shade.
        FillPlanRect(XRight - ChunkWidth, BandStart + 1,
          XRight, BandStart + 1 + RowHBlocks, fcLogic, Levels[L]);
        FillPlanRect(1, BandStart + 1,
          XRight - ChunkWidth, BandStart + 1 + RowHBlocks, fcLogicFill, Levels[L]);
        // Bias line above the clock row.
        FillPlanRect(0, BandStart + 1 + RowHBlocks,
          XRight, BandStart + 2 + RowHBlocks, fcBias, Levels[L]);
        // Clock row (green), right-aligned; fill the remainder lighter.
        FillPlanRect(XRight - ChunkWidth, BandStart + 2 + RowHBlocks,
          XRight, BandStart + 2 + 2 * RowHBlocks, fcClock, Levels[L]);
        FillPlanRect(1, BandStart + 2 + RowHBlocks,
          XRight - ChunkWidth, BandStart + 2 + 2 * RowHBlocks, fcClockFill, Levels[L]);
        Inc(Band);
      end;
    end;

    // Snapshot the layout for the ordering animation.
    FPlanCore := Core;
    FPlanLevels := Levels.ToArray;
    FPlanNumLayers := NumLayers;
    FPlanLevelFirstBand := LevelFirstBand;
    FPlanLevelBandCount := LevelBandCount;
    FPlanBandStarts := BandStarts;
    FPlanXRight := XRight;
    FPlanRowHBlocks := RowHBlocks;

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
        PadRec.X := XRight + 1 + RowHBlocks div 2;
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
      CurX[L] := 1; // fill the entire row (from the bias trunk rightwards)
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
            CurX[L] := 1
          else
            CurX[L] := High(Integer);
        end;
        if CurChunk[L] >= LevelBandCount[L] then
        begin
          Inc(FDroppedCells);
          Continue; // no more room for this layer
        end;
        BandIndex := LevelFirstBand[L] + CurChunk[L];
        RowY := BandStarts[BandIndex] + 1 + ((RowHBlocks - P.H) div 2);
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
  Tmp, j, Idx, W, MinX, NextLeft, BandCount, BandHeight, s, e: Integer;
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
          FClockSubtree[L][Node].X := FPlanXRight div 2;
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
          if FClockSubtree[L][Node].X < 1 then
            FClockSubtree[L][Node].X := 1;
          if FClockSubtree[L][Node].X + FClockSubtree[L][Node].W > FPlanXRight then
            FClockSubtree[L][Node].X := FPlanXRight - FClockSubtree[L][Node].W;
          FClockSubtree[L][Node].Y := ClkY - FClockSubtree[L][Node].H div 2;
          if FClockSubtree[L][Node].Y < 0 then
            FClockSubtree[L][Node].Y := 0;
        end
        else
        begin
          FClockSubtree[L][Node].X := FPlanXRight div 2;
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
      Band := (FClockSubtree[L][NodeIdx].Y - 1) div BandHeight -
        FPlanLevelFirstBand[L];
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
    FClockSubtree[L][NodeIdx].Y := FPlanBandStarts[
      FPlanLevelFirstBand[L] + BestBand] + 2 + FPlanRowHBlocks +
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
        FPlanBandStarts[FPlanLevelFirstBand[L]] + 2 + FPlanRowHBlocks +
        FPlanRowHBlocks div 2);
      // Spread the level's network across its wrapped bands: assign each node
      // to the band holding the majority of its descendant leaves, and place
      // interior nodes in that band's clock row. WalkNet appends the root
      // first, so the tree root is its returned value, not the last index.
      if RootNode >= 0 then
      begin
        BandCount := FPlanLevelBandCount[L];
        if BandCount < 1 then
          BandCount := 1;
        BandHeight := 2 + 2 * FPlanRowHBlocks;
        if BandHeight < 1 then
          BandHeight := 1;
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
          MinX := 1;
          for i := s to e - 1 do
          begin
            Idx := Interior[i];
            W := FClockSubtree[L][Idx].W;
            if FClockSubtree[L][Idx].X < MinX then
              FClockSubtree[L][Idx].X := MinX;
            if FClockSubtree[L][Idx].X + W > FPlanXRight then
              FClockSubtree[L][Idx].X := FPlanXRight - W;
            if FClockSubtree[L][Idx].X < 1 then
              FClockSubtree[L][Idx].X := 1;
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
            if FClockSubtree[L][Idx].X < 1 then
              FClockSubtree[L][Idx].X := 1;
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
  i, j, k, L, Lv, NextJ, Cursor, BufY, BestB, TrunkX, BandHeight: Integer;
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
  TrunkX := FPlanXRight + 1;
  BandHeight := 2 + 2 * FPlanRowHBlocks;
  if BandHeight < 1 then
    BandHeight := 1;
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
      SegBottom := FPlanBandStarts[FPlanLevelFirstBand[L] +
        FPlanLevelBandCount[L] - 1] + BandHeight;
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
          ClkY := FPlanBandStarts[k] + 2 + FPlanRowHBlocks +
            FPlanRowHBlocks / 2;
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
        FSpine[j].Y := FPlanBandStarts[BestB] + 2 + FPlanRowHBlocks +
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

end.

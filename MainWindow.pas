unit MainWindow;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.ListBox, FMX.Memo, FMX.Layouts, FMX.TabControl,
  FMX.Objects,
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
  FMX.Memo.Types, FMX.ScrollBox;

type
  TForm1 = class(TForm)
    TabControl1: TTabControl;
    TabItem1: TTabItem;
    WelcomeLabel: TLabel;
    Button1: TButton;
    TabItem2: TTabItem;
    Button3: TButton;
    ListBox1: TListBox;
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
    TabItem5: TTabItem;
    PaintBox1: TPaintBox;
    TrackBar1: TTrackBar;
    LabelMode: TLabel;
    LabelFreqLeft: TLabel;
    LabelFreqRight: TLabel;
    TabItem6: TTabItem;
    Label8: TLabel;
    PaintBox2: TPaintBox;
    ButtonBack: TButton;
    ButtonNext: TButton;
    OpenDialog1: TOpenDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
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
    FClockNet: TClockNetworkInfo; // clock stage registry (top-down)
    FSplittersInserted: Boolean;
    FPanX, FPanY: Single;
    FDragX, FDragY: Single;
    FDragging: Boolean;
    FZoom: Single;
    FClockPanX, FClockPanY: Single;
    FClkDragX, FClkDragY: Single;
    FClkDragging: Boolean;
    FClockZoom: Single;
    procedure FreeLib;
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

procedure TForm1.UpdateUI;
begin
  Button3.Enabled := (FLib <> nil);
  Button5.Enabled := (FLib <> nil);
  ButtonBack.Enabled := (TabControl1.TabIndex > 0);
  ButtonNext.Enabled := (FLib <> nil) and
    (TabControl1.TabIndex < TabControl1.TabCount - 1);
  if TabControl1.TabIndex = 2 then
    ButtonNext.Enabled := ButtonNext.Enabled and
      (FSplitterNames.Count > 0) and (FFlipFlopNames.Count > 0) and
      (FBufferNames.Count > 0);
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FSplitterNames := TStringList.Create;
  FCandidateCells := TList<TCell>.Create;
  FCellDelays := TDictionary<string, Double>.Create;
  FFlipFlopNames := TStringList.Create;
  FFlipFlopCandidates := TList<TCell>.Create;
  FBufferNames := TStringList.Create;
  FBufferCandidates := TList<TCell>.Create;
  ListBox1.OnDblClick := ListBox1DblClick;
  ListBoxSplitters.OnDblClick := ListBoxSplittersDblClick;
  ListBoxDFF.OnDblClick := ListBoxDFFDblClick;
  ListBoxBuffers.OnDblClick := ListBoxBuffersDblClick;
  ListBoxSelected.OnDblClick := ListBoxSelectedDblClick;
  PaintBox1.OnPaint := PaintPipeline;
  PaintBox1.OnMouseDown := PaintBox1MouseDown;
  PaintBox1.OnMouseMove := PaintBox1MouseMove;
  PaintBox1.OnMouseUp := PaintBox1MouseUp;
  PaintBox2.OnPaint := PaintClockNetwork;
  PaintBox2.OnMouseDown := PaintBox2MouseDown;
  PaintBox2.OnMouseMove := PaintBox2MouseMove;
  PaintBox2.OnMouseUp := PaintBox2MouseUp;
  OnMouseWheel := FormMouseWheel;
  FZoom := 1.0;
  FClockZoom := 1.0;
  TabControl1.OnChange := TabControl1Change;
  FSliderPos := 0;
  FSliderTimer := TTimer.Create(Self);
  FSliderTimer.Interval := 200;
  FSliderTimer.Enabled := False;
  FSliderTimer.OnTimer := SliderTimerTimer;
  UpdateModeLabel;
  UpdateLimitLabels;
  UpdateUI;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FSplitterNames.Free;
  FCandidateCells.Free;
  FCellDelays.Free;
  FFlipFlopNames.Free;
  FFlipFlopCandidates.Free;
  FBufferNames.Free;
  FBufferCandidates.Free;
  FSliderTimer.Free;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  FreeLib;
end;

procedure TForm1.Button1Click(Sender: TObject);
var
  Lib: TLibrary;
  i: Integer;
begin
  OpenDialog1.Filter := 'LEF files (*.lef)|*.lef|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;

  FLefFile := OpenDialog1.FileName;
  FreeLib; // a new LEF file invalidates the previously parsed library
  FSplittersInserted := False;
  FreePipelineRows;
  FreePipelineModel;
  FreeClockModel;
  UpdateLimitLabels;
  ListBox1.Clear;
  Memo1.Lines.Clear;
  FSplitterNames.Clear;
  FCandidateCells.Clear;
  FCellDelays.Clear;
  FFlipFlopNames.Clear;
  FFlipFlopCandidates.Clear;
  FBufferNames.Clear;
  FBufferCandidates.Clear;
  Label1.Text := 'Parsing: ' + ExtractFileName(FLefFile);

  try
    Lib := LoadLefLibrary(FLefFile);
  except
    on E: Exception do
    begin
      ShowMessage('Failed to parse LEF file:' + sLineBreak + sLineBreak + E.Message);
      UpdateUI;
      Exit;
    end;
  end;

  FLib := Lib;
  for i := 0 to FLib.Cells.Count - 1 do
    ListBox1.Items.Add(FLib.Cells[i].Name);
  Label1.Text := Format('Loaded %d cell(s) from %s',
    [FLib.Cells.Count, ExtractFileName(FLefFile)]);
  UpdateUI;
end;

procedure TForm1.Button3Click(Sender: TObject);
var
  Folder: string;
  Cell: TCell;
  CellsWithMatches, TotalFiles: Integer;
begin
  if FLib = nil then
    Exit;

  Folder := FCellFolder;
  if not SelectDirectory('Select folder containing cell source files', '', Folder) then
    Exit;
  FCellFolder := Folder;

  if not TDirectory.Exists(FCellFolder) then
  begin
    ShowMessage('Cell folder no longer exists.');
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

procedure TForm1.Button5Click(Sender: TObject);
var
  Errors: TStringList;
begin
  if FLib = nil then
    Exit;

  OpenDialog1.Filter := 'BLIF files (*.blif)|*.blif|All files (*.*)|*.*';
  OpenDialog1.FilterIndex := 1;
  if not OpenDialog1.Execute then
    Exit;

  FBlifFile := OpenDialog1.FileName;
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
        ShowMessage('Failed to parse BLIF file:' + sLineBreak + sLineBreak + E.Message);
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

procedure TForm1.FormMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; var Handled: Boolean);
const
  MinZoom = 0.2;
  MaxZoom = 5.0;

  // Zoom around the cursor position; returns True if the zoom changed.
  function ZoomAt(ABox: TControl; var APanX, APanY, AZoom: Single): Boolean;
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
    if NewZoom < MinZoom then
      NewZoom := MinZoom;
    if NewZoom > MaxZoom then
      NewZoom := MaxZoom;
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
  if TabControl1.TabIndex = 3 then
  begin
    if ZoomAt(PaintBox1, FPanX, FPanY, FZoom) then
    begin
      Handled := True;
      RepaintPipelinePage;
    end;
  end
  else if TabControl1.TabIndex = 4 then
  begin
    if ZoomAt(PaintBox2, FClockPanX, FClockPanY, FClockZoom) then
    begin
      Handled := True;
      RepaintClockPage;
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
  if TabControl1.TabIndex <> 3 then
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
  if TabControl1.TabIndex <> 3 then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.RepaintClockPage;
begin
  if TabControl1.TabIndex <> 4 then
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
  TrunkX, TreeX0, ColGap, LayerStep, Sq, RootY, YMid, StageDelay, XCur: Single;
  TapNetName, DelayTxt, LevelTxt: string;
  Roots: TObjectList<TClockTreeNode>;
  RootYs: TArray<Single>;
  RowHeights: TArray<Single>;
  MaxDepths: TArray<Integer>;
  Node, RootSplitter: TClockTreeNode;
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
  const
    THICK = 1.6;
  var
    Steps, i: Integer;
    t, X, Y: Single;
  begin
    Canvas.Fill.Color := $FF555555;
    if Abs(X2 - X1) < 0.5 then
      Canvas.FillRect(TRectF.Create(
        WX(X1) - WLen(THICK) / 2, WY(Min(Y1, Y2)),
        WX(X1) + WLen(THICK) / 2, WY(Max(Y1, Y2))), 0, 0, [], 1.0)
    else if Abs(Y2 - Y1) < 0.5 then
      Canvas.FillRect(TRectF.Create(
        WX(Min(X1, X2)) - WLen(THICK) / 2, WY(Y1) - WLen(THICK) / 2,
        WX(Max(X1, X2)) + WLen(THICK) / 2, WY(Y1) + WLen(THICK) / 2), 0, 0, [], 1.0)
    else
    begin
      Steps := Ceil(Max(Abs(X2 - X1), Abs(Y2 - Y1)) / 2);
      if Steps < 1 then
        Steps := 1;
      for i := 0 to Steps do
      begin
        t := i / Steps;
        X := X1 + (X2 - X1) * t;
        Y := Y1 + (Y2 - Y1) * t;
        Canvas.FillRect(TRectF.Create(WX(X) - WLen(THICK) / 2,
          WY(Y) - WLen(THICK) / 2, WX(X) + WLen(THICK) / 2,
          WY(Y) + WLen(THICK) / 2), 0, 0, [], 1.0);
      end;
    end;
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

    Canvas.Stroke.Color := $FF9E9E9E;
    Canvas.Stroke.Thickness := 1;

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
          // The tree root must be the row's root SPLITTER, not whichever
          // gate happens to sit first on the tap net.
          RootSplitter := nil;
          for i := 0 to Node.Children.Count - 1 do
            if Node.Children[i].Children.Count > 0 then
            begin
              RootSplitter := Node.Children[i];
              Break;
            end;
          if RootSplitter = nil then
            RootSplitter := Node.Children[0];

          RootSplitter.X := TrunkX;
          RootSplitter.Y := RootYs[rIdx];
          RootSplitter.Depth := 0;
          LevelCols.Clear;
          // Junction's outA child (the row tree root / lone gate) grows
          // right of the trunk; LayoutSubtree floors it at the junction's
          // own column via the BaseCol=0 start.
          for i := 0 to RootSplitter.Children.Count - 1 do
            LayoutSubtree(RootSplitter.Children[i], 1, 0, RootYs[rIdx]);
          DrawEdges(RootSplitter);
          DrawNodes(RootSplitter);
        end;
      end;
    finally
      LevelCols.Free;
    end;

    Canvas.Stroke.Color := $FF9E9E9E;

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
  if TabControl1.TabIndex = 2 then
    PopulateSelectionTab;
  if TabControl1.TabIndex = 3 then
  begin
    FPanX := 0;
    FPanY := 0;
    FZoom := 1.0;
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
  if TabControl1.TabIndex = 4 then
  begin
    // Clock stage: always rebuild from the current DFF-inserted netlist.
    FClockPanX := 0;
    FClockPanY := 0;
    FClockZoom := 1.0;
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
  if (TabControl1.TabIndex = 3) and (FPipelineModel <> nil) and
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
  // Leaving the selection tab runs the splitter insertion automatically.
  if (TabControl1.TabIndex = 2) and (not FSplittersInserted) then
    RunSplitterInsertion;
  if TabControl1.TabIndex < TabControl1.TabCount - 1 then
    TabControl1.TabIndex := TabControl1.TabIndex + 1;
  UpdateUI;
end;

end.

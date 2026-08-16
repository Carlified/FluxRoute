unit MainWindow;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Controls.Presentation, FMX.ListBox, FMX.Memo, FMX.Layouts, FMX.TabControl,
  FMX.Objects,
  System.IOUtils, System.JSON, System.Math, System.Math.Vectors,
  System.Generics.Collections, System.StrUtils,
  Winapi.Windows,
  LefLibrary,
  BlifLibrary,
  CellViewer,
  VerilogTiming,
  SplitterInsert,
  PipelineConfig,
  PipelineAnalysis,
  FlipFlopInsert, FMX.Memo.Types, FMX.ScrollBox;

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
    Label3: TLabel;
    ListBox2: TListBox;
    Label4: TLabel;
    ListBox3: TListBox;
    ButtonSplit: TButton;
    TabItem4: TTabItem;
    Label5: TLabel;
    Label6: TLabel;
    ListBox4: TListBox;
    Label7: TLabel;
    ListBox5: TListBox;
    TabItem5: TTabItem;
    PaintBox1: TPaintBox;
    TrackBar1: TTrackBar;
    ButtonBack: TButton;
    ButtonNext: TButton;
    OpenDialog1: TOpenDialog;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure Button1Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure ListBox1DblClick(Sender: TObject);
    procedure ListBox2DblClick(Sender: TObject);
    procedure ListBox3DblClick(Sender: TObject);
    procedure ListBox4DblClick(Sender: TObject);
    procedure ListBox5DblClick(Sender: TObject);
    procedure TabControl1Change(Sender: TObject);
    procedure TrackBar1Change(Sender: TObject);
    procedure ButtonSplitClick(Sender: TObject);
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
    FPipelineRows: TArray<TList<TGateInstance>>;
    FPipelineModels: TArray<TBlifModel>;
    FStrategyIndex: Integer;
    FSliderUpdating: Boolean;
    FSplittersInserted: Boolean;
    FPanX, FPanY: Single;
    FDragX, FDragY: Single;
    FDragging: Boolean;
    procedure FreeLib;
    procedure UpdateUI;
    procedure RenderNetlist(Model: TBlifModel; Errors: TStrings);
    function IsSplitterCandidate(const Cell: TCell; out NumOutputs: Integer): Boolean;
    function CellDelayPs(const Cell: TCell): Double;
    function DelayTextPs(const Delay: Double): string;
    procedure PopulateSplitterList;
    procedure RefreshSplitterList;
    procedure PopulateFlipFlopList;
    procedure RefreshFlipFlopList;
    procedure FreePipelineRows;
    procedure BuildPipelineRows(const AModel: TBlifModel);
    procedure PaintPipeline(Sender: TObject; Canvas: TCanvas);
    procedure FreePipelineModels;
    procedure BuildPipelineModels;
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
  ButtonSplit.Enabled := (FModel <> nil) and (FSplitterNames.Count > 0);
  ButtonBack.Enabled := (TabControl1.TabIndex > 0);
  ButtonNext.Enabled := (FLib <> nil) and
    (TabControl1.TabIndex < TabControl1.TabCount - 1);
  if TabControl1.TabIndex = 2 then
    ButtonNext.Enabled := ButtonNext.Enabled and FSplittersInserted;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FSplitterNames := TStringList.Create;
  FCandidateCells := TList<TCell>.Create;
  FCellDelays := TDictionary<string, Double>.Create;
  FFlipFlopNames := TStringList.Create;
  FFlipFlopCandidates := TList<TCell>.Create;
  ListBox1.OnDblClick := ListBox1DblClick;
  ListBox2.OnDblClick := ListBox2DblClick;
  ListBox3.OnDblClick := ListBox3DblClick;
  ListBox4.OnDblClick := ListBox4DblClick;
  ListBox5.OnDblClick := ListBox5DblClick;
  PaintBox1.OnPaint := PaintPipeline;
  PaintBox1.OnMouseDown := PaintBox1MouseDown;
  PaintBox1.OnMouseMove := PaintBox1MouseMove;
  PaintBox1.OnMouseUp := PaintBox1MouseUp;
  TabControl1.OnChange := TabControl1Change;
  FStrategyIndex := 0;
  UpdateUI;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FSplitterNames.Free;
  FCandidateCells.Free;
  FCellDelays.Free;
  FFlipFlopNames.Free;
  FFlipFlopCandidates.Free;
  FreePipelineRows;
  FreePipelineModels;
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
  FreePipelineModels;
  ListBox1.Clear;
  Memo1.Lines.Clear;
  FSplitterNames.Clear;
  FCandidateCells.Clear;
  FCellDelays.Clear;
  FFlipFlopNames.Clear;
  FFlipFlopCandidates.Clear;
  ListBox2.Clear;
  ListBox3.Clear;
  ListBox4.Clear;
  ListBox5.Clear;
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
  FreePipelineModels;
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

procedure TForm1.RefreshSplitterList;
var
  i: Integer;
  Cell: TCell;
  NumOutputs: Integer;
  Delay: Double;
begin
  ListBox3.Clear;
  for i := 0 to FSplitterNames.Count - 1 do
  begin
    if FLib = nil then
      Break;
    Cell := FLib.FindCell(FSplitterNames[i]);
    if (Cell = nil) or not IsSplitterCandidate(Cell, NumOutputs) then
      Continue;
    Delay := CellDelayPs(Cell);
    ListBox3.Items.Add(Format('%s (%d-way, %s)',
      [Cell.Name, NumOutputs, DelayTextPs(Delay)]));
  end;
end;

procedure TForm1.PopulateSplitterList;
var
  i: Integer;
  Cell: TCell;
  NumOutputs: Integer;
  Delay: Double;
begin
  ListBox2.Clear;
  FCandidateCells.Clear;
  RefreshSplitterList;
  if FLib = nil then
    Exit;
  for i := 0 to FLib.Cells.Count - 1 do
  begin
    Cell := FLib.Cells[i];
    if IsSplitterCandidate(Cell, NumOutputs) then
    begin
      Delay := CellDelayPs(Cell);
      ListBox2.Items.Add(Format('%s (%d outputs, %s)',
        [Cell.Name, NumOutputs, DelayTextPs(Delay)]));
      FCandidateCells.Add(Cell);
    end;
  end;
  if ListBox2.Items.Count = 0 then
    ListBox2.Items.Add('(no splitter cells: need 1 input, 2+ outputs)');
end;

procedure TForm1.ListBox2DblClick(Sender: TObject);
var
  Cell: TCell;
begin
  if (ListBox2.ItemIndex < 0) or (ListBox2.ItemIndex >= FCandidateCells.Count) then
    Exit;
  Cell := FCandidateCells[ListBox2.ItemIndex];
  if FSplitterNames.IndexOf(Cell.Name) < 0 then
  begin
    FSplitterNames.Add(Cell.Name);
    RefreshSplitterList;
    UpdateUI;
  end;
end;

procedure TForm1.ListBox3DblClick(Sender: TObject);
begin
  if (ListBox3.ItemIndex < 0) or (ListBox3.ItemIndex >= FSplitterNames.Count) then
    Exit;
  FSplitterNames.Delete(ListBox3.ItemIndex);
  RefreshSplitterList;
  UpdateUI;
end;

procedure TForm1.RefreshFlipFlopList;
var
  i: Integer;
  Cell: TCell;
  ClockPin, DataPin, OutputPin: string;
  Delay: Double;
begin
  ListBox5.Clear;
  for i := 0 to FFlipFlopNames.Count - 1 do
  begin
    if FLib = nil then
      Break;
    Cell := FLib.FindCell(FFlipFlopNames[i]);
    if (Cell = nil) or not IsFlipFlopCandidate(Cell, ClockPin, DataPin, OutputPin) then
      Continue;
    Delay := CellDelayPs(Cell);
    ListBox5.Items.Add(Format('%s (%s, %s -> %s, %s)',
      [Cell.Name, DataPin, ClockPin, OutputPin, DelayTextPs(Delay)]));
  end;
end;

procedure TForm1.PopulateFlipFlopList;
var
  i: Integer;
  Cell: TCell;
  ClockPin, DataPin, OutputPin: string;
  Delay: Double;
begin
  ListBox4.Clear;
  FFlipFlopCandidates.Clear;
  RefreshFlipFlopList;
  if FLib = nil then
    Exit;
  for i := 0 to FLib.Cells.Count - 1 do
  begin
    Cell := FLib.Cells[i];
    if IsFlipFlopCandidate(Cell, ClockPin, DataPin, OutputPin) then
    begin
      Delay := CellDelayPs(Cell);
      ListBox4.Items.Add(Format('%s (%s, %s -> %s, %s)',
        [Cell.Name, DataPin, ClockPin, OutputPin, DelayTextPs(Delay)]));
      FFlipFlopCandidates.Add(Cell);
    end;
  end;
  if ListBox4.Items.Count = 0 then
    ListBox4.Items.Add(
      '(no flip-flop cells: need 2 inputs, 1 output, one input named clk/clock)');
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
  i, j: Integer;
  Gate, Src: TGateInstance;
  MaxCells, MaxRows, MaxOutputLevel: Integer;
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
  OutName: string;
  OutLevel, RowGateCount: Integer;
  LevelDelay, MaxLevelDelay, TotalArea, GateArea, RecvDelay: Double;
  LevelIdx, TotalLevels, k: Integer;
  StatsText: string;
  StatsR: TRectF;
  DelayMemo: TDictionary<TGateInstance, Double>;

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
      Result := 0;
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
begin
  R := TRectF.Create(0, 0, PaintBox1.Width, PaintBox1.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  ActiveModel := FModel;
  if (FStrategyIndex = 0) and (Length(FPipelineModels) > 0) then
    ActiveModel := FPipelineModels[0]
  else if (FStrategyIndex >= 1) and (Length(FPipelineModels) > 1) then
    ActiveModel := FPipelineModels[1];

  Note := '';
  if (ActiveModel <> nil) and (FFlipFlopNames.Count = 0) then
    Note := 'No flip-flop cells selected on the Flip-flops page.';

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

    // Compute MaxCells and MaxRows, accounting for inputs and outputs.
    MaxRows := Length(FPipelineRows);
    if MaxOutputLevel >= MaxRows then
      MaxRows := MaxOutputLevel + 1;
    if MaxRows = 0 then
      MaxRows := 1;

    MaxCells := 1;
    for i := 0 to MaxRows - 1 do
    begin
      RowGateCount := 0;
      if i <= High(FPipelineRows) then
        RowGateCount := FPipelineRows[i].Count;
      if i = 0 then
        RowGateCount := RowGateCount + InputNets.Count;
      for j := 0 to OutputLevels.Count - 1 do
        if OutputLevels[j] = i then
          Inc(RowGateCount);
      if RowGateCount > MaxCells then
        MaxCells := RowGateCount;
    end;

    HGap := 4;
    VGap := 4;
    Left := 40;
    Square := 18;

    // Draw rows: inputs (yellow) at level 0, gates (coloured), outputs (purple) at driver+1.
    for i := 0 to MaxRows - 1 do
    begin
      Y := FPanY + 4 + i * (Square + VGap);
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(TRectF.Create(FPanX, Y, FPanX + Left - 6, Y + Square),
        IntToStr(i), False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
      X := FPanX + Left;

      // Primary inputs at level 0.
      if i = 0 then
        for j := 0 to InputNets.Count - 1 do
        begin
          Canvas.Fill.Color := $FFFFEB3B;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          InputPositions.AddOrSetValue(InputNets[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
          X := X + Square + HGap;
        end;

      // Gates at this level.
      if i <= High(FPipelineRows) then
        for j := 0 to FPipelineRows[i].Count - 1 do
        begin
          Gate := FPipelineRows[i][j];
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
          X := X + Square + HGap;
        end;

      // Primary outputs at this level.
      for j := 0 to OutputLevels.Count - 1 do
        if OutputLevels[j] = i then
        begin
          Canvas.Fill.Color := $FF9C27B0;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          OutputPositions.AddOrSetValue(OutputNets[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
          X := X + Square + HGap;
        end;
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
      // from any register/PI at level L-1 to any register at level L.
      for LevelIdx := 0 to MaxRows - 1 do
      begin
        LevelDelay := 0;
        if LevelIdx <= High(FPipelineRows) then
          for j := 0 to FPipelineRows[LevelIdx].Count - 1 do
          begin
            Gate := FPipelineRows[LevelIdx][j];
            RecvDelay := CellDelayPs(Gate.Cell);
            if RecvDelay < 0 then RecvDelay := 0;
            for k := 0 to Gate.Connections.Count - 1 do
            begin
              Conn := Gate.Connections[k];
              if Conn.Port.Direction <> pdInput then Continue;
              if IsClockPinName(Conn.Port.Name) then Continue;
              if ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
                for NC in Net.Connections do
                  if NC.IsDriver then
                  begin
                    GateArea := DelayToOutput(NC.Gate) + RecvDelay;
                    if GateArea > LevelDelay then
                      LevelDelay := GateArea;
                  end;
            end;
          end;
        if LevelDelay > MaxLevelDelay then
          MaxLevelDelay := LevelDelay;
      end;
    finally
      DelayMemo.Free;
    end;

    if MaxLevelDelay > 0 then
      StatsText := Format(
        'Levels: %d  |  Worst path/level: %.1f ps  |  Fmax: %.1f GHz  |  Throughput: %.1f GLPS  |  Area: %.1f um2',
        [TotalLevels, MaxLevelDelay,
         1000.0 / MaxLevelDelay,
         1000.0 / MaxLevelDelay * TotalLevels,
         TotalArea])
    else
      StatsText := Format(
        'Levels: %d  |  Worst path/level: (no timing)  |  Area: %.1f um2',
        [TotalLevels, TotalArea]);

    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    StatsR := TRectF.Create(4, PaintBox1.Height - 22, PaintBox1.Width - 4, PaintBox1.Height - 2);
    Canvas.FillText(StatsR, StatsText, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);

  finally
    InputNets.Free;
    OutputNets.Free;
    OutputLevels.Free;
    InputPositions.Free;
    OutputPositions.Free;
    GateCenters.Free;
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
    PaintBox1.Repaint;
  end;
end;

procedure TForm1.PaintBox1MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FDragging := False;
end;

procedure TForm1.FreePipelineModels;
var
  i: Integer;
begin
  for i := 0 to High(FPipelineModels) do
    FPipelineModels[i].Free;
  FPipelineModels := nil;
end;

procedure TForm1.BuildPipelineModels;
var
  Dummy: TStringList;
  MaxDelay, Delay: Double;
  Gate: TGateInstance;
begin
  FreePipelineModels;
  if FModel = nil then
    Exit;
  SetLength(FPipelineModels, 2);
  FPipelineModels[0] := FModel.Clone;
  FPipelineModels[1] := FModel.Clone;
  if (FLib <> nil) and (FFlipFlopNames.Count > 0) then
  begin
    // [0] = compact: clock-level gap-filling with merge
    InsertCompactFlipFlops(FPipelineModels[0], FLib, FFlipFlopNames[0]);
    Dummy := TStringList.Create;
    try
      ComputeClockLevels(FPipelineModels[0], Dummy);
      PadOutputFFs(FPipelineModels[0], FLib, FFlipFlopNames[0]);
      ComputeClockLevels(FPipelineModels[0], Dummy);
    finally
      Dummy.Free;
    end;

    // [1] = maximum speed: delay-levelization; threshold = max cell delay
    MaxDelay := 1;
    for Gate in FPipelineModels[1].Gates do
    begin
      Delay := CellDelayPs(Gate.Cell);
      if (Delay > 0) and (Delay > MaxDelay) then
        MaxDelay := Delay;
    end;
    InsertDelayLevelizedFFs(FPipelineModels[1], FLib, FFlipFlopNames[0], MaxDelay);
    PadOutputFFs(FPipelineModels[1], FLib, FFlipFlopNames[0]);
  end;
end;

procedure TForm1.TrackBar1Change(Sender: TObject);
begin
  if FSliderUpdating then
    Exit;
  FSliderUpdating := True;
  try
    TrackBar1.Value := Round(TrackBar1.Value);
  finally
    FSliderUpdating := False;
  end;
  if FStrategyIndex <> Trunc(TrackBar1.Value) then
  begin
    FStrategyIndex := Trunc(TrackBar1.Value);
    PaintBox1.Repaint;
  end;
end;

procedure TForm1.ListBox4DblClick(Sender: TObject);
var
  Cell: TCell;
begin
  if (ListBox4.ItemIndex < 0) or (ListBox4.ItemIndex >= FFlipFlopCandidates.Count) then
    Exit;
  Cell := FFlipFlopCandidates[ListBox4.ItemIndex];
  if FFlipFlopNames.IndexOf(Cell.Name) < 0 then
  begin
    FFlipFlopNames.Add(Cell.Name);
    RefreshFlipFlopList;
  end;
end;

procedure TForm1.ListBox5DblClick(Sender: TObject);
begin
  if (ListBox5.ItemIndex < 0) or (ListBox5.ItemIndex >= FFlipFlopNames.Count) then
    Exit;
  FFlipFlopNames.Delete(ListBox5.ItemIndex);
  RefreshFlipFlopList;
end;

procedure TForm1.TabControl1Change(Sender: TObject);
begin
  if TabControl1.TabIndex = 2 then
    PopulateSplitterList;
  if TabControl1.TabIndex = 3 then
    PopulateFlipFlopList;
  if TabControl1.TabIndex = 4 then
  begin
    FPanX := 0;
    FPanY := 0;
    BuildPipelineModels;
    PaintBox1.Repaint;
  end;
  UpdateUI;
end;

procedure TForm1.ButtonSplitClick(Sender: TObject);
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
  begin
    Label1.Text := Format('Inserted %d splitter(s) into the netlist.', [Inserted]);
    FSplittersInserted := True;
  end
  else
    Label1.Text := 'No splitters needed (no net has fanout > 1).';

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
  i: Integer;
  Gate: TGateInstance;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  NetName: string;
  Line: string;
begin
  Dump := TStringList.Create;
  try
    Dump.Add('Model: ' + Model.Name);
    Dump.Add('');
    Dump.Add('Primary inputs: ' + Model.Inputs.CommaText);
    Dump.Add('Primary outputs: ' + Model.Outputs.CommaText);
    Dump.Add('');

    Dump.Add(Format('Gates (%d):', [Model.Gates.Count]));
    for i := 0 to Model.Gates.Count - 1 do
    begin
      Gate := Model.Gates[i];
      Line := Format('  %2d. %s', [i + 1, Gate.CellName]);
      for Conn in Gate.Connections do
        Line := Line + Format('  %s=%s', [Conn.PinName, Conn.NetName]);
      Dump.Add(Line);
    end;
    Dump.Add('');

    Dump.Add(Format('Nets (%d):', [Model.Nets.Count]));
    for NetName in Model.Nets.Keys do
    begin
      Net := Model.Nets[NetName];
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
  if TabControl1.TabIndex < TabControl1.TabCount - 1 then
    TabControl1.TabIndex := TabControl1.TabIndex + 1;
  UpdateUI;
end;

end.

unit CellViewer;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.StdCtrls,
  FMX.Layouts, FMX.ListBox, FMX.Objects,
  System.IOUtils, System.JSON, System.Math, System.Math.Vectors,
  System.Generics.Collections, System.StrUtils,
  {$IF DEFINED(MSWINDOWS)}
  Winapi.Windows,
  {$ELSE}
  Posix.Unistd,
  Posix.SysWait,
  {$ENDIF}
  LefLibrary,
  VerilogTiming;

type
  TPolygonShape = record
    CellName: string;
    Layer: Integer;
    Points: TArray<TPointF>;
  end;

  // Exposes the protected Capture/ReleaseCapture so the drag can keep
  // receiving mouse moves once the cursor leaves the 5px bar.
  TCellViewerSplitter = class(TRectangle)
  public
    procedure GrabMouse;
    procedure ReleaseMouse;
  end;

  // Popup window showing a single cell's GDS polygons next to the list of
  // source files linked to that cell. Built entirely in code (no .fmx).
  TCellViewerForm = class(TForm)
  private
    FCell: TCell;
    FShapes: TArray<TPolygonShape>;
    FBounds: TRectF;
    FStatus: TLabel;
    FDockLayout: TLayout;
    FFilesBox: TListBox;
    FFilesSplitter: TCellViewerSplitter;
    FPaintBox: TPaintBox;
    FSplitterDragging: Boolean;
    FDownAbs: TPointF;
    FSplitterStartWidth: Single;
    procedure SplitterMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure SplitterMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Single);
    procedure SplitterMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure PaintShapes(Sender: TObject; Canvas: TCanvas);
    procedure LoadCellGds;
    procedure BuildCellInfo(const Cell: TCell; Lines: TStrings);
    procedure AppendPortGroup(Lines: TStrings; const Title: string;
      Entries: TStrings);
  protected
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetCell(ACell: TCell);
  end;

// Shared GDS helpers (kept here so the main form stays slim).
function FindPythonExe: string;
function FindScriptPath: string;
function RunProcess(const Exe, Args, StdErrFile: string;
  out ErrMsg: string): Integer;
// Runs gds_to_json.py on AFileName and parses the result. Returns '' on
// success (Shapes/Bounds filled), or an error message on failure.
function LoadGdsShapes(const GdsFile: string;
  out Shapes: TArray<TPolygonShape>; out Bounds: TRectF): string;

implementation

function FindPythonExe: string;
var
  Cand, PathStr: string;
  Dirs: TArray<string>;
  D: string;
{$IF DEFINED(MSWINDOWS)}
  Local: string;
{$ENDIF}
begin
  Result := '';
  {$IF DEFINED(MSWINDOWS)}
  Local := GetEnvironmentVariable('LOCALAPPDATA');

  Cand := Local + '\Python\pythoncore-3.14-64\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := Local + '\Programs\Python\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := 'C:\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := 'C:\Python\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);

  PathStr := GetEnvironmentVariable('PATH');
  Dirs := PathStr.Split([';'], TStringSplitOptions.ExcludeEmpty);
  for D in Dirs do
  begin
    if UpperCase(D).IndexOf('WINDOWSAPPS') >= 0 then
      Continue; // app-execution alias shim, not a real interpreter
    Cand := TPath.Combine(D, 'python.exe');
    if FileExists(Cand) then Exit(Cand);
  end;
  {$ELSE}
  // macOS/Linux: common interpreter locations, then PATH.
  Cand := '/opt/homebrew/bin/python3';
  if FileExists(Cand) then Exit(Cand);
  Cand := '/usr/local/bin/python3';
  if FileExists(Cand) then Exit(Cand);
  Cand := '/usr/bin/python3';
  if FileExists(Cand) then Exit(Cand);

  PathStr := GetEnvironmentVariable('PATH');
  Dirs := PathStr.Split([':'], TStringSplitOptions.ExcludeEmpty);
  for D in Dirs do
  begin
    Cand := TPath.Combine(D, 'python3');
    if FileExists(Cand) then Exit(Cand);
  end;
  {$ENDIF}
end;

function FindScriptPath: string;
var
  Dir: string;
  i: Integer;
begin
  Result := '';

  // running from the IDE usually means the working directory is the project
  Dir := IncludeTrailingPathDelimiter(GetCurrentDir);
  if FileExists(Dir + 'gds_to_json.py') then
    Exit(Dir + 'gds_to_json.py');

  // otherwise walk up from the exe (Win32\Debug -> Win32 -> project root, ...)
  Dir := ExtractFilePath(GetModuleName(HInstance));
  for i := 0 to 6 do
  begin
    if FileExists(Dir + 'gds_to_json.py') then
      Exit(Dir + 'gds_to_json.py');
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then Break;
  end;
end;

function RunProcess(const Exe, Args, StdErrFile: string;
  out ErrMsg: string): Integer;
{$IF DEFINED(MSWINDOWS)}
var
  CmdLine: string;
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  HErr: THandle;
  ExitCode: Cardinal;
begin
  Result := -1;
  ErrMsg := '';
  CmdLine := '"' + Exe + '" ' + Args;

  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := nil;
  SA.bInheritHandle := True;

  HErr := CreateFile(PChar(StdErrFile), GENERIC_WRITE, FILE_SHARE_WRITE, @SA,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if HErr = INVALID_HANDLE_VALUE then
  begin
    ErrMsg := 'Could not create output file: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := HErr;
  SI.hStdError := HErr;

  FillChar(PI, SizeOf(PI), 0);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(HErr);
    ErrMsg := 'CreateProcess failed: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  CloseHandle(HErr);
  WaitForSingleObject(PI.hProcess, INFINITE);
  GetExitCodeProcess(PI.hProcess, ExitCode);
  Result := Integer(ExitCode);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);

  if Result <> 0 then
  begin
    if FileExists(StdErrFile) then
      ErrMsg := Trim(TFile.ReadAllText(StdErrFile))
    else
      ErrMsg := Format('Python exited with code %d.', [Result]);
  end;
end;
{$ELSE}
var
  CmdLine: string;
  PID, Status: Integer;
begin
  Result := -1;
  ErrMsg := '';

  // /bin/sh performs the stderr redirection for us; the caller already
  // wraps every path argument in double quotes.
  CmdLine := Format('%s %s 2>"%s"', [Exe, Args, StdErrFile]);

  PID := fork;
  if PID < 0 then
  begin
    ErrMsg := 'fork failed.';
    Exit;
  end;
  if PID = 0 then
  begin
    execl(PAnsiChar(UTF8String('/bin/sh')),
          PAnsiChar(UTF8String('sh')),
          PAnsiChar(UTF8String('-c')),
          PAnsiChar(UTF8String(CmdLine)),
          nil);
    _exit(127); // exec never returns on success
  end;

  waitpid(PID, @Status, 0);
  if (Status and $7F) = 0 then
    Result := (Status shr 8) and $FF // WEXITSTATUS
  else
    Result := -1;

  if Result <> 0 then
  begin
    if FileExists(StdErrFile) then
      ErrMsg := Trim(TFile.ReadAllText(StdErrFile))
    else
      ErrMsg := Format('Python exited with code %d.', [Result]);
  end;
end;
{$ENDIF}

function LoadGdsShapes(const GdsFile: string;
  out Shapes: TArray<TPolygonShape>; out Bounds: TRectF): string;
var
  PyExe, Script, JsonPath, ErrMsg: string;
  ExitCode: Integer;
  Root: TJSONObject;
  Cells, Polys, Pts: TJSONArray;
  CellObj, PolyObj: TJSONObject;
  Shape: TPolygonShape;
  i, j, k: Integer;
  P: TPointF;
  TargetCell: string;
  CellFound: Boolean;
  AllShapes: TArray<TPolygonShape>;
begin
  Result := '';
  Shapes := nil;
  Bounds := TRectF.Empty;

  PyExe := FindPythonExe;
  if PyExe = '' then
    Exit('Python was not found. Install Python 3 with gdstk installed.');

  Script := FindScriptPath;
  if Script = '' then
    Exit('gds_to_json.py was not found next to the application.');

  JsonPath := TPath.Combine(TPath.GetTempPath,
    'pnr_cell_' + IntToStr(TThread.GetTickCount) + '.json');

  ExitCode := RunProcess(PyExe,
    Format('"%s" "%s" "%s"', [Script, GdsFile, JsonPath]),
    ChangeFileExt(JsonPath, '.err'), ErrMsg);

  if ExitCode <> 0 then
    Exit('gds_to_json failed: ' + ErrMsg);

  Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(JsonPath)) as TJSONObject;
  if Root = nil then
    Exit('Could not parse the JSON produced by gds_to_json.');
  try
    Cells := Root.GetValue('cells') as TJSONArray;
    if Cells = nil then
      Exit('The GDS file contains no top-level cells.');

    for i := 0 to Cells.Count - 1 do
    begin
      CellObj := Cells[i] as TJSONObject;
      Polys := CellObj.GetValue('polygons') as TJSONArray;
      if Polys = nil then Continue;

      for j := 0 to Polys.Count - 1 do
      begin
        PolyObj := Polys[j] as TJSONObject;
        Shape.CellName := CellObj.GetValue<string>('name');
        Shape.Layer := PolyObj.GetValue<Integer>('layer');

        Pts := PolyObj.GetValue('points') as TJSONArray;
        if Pts = nil then Continue;
        SetLength(Shape.Points, Pts.Count);
        for k := 0 to Pts.Count - 1 do
        begin
          Shape.Points[k].X := ((Pts.Items[k] as TJSONArray).Items[0] as TJSONNumber).AsDouble;
          Shape.Points[k].Y := ((Pts.Items[k] as TJSONArray).Items[1] as TJSONNumber).AsDouble;
        end;

        SetLength(AllShapes, Length(AllShapes) + 1);
        AllShapes[High(AllShapes)] := Shape;
      end;
    end;
  finally
    Root.Free;
  end;

  // prefer the cell whose name matches the GDS file stem; otherwise keep all
  TargetCell := ChangeFileExt(ExtractFileName(GdsFile), '');
  CellFound := False;
  for i := 0 to High(AllShapes) do
    if SameText(AllShapes[i].CellName, TargetCell) then
    begin
      CellFound := True;
      Break;
    end;

  if CellFound then
  begin
    Shapes := nil;
    for i := 0 to High(AllShapes) do
      if SameText(AllShapes[i].CellName, TargetCell) then
      begin
        SetLength(Shapes, Length(Shapes) + 1);
        Shapes[High(Shapes)] := AllShapes[i];
      end;
  end
  else
    Shapes := AllShapes;

  try TFile.Delete(JsonPath); except end;
  try TFile.Delete(ChangeFileExt(JsonPath, '.err')); except end;

  if Length(Shapes) > 0 then
  begin
    Bounds := TRectF.Create(Shapes[0].Points[0].X, Shapes[0].Points[0].Y,
      Shapes[0].Points[0].X, Shapes[0].Points[0].Y);
    for i := 0 to High(Shapes) do
      for k := 0 to High(Shapes[i].Points) do
      begin
        P := Shapes[i].Points[k];
        if P.X < Bounds.Left then Bounds.Left := P.X;
        if P.Y < Bounds.Top then Bounds.Top := P.Y;
        if P.X > Bounds.Right then Bounds.Right := P.X;
        if P.Y > Bounds.Bottom then Bounds.Bottom := P.Y;
      end;
  end;
end;

{ TCellViewerSplitter }

procedure TCellViewerSplitter.GrabMouse;
begin
  Capture;
end;

procedure TCellViewerSplitter.ReleaseMouse;
begin
  ReleaseCapture;
end;

{ TCellViewerForm }

procedure TCellViewerForm.DoClose(var CloseAction: TCloseAction);
begin
  CloseAction := TCloseAction.caFree;
end;

constructor TCellViewerForm.Create(AOwner: TComponent);
begin
  // CreateNew skips the .fmx resource lookup (this form is built in code)
  inherited CreateNew(AOwner);

  Caption := 'Cell Viewer';
  ClientWidth := 900;
  ClientHeight := 600;
  Position := TFormPosition.ScreenCenter;
  Constraints.MinWidth := 600;
  Constraints.MinHeight := 400;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.AutoSize := False;
  FStatus.Align := TAlignLayout.Top;
  FStatus.Height := 32;
  FStatus.Margins.Left := 8;
  FStatus.Margins.Right := 8;
  FStatus.VertTextAlign := TTextAlign.Center;
  FStatus.Text := 'Select a cell to view its GDS.';

  FDockLayout := TLayout.Create(Self);
  FDockLayout.Parent := Self;
  FDockLayout.Align := TAlignLayout.Left;
  FDockLayout.Width := 320;
  FDockLayout.Margins.Left := 8;
  FDockLayout.Margins.Top := 8;
  FDockLayout.Margins.Bottom := 8;

  FFilesBox := TListBox.Create(Self);
  FFilesBox.Parent := FDockLayout;
  FFilesBox.Align := TAlignLayout.Client;

  FFilesSplitter := TCellViewerSplitter.Create(Self);
  FFilesSplitter.Parent := Self;
  // FMX orders left-aligned siblings by current Position.X, which drifts
  // during construction; pin the bar to the right of the dock so it sorts second.
  FFilesSplitter.Position.X := 500;
  FFilesSplitter.Align := TAlignLayout.Left;
  FFilesSplitter.Width := 5;
  FFilesSplitter.Margins.Top := 8;
  FFilesSplitter.Margins.Bottom := 8;
  FFilesSplitter.Fill.Color := $FF909090;
  FFilesSplitter.Stroke.Kind := TBrushKind.None;
  FFilesSplitter.HitTest := True;
  FFilesSplitter.Cursor := crHSplit;
  FFilesSplitter.OnMouseDown := SplitterMouseDown;
  FFilesSplitter.OnMouseMove := SplitterMouseMove;
  FFilesSplitter.OnMouseUp := SplitterMouseUp;

  FPaintBox := TPaintBox.Create(Self);
  FPaintBox.Parent := Self;
  FPaintBox.Align := TAlignLayout.Client;
  FPaintBox.Margins.Left := 8;
  FPaintBox.Margins.Top := 8;
  FPaintBox.Margins.Right := 8;
  FPaintBox.Margins.Bottom := 8;
  FPaintBox.OnPaint := PaintShapes;
end;

procedure TCellViewerForm.SplitterMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  if Button = TMouseButton.mbLeft then
  begin
    FFilesSplitter.GrabMouse;
    FSplitterDragging := True;
    FDownAbs := FFilesSplitter.LocalToAbsolute(PointF(X, Y));
    FSplitterStartWidth := FDockLayout.Width;
  end;
end;

procedure TCellViewerForm.SplitterMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Single);
var
  NewWidth: Single;
begin
  if FSplitterDragging and (ssLeft in Shift) then
  begin
    NewWidth := FSplitterStartWidth
      + (FFilesSplitter.LocalToAbsolute(PointF(X, Y)).X - FDownAbs.X);
    if NewWidth < 80 then
      NewWidth := 80;
    if NewWidth > (FPaintBox.Width + FDockLayout.Width - 40) then
      NewWidth := FPaintBox.Width + FDockLayout.Width - 40;
    FDockLayout.Width := NewWidth;
  end
  else
    FSplitterDragging := False;
end;

procedure TCellViewerForm.SplitterMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  FSplitterDragging := False;
  FFilesSplitter.ReleaseMouse;
end;

procedure TCellViewerForm.AppendPortGroup(Lines: TStrings; const Title: string;
  Entries: TStrings);
var
  i: Integer;
begin
  if Entries.Count = 0 then
    Lines.Add(Title + ' (none)')
  else
  begin
    Lines.Add(Title);
    for i := 0 to Entries.Count - 1 do
      Lines.Add(Entries[i]);
  end;
end;

procedure TCellViewerForm.BuildCellInfo(const Cell: TCell; Lines: TStrings);
var
  Inv: TFormatSettings;
  i, j: Integer;
  Port: TPort;
  Shape: TPortShape;
  Inputs, Outputs, Inouts, Other, Power, Section: TStringList;
  VFile: string;
  Timing: TCellTiming;
  Arc: TArcDelay;
begin
  Inv := TFormatSettings.Invariant;
  Lines.Add('Cell: ' + Cell.Name);

  if Cell.Width > 0 then
    Lines.Add(Format('Size: %.3f x %.3f um', [Cell.Width, Cell.Height], Inv))
  else
    Lines.Add('Size: (not found in LEF)');

  Lines.Add('');
  Lines.Add('Ports:');

  Inputs := TStringList.Create;
  Outputs := TStringList.Create;
  Inouts := TStringList.Create;
  Other := TStringList.Create;
  Power := TStringList.Create;
  try
    for i := 0 to Cell.Ports.Count - 1 do
    begin
      Port := Cell.Ports[i];
      case Port.Direction of
        pdInput:  Section := Inputs;
        pdOutput: Section := Outputs;
        pdInOut:  Section := Inouts;
      else
        Section := Other;
      end;
      if Port.Shapes.Count = 0 then
        Section.Add(Format('  %s (no geometry in LEF)', [Port.Name]))
      else
        for j := 0 to Port.Shapes.Count - 1 do
        begin
          Shape := Port.Shapes[j];
          Section.Add(Format('  %s [%s] %.3f x %.3f um at (%.3f, %.3f)',
            [Port.Name, Shape.Layer,
             Abs(Shape.x2 - Shape.x1), Abs(Shape.y2 - Shape.y1),
             Shape.x1, Shape.y1], Inv));
        end;
    end;

    for i := 0 to Cell.PowerPorts.Count - 1 do
    begin
      Port := Cell.PowerPorts[i];
      if Port.Shapes.Count = 0 then
        Power.Add(Format('  %s (no geometry in LEF)', [Port.Name]))
      else
        for j := 0 to Port.Shapes.Count - 1 do
        begin
          Shape := Port.Shapes[j];
          Power.Add(Format('  %s [%s] %.3f x %.3f um at (%.3f, %.3f)',
            [Port.Name, Shape.Layer,
             Abs(Shape.x2 - Shape.x1), Abs(Shape.y2 - Shape.y1),
             Shape.x1, Shape.y1], Inv));
        end;
    end;

    AppendPortGroup(Lines, 'Inputs:', Inputs);
    AppendPortGroup(Lines, 'Outputs:', Outputs);
    AppendPortGroup(Lines, 'Inouts:', Inouts);
    if Other.Count > 0 then
      AppendPortGroup(Lines, 'Direction unknown:', Other);
    if Power.Count > 0 then
      AppendPortGroup(Lines, 'Power:', Power);
  finally
    Inputs.Free;
    Outputs.Free;
    Inouts.Free;
    Other.Free;
    Power.Free;
  end;

  Lines.Add('');
  Timing := nil;
  VFile := '';
  for i := 0 to Cell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(Cell.SourceFiles[i]), '.v') then
    begin
      VFile := Cell.SourceFiles[i];
      Timing := ParseVerilogTiming(VFile);
      if Timing <> nil then
        Break;
    end;

  if Timing = nil then
  begin
    if VFile = '' then
      Lines.Add('Timing: (no .v file linked - run "Find linked files")')
    else
      Lines.Add('Timing: (no specify block / arcs found in '
        + ExtractFileName(VFile) + ')');
  end
  else
  begin
    Lines.Add(Format('Timing: %.1f ps worst-case input->output (%s)',
      [Timing.OutputDelayPs, ExtractFileName(VFile)], Inv));
    for Arc in Timing.Arcs do
      Lines.Add(Format('  %s -> %s: %.1f ps',
        [Arc.FromPin, Arc.ToPin, Arc.DelayPs], Inv));
    Timing.Free;
  end;
end;

procedure TCellViewerForm.SetCell(ACell: TCell);
var
  Path: string;
  Info: TStringList;
begin
  FCell := ACell;
  Caption := 'Cell: ' + FCell.Name;

  FFilesBox.Clear;
  Info := TStringList.Create;
  try
    BuildCellInfo(FCell, Info);
    for Path in Info do
      FFilesBox.Items.Add(Path);
  finally
    Info.Free;
  end;

  FFilesBox.Items.Add('');
  FFilesBox.Items.Add('---- Linked files ----');
  if FCell.SourceFiles.Count = 0 then
  begin
    FFilesBox.Items.Add('(no linked source files)');
    FStatus.Text := 'Run "Find linked files" first to populate this list.';
  end
  else
  begin
    for Path in FCell.SourceFiles do
      FFilesBox.Items.Add(Path);
    LoadCellGds;
  end;
end;

procedure TCellViewerForm.LoadCellGds;
var
  Path, Gds, Err: string;
begin
  Gds := '';
  for Path in FCell.SourceFiles do
    if SameText(ExtractFileExt(Path), '.gds') then
    begin
      Gds := Path;
      Break;
    end;

  if Gds = '' then
  begin
    FStatus.Text := 'No .gds file found among the linked sources.';
    Exit;
  end;

  FStatus.Text := 'Loading GDS: ' + ExtractFileName(Gds) + ' ...';
  Err := LoadGdsShapes(Gds, FShapes, FBounds);
  if Err <> '' then
    FStatus.Text := 'GDS load failed: ' + Err
  else
  begin
    FStatus.Text := Format('%d polygon(s) loaded from %s',
      [Length(FShapes), ExtractFileName(Gds)]);
    FPaintBox.Repaint;
  end;
end;

procedure TCellViewerForm.PaintShapes(Sender: TObject; Canvas: TCanvas);
const
  LayerColors: array[0..5] of TAlphaColor = (
    $B34488CC, $B388AA44, $B3CC8844, $B38844CC, $B344CCAA, $B3CC4488);
var
  R: TRectF;
  Scale, Ox, Oy, W, H: Double;
  i, k: Integer;
  Pts: TPolygon;
begin
  R := TRectF.Create(0, 0, FPaintBox.Width, FPaintBox.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  if Length(FShapes) = 0 then
  begin
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(R, 'No GDS polygons for this cell.', False, 1.0, [],
      TTextAlign.Center, TTextAlign.Center);
    Exit;
  end;

  W := FBounds.Width;
  H := FBounds.Height;
  if (W <= 0) or (H <= 0) then Exit;

  Scale := Min((FPaintBox.Width - 40) / W, (FPaintBox.Height - 40) / H);
  Ox := (FPaintBox.Width - W * Scale) / 2 - FBounds.Left * Scale;
  // flip Y so the layout reads in GDS orientation (y up) on screen
  Oy := (FPaintBox.Height - H * Scale) / 2 - FBounds.Top * Scale;

  for i := 0 to High(FShapes) do
  begin
    SetLength(Pts, Length(FShapes[i].Points));
    for k := 0 to High(FShapes[i].Points) do
    begin
      Pts[k].X := FShapes[i].Points[k].X * Scale + Ox;
      Pts[k].Y := (FBounds.Top + FBounds.Bottom - FShapes[i].Points[k].Y)
        * Scale + Oy;
    end;
    Canvas.Fill.Color := LayerColors[FShapes[i].Layer mod Length(LayerColors)];
    Canvas.FillPolygon(Pts, 1.0);
  end;
end;

end.

unit LefLibrary;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.StrUtils,
  System.IOUtils;

type
  TPinDirection = (pdUnknown, pdInput, pdOutput, pdInOut); //Delphi version of enum

  TPortShape = class //assumes port is a rect - no reason to think otherwise
  public
    Layer: string;
    x1, x2, y1, y2: Double;
  end;

  TPort = class
  public
    Name: string;
    Direction: TPinDirection;
    Shapes: TObjectList<TPortShape>; // allows multi layer ports (only used with pads)
    constructor Create;
    destructor Destroy; override;
  end;

  TCell = class
  public
    Name: string;
    Width: Double;
    Height: Double;
    Ports: TObjectList<TPort>;
    PortsByName: TDictionary<string, TPort>; //for quick lookup with blif parser
    SourceFiles: TStringList; // linked source files matching this cell (see FindCellSourceFiles)
    constructor Create;
    destructor Destroy; override;
    // Returns nil if the pin doesn't exist on this cell.
    function FindPort(const PinName: string): TPort;
  end;

  TLibrary = class
  public
    Cells: TObjectList<TCell>;
    CellsByName: TDictionary<string, TCell>; //used for verifying blif files
    constructor Create;
    destructor Destroy; override;
    // Returns nil if the cell doesn't exist in the library.
    function FindCell(const CellName: string): TCell;
    // Fills every cell's SourceFiles with the paths of each linked file under
    // ABaseDir whose name matches that cell (see CollectCellSourceFiles).
    procedure FindCellSourceFiles(const ABaseDir: string);
  end;

// Parses the LEF file and returns a fully-populated TLibrary.
// !!Caller owns the result and must Free it.
function LoadLefLibrary(const FileName: string): TLibrary;

const
  // Linked-source extensions for a cell: timing (.v), layout (.gds),
  // schematic (.cir). New formats get added here.
  CellSourceExts: array[0..2] of string = ('.v', '.gds', '.cir');

// Recursively finds every file under ABaseDir whose name (without extension)
// starts with ACellName (case-insensitive) AND whose extension is in
// CellSourceExts, e.g. cell "AND2T" matches "AND2T_v3p0.v". Matching paths
// are appended to AResult. A no-op if ABaseDir doesn't exist.
procedure CollectCellSourceFiles(const ACellName, ABaseDir: string; AResult: TStrings);

implementation

{ TPort }

constructor TPort.Create;
begin
  Direction := pdUnknown;
  Shapes := TObjectList<TPortShape>.Create(True);
end;

destructor TPort.Destroy;
begin
  Shapes.Free;
  inherited;
end;

{ TCell }

constructor TCell.Create;
begin
  Ports := TObjectList<TPort>.Create(True);
  PortsByName := TDictionary<string, TPort>.Create(TIStringComparer.Ordinal);
  SourceFiles := TStringList.Create;
end;

destructor TCell.Destroy;
begin
  SourceFiles.Free;
  Ports.Free;
  PortsByName.Free; // does not own the TPort objects -- Ports does
  inherited;
end;

function TCell.FindPort(const PinName: string): TPort;
begin
  if not PortsByName.TryGetValue(PinName, Result) then
    Result := nil;
end;

{ TLibrary }

constructor TLibrary.Create;
begin
  Cells := TObjectList<TCell>.Create(True);
  CellsByName := TDictionary<string, TCell>.Create(TIStringComparer.Ordinal);
end;

destructor TLibrary.Destroy;
begin
  Cells.Free;
  CellsByName.Free; // does not own the TCell objects -- Cells does
  inherited;
end;

function TLibrary.FindCell(const CellName: string): TCell;
begin
  if not CellsByName.TryGetValue(CellName, Result) then
    Result := nil;
end;

procedure TLibrary.FindCellSourceFiles(const ABaseDir: string);
var
  Cell: TCell;
begin
  for Cell in Cells do
  begin
    Cell.SourceFiles.Clear;
    CollectCellSourceFiles(Cell.Name, ABaseDir, Cell.SourceFiles);
  end;
end;

{ File matching }

procedure CollectCellSourceFiles(const ACellName, ABaseDir: string; AResult: TStrings);
var
  Files: TArray<string>;
  FileName, Stem, Ext: string;
begin
  if not TDirectory.Exists(ABaseDir) then
    Exit;

  Files := TDirectory.GetFiles(ABaseDir, '*', TSearchOption.soAllDirectories);
  AResult.BeginUpdate;
  try
    for FileName in Files do
    begin
      Stem := ChangeFileExt(ExtractFileName(FileName), '');
      Ext := ExtractFileExt(FileName);
      if StartsText(ACellName, Stem) and MatchText(Ext, CellSourceExts) then
        AResult.Add(FileName);
    end;
  finally
    AResult.EndUpdate;
  end;
end;

{ Parsing }

function ParseDirection(const Token: string): TPinDirection;
begin
  if SameText(Token, 'INPUT') then
    Result := pdInput
  else if SameText(Token, 'OUTPUT') then
    Result := pdOutput
  else if SameText(Token, 'INOUT') then
    Result := pdInOut
  else
    Result := pdUnknown;
end;

function LoadLefLibrary(const FileName: string): TLibrary;
var
  i: Integer;
  Lines: TStringList;
  Line: string;
  Parts: TArray<string>;
  CurrentCell: TCell;
  CurrentPort: TPort;
  Shape: TPortShape;
  CurrentLayer: string;
  Inv: TFormatSettings;
begin
  Result := TLibrary.Create;
  // LEF files always use '.' as the decimal separator; parse invariantly so
  // a locale with ',' (e.g. German) does not break the numbers.
  Inv := TFormatSettings.Invariant;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    CurrentCell := nil;
    CurrentPort := nil;
    CurrentLayer := '';

    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);

      if StartsText('MACRO', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        CurrentCell := TCell.Create;
        CurrentCell.Name := Parts[1];
        Result.Cells.Add(CurrentCell);
        Result.CellsByName.AddOrSetValue(CurrentCell.Name, CurrentCell);
      end

      else if (CurrentCell <> nil) and StartsText('SIZE', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        CurrentCell.Width := StrToFloat(Parts[1], Inv);
        CurrentCell.Height := StrToFloat(Parts[3], Inv);
      end

      else if (CurrentCell <> nil) and StartsText('PIN', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        CurrentPort := TPort.Create;
        CurrentPort.Name := Parts[1];
        CurrentCell.Ports.Add(CurrentPort);
        CurrentCell.PortsByName.AddOrSetValue(CurrentPort.Name, CurrentPort);
        CurrentLayer := '';
      end

      else if (CurrentCell <> nil) and (CurrentPort <> nil) and
        StartsText('DIRECTION', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        CurrentPort.Direction := ParseDirection(Parts[1]);
      end

      else if (CurrentCell <> nil) and (CurrentPort <> nil) and
        StartsText('LAYER', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        CurrentLayer := Parts[1];
      end

      else if (CurrentCell <> nil) and (CurrentPort <> nil) and
        StartsText('RECT', Line) then
      begin
        Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
        Shape := TPortShape.Create;
        Shape.Layer := CurrentLayer;
        Shape.x1 := StrToFloat(Parts[1], Inv);
        Shape.y1 := StrToFloat(Parts[2], Inv);
        Shape.x2 := StrToFloat(Parts[3], Inv);
        Shape.y2 := StrToFloat(Parts[4], Inv);
        CurrentPort.Shapes.Add(Shape);
      end

      else if StartsText('END', Line) then
      begin
        if Assigned(CurrentCell) then
        begin
          Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
          if Length(Parts) > 1 then //if line not just a single end statement
          begin
            if SameText(Parts[1], CurrentCell.Name) then
            begin
              CurrentCell := nil;
              CurrentPort := nil;
              CurrentLayer := '';
            end
            else if Assigned(CurrentPort) and SameText(Parts[1], CurrentPort.Name) then
            begin
              CurrentPort := nil;
              CurrentLayer := '';
            end;
          end;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

end.

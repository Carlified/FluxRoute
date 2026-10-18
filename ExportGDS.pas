unit ExportGDS;

// Phase 4: builds the write_die_gds.py placement recipe (JSON) from the export
// instances. The actual binary GDS is produced by the gdstk script - this unit
// only serialises the geometry the app already knows: block tiles, cells, and
// the die boundary.

interface

uses
  System.SysUtils, System.JSON, ExportLibrary, ExportModel;

type
  // One placement on the die, in micro-metres. Cols/Rows + DXUm/DYUm array the
  // unit tile (a straight run); a single placement leaves them 1.
  TGDSInstance = record
    Cell: string;
    SrcFile: string;     // '' = resolve by Cell name; else read this GDS for the cell
    XUm, YUm: Double;    // block bottom-left, OR the final reference origin when Mirror
    RotDeg: Integer;
    Mirror: Boolean;     // place at (XUm,YUm) with rot + x_reflection, no other shift
    Cols, Rows: Integer;
    DXUm, DYUm: Double;
  end;

// A single placement of a block/structure. Returns a 1x1 instance.
function GdsSingle(const ACell: string; AXUm, AYUm: Double): TGDSInstance;

// A straight run: the unit tile placed at (AXUm,AYUm), rotated ARot degrees,
// repeated ACols x ARows with pitch (ADXUm,ADYUm).
function GdsArrayed(const ACell: string; AXUm, AYUm: Double; ARot: Integer;
  ACols, ARows: Integer; ADXUm, ADYUm: Double): TGDSInstance;

// Serialises the recipe JSON document for write_die_gds.py.
function BuildDieRecipe(const DieWUm, DieHUm, PitchUm: Double;
  const Sources: TArray<string>; const Instances: TArray<TGDSInstance>;
  const OutPath: string; BoundaryLayer: Integer): string;

implementation

function GdsSingle(const ACell: string; AXUm, AYUm: Double): TGDSInstance;
begin
  Result.Cell := ACell;
  Result.SrcFile := '';
  Result.XUm := AXUm;
  Result.YUm := AYUm;
  Result.RotDeg := 0;
  Result.Mirror := False;
  Result.Cols := 1;
  Result.Rows := 1;
  Result.DXUm := 0;
  Result.DYUm := 0;
end;

function GdsArrayed(const ACell: string; AXUm, AYUm: Double; ARot: Integer;
  ACols, ARows: Integer; ADXUm, ADYUm: Double): TGDSInstance;
begin
  Result.Cell := ACell;
  Result.SrcFile := '';
  Result.XUm := AXUm;
  Result.YUm := AYUm;
  Result.RotDeg := ARot;
  Result.Mirror := False;
  Result.Cols := ACols;
  Result.Rows := ARows;
  Result.DXUm := ADXUm;
  Result.DYUm := ADYUm;
end;

function BuildDieRecipe(const DieWUm, DieHUm, PitchUm: Double;
  const Sources: TArray<string>; const Instances: TArray<TGDSInstance>;
  const OutPath: string; BoundaryLayer: Integer): string;
var
  Root, JSrcs, JI: TJSONObject;
  JArr: TJSONArray;
  i: Integer;
begin
  Root := TJSONObject.Create;
  try
    JArr := TJSONArray.Create;
    for i := 0 to High(Sources) do
      JArr.Add(Sources[i]);
    Root.AddPair('sources', JArr);

    JSrcs := TJSONObject.Create;
    JSrcs.AddPair('w_um', TJSONNumber.Create(DieWUm));
    JSrcs.AddPair('h_um', TJSONNumber.Create(DieHUm));
    JSrcs.AddPair('pitch', TJSONNumber.Create(PitchUm));
    Root.AddPair('die', JSrcs);
    Root.AddPair('boundary_layer', TJSONNumber.Create(BoundaryLayer));

    JArr := TJSONArray.Create;
    for i := 0 to High(Instances) do
    begin
      JI := TJSONObject.Create;
      JI.AddPair('cell', TJSONString.Create(Instances[i].Cell));
      if Instances[i].SrcFile <> '' then
        JI.AddPair('file', TJSONString.Create(Instances[i].SrcFile));
      JI.AddPair('x_um', TJSONNumber.Create(Instances[i].XUm));
      JI.AddPair('y_um', TJSONNumber.Create(Instances[i].YUm));
      JI.AddPair('rot', TJSONNumber.Create(Instances[i].RotDeg));
      if Instances[i].Mirror then
        JI.AddPair('mirror', TJSONBool.Create(True));
      if (Instances[i].Cols > 1) or (Instances[i].Rows > 1) then
      begin
        JI.AddPair('cols', TJSONNumber.Create(Instances[i].Cols));
        JI.AddPair('rows', TJSONNumber.Create(Instances[i].Rows));
        JI.AddPair('dx_um', TJSONNumber.Create(Instances[i].DXUm));
        JI.AddPair('dy_um', TJSONNumber.Create(Instances[i].DYUm));
      end;
      JArr.AddElement(JI);
    end;
    Root.AddPair('instances', JArr);

    Root.AddPair('out', TJSONString.Create(OutPath));
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

end.

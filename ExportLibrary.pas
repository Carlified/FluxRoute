unit ExportLibrary;

// Phase 2 of the export feature: the block library. A "block" is one DRC-clean,
// reusable unit that the export tiles the design with, and each block is a
// triple of files that must agree:
//   * a GDS cell   (the opaque artwork - DRC clean by construction)
//   * a LEF macro  (SIZE + pins: the semantic of the block)
//   * a CIR subckt (the electrical model: two or more ports)
// The same `Name` names the GDS cell, the LEF macro and the CIR subckt. The
// manifest JSON (one per process/PDK) maps a design KIND to its block files.
//
// Kinds are direction-agnostic (the owner's rule): a straight run's direction is
// only an instance rotation, never a different kind; bends are their own kind;
// via composites split curved-90 by handedness (L/R) because the layer stack
// pins which metal is on top; bias splits are keyed by connection count; the
// TRACK (ground/track tile) is always required even though it is not produced by
// the wire walk.

interface

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.StrUtils,
  System.Generics.Collections,
  ExportModel;

type
  // One optional GDS fill for a layer: if the export never placed geometry on
  // Layer, the cleanup stage fills the remaining areas from the Gds cell/file.
  TIfUnusedFill = record
    Layer: string;
    Gds: string; // GDS cell/file used to fill Layer's uncovered areas
  end;

  TExportBlockEntry = record
    Name: string;              // GDS cell / CIR subckt name
    GdsFile: string;           // path relative to the library root ('' = Name+'.gds')
    CirFile: string;           // '' = Name+'.cir'
    SizeWUm, SizeHUm: Double;  // tile dimensions
    StructuralOnly: Boolean;   // TRACK: purely structural - no CIR, LEF optional
    NoCir: Boolean;            // BIAS: voltage-source lines - no CIR subckt needed
    IfUnused: TArray<TIfUnusedFill>; // fill GDS for layers left empty post-export
    Ports: Integer;            // .SUBCKT port count the CIR check expects
  end;

  // The loaded manifest + block index, one per process/PDK.
  TExportLibrary = class
  private
    FGridPitchUm: Double;
    FSpiceInclude: string;
    FBlocks: TDictionary<string, TExportBlockEntry>;
    FChanged: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFile(const APath: string);
    procedure SaveFile(const APath: string);
    function BlockCount: Integer;
    function Find(const AKind: string): Boolean;
    function GetBlock(const AKind: string; out B: TExportBlockEntry): Boolean;
    procedure AddBlock(const AKind: string; const B: TExportBlockEntry);
    property GridPitchUm: Double read FGridPitchUm write FGridPitchUm;
    property SpiceInclude: string read FSpiceInclude write FSpiceInclude;
    property Blocks: TDictionary<string, TExportBlockEntry> read FBlocks;
  end;

// ---- Kind-key grammar (stable: never change these without a manifest bump) ----
function KindFamilyName(const Family: TExportFamily): string;
function KindRun(const Family: TExportFamily; const ALayer, ATaps: string): string;    // 'PTL:M1' / 'PTL:M1:WE'
function KindBend(const Family: TExportFamily; const ALayer, ATaps: string): string;  // 'BEND:PTL:M1'
function KindVia(const LoLayer, HiLayer: string; Kind: TExportViaKind;
  Variant: Integer): string;                                                          // 'VIA:M1_M3:BENDN'
function KindSplit(const ALayer: string; ConnCount: Integer; const ATaps: string): string; // 'SPLIT:M5:3'
function KindCap(const Family: TExportFamily; const ALayer, ATaps: string): string;  // 'PTLCAP:M1'
function KindNeedsCir(const AKind: string): Boolean;
function KindCell(const ACellName: string): string;                                   // 'CELL:TH_XORT'
function AlwaysRequiredKind: string;                                                  // 'TRACK'
function KindDefaultName(const AKind: string): string;   // GDS/LEF/CIR/tile name for a kind

// The unique set of kinds a design needs (deduplicated), incl. TRACK. Placed
// cells are NOT part of the block library - each cell's GDS/CIR are resolved
// from the already-parsed design library (TCell.SourceFiles) and its LEF macro
// is derived from the parsed cell, so cells never appear here. This set is what
// the export preflight diffs against the library.
procedure CollectDesignKinds(const D: TExportDesign; const Kinds: TList<string>);

// Verifies the block against its files on disk: the CIR file must hold a .SUBCKT
// named entry.Name whose port count equals the pin count; the GDS file must
// exist and be non-empty. Returns False and fills Msgs with the mismatches. Only
// the requested formats are required: NeedGds verifies the GDS (and any
// structural fills); NeedCir the CIR subckt. Formats the caller is not exporting
// are ignored.
function CheckBlockTriple(const RootDir: string; const B: TExportBlockEntry;
  var Msgs: TStringList; NeedGds: Boolean = True;
  NeedCir: Boolean = True): Boolean;

// Writes a ready-to-fill manifest for APath (one entry per kind in Kinds) with
// kind-derived names and pin placeholders, so the user only has to supply real
// sizes/pins and drop the .gds/.cir files. GridPitchUm seeds the default
// unit-tile size.
procedure WriteManifestTemplate(const APath: string; GridPitchUm: Double;
  const Kinds: TList<string>);

implementation

function KindFamilyName(const Family: TExportFamily): string;
begin
  if Family = xfBias then
    Result := 'BIAS'
  else
    Result := 'PTL';
end;

function KindRun(const Family: TExportFamily; const ALayer, ATaps: string): string;
begin
  Result := KindFamilyName(Family) + ':' + ALayer;
  if ATaps <> '' then
    Result := Result + ':' + ATaps;
end;

function KindBend(const Family: TExportFamily; const ALayer, ATaps: string): string;
begin
  Result := 'BEND:' + KindFamilyName(Family) + ':' + ALayer;
  if ATaps <> '' then
    Result := Result + ':' + ATaps;
end;

function KindVia(const LoLayer, HiLayer: string; Kind: TExportViaKind;
  Variant: Integer): string;
begin
  // One kind per (lower, higher) metal pair; the pair is stored low-first so the
  // M1>M3 and M3>M1 directions collapse to the same block. The style names the
  // higher metal's exit side once the lower metal is on the W side.
  Result := 'VIA:' + LoLayer + '_' + HiLayer + ':';
  case Kind of
    vkViaBend:
      if Variant > 0 then
        Result := Result + 'BENDN'
      else
        Result := Result + 'BENDS';
    vkViaTurn:
      Result := Result + 'TURN';
  else
    Result := Result + 'STRAIGHT';
  end;
end;

function KindSplit(const ALayer: string; ConnCount: Integer; const ATaps: string): string;
begin
  Result := 'SPLIT:' + ALayer + ':' + IntToStr(ConnCount);
  if ATaps <> '' then
    Result := Result + ':' + ATaps;
end;

function KindCap(const Family: TExportFamily; const ALayer, ATaps: string): string;
begin
  Result := KindFamilyName(Family) + 'CAP:' + ALayer;
  if ATaps <> '' then
    Result := Result + ':' + ATaps;
end;

// True when a kind needs a CIR subckt in the preflight: the PTL family (runs,
// bends, caps), vias, and placed cells (which carry their own .cir). The bias
// family (BIAS/BEND:BIAS/SPLIT/BIASCAP) and TRACK have no circuit equivalent.
function KindNeedsCir(const AKind: string): Boolean;
begin
  Result := False;
  if AKind = 'TRACK' then
    Exit;
  if Pos('PTL', AKind) = 1 then
    Result := True // PTL:M1, PTLCAP:M1
  else if Pos('BEND:PTL', AKind) = 1 then
    Result := True
  else if Pos('VIA:', AKind) = 1 then
    Result := True
  else if Pos('CELL:', AKind) = 1 then
    Result := True;
end;

function KindCell(const ACellName: string): string;
begin
  Result := 'CELL:' + ACellName;
end;

function AlwaysRequiredKind: string;
begin
  Result := 'TRACK';
end;

procedure AddUnique(const Kinds: TList<string>; const AKind: string);
begin
  if AKind <> '' then
    if Kinds.IndexOf(AKind) < 0 then
      Kinds.Add(AKind);
end;

procedure CollectDesignKinds(const D: TExportDesign; const Kinds: TList<string>);
var
  i: Integer;
begin
  Kinds.Clear;
  for i := 0 to High(D.Runs) do
    AddUnique(Kinds, KindRun(D.Runs[i].Family, D.Runs[i].Layer, D.Runs[i].Taps));
  for i := 0 to High(D.Bends) do
    AddUnique(Kinds, KindBend(D.Bends[i].Family, D.Bends[i].Layer, D.Bends[i].Taps));
  for i := 0 to High(D.ViaBlocks) do
    AddUnique(Kinds, KindVia(D.ViaBlocks[i].LoLayer, D.ViaBlocks[i].HiLayer,
      D.ViaBlocks[i].Kind, D.ViaBlocks[i].Variant));
  for i := 0 to High(D.Splits) do
    AddUnique(Kinds, KindSplit(D.Splits[i].Layer, D.Splits[i].ConnCount, D.Splits[i].Taps));
  for i := 0 to High(D.Terminals) do
    // The bias trunk ends in the top row heading straight up out of the die; that
    // end is exported as a straight bias tile (see RunGdsExport), so ask for the
    // run kind rather than a cap for it.
    if (D.Terminals[i].Family = xfBias) and (D.Terminals[i].Y = 0) then
      AddUnique(Kinds, KindRun(xfBias, D.Terminals[i].Layer, ''))
    else
      AddUnique(Kinds, KindCap(D.Terminals[i].Family, D.Terminals[i].Layer,
        D.Terminals[i].Taps));
  AddUnique(Kinds, AlwaysRequiredKind);
end;

{ TExportLibrary }

constructor TExportLibrary.Create;
begin
  inherited;
  FGridPitchUm := 0;
  FSpiceInclude := '';
  FBlocks := TDictionary<string, TExportBlockEntry>.Create;
  FChanged := False;
end;

destructor TExportLibrary.Destroy;
begin
  FBlocks.Free;
  inherited;
end;

procedure TExportLibrary.Clear;
begin
  FBlocks.Clear;
  FGridPitchUm := 0;
  FSpiceInclude := '';
  FChanged := True;
end;

function TExportLibrary.BlockCount: Integer;
begin
  Result := FBlocks.Count;
end;

function TExportLibrary.Find(const AKind: string): Boolean;
begin
  Result := FBlocks.ContainsKey(AKind);
end;

function TExportLibrary.GetBlock(const AKind: string; out B: TExportBlockEntry): Boolean;
begin
  Result := FBlocks.TryGetValue(AKind, B);
end;

procedure TExportLibrary.AddBlock(const AKind: string; const B: TExportBlockEntry);
begin
  FBlocks.AddOrSetValue(AKind, B);
  FChanged := True;
end;

procedure TExportLibrary.LoadFile(const APath: string);
var
  Root: TJSONObject;
  JBlocks, JBlock, JPin: TJSONObject;
  JVal: TJSONValue;
  JArr: TJSONArray;
  Pair: TJSONPair;
  i: Integer;
  B: TExportBlockEntry;
begin
  Clear;
  if not TFile.Exists(APath) then
    Exit;
  Root := nil;
  try
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(APath)) as TJSONObject;
    if Root = nil then
      Exit;
    if Root.GetValue('gridPitchUm') is TJSONNumber then
      FGridPitchUm := (Root.GetValue('gridPitchUm') as TJSONNumber).AsDouble;
    if Root.GetValue('spiceInclude') is TJSONString then
      FSpiceInclude := (Root.GetValue('spiceInclude') as TJSONString).Value;
    JVal := Root.GetValue('blocks');
    if (JVal = nil) or not (JVal is TJSONObject) then
      Exit;
    JBlocks := JVal as TJSONObject;
    for Pair in JBlocks do
    begin
      if not (Pair.JsonValue is TJSONObject) then
        Continue;
      JBlock := Pair.JsonValue as TJSONObject;
      B := Default(TExportBlockEntry);
      if JBlock.GetValue('name') is TJSONString then
        B.Name := (JBlock.GetValue('name') as TJSONString).Value;
      if JBlock.GetValue('gds') is TJSONString then
        B.GdsFile := (JBlock.GetValue('gds') as TJSONString).Value;
      if JBlock.GetValue('cir') is TJSONString then
        B.CirFile := (JBlock.GetValue('cir') as TJSONString).Value;
      if JBlock.GetValue('structuralOnly') is TJSONBool then
        B.StructuralOnly := (JBlock.GetValue('structuralOnly') as TJSONBool).AsBoolean;
      if JBlock.GetValue('noCir') is TJSONBool then
        B.NoCir := (JBlock.GetValue('noCir') as TJSONBool).AsBoolean;
      JVal := JBlock.GetValue('if_unused');
      if (JVal is TJSONArray) then
      begin
        JArr := JVal as TJSONArray;
        SetLength(B.IfUnused, JArr.Count);
        for i := 0 to JArr.Count - 1 do
          if JArr.Items[i] is TJSONObject then
          begin
            JPin := JArr.Items[i] as TJSONObject;
            if JPin.GetValue('layer') is TJSONString then
              B.IfUnused[i].Layer := (JPin.GetValue('layer') as TJSONString).Value;
            if JPin.GetValue('fill') is TJSONString then
              B.IfUnused[i].Gds := (JPin.GetValue('fill') as TJSONString).Value;
          end;
      end;
      JArr := JBlock.GetValue('sizeUm') as TJSONArray;
      if (JArr <> nil) and (JArr.Count >= 2) then
      begin
        B.SizeWUm := JArr.Items[0].AsType<Double>;
        B.SizeHUm := JArr.Items[1].AsType<Double>;
      end;
      // Port count for the CIR subckt check. Legacy manifests stored a "pins"
      // object; its key count is used when "ports" is absent.
      B.Ports := 0;
      if JBlock.GetValue('ports') is TJSONNumber then
        B.Ports := (JBlock.GetValue('ports') as TJSONNumber).AsInt
      else
      begin
        JVal := JBlock.GetValue('pins');
        if JVal is TJSONObject then
          B.Ports := (JVal as TJSONObject).Count;
      end;
      FBlocks.AddOrSetValue(Pair.JsonString.Value, B);
    end;
  finally
    Root.Free;
  end;
  FChanged := False;
end;

procedure TExportLibrary.SaveFile(const APath: string);
var
  Root, JBlocks, JBlock, JPin: TJSONObject;
  JArr: TJSONArray;
  Kind: string;
  i: Integer;
  B: TExportBlockEntry;
begin
  Root := TJSONObject.Create;
  JBlocks := TJSONObject.Create;
  try
    Root.AddPair('version', TJSONNumber.Create(1));
    if FGridPitchUm > 0 then
      Root.AddPair('gridPitchUm', TJSONNumber.Create(FGridPitchUm));
    if FSpiceInclude <> '' then
      Root.AddPair('spiceInclude', TJSONString.Create(FSpiceInclude));
    for Kind in FBlocks.Keys do
    begin
      B := FBlocks[Kind];
      JBlock := TJSONObject.Create;
      if B.Name <> '' then
        JBlock.AddPair('name', TJSONString.Create(B.Name));
      if B.GdsFile <> '' then
        JBlock.AddPair('gds', TJSONString.Create(B.GdsFile));
      if B.CirFile <> '' then
JBlock.AddPair('cir', TJSONString.Create(B.CirFile));
      if B.StructuralOnly then
        JBlock.AddPair('structuralOnly', TJSONBool.Create(True));
      if B.NoCir then
        JBlock.AddPair('noCir', TJSONBool.Create(True));
      if Length(B.IfUnused) > 0 then
      begin
        JArr := TJSONArray.Create;
        for i := 0 to High(B.IfUnused) do
        begin
          JPin := TJSONObject.Create;
          JPin.AddPair('layer', TJSONString.Create(B.IfUnused[i].Layer));
          JPin.AddPair('fill', TJSONString.Create(B.IfUnused[i].Gds));
          JArr.AddElement(JPin);
        end;
        JBlock.AddPair('if_unused', JArr);
      end;
      JArr := TJSONArray.Create;
  JArr.Add(B.SizeWUm);
  JArr.Add(B.SizeHUm);
  JBlock.AddPair('sizeUm', JArr);
      if B.Ports > 0 then
        JBlock.AddPair('ports', TJSONNumber.Create(B.Ports));
      JBlocks.AddPair(Kind, JBlock);
    end;
    Root.AddPair('blocks', JBlocks);
    TFile.WriteAllText(APath, Root.ToJSON);
  finally
    Root.Free;
  end;
  FChanged := False;
end;

// ---- triple-consistency check helpers -------------------------------------

function FileFor(const RootDir, F, Name, Ext: string): string;
begin
  if F <> '' then
    Result := TPath.Combine(RootDir, F)
  else
    Result := TPath.Combine(RootDir, Name + Ext);
end;

function CheckCir(const RootDir: string; const B: TExportBlockEntry; var Msgs: TStringList): Boolean;
var
  Path: string;
  Lines: TArray<string>;
  i, p, PortCount: Integer;
  Up, Tail: string;
begin
  Result := True;
  Path := FileFor(RootDir, B.CirFile, B.Name, '.cir');
  if not TFile.Exists(Path) then
  begin
    Msgs.Add('CIR file not found: ' + Path);
    Exit(False);
  end;
  Lines := TFile.ReadAllLines(Path);
  PortCount := -1;
  for i := 0 to High(Lines) do
  begin
    Up := UpperCase(Trim(Lines[i]));
    if not Up.StartsWith('.SUBCKT ') then
      Continue;
    Tail := Trim(Copy(Up, 9, MaxInt));
    p := Pos(' ', Tail);
    if p = 0 then
      Continue; // a .SUBCKT with a name only and no ports is not ours
    if Copy(Tail, 1, p - 1) <> UpperCase(B.Name) then
      Continue; // another subckt
    // Count the remaining tokens as ports.
    Tail := Trim(Copy(Tail, p + 1, MaxInt));
    PortCount := 0;
    while Tail <> '' do
    begin
      Tail := Tail.Trim;
      p := Pos(' ', Tail);
      if p = 0 then
      begin
        Inc(PortCount);
        Tail := '';
      end
      else
      begin
        Inc(PortCount);
        Tail := Copy(Tail, p + 1, MaxInt);
      end;
    end;
    Break;
  end;
  if PortCount < 0 then
  begin
    Msgs.Add(Format('CIR %s: no .SUBCKT named "%s".', [Path, B.Name]));
    Result := False;
  end
  else if PortCount <> B.Ports then
  begin
    Msgs.Add(Format('CIR %s: subckt "%s" has %d ports, manifest declares %d.',
      [Path, B.Name, PortCount, B.Ports]));
    Result := False;
  end;
end;

function CheckBlockTriple(const RootDir: string; const B: TExportBlockEntry;
  var Msgs: TStringList; NeedGds, NeedCir: Boolean): Boolean;
var
  Path: string;
  i: Integer;
begin
  Result := True;
  if Msgs = nil then
    Msgs := TStringList.Create;
  // GDS file must exist and be non-empty (deep cell-name verification is a
  // later slice; the artwork is trusted by the user).
  if NeedGds then
  begin
    Path := FileFor(RootDir, B.GdsFile, B.Name, '.gds');
    if not TFile.Exists(Path) then
    begin
      Msgs.Add('GDS file not found: ' + Path);
      Result := False;
    end
    else if TFile.GetSize(Path) = 0 then
    begin
      Msgs.Add('GDS file is empty: ' + Path);
      Result := False;
    end;
  end;
  if (B.StructuralOnly) or (B.NoCir) then
  begin
    // Structural (TRACK) and bias (voltage-source) blocks carry no CIR subckt.
    if B.StructuralOnly and NeedGds then
      for i := 0 to High(B.IfUnused) do
        if B.IfUnused[i].Gds <> '' then
          if not TFile.Exists(TPath.Combine(RootDir, B.IfUnused[i].Gds)) then
          begin
            Msgs.Add(Format('fill GDS for layer %s not found: %s',
              [B.IfUnused[i].Layer,
               TPath.Combine(RootDir, B.IfUnused[i].Gds)]));
            Result := False;
          end;
    Exit;
  end;
  if NeedCir then
    if not CheckCir(RootDir, B, Msgs) then
      Result := False;
end;

// ---- template-manifest generation ------------------------------------------

// Splits a kind key into {Head, Layer, Sub, Aux}: Head = PTL/BIAS/BEND/VIA/
// SPLIT/CELL/TRACK; Layer = the metal layer the block sits on (the below layer
// for a VIA); Aux = the above layer for a VIA ('' otherwise); Sub = for VIA the
// S/L/R/180 suffix, for SPLIT the connection count, for CELL the cell name.
procedure KindInfo(const AKind: string; var Head, Layer, Sub, Aux: string);
var
  p, q, r: Integer;
begin
  Head := '';
  Layer := '';
  Sub := '';
  Aux := '';
  if AKind = 'TRACK' then
  begin
    Head := 'TRACK';
    Exit;
  end;
  if Pos('CELL:', AKind) = 1 then
  begin
    Head := 'CELL';
    Sub := Copy(AKind, 6, MaxInt);
    Exit;
  end;
  if Pos('SPLIT:', AKind) = 1 then
  begin
    Head := 'SPLIT';
    p := Pos(':', AKind);
    q := PosEx(':', AKind, p + 1);
    if q > p then
    begin
      Layer := Copy(AKind, p + 1, q - p - 1);
      Sub := Copy(AKind, q + 1, MaxInt);
    end;
    Exit;
  end;
  if Pos('BEND:', AKind) = 1 then
  begin
    Head := 'BEND';
    p := Pos(':', AKind);
    q := PosEx(':', AKind, p + 1);
    if q > p then
    begin
      r := PosEx(':', AKind, q + 1);
      if r > q then
        Layer := Copy(AKind, q + 1, r - q - 1)
      else
        Layer := Copy(AKind, q + 1, MaxInt);
    end;
    Exit;
  end;
  if Pos('VIA:', AKind) = 1 then
  begin
    Head := 'VIA';
    p := Pos(':', AKind);
    q := PosEx(':', AKind, p + 1);
    if q > p then
    begin
      Layer := Copy(AKind, p + 1, q - p - 1); // '<lo>_<hi>'
      Sub := Copy(AKind, q + 1, MaxInt);      // STRAIGHT / BENDN / BENDS / TURN
    end;
    Exit;
  end;
  p := Pos(':', AKind);
  if p > 0 then
  begin
    Head := Copy(AKind, 1, p - 1); // 'PTL' / 'BIAS' / 'PTLCAP' / 'BIASCAP'
    q := PosEx(':', AKind, p + 1);
    if q > p then
      Layer := Copy(AKind, p + 1, q - p - 1)
    else
      Layer := Copy(AKind, p + 1, MaxInt);
  end;
end;

function KindDefaultName(const AKind: string): string;
begin
  if Pos('CELL:', AKind) = 1 then
    Result := Copy(AKind, 6, MaxInt)
  else if AKind = 'TRACK' then
    Result := 'TRACK_TILE'
  else
  begin
    Result := AKind;
    Result := StringReplace(Result, ':', '_', [rfReplaceAll]);
    Result := StringReplace(Result, '>', '_', [rfReplaceAll]);
  end;
end;

// The port count a template entry is born with: 2 on a run/bend/via, N on a
// split, 1 on a bias cap, none on a cell/track (the user fills those by hand).
function KindPortCount(const AKind: string): Integer;
var
  Head, Layer, Sub, Aux: string;
begin
  KindInfo(AKind, Head, Layer, Sub, Aux);
  if Head = 'VIA' then
    Result := 2
  else if Head = 'SPLIT' then
    Result := StrToIntDef(Sub, 3)
  else if Head = 'BIASCAP' then
    Result := 1
  else if (Head = 'PTL') or (Head = 'PTLCAP') or (Head = 'BIAS') or
          (Head = 'BEND') then
    Result := 2
  else
    Result := 0; // CELL / TRACK
end;

procedure WriteManifestTemplate(const APath: string; GridPitchUm: Double;
  const Kinds: TList<string>);
var
  Lib: TExportLibrary;
  B: TExportBlockEntry;
  Head, Layer, Sub, Aux: string;
  k: Integer;
begin
  Lib := TExportLibrary.Create;
  try
    // Merge into an existing manifest when there is one: only the kinds it is
    // missing get scaffolding, so repeatedly re-importing does not throw away
    // the user's filled-in entries. Empty/absent -> a fresh manifest.
    if TFile.Exists(APath) then
    begin
      try
        Lib.LoadFile(APath);
      except
        Lib.GridPitchUm := GridPitchUm;
      end;
      if Lib.GridPitchUm <= 0 then
        Lib.GridPitchUm := GridPitchUm;
    end
    else
      Lib.GridPitchUm := GridPitchUm;
    for k := 0 to Kinds.Count - 1 do
    begin
      if Lib.Find(Kinds[k]) then
        Continue; // already present: keep the user's entry
      B := Default(TExportBlockEntry);
      B.Name := KindDefaultName(Kinds[k]);
      B.GdsFile := B.Name + '.gds';
      B.CirFile := B.Name + '.cir';
      // Unit-tile size seed; the user overrides width/height for their cells.
      B.SizeWUm := GridPitchUm;
      B.SizeHUm := GridPitchUm;
      if Kinds[k] = AlwaysRequiredKind then
      begin
        // TRACK: purely structural - no CIR, LEF optional. Show the optional
        // per-layer fill format (M0 here is a sample row; edit/replace it).
        B.StructuralOnly := True;
        B.CirFile := '';
        SetLength(B.IfUnused, 1);
        B.IfUnused[0].Layer := 'M0';
        B.IfUnused[0].Gds := 'M0_fill.gds';
      end
      else
      begin
        KindInfo(Kinds[k], Head, Layer, Sub, Aux);
        if Head = 'BIASCAP' then
        begin
          // Bias pin cap: a physical contact, no CIR subckt and no LEF
          // (structural, like TRACK). A PTL cap is a real two-port element.
          B.StructuralOnly := True;
            B.CirFile := '';
        end
        else if Pos('BIAS', Kinds[k]) > 0 then
        begin
          // Bias straight runs and bias bends are voltage sources: their
          // geometry is placed but they carry no per-block CIR subckt. Test the
          // whole kind: KindInfo drops a bend's family (BEND:BIAS:M5 reports
          // Layer = 'M5'), so Head/Layer cannot identify them. BIASCAP is
          // caught by the branch above.
          B.NoCir := True;
          B.CirFile := '';
        end;
      end;
      B.Ports := KindPortCount(Kinds[k]);
      Lib.AddBlock(Kinds[k], B);
    end;
    Lib.SaveFile(APath);
  finally
    Lib.Free;
  end;
end;

end.

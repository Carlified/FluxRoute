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
  TLibraryPin = record
    Name: string;
    Layer: string;
    Dir: string; // informational ('IN'/'OUT'/'INOUT' etc.)
    DXUm, DYUm: Double;
  end;

  // One optional GDS fill for a layer: if the export never placed geometry on
  // Layer, the cleanup stage fills the remaining areas from the Gds cell/file.
  TIfUnusedFill = record
    Layer: string;
    Gds: string; // GDS cell/file used to fill Layer's uncovered areas
  end;

  TExportBlockEntry = record
    Name: string;              // GDS cell / LEF macro / CIR subckt name
    GdsFile: string;           // path relative to the library root ('' = Name+'.gds')
    LefFile: string;           // '' = Name+'.lef'
    CirFile: string;           // '' = Name+'.cir'
    SizeWUm, SizeHUm: Double;  // tile dimensions
    StructuralOnly: Boolean;   // TRACK: purely structural - no CIR, LEF optional
    NoCir: Boolean;            // BIAS: voltage-source lines - no CIR subckt needed
    IfUnused: TArray<TIfUnusedFill>; // fill GDS for layers left empty post-export
    Pins: TArray<TLibraryPin>;
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

// Verifies the block triple against its files on disk: the LEF file must hold a
// MACRO named entry.Name whose SIZE matches and whose PIN count equals the pin
// list; the CIR file must hold a .SUBCKT named entry.Name whose port count
// equals the pin count; the GDS file must exist and be non-empty. Returns False
// and fills Msgs with the mismatches. Only the requested formats are required:
// NeedGds verifies the GDS (and any structural fills); NeedLef the LEF macro;
// NeedCir the CIR subckt. Formats the caller is not exporting are ignored.
function CheckBlockTriple(const RootDir: string; const B: TExportBlockEntry;
  var Msgs: TStringList; NeedGds: Boolean = True; NeedLef: Boolean = True;
  NeedCir: Boolean = True): Boolean;

// Writes a ready-to-fill manifest for APath (one entry per kind in Kinds) with
// kind-derived names and pin placeholders, so the user only has to supply real
// sizes/pins and drop the .gds/.lef/.cir files. GridPitchUm seeds the default
// unit-tile size and pin offsets.
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
    AddUnique(Kinds, KindCap(D.Terminals[i].Family, D.Terminals[i].Layer, D.Terminals[i].Taps));
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
  JBlocks, JBlock, JPins, JPin: TJSONObject;
  JVal: TJSONValue;
  JArr: TJSONArray;
  Pair, PinPair: TJSONPair;
  i: Integer;
  B: TExportBlockEntry;
  P: TLibraryPin;
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
      if JBlock.GetValue('lef') is TJSONString then
        B.LefFile := (JBlock.GetValue('lef') as TJSONString).Value;
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
      JVal := JBlock.GetValue('pins');
      if (JVal is TJSONObject) then
      begin
        JPins := JVal as TJSONObject;
        SetLength(B.Pins, JPins.Count);
        i := 0;
        for PinPair in JPins do
        begin
          if PinPair.JsonValue is TJSONObject then
          begin
            JPin := PinPair.JsonValue as TJSONObject;
            P := Default(TLibraryPin);
            P.Name := PinPair.JsonString.Value;
            if JPin.GetValue('layer') is TJSONString then
              P.Layer := (JPin.GetValue('layer') as TJSONString).Value;
            if JPin.GetValue('dir') is TJSONString then
              P.Dir := (JPin.GetValue('dir') as TJSONString).Value;
            if JPin.GetValue('dx') is TJSONNumber then
              P.DXUm := (JPin.GetValue('dx') as TJSONNumber).AsDouble;
            if JPin.GetValue('dy') is TJSONNumber then
              P.DYUm := (JPin.GetValue('dy') as TJSONNumber).AsDouble;
            B.Pins[i] := P;
          end;
          Inc(i);
        end;
      end
      else
        SetLength(B.Pins, 0);
      FBlocks.AddOrSetValue(Pair.JsonString.Value, B);
    end;
  finally
    Root.Free;
  end;
  FChanged := False;
end;

procedure TExportLibrary.SaveFile(const APath: string);
var
  Root, JBlocks, JBlock, JPins, JPin: TJSONObject;
  JArr: TJSONArray;
  Kind, S: string;
  i: Integer;
  B: TExportBlockEntry;
  P: TLibraryPin;
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
      if B.LefFile <> '' then
        JBlock.AddPair('lef', TJSONString.Create(B.LefFile));
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
      JPins := TJSONObject.Create;
      for i := 0 to High(B.Pins) do
      begin
        P := B.Pins[i];
        S := P.Name;
        if S = '' then
          S := 'P' + IntToStr(i);
        JPin := TJSONObject.Create;
        JPin.AddPair('layer', TJSONString.Create(P.Layer));
        if P.Dir <> '' then
          JPin.AddPair('dir', TJSONString.Create(P.Dir));
        JPin.AddPair('dx', TJSONNumber.Create(P.DXUm));
        JPin.AddPair('dy', TJSONNumber.Create(P.DYUm));
        JPins.AddPair(S, JPin);
      end;
      JBlock.AddPair('pins', JPins);
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

function CheckLef(const RootDir: string; const B: TExportBlockEntry; var Msgs: TStringList): Boolean;
var
  Path: string;
  Lines: TArray<string>;
  Up: string;
  i, PinCount: Integer;
  InMacro: Boolean;
  SizeW, SizeH: Double;
  HaveSize: Boolean;
begin
  Result := True;
  Path := FileFor(RootDir, B.LefFile, B.Name, '.lef');
  if not TFile.Exists(Path) then
  begin
    Msgs.Add('LEF file not found: ' + Path);
    Exit(False);
  end;
  Lines := TFile.ReadAllLines(Path);
  InMacro := False;
  PinCount := 0;
  SizeW := 0;
  SizeH := 0;
  HaveSize := False;
  for i := 0 to High(Lines) do
  begin
    Up := UpperCase(Trim(Lines[i]));
    if not InMacro then
    begin
      if Up.StartsWith('MACRO ') then
        if Up.Substring(6).Trim() = UpperCase(B.Name) then
          InMacro := True;
    end
    else
    begin
      if Up.StartsWith('SIZE ') then
      begin
        // SIZE w BY h
        SizeW := StrToFloatDef(Copy(Up, 6, Pos(' BY ', Up) - 6), 0);
        SizeH := StrToFloatDef(Copy(Up, Pos(' BY ', Up) + 4, MaxInt), 0);
        HaveSize := True;
      end
      else if Up.StartsWith('PIN ') then
        Inc(PinCount)
      else if Up = 'END ' + UpperCase(B.Name) then
        Break;
    end;
  end;
  if not InMacro then
  begin
    Msgs.Add(Format('LEF %s: no MACRO named "%s".', [Path, B.Name]));
    Result := False;
  end
  else
  begin
    if not HaveSize then
    begin
      Msgs.Add(Format('LEF %s: MACRO "%s" has no SIZE.', [Path, B.Name]));
      Result := False;
    end
    else if (Abs(SizeW - B.SizeWUm) > 0.01) or (Abs(SizeH - B.SizeHUm) > 0.01) then
    begin
      Msgs.Add(Format('LEF %s: SIZE %.3f x %.3f != manifest %.3f x %.3f um.',
        [Path, SizeW, SizeH, B.SizeWUm, B.SizeHUm]));
      Result := False;
    end;
    if PinCount <> Length(B.Pins) then
    begin
      Msgs.Add(Format('LEF %s: %d pins, manifest declares %d.',
        [Path, PinCount, Length(B.Pins)]));
      Result := False;
    end;
  end;
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
  else if PortCount <> Length(B.Pins) then
  begin
    Msgs.Add(Format('CIR %s: subckt "%s" has %d ports, manifest declares %d pins.',
      [Path, B.Name, PortCount, Length(B.Pins)]));
    Result := False;
  end;
end;

function CheckBlockTriple(const RootDir: string; const B: TExportBlockEntry;
  var Msgs: TStringList; NeedGds, NeedLef, NeedCir: Boolean): Boolean;
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
    // Structural (TRACK) and bias (voltage-source) blocks carry no CIR subckt;
    // their LEF is optional - validate it only if the file is actually present.
    if NeedLef and TFile.Exists(FileFor(RootDir, B.LefFile, B.Name, '.lef')) then
      if not CheckLef(RootDir, B, Msgs) then
        Result := False;
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
  if NeedLef then
    if not CheckLef(RootDir, B, Msgs) then
      Result := False;
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

// The pin list a template entry is born with: 2 through pins on a run/bend/via,
// N on a split, none yet on a cell/track (the user fills those by hand).
procedure KindTemplatePins(const AKind: string; GridPitchUm: Double;
  var Pins: TArray<TLibraryPin>);
var
  Head, Layer, Sub, Aux, Lo, Hi: string;
  n, i, q: Integer;
  P: TLibraryPin;
begin
  SetLength(Pins, 0);
  KindInfo(AKind, Head, Layer, Sub, Aux);
  if Head = 'VIA' then
  begin
    // Layer is '<lo>_<hi>': P0 on the lower metal (W side), P1 on the higher.
    Lo := Layer;
    Hi := '';
    q := Pos('_', Layer);
    if q > 0 then
    begin
      Lo := Copy(Layer, 1, q - 1);
      Hi := Copy(Layer, q + 1, MaxInt);
    end;
    SetLength(Pins, 2);
    Pins[0].Name := 'P0';
    Pins[0].Layer := Lo;
    Pins[0].Dir := 'IN';
    Pins[1].Name := 'P1';
    Pins[1].Layer := Hi;
    Pins[1].Dir := 'OUT';
    Exit;
  end;
  if Head = 'SPLIT' then
  begin
    n := StrToIntDef(Sub, 3);
    SetLength(Pins, n);
    for i := 0 to n - 1 do
    begin
      P := Default(TLibraryPin);
      P.Name := 'P' + IntToStr(i);
      P.Layer := Layer;
      P.DXUm := i * GridPitchUm;
      P.Dir := 'INOUT';
      Pins[i] := P;
    end;
    Exit;
  end;
  if Head = 'BIASCAP' then
  begin
    // One contact to the cell's power pin on the bias layer (structural).
    SetLength(Pins, 1);
    Pins[0].Name := 'P0';
    Pins[0].Layer := Layer;
    Pins[0].DXUm := 0;
    Pins[0].Dir := 'INOUT';
    Exit;
  end;
  if (Head = 'PTL') or (Head = 'PTLCAP') or (Head = 'BIAS') or (Head = 'BEND') then
  begin
    // Two through pins (a PTL cap is a short two-port segment too).
    SetLength(Pins, 2);
    Pins[0].Name := 'P0';
    Pins[0].Layer := Layer;
    Pins[0].DXUm := 0;
    Pins[0].Dir := 'IN';
    Pins[1].Name := 'P1';
    Pins[1].Layer := Layer;
    Pins[1].DXUm := GridPitchUm;
    Pins[1].Dir := 'OUT';
    Exit;
  end;
  // CELL / TRACK: leave blank for the user.
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
      B.LefFile := B.Name + '.lef';
      B.CirFile := B.Name + '.cir';
      // Unit-tile size seed; the user overrides width/height for their cells.
      B.SizeWUm := GridPitchUm;
      B.SizeHUm := GridPitchUm;
      if Kinds[k] = AlwaysRequiredKind then
      begin
        // TRACK: purely structural - no CIR, LEF optional. Show the optional
        // per-layer fill format (M0 here is a sample row; edit/replace it).
        B.StructuralOnly := True;
        B.LefFile := '';
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
          B.LefFile := '';
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
      KindTemplatePins(Kinds[k], GridPitchUm, B.Pins);
      Lib.AddBlock(Kinds[k], B);
    end;
    Lib.SaveFile(APath);
  finally
    Lib.Free;
  end;
end;

end.

unit ExportCIR;

// Phase 6 (CIR): builds a flat SPICE netlist for the routed design. Mirrors
// ExportGDS - the form-side RunCirExport gathers the design snapshot and calls
// BuildCirText here, so this unit owns the netlist construction and holds no
// form state. Shared with ExportGDS: the block enumeration (ExportScanAll) and
// the block-kind grammar (ExportLibrary) are the same machinery the GDS uses.
//
// Netlist shape:
//   * .include lines for the block-library subckts and each placed cell's .cir;
//   * one X-instance per placed cell, its pins bound to their netlist nets;
//   * one X-instance per routed PTL/VIA block - each a two-port element (a PTL
//     cap has a beginning and an end too) - chained node_i -> node_{i+1}, with
//     the driver/load cell pins bound to the ends (net_i / net_o);
//   * the bias family and structural (TRACK) blocks have no circuit equivalent
//     and are omitted; the block map is keyed by (cell, layer) so two PTL layers
//     may pass through one cell.
//
// Clone tolerance: the pipeline deep-clones models (so the user can step back
// and retry), so nothing here keys off gate pointers. Route endpoints are
// resolved by NET NAME + LEF port direction, and a clock pin is read from the
// clock model (where the row splitter trees / balancing buffers live) by gate
// index then by data-signature.

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Generics.Collections,
  PlacementTypes, BlifLibrary, ExportModel, ExportLibrary;

// Builds the .cir text. Lib must already be loaded from BlockRoot (its manifest
// and block kinds drive the includes). Model may be nil (no net binding).
function BuildCirText(const Traces: TArray<TRoutedTrace>;
  const BiasCells: TArray<TBiasCell>; const Layers: TArray<string>;
  const Cells: TArray<TPlacedComponent>;
  const ClockNodes: TArray<TArray<TPlacedClockNode>>;
  const Spine: TArray<TSpineComponent>; const Model, ClockModel: TBlifModel;
  const Lib: TExportLibrary; const BlockRoot, Stem: string): string;

// Builds the test-bench helper config written next to die.cir (die.tb.json): the
// clock net, the input/output nets, and the design numbers the Python tools need
// (clock frequency, PTL delay, core pitch, die size). Form-free.
function BuildTbJson(const Stem, ClockNet: string;
  const Inputs, Outputs: TArray<string>;
  const FreqGHz, PtlDelayPsPerUm, CoreUm, DieWUm, DieHUm,
  MaxPtlLengthUm: Double): string;

implementation

uses
  System.IOUtils, System.StrUtils, LefLibrary, UNetNaming;

function BuildCirText(const Traces: TArray<TRoutedTrace>;
  const BiasCells: TArray<TBiasCell>; const Layers: TArray<string>;
  const Cells: TArray<TPlacedComponent>;
  const ClockNodes: TArray<TArray<TPlacedClockNode>>;
  const Spine: TArray<TSpineComponent>; const Model, ClockModel: TBlifModel;
  const Lib: TExportLibrary; const BlockRoot, Stem: string): string;
var
  Body, Incs: TStringList;
  S, Sub: string;
  i, j, k, N: Integer;
  Ent: TExportBlockEntry;
  D: TExportDesign;
  CellKind: TDictionary<string, string>;   // (cell, layer) -> subckt name
  ViaKind: TDictionary<string, string>;    // via cell -> subckt name
  Clean: TArray<TPoint>;                   // trace points with same-cell hops merged
  CleanLayer: TArray<string>;              // routing layer of each cleaned point
  TracedNets: TDictionary<string, Boolean>;
  ClkNet: TDictionary<TGateInstance, string>; // placed gate -> clock-model clk net
  ClkSig: TDictionary<string, string>;        // gate data-signature -> clk net (fallback)
  CG: TGateInstance;
  CC: TPinConnection;
  ClkNetName: string;
  CirSub: TDictionary<string, string>;
  CirPorts: TDictionary<string, TArray<string>>;

  // A block is identified by its grid cell AND its routing layer: two PTL layers
  // can run through the same cell (never assuming one block per cell). Vias are
  // keyed by cell alone (a via cell carries no single-layer tile).
  function CellKeyOf(AX, AY: Integer; const ALayer: string): string;
  begin
    Result := IntToStr(AX) + '|' + IntToStr(AY) + '|' + ALayer;
  end;

  function ViaKeyOf(AX, AY: Integer): string;
  begin
    Result := IntToStr(AX) + '|' + IntToStr(AY) + '|#via';
  end;

  // A netlist-safe node name (SPICE identifiers).
  function Sanitize(const AName: string): string;
  var
    ch: Char;
  begin
    Result := '';
    for ch in AName do
      if CharInSet(ch, ['0'..'9', 'A'..'Z', 'a'..'z', '_', '.']) then
        Result := Result + ch
      else
        Result := Result + '_';
    if Result = '' then
      Result := 'n';
  end;

  function CellCirOf(const C: TCell): string;
  var
    jj: Integer;
  begin
    Result := '';
    if C = nil then
      Exit;
    for jj := 0 to C.SourceFiles.Count - 1 do
      if SameText(ExtractFileExt(C.SourceFiles[jj]), '.cir') then
        Exit(C.SourceFiles[jj]);
  end;

  // Reads (and caches) a .cir's first `.subckt <name> <ports...>`.
  procedure SubcktOf(const APath: string; out AName: string;
    out APorts: TArray<string>);
  var
    Lns: TArray<string>;
    ii, pp: Integer;
    Line, Tail: string;
  begin
    AName := '';
    APorts := nil;
    if CirSub.TryGetValue(APath, AName) and CirPorts.TryGetValue(APath, APorts) then
      Exit;
    if TFile.Exists(APath) then
    begin
      Lns := TFile.ReadAllLines(APath);
      for ii := 0 to High(Lns) do
      begin
        Line := Trim(Lns[ii]);
        if not SameText(Copy(Line, 1, 8), '.subckt ') then
          Continue;
        Tail := Trim(Copy(Line, 9, MaxInt));
        pp := Pos(' ', Tail);
        if pp = 0 then
          Continue;
        AName := Copy(Tail, 1, pp - 1);
        Tail := Trim(Copy(Tail, pp + 1, MaxInt));
        APorts := Tail.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
        Break;
      end;
    end;
    CirSub.AddOrSetValue(APath, AName);
    CirPorts.AddOrSetValue(APath, APorts);
  end;

  procedure AddInclude(const APath: string);
  begin
    if (APath <> '') and (Incs.IndexOf('.include ' + APath) < 0) then
      Incs.Add('.include ' + APath);
  end;

  function PinNet(const G: TGateInstance; const APin: string): string;
  var
    NC2: TPinConnection;
  begin
    Result := '';
    for NC2 in G.Connections do
      if SameText(NC2.PinName, APin) and (NC2.NetName <> '') then
        Exit(Sanitize(NC2.NetName));
  end;

  // Order-independent gate signature: cell name + the sorted set of its non-clk
  // pin->net pairs. Whether or not the clock model is index-aligned, the same
  // logical gate yields the same signature in both models, so the placed gate's
  // clock net can be looked up by tracing its data connections.
  function GateSig(const G: TGateInstance): string;
  var
    Pairs: TStringList;
    C: TPinConnection;
  begin
    Pairs := TStringList.Create;
    try
      for C in G.Connections do
        if not SameText(C.PinName, 'clk') then
          Pairs.Add(LowerCase(C.PinName) + '=' + LowerCase(C.NetName));
      Pairs.Sort;
      Result := LowerCase(G.CellName) + '|' + Pairs.CommaText;
    finally
      Pairs.Free;
    end;
  end;

  procedure EmitCell(const G: TGateInstance; const AInst: string);
  var
    Sub2, PN, Node, ClkName: string;
    APorts2: TArray<string>;
    PP: TPort;
  begin
    if (G = nil) or (G.Cell = nil) then
      Exit;
    SubcktOf(CellCirOf(G.Cell), Sub2, APorts2);
    if (Sub2 = '') or (Length(APorts2) = 0) then
      Exit;
    S := 'X' + Sanitize(AInst) + ' ';
    for PN in APorts2 do
    begin
      // Resolve this pin's netlist node:
      //  1. a clk pin comes from the CLOCK model (row splitter tree / balancing
      //     buffer) - the placement model's own clk connection is stale (it still
      //     says the root "clk"). Look it up by gate index (the placement /
      //     validation CloneToPlace mapping), then by data-signature (fully
      //     clone-safe), so it survives the deep clones;
      //  2. otherwise it is the gate's own connection net;
      //  3. bind to the route endpoint (<net>_i for an output pin, <net>_o for an
      //     input pin) when that net is routed, per the LEF port direction.
      Node := '';
      if SameText(PN, 'clk') then
      begin
        if ClkNet.TryGetValue(G, ClkName) then
          Node := Sanitize(ClkName)
        else if ClkSig.TryGetValue(GateSig(G), ClkName) then
          Node := Sanitize(ClkName);
      end;
      if Node = '' then
        Node := PinNet(G, PN);
      if (Node = '') and SameText(PN, 'clk') and (G.ClockLevel >= 0) then
        Node := Sanitize(UNetNaming.ClockRowNetName(G.ClockLevel));
      if (Node <> '') and TracedNets.ContainsKey(Node) then
      begin
        PP := nil;
        if G.Cell <> nil then
          PP := G.Cell.FindPort(PN);
        if (PP <> nil) and (PP.Direction = pdOutput) then
          Node := Node + '_i'
        else
          Node := Node + '_o';
      end;
      if Node = '' then
        Node := Sanitize(AInst) + '_' + Sanitize(PN);
      S := S + Node + ' ';
    end;
    S := S + Sub2;
    Body.Add(S);
    AddInclude(CellCirOf(G.Cell));
  end;

  procedure MapCell(const AX, AY: Integer; const ALayer, ASub: string);
  begin
    if ASub <> '' then
      CellKind.AddOrSetValue(CellKeyOf(AX, AY, ALayer), ASub);
  end;

  // The chain node at boundary index AIdx of an N-block trace: net_i at the
  // driver end (index 0), net_o at the load end (index N), interior between.
  function NodeOf(const ANet: string; AIdx, AN: Integer): string;
  begin
    if AIdx <= 0 then
      Result := Sanitize(ANet) + '_i'
    else if AIdx >= AN then
      Result := Sanitize(ANet) + '_o'
    else
      Result := Sanitize(ANet) + '_' + IntToStr(AIdx);
  end;

begin
  Body := TStringList.Create;
  Incs := TStringList.Create;
  CirSub := TDictionary<string, string>.Create;
  CirPorts := TDictionary<string, TArray<string>>.Create;
  CellKind := TDictionary<string, string>.Create;
  ViaKind := TDictionary<string, string>.Create;
  TracedNets := TDictionary<string, Boolean>.Create;
  ClkNet := TDictionary<TGateInstance, string>.Create;
  ClkSig := TDictionary<string, string>.Create;
  try
    if Lib.SpiceInclude <> '' then
      AddInclude(Lib.SpiceInclude);
    for S in Lib.Blocks.Keys do
      if Lib.GetBlock(S, Ent) and (Ent.CirFile <> '') then
        AddInclude(TPath.Combine(BlockRoot, Ent.CirFile));

    // Block kinds (from the export enumeration), keyed by (cell, layer) so two
    // PTL layers through one cell stay distinct. ONLY the PTL family: bias blocks
    // share the grid and would otherwise clobber the PTL block at a cell.
    ExportScanAll(Traces, BiasCells, Layers, D);
    for i := 0 to High(D.Runs) do
      if D.Runs[i].Family = xfPtl then
      begin
        Sub := KindDefaultName(KindRun(D.Runs[i].Family, D.Runs[i].Layer, D.Runs[i].Taps));
        for k := 0 to D.Runs[i].Count - 1 do
          if D.Runs[i].Dir = xdH then
            MapCell(D.Runs[i].X0 + k, D.Runs[i].Y0, D.Runs[i].Layer, Sub)
          else
            MapCell(D.Runs[i].X0, D.Runs[i].Y0 + k, D.Runs[i].Layer, Sub);
      end;
    for i := 0 to High(D.Bends) do
      if D.Bends[i].Family = xfPtl then
        MapCell(D.Bends[i].X, D.Bends[i].Y, D.Bends[i].Layer,
          KindDefaultName(KindBend(D.Bends[i].Family, D.Bends[i].Layer, D.Bends[i].Taps)));
    for i := 0 to High(D.ViaBlocks) do
      ViaKind.AddOrSetValue(ViaKeyOf(D.ViaBlocks[i].X, D.ViaBlocks[i].Y),
        KindDefaultName(KindVia(D.ViaBlocks[i].LoLayer, D.ViaBlocks[i].HiLayer,
          D.ViaBlocks[i].Kind, D.ViaBlocks[i].Variant)));
    for i := 0 to High(D.Terminals) do
      if D.Terminals[i].Family = xfPtl then
        MapCell(D.Terminals[i].X, D.Terminals[i].Y, D.Terminals[i].Layer,
          KindDefaultName(KindCap(D.Terminals[i].Family, D.Terminals[i].Layer,
            D.Terminals[i].Taps)));

    // Routed (PTL) nets: a cell pin sitting on one of these is bound to the
    // route's endpoint (<net>_i / <net>_o) in EmitCell.
    for i := 0 to High(Traces) do
      if not UNetNaming.IsBiasNetName(Traces[i].NetName) then
        TracedNets.AddOrSetValue(Sanitize(Traces[i].NetName), True);

    // The placed logic gates come from FPlacementModel (the pre-clock model) and
    // carry no clk connection (BLIF omits clk=). The clock tree - row splitter
    // trees + balancing buffers - lives in ClockModel. Placement and validation
    // map the two models by gate index (Placement.inc CloneToPlace), so do the
    // same: Model.Gates[i] <-> ClockModel.Gates[i]. A data-signature map is kept
    // as a fallback for any gate whose index has drifted.
    if ClockModel <> nil then
      for i := 0 to ClockModel.Gates.Count - 1 do
      begin
        CG := ClockModel.Gates[i];
        ClkNetName := '';
        for CC in CG.Connections do
          if SameText(CC.PinName, 'clk') and (CC.NetName <> '') then
          begin
            ClkNetName := CC.NetName;
            Break;
          end;
        if ClkNetName = '' then
          Continue;
        if (Model <> nil) and (i < Model.Gates.Count) then
          ClkNet.AddOrSetValue(Model.Gates[i], ClkNetName);
        ClkSig.AddOrSetValue(GateSig(CG), ClkNetName);
      end;

    Body.Add(Format('* %s - SPICE netlist (flat)', [Stem]));
    Body.Add('');
    if (Model <> nil) and (ClockModel <> nil) then
      Body.Add(Format('* clock map: model=%d clock=%d clknet=%d clksig=%d',
        [Model.Gates.Count, ClockModel.Gates.Count, ClkNet.Count, ClkSig.Count]));

    // PTL + VIA block instances: one per trace point, chained by shared nodes.
    // The per-unit models are symmetric, so rotation is irrelevant - the wiring
    // is positional.
    for k := 0 to High(Traces) do
    begin
      if UNetNaming.IsBiasNetName(Traces[k].NetName) then
        Continue;
      // Merge consecutive same-cell points: a via is a same-cell layer hop, so it
      // is ONE block, not two. Keep each point's routing layer.
      SetLength(Clean, 0);
      SetLength(CleanLayer, 0);
      for i := 0 to High(Traces[k].Points) do
        if (i = 0) or
           (Traces[k].Points[i].X <> Traces[k].Points[i - 1].X) or
           (Traces[k].Points[i].Y <> Traces[k].Points[i - 1].Y) then
        begin
          SetLength(Clean, Length(Clean) + 1);
          Clean[High(Clean)] := Traces[k].Points[i];
          SetLength(CleanLayer, Length(CleanLayer) + 1);
          if i <= High(Traces[k].Layers) then
            CleanLayer[High(CleanLayer)] := Traces[k].Layers[i]
          else
            CleanLayer[High(CleanLayer)] := '';
        end;
      N := Length(Clean);
      if N < 2 then
        Continue;
      for i := 0 to N - 1 do
      begin
        // (cell, layer) block; a via cell has no single-layer tile, so fall back.
        Sub := '';
        if not CellKind.TryGetValue(CellKeyOf(Clean[i].X, Clean[i].Y, CleanLayer[i]), Sub) then
          if not ViaKind.TryGetValue(ViaKeyOf(Clean[i].X, Clean[i].Y), Sub) then
            Continue;
        // Every block is a two-port element (a PTL cap has a beginning and an
        // end too), chained node_i -> node_{i+1}; the pins bind to the ends.
        Body.Add(Format('X%s_t%d %s %s %s',
          [Sanitize(Traces[k].NetName), i,
           NodeOf(Traces[k].NetName, i, N),
           NodeOf(Traces[k].NetName, i + 1, N), Sub]));
      end;
    end;

    // Placed cells (logic, clock-tree interiors, clock trunk).
    for i := 0 to High(Cells) do
      EmitCell(Cells[i].Gate, Cells[i].InstanceName);
    for i := 0 to High(ClockNodes) do
      for j := 0 to High(ClockNodes[i]) do
        if (not ClockNodes[i][j].IsLeaf) and (ClockNodes[i][j].Gate <> nil) then
          EmitCell(ClockNodes[i][j].Gate,
            Format('%s_%d_%d', [ClockNodes[i][j].Gate.CellName, i, j]));
    for i := 0 to High(Spine) do
      if Spine[i].Gate <> nil then
        EmitCell(Spine[i].Gate, Format('%s_sp%d', [Spine[i].Gate.CellName, i]));

    // Prepend the includes (block subckts + cell subckts).
    Body.Insert(0, '');
    Body.Insert(0, '* --- subcircuit includes ---');
    for i := Incs.Count - 1 downto 0 do
      Body.Insert(1, Incs[i]);

    Result := Body.Text;
  finally
    ClkSig.Free;
    ClkNet.Free;
    TracedNets.Free;
    ViaKind.Free;
    CellKind.Free;
    CirPorts.Free;
    CirSub.Free;
    Incs.Free;
    Body.Free;
  end;
end;

function BuildTbJson(const Stem, ClockNet: string;
  const Inputs, Outputs: TArray<string>;
  const FreqGHz, PtlDelayPsPerUm, CoreUm, DieWUm, DieHUm,
  MaxPtlLengthUm: Double): string;
var
  S: TStringList;
  FS: TFormatSettings;

  function Q(const V: string): string;
  var
    ch: Char;
  begin
    Result := '"';
    for ch in V do
      if ch = '"' then
        Result := Result + '\"'
      else if ch = '\' then
        Result := Result + '\\'
      else
        Result := Result + ch;
    Result := Result + '"';
  end;

  function Arr(const A: TArray<string>): string;
  var
    k: Integer;
  begin
    Result := '[';
    for k := 0 to High(A) do
    begin
      if k > 0 then
        Result := Result + ', ';
      Result := Result + Q(A[k]);
    end;
    Result := Result + ']';
  end;

  function Num(const V: Double): string;
  begin
    Result := FloatToStr(V, FS);
  end;

begin
  FS := TFormatSettings.Invariant;
  S := TStringList.Create;
  try
    S.Add('{');
    S.Add(Format('  "stem": %s,', [Q(Stem)]));
    S.Add(Format('  "clock": %s,', [Q(ClockNet)]));
    S.Add(Format('  "inputs": %s,', [Arr(Inputs)]));
    S.Add(Format('  "outputs": %s,', [Arr(Outputs)]));
    S.Add(Format('  "freqGHz": %s,', [Num(FreqGHz)]));
    S.Add(Format('  "ptlDelayPsPerUm": %s,', [Num(PtlDelayPsPerUm)]));
    S.Add(Format('  "coreUm": %s,', [Num(CoreUm)]));
    S.Add(Format('  "dieWUm": %s,', [Num(DieWUm)]));
    S.Add(Format('  "dieHUm": %s,', [Num(DieHUm)]));
    S.Add(Format('  "maxPtlLengthUm": %s', [Num(MaxPtlLengthUm)]));
    S.Add('}');
    Result := S.Text;
  finally
    S.Free;
  end;
end;

end.

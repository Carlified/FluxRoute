unit ExportModel;

// Phase 1 of the export feature: the neutral block enumeration. Walks the routed
// traces and produces the block KINDS the block library must contain (each block
// is a GDS cell + LEF macro + CIR subckt triple). Pure: no form state.
//
// Block model (per the owner):
//  * processes are direction-agnostic: a run's direction is stored only for the
//    instance's rotation, never part of a kind;
//  * a via is NEVER a standalone block - it is absorbed into a composite cell.
//    One kind per (lower, higher) metal PAIR: the trace direction is irrelevant
//    (M1>M3 == M3>M1), so the pair is stored low-first and the block is authored
//    with the LOWER metal on the W side:
//      - straight (higher exits E)
//      - bend (higher exits N or S: the two mirror variants)
//      - turnaround (higher exits W, same side - geometrically direction-free)
//  * a pure 90 deg turn (single layer) is its own bend block;
//  * bias blocks: straight, curved, 3-connection and 4-connection junctions;
//  * the `frame/ground track` tile is ALWAYS required (a general foundation
//    block), even though it is not derived from the wire walk;
//  * pads are not supported yet - not enumerated;
//  * placed cells are enumerated by cell name (every cell file accounted for).

interface

uses
  System.Types, System.Generics.Collections, System.SysUtils,
  PlacementTypes, UNetNaming;

type
  TExportFamily = (xfPtl, xfBias);
  TExportDir = (xdH, xdV);
  TExportViaKind = (vkViaStraight, vkViaBend, vkViaTurn);

  // Pure straight run on one layer. Count = number of unit cells tiled; covers
  // Count cells from (X0,Y0) along Dir (block-based, identical for bias and PTL).
  TExportRun = record
    Net: string;
    Family: TExportFamily;
    Layer: string;
    Dir: TExportDir;   // rotation only - NOT part of the kind
    X0, Y0: Integer;   // start grid cell (block coords)
    Count: Integer;    // number of unit cells tiled along Dir
    Taps: string;      // canonical tap directions ('' = none)
  end;

  // A 90 deg turn of one line on a single layer (one kind; left/right under
// rotation). InX/InY are the unit direction the wire TRAVELLED when it entered
// the corner cell; OutX/OutY the unit direction it leaves - used to rotate the
// authored corner block to match this exact turn.
  TExportBend = record
    Net: string;
    Family: TExportFamily;
    Layer: string;
    X, Y: Integer; // the turn cell
    InX, InY: Integer;   // unit arrival heading (+-1)
    OutX, OutY: Integer; // unit departure heading (+-1)
    Taps: string;        // canonical tap directions ('' = none)
  end;

  // A via composite that carries one via + its adjacent line stubs. Never emitted
  // on its own body (the via's geometry lives inside this block). One kind per
  // (lower, higher) metal PAIR - the trace direction is irrelevant, so the pair
  // is stored low-first and the block is authored with the LOWER metal on the W
  // side. Styles: straight (higher exits E), bend (higher exits N or S - the two
  // mirror variants, Variant +1/-1) and turnaround (higher exits W, same side).
  TExportViaBlock = record
    Net: string;
    LoLayer, HiLayer: string;  // lower / higher metal (canonical order)
    Kind: TExportViaKind;
    Variant: Integer;          // vkViaBend: +1 higher exits N, -1 higher exits S; else 0
    X, Y: Integer;             // the via cell
    RotDeg: Integer;           // rotation (deg) that brings the lower stub to W
  end;

  // A bias junction with 3 or 4 line ends (a T or a cross).
  TExportSplit = record
    Net: string;
    Layer: string;
    X, Y: Integer;
    ConnCount: Integer; // 3 or 4 (number of distinct line ends at the cell)
    Dirs: Byte;         // neighbour direction bits (BiasDirN/E/S/W)
    Taps: string;       // canonical tap directions ('' = none)
  end;

  // A degree-1 end of a line: a pin contact. Placed as a cap block whose single
  // stub points at the wire.
  TExportTerminal = record
    Net: string;
    Family: TExportFamily;
    Layer: string;
    X, Y: Integer;
    Dirs: Byte;         // the one neighbour direction (BiasDirN/E/S/W)
    Taps: string;       // canonical tap directions ('' = none)
  end;

  TExportDesign = record
    Runs: TArray<TExportRun>;
    Bends: TArray<TExportBend>;
    ViaBlocks: TArray<TExportViaBlock>; // via composites (never standalone)
    Splits: TArray<TExportSplit>;
    Terminals: TArray<TExportTerminal>;
  end;

  TExportCellCount = record
    Name: string;
    Count: Integer;
  end;

// Decomposes every routed trace into the instance arrays of D. LayerOrder is the
// routing layer stack (bottom-to-top), used to order via metal pairs.
procedure ExportScanTraces(const Traces: TArray<TRoutedTrace>;
  const LayerOrder: TArray<string>; out D: TExportDesign);

// Decomposes the block-based bias network (one cell per grid block, with the
// neighbour directions each cell connects to) into the same instance arrays as
// the trace scan, so bias lines enumerate with exactly the same classification.
procedure ExportScanBias(const Cells: TArray<TBiasCell>; var D: TExportDesign);

// Scan of both: PTL traces then bias cells (the single export entry point).
procedure ExportScanAll(const Traces: TArray<TRoutedTrace>;
  const BiasCells: TArray<TBiasCell>; const LayerOrder: TArray<string>;
  out D: TExportDesign);

// The direction bit (BiasDirN/E/S/W) of a unit step, 0 if not axis-aligned.
function DirBitOf(DX, DY: Integer): Byte;

// Rotation steps (0..3) that map the canonical authored block for a cell's
// connection set onto the actual set. Authored blocks always touch the W side
// and continue counterclockwise: cap {W}, bend {W,S}, straight {W,E},
// 3-way {W,S,E}, 4-way {W,S,E,N}; the returned step is multiplied by 90 for the
// instance's rotation (data direction is irrelevant - the geometry just rotates).
function NodeRotation(Actual: Byte): Integer;

// Tallies placed cell types by name (CellName) for the CELL block inventory.
procedure ExportScanCells(const CellNames: TArray<string>;
  out Cells: TArray<TExportCellCount>);

implementation

const
  RowSpan = 16384;            // cells per row in the key space
  RowHalf = RowSpan div 2;
  EdgeBase = Int64(1) shl 28; // packing base for edge keys (any cell < 2^28)

function CellKey(X, Y: Integer): Int64;
begin
  Result := (Int64(Y + RowHalf) * RowSpan) + Int64(X + RowHalf);
end;

procedure CellXY(Key: Int64; var X, Y: Integer);
begin
  Y := Integer(Key div RowSpan) - RowHalf;
  X := Integer(Key mod RowSpan) - RowHalf;
end;

function SignOf(V: Integer): Integer;
begin
  if V > 0 then
    Result := 1
  else if V < 0 then
    Result := -1
  else
    Result := 0;
end;

function PackEdge(A, B: Int64): Int64;
begin
  if A > B then
    Result := B * EdgeBase + A
  else
    Result := A * EdgeBase + B;
end;

procedure UnpackEdge(Key: Int64; var A, B: Int64);
begin
  A := Key div EdgeBase;
  B := Key mod EdgeBase;
end;

function DirBitOf(DX, DY: Integer): Byte;
begin
  if (DX > 0) and (DY = 0) then
    Result := BiasDirE
  else if (DX < 0) and (DY = 0) then
    Result := BiasDirW
  else if (DX = 0) and (DY > 0) then
    Result := BiasDirS
  else if (DX = 0) and (DY < 0) then
    Result := BiasDirN
  else
    Result := 0;
end;

// The cycle index of a single direction bit: W=0, S=1, E=2, N=3.
function DirIndex(ABit: Byte): Integer;
begin
  if ABit = BiasDirW then
    Result := 0
  else if ABit = BiasDirS then
    Result := 1
  else if ABit = BiasDirE then
    Result := 2
  else
    Result := 3; // BiasDirN (and the 0 sentinel)
end;

// Position of a layer in the routing stack (bottom-to-top); MaxInt if unknown.
function LayerRank(const Order: TArray<string>; const AName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Order) do
    if SameText(Order[i], AName) then
      Exit(i);
  Result := MaxInt;
end;

// The bit at cycle index j (W=0, S=1, E=2, N=3).
function IdxBit(j: Integer): Byte;
begin
  case ((j mod 4) + 4) mod 4 of
    0: Result := BiasDirW;
    1: Result := BiasDirS;
    2: Result := BiasDirE;
  else
    Result := BiasDirN;
  end;
end;

// Rotate a direction set by Steps in the W->S->E->N cycle.
function RotMask(M: Byte; Steps: Integer): Byte;
begin
  Result := 0;
  if (M and BiasDirW) <> 0 then
    Result := Result or IdxBit(0 + Steps);
  if (M and BiasDirS) <> 0 then
    Result := Result or IdxBit(1 + Steps);
  if (M and BiasDirE) <> 0 then
    Result := Result or IdxBit(2 + Steps);
  if (M and BiasDirN) <> 0 then
    Result := Result or IdxBit(3 + Steps);
end;

function PopCount(M: Byte): Integer;
begin
  Result := 0;
  if (M and BiasDirW) <> 0 then Inc(Result);
  if (M and BiasDirS) <> 0 then Inc(Result);
  if (M and BiasDirE) <> 0 then Inc(Result);
  if (M and BiasDirN) <> 0 then Inc(Result);
end;

function NodeRotation(Actual: Byte): Integer;
var
  Authored: Byte;
  k: Integer;
begin
  case PopCount(Actual) of
    1: Authored := BiasDirW;
    2: if ((Actual and (BiasDirW or BiasDirE)) = (BiasDirW or BiasDirE)) or
          ((Actual and (BiasDirN or BiasDirS)) = (BiasDirN or BiasDirS)) then
         Authored := BiasDirW or BiasDirE   // straight: opposite pair
       else
         Authored := BiasDirW or BiasDirS;  // bend: adjacent pair
    3: Authored := BiasDirW or BiasDirS or BiasDirE;
  else
    Authored := BiasDirW or BiasDirS or BiasDirE or BiasDirN;
  end;
  Result := 0;
  for k := 0 to 3 do
    if RotMask(Authored, k) = Actual then
    begin
      Result := k;
      Exit;
    end;
end;

// Canonical tap token for a node: the authored-frame tap directions (the tap
// mask rotated back by the node's rotation), as letters in W,S,E,N order. ''
// when the node has no taps.
function TapToken(const Dirs, Taps: Byte): string;
var
  Canon: Byte;
begin
  Result := '';
  if (Taps and Dirs) = 0 then
    Exit;
  Canon := RotMask(Taps and Dirs, -NodeRotation(Dirs));
  if (Canon and BiasDirW) <> 0 then Result := Result + 'W';
  if (Canon and BiasDirS) <> 0 then Result := Result + 'S';
  if (Canon and BiasDirE) <> 0 then Result := Result + 'E';
  if (Canon and BiasDirN) <> 0 then Result := Result + 'N';
end;

type
  TLAdj = TDictionary<string, TDictionary<Int64, TList<Int64>>>;
  TLVist = TDictionary<string, TDictionary<Int64, Boolean>>;

procedure FreeLAdj(const Adj: TLAdj);
var
  L: string;
  D: TDictionary<Int64, TList<Int64>>;
  Lst: TList<Int64>;
begin
  for L in Adj.Keys do
  begin
    D := Adj[L];
    for Lst in D.Values do
      Lst.Free;
    D.Free;
  end;
  Adj.Free;
end;

procedure FreeLVist(const V: TLVist);
var
  L: string;
begin
  for L in V.Keys do
    V[L].Free;
  V.Free;
end;

// Classifies one per-layer cell graph (built from PTL trace points or bias
// cells - both arrive here the same way) into straight runs, bends, junctions
// and terminals. A run is made of pass-through cells only: a cell with any
// off-axis neighbour (a bend, a T/cross junction, or a via) is a NODE that
// owns its own block and is never tiled by a run - so a bias 3-way split can
// no longer be hidden under a straight tile.
procedure ClassifyNodes(const Adj: TLAdj; const Vis: TLVist;
  const ViaCells: TDictionary<Int64, Boolean>;
  const TapCells: TDictionary<Int64, Byte>; const ANetName: string;
  const AFam: TExportFamily; var D: TExportDesign);
var
  L: string;
  LAdj: TDictionary<Int64, TList<Int64>>;
  LVis: TDictionary<Int64, Boolean>;
  EK, EK2, N, Nxt, CK, N1, N2: Int64;
  X, Y, Xn, Yn, P1X, P1Y: Integer;
  ci: Integer;
  Axis: Integer;         // 0 = horizontal, 1 = vertical (per current run)
  RunDirs: Byte;
  RunCells: TList<Int64>;
  R: TExportRun;
  Bnd: TExportBend;
  Sp: TExportSplit;
  Tm: TExportTerminal;

  // The tap mask recorded for a cell (0 when it has none / is a PTL cell).
  function TapOf(const C: Int64): Byte;
  begin
    if not TapCells.TryGetValue(C, Result) then
      Result := 0;
  end;

  // The cell may be a straight pass-through member of a run on the current
  // axis: it is not a via and every neighbour sits on the axis (so bends,
  // T/cross junctions and dead-end pads never join runs - they classify as
  // nodes in step 4).
  function IsRunCell(const ACell: Int64): Boolean;
  var
    j, XX, YY, NX, NY: Integer;
  begin
    Result := False;
    if ViaCells.ContainsKey(ACell) then
      Exit;
    if not LAdj.ContainsKey(ACell) then
      Exit;
    if LAdj[ACell].Count <> 2 then
      Exit;
    CellXY(ACell, XX, YY);
    for j := 0 to LAdj[ACell].Count - 1 do
    begin
      CellXY(LAdj[ACell][j], NX, NY);
      if (Axis = 0) and (NY <> YY) then
        Exit(False);
      if (Axis = 1) and (NX <> XX) then
        Exit(False);
    end;
    Result := True;
  end;

  // The adjacent cell one grid block along the current axis (0 when it would
  // sit outside the key space).
  function NextAxisCell(const ACell: Int64; Step: Integer): Int64;
  var
    XX, YY: Integer;
  begin
    CellXY(ACell, XX, YY);
    if Axis = 0 then
      Result := CellKey(XX + Step, YY)
    else
      Result := CellKey(XX, YY + Step);
  end;

begin
  RunCells := TList<Int64>.Create;
  try
    // ---- 3. Maximal straight runs per layer ----
    for L in Vis.Keys do
    begin
      LAdj := Adj[L];
      LVis := Vis[L];
      for EK in LVis.Keys do
      begin
        if LVis[EK] then
          Continue;
        UnpackEdge(EK, N, Nxt);
        LVis[EK] := True;
        CellXY(N, X, Y);
        CellXY(Nxt, Xn, Yn);
        if (Y = Yn) and (X <> Xn) then
          Axis := 0
        else if (X = Xn) and (Y <> Yn) then
          Axis := 1
        else
          Continue;
        if not (IsRunCell(N) or IsRunCell(Nxt)) then
          Continue; // the seed edge touches only node cells: no straight run
        RunCells.Clear;
        if IsRunCell(N) then
          RunCells.Add(N);
        if IsRunCell(Nxt) then
          RunCells.Add(Nxt);
        // Grow the run backward along the axis.
        N := RunCells[0];
        while True do
        begin
          Nxt := NextAxisCell(N, -1);
          if Nxt = 0 then
            Break;
          if not IsRunCell(Nxt) then
            Break;
          EK2 := PackEdge(N, Nxt);
          if not LVis.ContainsKey(EK2) then
            Break;
          if LVis[EK2] then
            Break;
          LVis[EK2] := True;
          RunCells.Insert(0, Nxt);
          N := Nxt;
        end;
        // Grow the run forward along the axis.
        N := RunCells[RunCells.Count - 1];
        while True do
        begin
          Nxt := NextAxisCell(N, 1);
          if Nxt = 0 then
            Break;
          if not IsRunCell(Nxt) then
            Break;
          EK2 := PackEdge(N, Nxt);
          if not LVis.ContainsKey(EK2) then
            Break;
          if LVis[EK2] then
            Break;
          LVis[EK2] := True;
          RunCells.Add(Nxt);
          N := Nxt;
        end;
        R.Net := ANetName;
        R.Family := AFam;
        R.Layer := L;
        CellXY(RunCells[0], R.X0, R.Y0);
        if Axis = 0 then
          R.Dir := xdH
        else
          R.Dir := xdV;
        R.Count := RunCells.Count;
        if Axis = 0 then
          RunDirs := BiasDirW or BiasDirE
        else
          RunDirs := BiasDirN or BiasDirS;
        R.Taps := TapToken(RunDirs, TapOf(RunCells[0]));
        SetLength(D.Runs, Length(D.Runs) + 1);
        D.Runs[High(D.Runs)] := R;
      end;
    end;

    // ---- 4. Node classification: terminals (deg 1), bends (deg 2, 90 deg),
    //         bias junctions (deg >= 3, conn count = deg). Via cells are their
    //         own kind, skipped here. ----
    for L in Adj.Keys do
    begin
      LAdj := Adj[L];
      for CK in LAdj.Keys do
      begin
        if ViaCells.ContainsKey(CK) then
          Continue;
        if LAdj[CK].Count = 1 then
        begin
          Tm.Net := ANetName;
          Tm.Family := AFam;
          Tm.Layer := L;
          CellXY(CK, Tm.X, Tm.Y);
          CellXY(LAdj[CK][0], Xn, Yn);
          Tm.Dirs := DirBitOf(Xn - Tm.X, Yn - Tm.Y);
          Tm.Taps := TapToken(Tm.Dirs, TapOf(CK));
          SetLength(D.Terminals, Length(D.Terminals) + 1);
          D.Terminals[High(D.Terminals)] := Tm;
        end
        else if LAdj[CK].Count = 2 then
        begin
          N1 := LAdj[CK][0];
          N2 := LAdj[CK][1];
          CellXY(CK, X, Y);
          CellXY(N1, Xn, Yn);
          if (Xn <> X) and (Yn = Y) then // N1 horizontal
          begin
            P1X := Xn;
            P1Y := Yn;
            CellXY(N2, Xn, Yn);
            if (Xn = X) and (Yn <> Y) then
            begin
              Bnd.Net := ANetName;
              Bnd.Family := AFam;
              Bnd.Layer := L;
              Bnd.X := X;
              Bnd.Y := Y;
              // Arrival heading along N1 (horizontal), departure along N2.
              Bnd.InX := SignOf(X - P1X);
              Bnd.InY := 0;
              Bnd.OutX := 0;
              Bnd.OutY := SignOf(Yn - Y);
              Bnd.Taps := TapToken(DirBitOf(-Bnd.InX, -Bnd.InY) or DirBitOf(Bnd.OutX, Bnd.OutY), TapOf(CK));
              SetLength(D.Bends, Length(D.Bends) + 1);
              D.Bends[High(D.Bends)] := Bnd;
            end;
          end
          else if (Xn = X) and (Yn <> Y) then // N1 vertical
          begin
            P1X := Xn;
            P1Y := Yn;
            CellXY(N2, Xn, Yn);
            if (Xn <> X) and (Yn = Y) then
            begin
              Bnd.Net := ANetName;
              Bnd.Family := AFam;
              Bnd.Layer := L;
              Bnd.X := X;
              Bnd.Y := Y;
              Bnd.InX := 0;
              Bnd.InY := SignOf(Y - P1Y);
              Bnd.OutX := SignOf(Xn - X);
              Bnd.OutY := 0;
              Bnd.Taps := TapToken(DirBitOf(-Bnd.InX, -Bnd.InY) or DirBitOf(Bnd.OutX, Bnd.OutY), TapOf(CK));
              SetLength(D.Bends, Length(D.Bends) + 1);
              D.Bends[High(D.Bends)] := Bnd;
            end;
          end;
        end
        else
        begin
          Sp.Net := ANetName;
          Sp.Layer := L;
          CellXY(CK, Sp.X, Sp.Y);
          Sp.ConnCount := LAdj[CK].Count;
          Sp.Dirs := 0;
          for ci := 0 to LAdj[CK].Count - 1 do
          begin
            CellXY(LAdj[CK][ci], Xn, Yn);
            Sp.Dirs := Sp.Dirs or DirBitOf(Xn - Sp.X, Yn - Sp.Y);
          end;
          Sp.Taps := TapToken(Sp.Dirs, TapOf(CK));
          SetLength(D.Splits, Length(D.Splits) + 1);
          D.Splits[High(D.Splits)] := Sp;
        end;
      end;
    end;
  finally
    RunCells.Free;
  end;
end;

procedure ScanOne(const Trace: TRoutedTrace; const LayerOrder: TArray<string>;
  var D: TExportDesign);
var
  Fam: TExportFamily;
  Adj: TLAdj;
  Vis: TLVist;
  ViaCells: TDictionary<Int64, Boolean>;
  TapCells: TDictionary<Int64, Byte>;
  k: Integer;
  LAdj: TDictionary<Int64, TList<Int64>>;
  CA, CB, EK, CK: Int64;
  InX, InY, OutX, OutY: Integer;
  m: Integer;
  Below, Above: string;
  ASide, DSide, LoSide, HiSide: Byte;
  V: TExportViaBlock;

begin
  if Length(Trace.Points) < 2 then
    Exit;
  if UNetNaming.IsBiasNetName(Trace.NetName) then
    Fam := xfBias
  else
    Fam := xfPtl;

  Adj := TLAdj.Create;
  Vis := TLVist.Create;
  ViaCells := TDictionary<Int64, Boolean>.Create;
  TapCells := TDictionary<Int64, Byte>.Create;
  try
    // ---- 1. Undirected unit-edge set per layer (deduplicated) ----
    for k := 0 to High(Trace.Points) - 1 do
    begin
      CA := CellKey(Trace.Points[k].X, Trace.Points[k].Y);
      CB := CellKey(Trace.Points[k + 1].X, Trace.Points[k + 1].Y);
      if CA = CB then
        Continue;
      if not Adj.TryGetValue(Trace.Layers[k], LAdj) then
      begin
        LAdj := TDictionary<Int64, TList<Int64>>.Create;
        Adj.Add(Trace.Layers[k], LAdj);
        Vis.Add(Trace.Layers[k], TDictionary<Int64, Boolean>.Create);
      end;
      EK := PackEdge(CA, CB);
      if not Vis[Trace.Layers[k]].ContainsKey(EK) then
      begin
        Vis[Trace.Layers[k]].Add(EK, False);
        if not LAdj.ContainsKey(CA) then
          LAdj.Add(CA, TList<Int64>.Create);
        LAdj[CA].Add(CB);
        if not LAdj.ContainsKey(CB) then
          LAdj.Add(CB, TList<Int64>.Create);
        LAdj[CB].Add(CA);
      end;
    end;

    // ---- 2. Via composites at every point where the routed layer changes ----
    for k := 1 to High(Trace.Points) do
      if Trace.Layers[k] <> Trace.Layers[k - 1] then
      begin
        CK := CellKey(Trace.Points[k].X, Trace.Points[k].Y);
        Below := Trace.Layers[k - 1];
        Above := Trace.Layers[k];
        V.Net := Trace.NetName;
        V.X := Trace.Points[k].X;
        V.Y := Trace.Points[k].Y;
        V.Kind := vkViaStraight;
        V.Variant := 0;
        V.RotDeg := 0;
        // Arrival/departure sides. A via is a SAME-CELL layer hop, so P[k] repeats
        // P[k-1] and the naive step is zero; the real headings are the last /
        // first non-zero steps across the repeated cell (this also handles a
        // layer change between two distinct cells).
        InX := 0;
        InY := 0;
        m := k;
        while (m >= 1) and (Trace.Points[m].X = Trace.Points[m - 1].X) and
              (Trace.Points[m].Y = Trace.Points[m - 1].Y) do
          Dec(m);
        if m >= 1 then
        begin
          InX := Trace.Points[m].X - Trace.Points[m - 1].X;
          InY := Trace.Points[m].Y - Trace.Points[m - 1].Y;
        end;
        OutX := 0;
        OutY := 0;
        m := k;
        while (m < High(Trace.Points)) and
              (Trace.Points[m].X = Trace.Points[m + 1].X) and
              (Trace.Points[m].Y = Trace.Points[m + 1].Y) do
          Inc(m);
        if m < High(Trace.Points) then
        begin
          OutX := Trace.Points[m + 1].X - Trace.Points[m].X;
          OutY := Trace.Points[m + 1].Y - Trace.Points[m].Y;
        end;
        ASide := DirBitOf(-InX, -InY);
        DSide := DirBitOf(OutX, OutY);
        // Lower metal = earlier in the stack; store the pair low-first and put
        // the lower metal's stub on the W side of the authored block.
        if LayerRank(LayerOrder, Below) <= LayerRank(LayerOrder, Above) then
        begin
          V.LoLayer := Below;
          V.HiLayer := Above;
          LoSide := ASide;
          HiSide := DSide;
        end
        else
        begin
          V.LoLayer := Above;
          V.HiLayer := Below;
          LoSide := DSide;
          HiSide := ASide;
        end;
        if (LoSide = 0) or (HiSide = 0) then
          // Trace starts/ends at the via: degenerate, keep a plain straight.
          V.Kind := vkViaStraight
        else
        begin
          // Rotate so the lower stub lands on W: steps = idx(lower side).
          V.RotDeg := 90 * DirIndex(LoSide);
          // Where the higher stub sits once the lower is on W.
          case ((DirIndex(HiSide) - DirIndex(LoSide)) mod 4 + 4) mod 4 of
            2: V.Kind := vkViaStraight;                 // opposite -> straight
            1: begin V.Kind := vkViaBend; V.Variant := -1; end; // higher exits S
            3: begin V.Kind := vkViaBend; V.Variant := 1; end;  // higher exits N
          else
            V.Kind := vkViaTurn;                        // same side -> turnaround
          end;
        end;
        SetLength(D.ViaBlocks, Length(D.ViaBlocks) + 1);
        D.ViaBlocks[High(D.ViaBlocks)] := V;
        ViaCells.AddOrSetValue(CK, True);
      end;

    // ---- 3+4. Straight runs, bends, junctions and terminals - shared with the
    //           block-based bias scan, so bias enumerates exactly like PTL. ----
    ClassifyNodes(Adj, Vis, ViaCells, TapCells, Trace.NetName, Fam, D);
  finally
    FreeLAdj(Adj);
    FreeLVist(Vis);
    ViaCells.Free;
    TapCells.Free;
  end;
end;

procedure ExportScanTraces(const Traces: TArray<TRoutedTrace>;
  const LayerOrder: TArray<string>; out D: TExportDesign);
var
  i: Integer;
begin
  SetLength(D.Runs, 0);
  SetLength(D.Bends, 0);
  SetLength(D.ViaBlocks, 0);
  SetLength(D.Splits, 0);
  SetLength(D.Terminals, 0);
  for i := 0 to High(Traces) do
    ScanOne(Traces[i], LayerOrder, D);
end;

// The block-based bias network enumerates through the exact same classifier as
// the PTL traces: each cell's dir bits become unit edges on the bias layer, and
// straight/bend/junction/terminal blocks fall out of the shared run/node pass.
// Bias cells carry no net identity - the whole tree is one constant-voltage
// net (the trunk), so the shared name is the bias trunk.
procedure ExportScanBias(const Cells: TArray<TBiasCell>; var D: TExportDesign);
var
  Adj: TLAdj;
  Vis: TLVist;
  ViaCells: TDictionary<Int64, Boolean>;
  TapCells: TDictionary<Int64, Byte>;
  Layer: string;
  LAdj: TDictionary<Int64, TList<Int64>>;
  i: Integer;
  B: TBiasCell;
  CN, CB, EK: Int64;

  // Adds ONE undirected unit edge to the per-layer graph (deduplicated).
  procedure AddEdge(AX0, AY0, AX1, AY1: Integer);
  begin
    CN := CellKey(AX0, AY0);
    CB := CellKey(AX1, AY1);
    EK := PackEdge(CN, CB);
    if not Vis[Layer].ContainsKey(EK) then
    begin
      Vis[Layer].Add(EK, False);
      if not LAdj.ContainsKey(CN) then
        LAdj.Add(CN, TList<Int64>.Create);
      LAdj[CN].Add(CB);
      if not LAdj.ContainsKey(CB) then
        LAdj.Add(CB, TList<Int64>.Create);
      LAdj[CB].Add(CN);
    end;
  end;

begin
  if Length(Cells) = 0 then
    Exit;
  Layer := Cells[0].Layer;
  Adj := TLAdj.Create;
  Vis := TLVist.Create;
  try
    LAdj := TDictionary<Int64, TList<Int64>>.Create;
    Adj.Add(Layer, LAdj);
    Vis.Add(Layer, TDictionary<Int64, Boolean>.Create);
    for i := 0 to High(Cells) do
    begin
      B := Cells[i];
      if (B.Dirs and BiasDirN) <> 0 then
        AddEdge(B.X, B.Y, B.X, B.Y - 1);
      if (B.Dirs and BiasDirS) <> 0 then
        AddEdge(B.X, B.Y, B.X, B.Y + 1);
      if (B.Dirs and BiasDirE) <> 0 then
        AddEdge(B.X, B.Y, B.X + 1, B.Y);
      if (B.Dirs and BiasDirW) <> 0 then
        AddEdge(B.X, B.Y, B.X - 1, B.Y);
    end;
    ViaCells := TDictionary<Int64, Boolean>.Create;
    TapCells := TDictionary<Int64, Byte>.Create;
    try
      // Record each cell's tap mask (which directions are skinny taps).
      for i := 0 to High(Cells) do
        if Cells[i].TapDirs <> 0 then
          TapCells.AddOrSetValue(CellKey(Cells[i].X, Cells[i].Y), Cells[i].TapDirs);
      ClassifyNodes(Adj, Vis, ViaCells, TapCells, UNetNaming.BiasTrunkName, xfBias, D);
    finally
      ViaCells.Free;
      TapCells.Free;
    end;
  finally
    FreeLAdj(Adj);
    FreeLVist(Vis);
  end;
end;

// The export's single scanning entry: PTL traces then the bias cell network.
procedure ExportScanAll(const Traces: TArray<TRoutedTrace>;
  const BiasCells: TArray<TBiasCell>; const LayerOrder: TArray<string>;
  out D: TExportDesign);
begin
  ExportScanTraces(Traces, LayerOrder, D);
  ExportScanBias(BiasCells, D);
end;

procedure ExportScanCells(const CellNames: TArray<string>;
  out Cells: TArray<TExportCellCount>);
var
  Tally: TDictionary<string, Integer>;
  i: Integer;
  s: string;
begin
  SetLength(Cells, 0);
  Tally := TDictionary<string, Integer>.Create;
  try
    for i := 0 to High(CellNames) do
      if CellNames[i] <> '' then
        if Tally.ContainsKey(CellNames[i]) then
          Tally[CellNames[i]] := Tally[CellNames[i]] + 1
        else
          Tally.Add(CellNames[i], 1);
    for s in Tally.Keys do
    begin
      SetLength(Cells, Length(Cells) + 1);
      Cells[High(Cells)].Name := s;
      Cells[High(Cells)].Count := Tally[s];
    end;
  finally
    Tally.Free;
  end;
end;

end.

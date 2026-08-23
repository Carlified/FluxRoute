unit ClockNetwork;

{
  Counter-flow clock network construction for the wave-pipelined netlist.

  Built AFTER flip-flop insertion, on a deep copy of the DFF-inserted model
  (the pipeline view never shows the clock). Structure:

    clk (PI) -> [tap: highest row's H-tree]
             -> [CLOCK_DELAY stage] -> [tap: next row's H-tree]
             -> ...

  - Every clocked gate's clock pin is rewired off the raw clock net onto its
    own row's distribution tree; the raw clock net keeps only the spine.
  - Row trees use the library's real splitters via the DP-based
    InsertSplitterTreeForNet (each splitter output drives exactly one load).
  - CLOCK_DELAY stages are synthetic cells carrying a continuous DelayPs
    parameter (discretized only at export). The ordered stage list returned
    in TClockNetworkInfo.Stages is the tuning registry: stage j sits between
    the subtree of row(top-j) and row(top-j-1).
  - Stage delays are seeded per cell by a two-way search from each row's
    splitter: the clock-tree path to a cell minus (the previous row's tree
    path to its data driver plus the data path to the cell), clamped to 0:
      DelayPs(stage) = max_C treeDist(C) - (treeDist(P) + dataDelay(P->C))
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Generics.Collections,
  LefLibrary,
  BlifLibrary,
  PipelineConfig,
  SplitterInsert;

const
  CLOCK_DELAY_CELL_NAME = 'CLOCK_DELAY';

type
  // One tunable spine element. Ordered from the highest row downwards.
  TClockStage = class
  public
    Gate: TGateInstance;  // the CLOCK_DELAY instance inside the model
    RowAbove: Integer;    // clock level tapped immediately above this stage
    DelayPs: Double;      // continuous; discretized at export
  end;

  TClockNetworkInfo = class
  public
    Stages: TObjectList<TClockStage>; // top-down; Count = Rows.Count - 1
    Rows: TList<Integer>;             // distinct clock levels, highest first
    SourceNet: string;                // net feeding the first junction (clk)
    constructor Create;
    destructor Destroy; override;
  end;

// True if the gate is a synthetic clock-network delay element.
function IsClockDelayGate(const Gate: TGateInstance): Boolean;

// Builds the clock network into AModel in place. SplitterTypes must contain
// at least one splitter cell present in Lib. Diagnostics (rows found, tree
// depths, stage seeds) are appended to Errors. Returns the registry object
// describing the built network; nil if there was nothing to build.
function BuildClockNetwork(AModel: TBlifModel; Lib: TLibrary;
  const SplitterTypes: TArray<TSplitterType>;
  Errors: TStrings): TClockNetworkInfo;

implementation

uses
  VerilogTiming,
  FlipFlopInsert; // ClockNetFor

function IsClockDelayGate(const Gate: TGateInstance): Boolean;
begin
  Result := SameText(Gate.CellName, CLOCK_DELAY_CELL_NAME);
end;

{ TClockNetworkInfo }

constructor TClockNetworkInfo.Create;
begin
  Stages := TObjectList<TClockStage>.Create(True);
  Rows := TList<Integer>.Create;
end;

destructor TClockNetworkInfo.Destroy;
begin
  Rows.Free;
  Stages.Free;
  inherited;
end;

// Cell delay from the cell's .v timing; memoized per builder invocation.
function CellDelayOf(Cell: TCell; Memo: TDictionary<string, Double>): Double;
var
  Timing: TCellTiming;
  i: Integer;
begin
  if Memo.TryGetValue(Cell.Name, Result) then
    Exit;
  Result := 0;
  for i := 0 to Cell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(Cell.SourceFiles[i]), '.v') then
    begin
      Timing := ParseVerilogTiming(Cell.SourceFiles[i]);
      if Timing <> nil then
      begin
        Result := Timing.OutputDelayPs;
        if Result < 0 then
          Result := 0;
        Timing.Free;
        Break;
      end;
    end;
  Memo.AddOrSetValue(Cell.Name, Result);
end;

// Creates (once per library) the synthetic delay cell: one clock input, one
// output. Registered in Lib so every model clone shares the same TCell and
// its lifetime matches the library's.
procedure EnsureClockDelayCell(Lib: TLibrary);
var
  Cell: TCell;
  Port: TPort;
begin
  if Lib.FindCell(CLOCK_DELAY_CELL_NAME) <> nil then
    Exit;
  Cell := TCell.Create;
  Cell.Name := CLOCK_DELAY_CELL_NAME;
  Port := TPort.Create;
  Port.Name := 'clk';
  Port.Direction := pdInput;
  Cell.Ports.Add(Port);
  Cell.PortsByName.AddOrSetValue(Port.Name, Port);
  Port := TPort.Create;
  Port.Name := 'clkout';
  Port.Direction := pdOutput;
  Cell.Ports.Add(Port);
  Cell.PortsByName.AddOrSetValue(Port.Name, Port);
  Lib.Cells.Add(Cell);
  Lib.CellsByName.AddOrSetValue(Cell.Name, Cell);
end;

// Worst root-to-leaf splitter delay of the distribution tree hanging off
// ANetName. Splitters are the only interior nodes; clocked gates are leaves
// (their clk-to-q is not part of the tree delay).
function MaxTreePathPs(AModel: TBlifModel; const ANetName: string;
  const SplitterDelays: TDictionary<string, Double>): Double;

  function Walk(const NetName: string; Arrived: Double): Double;
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    Down: Double;
  begin
    Result := Arrived;
    if not AModel.Nets.TryGetValue(NetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      // Clocked gates consume the signal: end of this branch. The spine
      // delay element feeding this tap is likewise not part of the tree.
      if CellHasClock(NC.Gate.Cell) or IsClockDelayGate(NC.Gate) then
        Continue;
      // Unknown cell types are not tree material; ignore defensively.
      if not SplitterDelays.ContainsKey(NC.Gate.CellName) then
        Continue;
      Down := Arrived + SplitterDelays[NC.Gate.CellName];
      for OutConn in NC.Gate.Connections do
        if OutConn.Port.Direction = pdOutput then
          Result := Max(Result, Walk(OutConn.NetName, Down));
    end;
  end;

begin
  Result := Walk(ANetName, 0);
end;

// DFS the clock distribution tree rooted at ARowNet, recording the
// cumulative splitter delay from the row's tap net to every clocked leaf.
// Interior splitter delays are summed per-type (handles >2-output cells);
// the leaves' own clk->q delays are NOT included.
procedure BuildTreeDistances(AModel: TBlifModel; const ARowNet: string;
  const SplitterDelays: TDictionary<string, Double>;
  Dist: TDictionary<TGateInstance, Double>);

  procedure Walk(const NetName: string; Arrived: Double);
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
  begin
    if not AModel.Nets.TryGetValue(NetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if IsClockDelayGate(NC.Gate) then
        Continue;
      if CellHasClock(NC.Gate.Cell) then
      begin
        Dist.AddOrSetValue(NC.Gate, Arrived);
        Continue;
      end;
      if not SplitterDelays.ContainsKey(NC.Gate.CellName) then
        Continue;
      for OutConn in NC.Gate.Connections do
        if OutConn.Port.Direction = pdOutput then
          Walk(OutConn.NetName, Arrived + SplitterDelays[NC.Gate.CellName]);
    end;
  end;

begin
  Walk(ARowNet, 0);
end;

// Traces G's DATA inputs back (against the nets' driving direction) to the
// nearest clocked driver. Returns that driver P and the delay from P's
// output to G's input: P's clk->q plus any non-clocked gates in between.
// For multi-input gates the largest arrival (worst case) is returned.
function DataArrivalFromClocked(AModel: TBlifModel; G: TGateInstance;
  Delays: TDictionary<string, Double>;
  out P: TGateInstance; out Dly: Double): Boolean;
var
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  SubP: TGateInstance;
  SubD, BestD: Double;
begin
  Result := False;
  P := nil;
  Dly := 0;
  BestD := -1;
  for Conn in G.Connections do
  begin
    if Conn.Port.Direction <> pdInput then
      Continue;
    if IsClockPinName(Conn.Port.Name) then
      Continue;
    if not AModel.Nets.TryGetValue(Conn.NetName, Net) then
      Continue;
    for NC in Net.Connections do
    begin
      if not NC.IsDriver then
        Continue;
      if CellHasClock(NC.Gate.Cell) then
      begin
        SubP := NC.Gate;
        SubD := CellDelayOf(NC.Gate.Cell, Delays);
      end
      else
      begin
        if not DataArrivalFromClocked(AModel, NC.Gate, Delays, SubP, SubD) then
          Continue;
        SubD := SubD + CellDelayOf(NC.Gate.Cell, Delays);
      end;
      if SubD > BestD then
      begin
        BestD := SubD;
        P := SubP;
      end;
      Result := True;
    end;
  end;
  if Result then
    Dly := BestD;
end;

// Assigns Level to every still-unleveled (splitter) gate reachable from
// ANetName through splitter outputs only.
procedure LabelRowTree(AModel: TBlifModel; const ANetName: string;
  Level: Integer; SplitterDelays: TDictionary<string, Double>);
var
  Net: TNet;
  NC: TNetConnection;
  OutConn: TPinConnection;
begin
  if not AModel.Nets.TryGetValue(ANetName, Net) then
    Exit;
  for NC in Net.Connections do
  begin
    if NC.IsDriver then
      Continue;
    if NC.Gate.ClockLevel >= 0 then
      Continue; // already leveled (leaf gates keep their data level)
    if CellHasClock(NC.Gate.Cell) then
      Continue;
    // Only known splitter cells are tree nodes.
    if not SplitterDelays.ContainsKey(NC.Gate.CellName) then
      Continue;
    NC.Gate.ClockLevel := Level;
    for OutConn in NC.Gate.Connections do
      if OutConn.Port.Direction = pdOutput then
        LabelRowTree(AModel, OutConn.NetName, Level, SplitterDelays);
  end;
end;

function BuildClockNetwork(AModel: TBlifModel; Lib: TLibrary;
  const SplitterTypes: TArray<TSplitterType>;
  Errors: TStrings): TClockNetworkInfo;
var
  Delays, SplitterDelays: TDictionary<string, Double>;
  Info: TClockNetworkInfo;
  Gate: TGateInstance;
  Conn: TPinConnection;
  Port: TPort;
  Net: TNet;
  NC, RowNC: TNetConnection;
  i, j, k, RowIdx, Level: Integer;
  ClockNetName, TapNet, SpineNetName: string;
  RowNetNames: TArray<string>;
  RowGateCount: TArray<Integer>;
  TreeDepth: TArray<Double>;
  BestSeed, TreeC, TreeP, DataDly, Val: Double;
  Stage: TClockStage;
  TreeDistU, TreeDistL: TDictionary<TGateInstance, Double>;
  P: TGateInstance;
  MovedCount, InsertedHere: Integer;
  HasClkConn: Boolean;
  LeftCount: Integer;
  JunctionCell: TCell;
  InPort, OutA, OutB: TPort;
  BranchNetName, DelayNetName, TreeTap: string;
begin
  Result := nil;
  if (AModel = nil) or (Lib = nil) or (Length(SplitterTypes) = 0) then
    Exit;

  for i := 0 to Length(SplitterTypes) - 1 do
    if Lib.FindCell(SplitterTypes[i].CellName) = nil then
      Exit;

  ClockNetName := ClockNetFor(AModel);
  if ClockNetName = '' then
  begin
    Errors.Add('Clock network: no clock net found in the model.');
    Exit;
  end;

  Delays := TDictionary<string, Double>.Create;
  SplitterDelays := TDictionary<string, Double>.Create;
  Info := TClockNetworkInfo.Create;
  Info.SourceNet := ClockNetName;
  try
    EnsureClockDelayCell(Lib);

    for i := 0 to Length(SplitterTypes) - 1 do
      SplitterDelays.AddOrSetValue(SplitterTypes[i].CellName,
        SplitterTypes[i].DelayPs);

    // ---- 1. Discover rows (distinct levels >= 0), highest first ----------
    for i := 0 to AModel.Gates.Count - 1 do
    begin
      Level := AModel.Gates[i].ClockLevel;
      if Level < 0 then
        Continue;
      if not Info.Rows.Contains(Level) then
      begin
        Info.Rows.Add(Level);
        j := Info.Rows.Count - 1; // keep descending order
        while (j > 0) and (Info.Rows[j] > Info.Rows[j - 1]) do
        begin
          k := Info.Rows[j - 1];
          Info.Rows[j - 1] := Info.Rows[j];
          Info.Rows[j] := k;
          Dec(j);
        end;
      end;
    end;
    if Info.Rows.Count = 0 then
    begin
      Errors.Add('Clock network: no leveled gates found.');
      Exit;
    end;

    // Counter-flow spec: distribution runs from the highest level down to
    // level 1 INCLUSIVE. Level 0 never contains clocked components (level
    // counts clocked components crossed), so it gets no clock hardware.
    while (Info.Rows.Count > 0) and
          (Info.Rows[Info.Rows.Count - 1] < 1) do
      Info.Rows.Delete(Info.Rows.Count - 1);
    if Info.Rows.Count = 0 then
    begin
      Errors.Add('Clock network: every row was below level 1.');
      Exit;
    end;

    SetLength(RowGateCount, Info.Rows.Count);
    SetLength(TreeDepth, Info.Rows.Count);

    // ---- 2. Move every clock pin onto its row's TAP net ------------------
    // Every row owns a dedicated clk_row_<level> net holding its gates'
    // clock pins; junction splitters and delays wire these nets together.
    SetLength(RowNetNames, Info.Rows.Count);
    MovedCount := 0;
    for i := 0 to High(RowNetNames) do
    begin
      RowNetNames[i] := Format('clk_row_%d', [Info.Rows[i]]);
      AModel.FindOrCreateNet(RowNetNames[i]);
      RowGateCount[i] := 0;
      TreeDepth[i] := 0;
    end;

    if AModel.Nets.TryGetValue(ClockNetName, Net) then
      for i := Net.Connections.Count - 1 downto 0 do
      begin
        NC := Net.Connections[i];
        if NC.IsDriver then
          Continue;
        if not IsClockPinName(NC.PinName) then
          Continue;
        RowIdx := Info.Rows.IndexOf(NC.Gate.ClockLevel);
        if RowIdx < 0 then
          Continue;
        // Retarget the gate-side connection onto the tap net.
        Conn := nil;
        for j := 0 to NC.Gate.Connections.Count - 1 do
          if SameText(NC.Gate.Connections[j].PinName, NC.PinName) and
             SameText(NC.Gate.Connections[j].NetName, ClockNetName) then
          begin
            Conn := NC.Gate.Connections[j];
            Break;
          end;
        if Conn <> nil then
          Conn.NetName := RowNetNames[RowIdx];
        // Move the net-side entry as well (no-op for the top row's net).
        Net.Connections.Delete(i);
        RowNC := NC;
        AModel.Nets[RowNetNames[RowIdx]].Connections.Add(RowNC);
        Inc(RowGateCount[RowIdx]);
        Inc(MovedCount);
      end;

    // Diagnostics: anything still hanging off the raw clock net (e.g.
    // gates with ClockLevel -1 that could not be placed on a row).
    LeftCount := 0;
    if AModel.Nets.TryGetValue(ClockNetName, Net) then
      for i := 0 to Net.Connections.Count - 1 do
      begin
        NC := Net.Connections[i];
        if NC.IsDriver or (not IsClockPinName(NC.PinName)) then
          Continue;
        Inc(LeftCount);
        Errors.Add(Format(
          'Clock network: LEFTOVER on "%s": %s (pin %s, level %d).',
          [ClockNetName, NC.Gate.CellName, NC.PinName, NC.Gate.ClockLevel]));
      end;
    Errors.Add(Format('Clock network: %d component(s) remain on the clock net.',
      [LeftCount]));

    // Wire up every clocked gate whose clock pin was never connected at all
    // (the BLIF files omit clk= lines, so ordinary logic gates arrive with a
    // dangling clock input). Attach each such pin to its row's tap net so the
    // distribution tree actually reaches every clocked component, not just
    // the flip-flops created during insertion.
    for i := 0 to AModel.Gates.Count - 1 do
    begin
      Gate := AModel.Gates[i];
      if not CellHasClock(Gate.Cell) then
        Continue;
      RowIdx := Info.Rows.IndexOf(Gate.ClockLevel);
      if RowIdx < 0 then
        Continue;
      for j := 0 to Gate.Cell.Ports.Count - 1 do
      begin
        Port := Gate.Cell.Ports[j];
        if (Port.Direction <> pdInput) or not IsClockPinName(Port.Name) then
          Continue;
        HasClkConn := False;
        for k := 0 to Gate.Connections.Count - 1 do
          if SameText(Gate.Connections[k].Port.Name, Port.Name) then
          begin
            HasClkConn := True;
            Break;
          end;
        if HasClkConn then
          Continue;
        // Add the missing clock connection.
        Conn := TPinConnection.Create;
        Conn.PinName := Port.Name;
        Conn.NetName := RowNetNames[RowIdx];
        Conn.Port := Port;
        Gate.Connections.Add(Conn);
        NC.Gate := Gate;
        NC.PinName := Port.Name;
        NC.IsDriver := False;
        AModel.Nets[RowNetNames[RowIdx]].Connections.Add(NC);
        Inc(RowGateCount[RowIdx]);
        Inc(MovedCount);
      end;
    end;

    Errors.Add(Format('Clock network: clock net "%s", wired %d clock pin(s).',
      [ClockNetName, MovedCount]));
    for i := 0 to High(RowGateCount) do
      Errors.Add(Format('Clock network: row %d holds %d clocked gate(s).',
        [Info.Rows[i], RowGateCount[i]]));

    // ---- 3. Spine taps + splitter trees ----------------------------------
    // Counter-flow chain, bottom (source) up:
    //   clk -> SPLITTER_S0 -> {row0 tree | DELAY_0 -> SPLITTER_S1 -> ...}
    // Each junction splitter legally fans the clock into (a) this layer's
    // distribution tree and (b) the delay leading to the next layer down.
    // Stages[j] sits between the tap of Rows[j] and the tap of Rows[j+1].
    TapNet := ClockNetName;
    for RowIdx := 0 to Info.Rows.Count - 1 do
    begin
      // Final row takes the delay output directly onto its own net - RSFQ
      // logic does not support open outputs, so no dangling junction is
      // left on the trunk.
      TreeTap := TapNet;

      // Junction splitter (all but the final row): fans the clock into
      // this row's distribution tree and the delay leading down.
      if RowIdx < Info.Rows.Count - 1 then
      begin
      JunctionCell := Lib.FindCell(SplitterTypes[0].CellName);
      InPort := nil;
      OutA := nil;
      OutB := nil;
      for i := 0 to JunctionCell.Ports.Count - 1 do
      begin
        if JunctionCell.Ports[i].Direction = pdInput then
        begin
          if InPort = nil then
            InPort := JunctionCell.Ports[i];
        end
        else if JunctionCell.Ports[i].Direction = pdOutput then
        begin
          if OutA = nil then
            OutA := JunctionCell.Ports[i]
          else if OutB = nil then
            OutB := JunctionCell.Ports[i];
        end;
      end;
      if (InPort = nil) or (OutA = nil) or (OutB = nil) then
      begin
        Errors.Add('Clock network: junction splitter cell lacks 1-in/2-out pins.');
        Exit;
      end;

      Gate := TGateInstance.Create;
      Gate.CellName := JunctionCell.Name;
      Gate.Cell := JunctionCell;
      Gate.ClockLevel := Info.Rows[RowIdx];

      Conn := TPinConnection.Create;
      Conn.Port := InPort;
      Conn.PinName := InPort.Name;
      Conn.NetName := TapNet;
      Gate.Connections.Add(Conn);
      NC.Gate := Gate;
      NC.PinName := InPort.Name;
      NC.IsDriver := False;
      AModel.Nets[TapNet].Connections.Add(NC);

      // outA drives this row's distribution net (its gates are already
      // hanging here; the tree below re-roots them under splitters).
      BranchNetName := RowNetNames[RowIdx];
      Conn := TPinConnection.Create;
      Conn.Port := OutA;
      Conn.PinName := OutA.Name;
      Conn.NetName := BranchNetName;
      Gate.Connections.Add(Conn);
      AModel.FindOrCreateNet(BranchNetName);
      NC.Gate := Gate;
      NC.PinName := OutA.Name;
      NC.IsDriver := True;
      AModel.Nets[BranchNetName].Connections.Add(NC);

      if RowIdx < Info.Rows.Count - 1 then
      begin
        DelayNetName := Format('clk_delay_%d', [RowIdx + 1]);
        Conn := TPinConnection.Create;
        Conn.Port := OutB;
        Conn.PinName := OutB.Name;
        Conn.NetName := DelayNetName;
        Gate.Connections.Add(Conn);
        AModel.FindOrCreateNet(DelayNetName);
        NC.Gate := Gate;
        NC.PinName := OutB.Name;
        NC.IsDriver := True;
        AModel.Nets[DelayNetName].Connections.Add(NC);
      end;

      AModel.Gates.Add(Gate);
      TreeTap := RowNetNames[RowIdx];
      end;

      // Delay component feeding the next row's junction. Every stage
      // emits a dedicated spine net - except the final stage, which hands
      // off straight to the last row's own net (no dangling splitter).
      if RowIdx < Info.Rows.Count - 1 then
      begin
        if RowIdx = Info.Rows.Count - 2 then
          SpineNetName := RowNetNames[RowIdx + 1]
        else
          SpineNetName := Format('clk_spine_%d', [RowIdx + 1]);
        Gate := TGateInstance.Create;
        Gate.CellName := CLOCK_DELAY_CELL_NAME;
        Gate.Cell := Lib.FindCell(CLOCK_DELAY_CELL_NAME);
        Gate.ClockLevel := Info.Rows[RowIdx];

        Conn := TPinConnection.Create;
        Conn.Port := Gate.Cell.FindPort('clk');
        Conn.PinName := 'clk';
        Conn.NetName := DelayNetName;
        Gate.Connections.Add(Conn);
        NC.Gate := Gate;
        NC.PinName := 'clk';
        NC.IsDriver := False;
        AModel.Nets[DelayNetName].Connections.Add(NC);

        Conn := TPinConnection.Create;
        Conn.Port := Gate.Cell.FindPort('clkout');
        Conn.PinName := 'clkout';
        Conn.NetName := SpineNetName;
        Gate.Connections.Add(Conn);
        AModel.FindOrCreateNet(SpineNetName);
        NC.Gate := Gate;
        NC.PinName := 'clkout';
        NC.IsDriver := True;
        AModel.Nets[SpineNetName].Connections.Add(NC);

        AModel.Gates.Add(Gate);

        Stage := TClockStage.Create;
        Stage.Gate := Gate;
        Stage.RowAbove := Info.Rows[RowIdx];
        Stage.DelayPs := 0;
        Info.Stages.Add(Stage);
      end;

      // This row's tree grows off the junction's tree branch (final row:
      // directly off its tap net).
      InsertedHere := InsertSplitterTreeForNet(AModel, Lib, TreeTap,
        SplitterTypes);
      LabelRowTree(AModel, TreeTap, Info.Rows[RowIdx], SplitterDelays);
      TreeDepth[RowIdx] := MaxTreePathPs(AModel, TreeTap, SplitterDelays);
      Errors.Add(Format(
        'Clock network: row %d tap "%s": %d splitter(s), tree depth %.1f ps.',
        [Info.Rows[RowIdx], TreeTap, InsertedHere, TreeDepth[RowIdx]]));

      // Continue the spine downward: the next junction hangs off the delay
      // output net (for the final stage that is the last row's own net).
      if RowIdx < Info.Rows.Count - 1 then
        TapNet := SpineNetName;
    end;

    // ---- 4. Seed stage delays (per-cell two-way search) -----------------
    // For stage i (connecting Rows[i] -> Rows[i+1]), start at the splitter
    // for Rows[i] and, for every clocked cell C in that row, follow both
    // outputs until reaching C:
    //   outA: clock tree down to C        -> treeDist(C)
    //   outB: delay -> next row tree -> P -> treeDist(P) + dataDelay(P->C)
    // where P is C's nearest clocked data driver. The delay is the max over
    // C of treeDist(C) - (treeDist(P) + dataDelay), clamped to 0. The final
    // row has no splitter/delay, so it is never the "current" row here.
    TreeDistU := TDictionary<TGateInstance, Double>.Create;
    TreeDistL := TDictionary<TGateInstance, Double>.Create;
    try
      for i := 0 to Info.Stages.Count - 1 do
      begin
        TreeDistU.Clear;
        TreeDistL.Clear;
        BuildTreeDistances(AModel, RowNetNames[i], SplitterDelays, TreeDistU);
        BuildTreeDistances(AModel, RowNetNames[i + 1], SplitterDelays,
          TreeDistL);

        BestSeed := 0;
        for Gate in AModel.Gates do
        begin
          if Gate.ClockLevel <> Info.Rows[i] then
            Continue;
          if not CellHasClock(Gate.Cell) then
            Continue;
          if not TreeDistU.TryGetValue(Gate, TreeC) then
            Continue;
          if not DataArrivalFromClocked(AModel, Gate, Delays, P, DataDly) then
            Continue;
          if P = nil then
            Continue;
          TreeP := 0;
          TreeDistL.TryGetValue(P, TreeP);
          Val := TreeC - TreeP - DataDly;
          if Val > BestSeed then
            BestSeed := Val;
        end;

        if BestSeed < 0 then
          BestSeed := 0;
        Info.Stages[i].DelayPs := BestSeed;
        Info.Stages[i].Gate.DelayPs := BestSeed;
        Errors.Add(Format(
          'Clock network: stage %d (row %d -> row %d): seed %.1f ps.',
          [i, Info.Rows[i], Info.Rows[i + 1], BestSeed]));
      end;
    finally
      TreeDistU.Free;
      TreeDistL.Free;
    end;

    Errors.Add(Format('Clock network: %d stage(s) built.', [Info.Stages.Count]));
    Result := Info;
    Info := nil;
  finally
    Delays.Free;
    SplitterDelays.Free;
    Info.Free;
  end;
end;

end.

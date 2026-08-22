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
  - Stage delays are seeded so a lower row never receives its clock before
    the earliest data wave from the row above can arrive:
      DelayPs(stage) >= maxTreePathPs(lower row) - minForwardPathPs(upper row)
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
        begin
          // All outputs of one splitter carry identical delay; one suffices.
          Result := Max(Result, Walk(OutConn.NetName, Down));
          Break;
        end;
    end;
  end;

begin
  Result := Walk(ANetName, 0);
end;

// Shortest data path (sum of cell delays) starting at any clocked gate of
// FromLevel and ending at the INPUT of any gate belonging to a higher level.
// Returns Infinity when the two rows share no forward edge.
function MinForwardPathPs(AModel: TBlifModel; FromLevel: Integer;
  Delays: TDictionary<string, Double>): Double;
var
  Best: TDictionary<TGateInstance, Double>;
  Queue: TList<TGateInstance>;
  G, H: TGateInstance;
  ArrIn, ArrOut: Double;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  i: Integer;

  procedure Push(Gate: TGateInstance; Arr: Double);
  var
    Prev: Double;
  begin
    if (not Best.TryGetValue(Gate, Prev)) or (Arr < Prev) then
    begin
      Best.AddOrSetValue(Gate, Arr);
      Queue.Add(Gate);
    end;
  end;

begin
  Result := Infinity;
  Best := TDictionary<TGateInstance, Double>.Create;
  Queue := TList<TGateInstance>.Create;
  try
    // Seed: clocked gates at this level launch their wave at t = clk->q.
    for i := 0 to AModel.Gates.Count - 1 do
    begin
      G := AModel.Gates[i];
      if (G.ClockLevel = FromLevel) and CellHasClock(G.Cell) then
        Push(G, 0); // arrival at input; arrival at output adds own delay
    end;

    i := 0;
    while i < Queue.Count do
    begin
      G := Queue[i];
      Inc(i);
      ArrIn := Best[G];
      ArrOut := ArrIn + CellDelayOf(G.Cell, Delays);
      for Conn in G.Connections do
      begin
        if Conn.Port.Direction <> pdOutput then
          Continue;
        if not AModel.Nets.TryGetValue(Conn.NetName, Net) then
          Continue;
        for NC in Net.Connections do
        begin
          if NC.IsDriver then
            Continue;
          H := NC.Gate;
          if H.ClockLevel > FromLevel then
          begin
            // Reached the next row: receiver's own delay is not counted.
            if ArrOut < Result then
              Result := ArrOut;
          end
          else if H.ClockLevel = FromLevel then
            Push(H, ArrOut);
        end;
      end;
    end;
  finally
    Queue.Free;
    Best.Free;
  end;
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
  Net: TNet;
  NC, RowNC: TNetConnection;
  i, j, k, RowIdx, Level: Integer;
  ClockNetName, TapNet, SpineNetName: string;
  RowNetNames: TArray<string>;
  RowGateCount: TArray<Integer>;
  TreeDepth: TArray<Double>;
  MinFwd, Seed: Double;
  Stage: TClockStage;
  MovedCount, InsertedHere: Integer;
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

    SetLength(RowGateCount, Info.Rows.Count);
    SetLength(TreeDepth, Info.Rows.Count);

    // ---- 2. Move every clock pin onto its row's TAP net ------------------
    // Tap nets are deterministic up-front: the highest row hangs directly
    // off the raw clock net; every lower row hangs off the spine net that
    // the stage above it drives.
    SetLength(RowNetNames, Info.Rows.Count);
    MovedCount := 0;
    for i := 0 to High(RowNetNames) do
    begin
      if i = 0 then
        RowNetNames[i] := ClockNetName
      else
        RowNetNames[i] := Format('clk_spine_%d', [i]);
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

    Errors.Add(Format('Clock network: clock net "%s", moved %d clock pin(s).',
      [ClockNetName, MovedCount]));
    for i := 0 to High(RowGateCount) do
      Errors.Add(Format('Clock network: row %d holds %d clocked gate(s).',
        [Info.Rows[i], RowGateCount[i]]));

    // ---- 3. Spine taps + splitter trees ----------------------------------
    // Per row: insert the tree FIRST, then attach the next spine stage's
    // input - so the stage pin is never mistaken for a tree load.
    // Stages[j] sits between the tap of Rows[j] and the tap of Rows[j+1].
    TapNet := ClockNetName;
    for RowIdx := 0 to Info.Rows.Count - 1 do
    begin
      InsertedHere := InsertSplitterTreeForNet(AModel, Lib, TapNet,
        SplitterTypes);
      LabelRowTree(AModel, TapNet, Info.Rows[RowIdx], SplitterDelays);
      TreeDepth[RowIdx] := MaxTreePathPs(AModel, TapNet, SplitterDelays);
      Errors.Add(Format(
        'Clock network: row %d tap "%s": %d splitter(s), tree depth %.1f ps.',
        [Info.Rows[RowIdx], TapNet, InsertedHere, TreeDepth[RowIdx]]));

      if RowIdx < Info.Rows.Count - 1 then
      begin
        SpineNetName := RowNetNames[RowIdx + 1];
        Gate := TGateInstance.Create;
        Gate.CellName := CLOCK_DELAY_CELL_NAME;
        Gate.Cell := Lib.FindCell(CLOCK_DELAY_CELL_NAME);
        Gate.ClockLevel := Info.Rows[RowIdx];

        Conn := TPinConnection.Create;
        Conn.Port := Gate.Cell.FindPort('clk');
        Conn.PinName := 'clk';
        Conn.NetName := TapNet;
        Gate.Connections.Add(Conn);
        NC.Gate := Gate;
        NC.PinName := 'clk';
        NC.IsDriver := False;
        AModel.Nets[TapNet].Connections.Add(NC);

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

        TapNet := SpineNetName;
      end;
    end;

    // ---- 4. Seed stage delays --------------------------------------------
    for i := 0 to Info.Stages.Count - 1 do
    begin
      MinFwd := MinForwardPathPs(AModel, Info.Rows[i], Delays);
      Seed := TreeDepth[i + 1] - MinFwd;
      if Seed < 0 then
        Seed := 0;
      Info.Stages[i].DelayPs := Seed;
      Info.Stages[i].Gate.DelayPs := Seed;
      Errors.Add(Format(
        'Clock network: stage %d (tap row %d -> row %d): tree %.1f ps, min fwd %.1f ps, seed %.1f ps.',
        [i, Info.Rows[i], Info.Rows[i + 1], TreeDepth[i + 1], MinFwd, Seed]));
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

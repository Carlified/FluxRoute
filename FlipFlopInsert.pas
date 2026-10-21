unit FlipFlopInsert;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Generics.Collections,
  LefLibrary,
  BlifLibrary,
  VerilogTiming,
  PipelineConfig,
  PipelineAnalysis;

// Two-phase flip-flop insertion:
//
//   Phase 1 (naive, backwards): walk the gates in reverse order. For every
//   cell, each data input whose driver's clock level is below what the cell
//   expects gets a series chain of flip-flops inserted right before the cell.
//   A clocked cell at level L expects data at level L-1; an unclocked cell at
//   level L expects data at level L. Every inserted flip-flop is exactly one
//   clock level above its predecessor (LA+1 .. LA+N).
//
//   Phase 2 (iterative merge, controlled by ADoMerge): while a splitter has
//   every output net leading into exactly one inserted flip-flop at the
//   splitter's level + 1, collapse those flip-flops into a single one placed
//   before the splitter and raise the splitter's clock level by one. Repeats
//   until no splitter qualifies, which pushes the shared chains up to just
//   before the splitting networks.
//
//   Phase 3: remove the nets left floating (empty) by the merge.
//
//   Pass ADoMerge = False to skip Phase 2, keeping the raw per-input chains.
//
// Callers should pass a clone if the original netlist must be preserved, and
// should re-run ComputeClockLevels afterwards to refresh all levels.
function InsertCompactFlipFlops(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string; ADoMerge: Boolean = True): Integer;

// After internal FF insertion, pad all primary outputs to the same clock level.
// Finds the maximum clock level among output drivers and inserts FF chains on
// any output whose driver sits below that maximum so that every output exits
// the circuit at the same cycle. Caller should re-run ComputeClockLevels
// afterwards.
function PadOutputFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string): Integer;

// Delay-levelization flip-flop insertion for maximum-speed pipelining.
// Walks gates in topological order, computing the cumulative delay from
// the nearest clocked boundary.  The driving clocked gate's own
// clock-to-output delay counts as the start of each path, so the counted
// delay is (clocked gate delay) + (non-clocked chain).  When a gate's
// cumulative delay exceeds ThresholdPs, DFFs are inserted on every
// non-clocked data input of that gate to break the long path.  Clocked
// gates are pipeline boundaries (their output arrival is their own delay)
// but their inputs are still checked.
// Caller should re-run ComputeClockLevels afterwards to refresh levels.
function InsertDelayLevelizedFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string; ThresholdPs: Double): Integer;

// Output alignment pre-step shared by both insertion modes. If any gate on
// the highest clock level is not already the selected flip-flop, a FF is
// interposed directly after each of its outputs so that all output signals
// are clocked out on the same clock edge. Gates that are already flip-flops
// are left untouched; returns the number of flip-flops inserted. The model's
// ClockLevel values must be up to date on entry; the caller should re-run
// ComputeClockLevels afterwards.
function InsertTopLevelFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string): Integer;

// Returns the name of the model's clock net (the primary input that clocked
// cells' clock pins attach to), or '' if none can be identified.
function ClockNetFor(Model: TBlifModel): string;

implementation

function IsSplitterCell(const Cell: TCell): Boolean;
var
  Port: TPort;
  NumInputs, NumOutputs: Integer;
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

function ClockNetFor(Model: TBlifModel): string;
var
  Gate: TGateInstance;
  Conn: TPinConnection;
  Counts: TDictionary<string, Integer>;
  NetName, Best: string;
  BestCount: Integer;
begin
  Counts := TDictionary<string, Integer>.Create;
  try
    for Gate in Model.Gates do
      if CellHasClock(Gate.Cell) then
        for Conn in Gate.Connections do
          if (Conn.Port.Direction = pdInput) and IsClockPinName(Conn.Port.Name) then
          begin
            if Counts.ContainsKey(Conn.NetName) then
              Counts[Conn.NetName] := Counts[Conn.NetName] + 1
            else
              Counts.Add(Conn.NetName, 1);
          end;
    Best := '';
    BestCount := 0;
    for NetName in Counts.Keys do
      if Counts[NetName] > BestCount then
      begin
        Best := NetName;
        BestCount := Counts[NetName];
      end;
    Result := Best;
  finally
    Counts.Free;
  end;
end;

function CreateFF(FFCell: TCell; const FFCellName, DataPin, OutputPin, ClockPin,
  ClockNetName, DataNetName, OutNetName: string; ALevel: Integer): TGateInstance;
var
  Gate: TGateInstance;
  Conn: TPinConnection;
begin
  Gate := TGateInstance.Create;
  Gate.CellName := FFCellName;
  Gate.Cell := FFCell;
  Gate.ClockLevel := ALevel;

  Conn := TPinConnection.Create;
  Conn.PinName := DataPin;
  Conn.NetName := DataNetName;
  Conn.Port := FFCell.FindPort(DataPin);
  Gate.Connections.Add(Conn);

  Conn := TPinConnection.Create;
  Conn.PinName := ClockPin;
  Conn.NetName := ClockNetName;
  Conn.Port := FFCell.FindPort(ClockPin);
  Gate.Connections.Add(Conn);

  Conn := TPinConnection.Create;
  Conn.PinName := OutputPin;
  Conn.NetName := OutNetName;
  Conn.Port := FFCell.FindPort(OutputPin);
  Gate.Connections.Add(Conn);

  Result := Gate;
end;

// Connects any clocked gate whose clock pin is missing from the netlist (BLIF
// omits clk= assignments) to the resolved clock net. Without this the model is
// inconsistent before level computation / DFF insertion: ClockNetFor sees no
// clock pins, the clock net is synthesised, and the existing clocked cells stay
// dangling until the clock network runs.
procedure EnsureClockPinsConnected(Model: TBlifModel; const ClockNetName: string);
var
  Gate: TGateInstance;
  Port: TPort;
  Conn: TPinConnection;
  NC: TNetConnection;
  Net: TNet;
  j, k: Integer;
  HasConn: Boolean;
begin
  if (Model = nil) or (ClockNetName = '') then
    Exit;
  Net := Model.FindOrCreateNet(ClockNetName);
  for Gate in Model.Gates do
  begin
    if not CellHasClock(Gate.Cell) then
      Continue;
    for j := 0 to Gate.Cell.Ports.Count - 1 do
    begin
      Port := Gate.Cell.Ports[j];
      if (Port.Direction <> pdInput) or not IsClockPinName(Port.Name) then
        Continue;
      HasConn := False;
      for k := 0 to Gate.Connections.Count - 1 do
        if SameText(Gate.Connections[k].PinName, Port.Name) then
        begin
          HasConn := True;
          Break;
        end;
      if HasConn then
        Continue;
      Conn := TPinConnection.Create;
      Conn.PinName := Port.Name;
      Conn.NetName := ClockNetName;
      Conn.Port := Port;
      Gate.Connections.Add(Conn);
      NC.Gate := Gate;
      NC.PinName := Port.Name;
      NC.IsDriver := False;
      Net.Connections.Add(NC);
    end;
  end;
end;

function InsertCompactFlipFlops(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string; ADoMerge: Boolean = True): Integer;
var
  FFCell: TCell;
  ClockPin, DataPin, OutputPin: string;
  ClockNetName: string;
  InsertedFFs: TDictionary<TGateInstance, Boolean>;
  Count, i, j, jj, N, LA, Expected, NetCounter: Integer;
  B, Gate, S, FF_br: TGateInstance;
  Conn: TPinConnection;
  Net, PrevNet, NewNet, OutNet, OutNet2, Nin, Nin2: TNet;
  NC: TNetConnection;
  ChildName: string;
  Merged: Boolean;
  FFLevel: Integer;
  EmptyNets: TList<string>;
  LoadPin: string;

  function CanMerge(S: TGateInstance): Boolean;
  var
    Conn2: TPinConnection;
    Net2: TNet;
    NC2: TNetConnection;
    LoadCount, OutCount: Integer;
  begin
    OutCount := 0;
    for Conn2 in S.Connections do
      if Conn2.Port.Direction = pdOutput then
      begin
        Inc(OutCount);
        Net2 := Model.Nets[Conn2.NetName];
        LoadCount := 0;
        for NC2 in Net2.Connections do
          if not NC2.IsDriver then
          begin
            Inc(LoadCount);
            if not InsertedFFs.ContainsKey(NC2.Gate) then
              Exit(False);
            if NC2.Gate.ClockLevel <> S.ClockLevel + 1 then
              Exit(False);
          end;
        if LoadCount <> 1 then
          Exit(False);
      end;
    Result := OutCount >= 2;
  end;

  procedure DoMerge(S: TGateInstance);
  var
    Conn, CC: TPinConnection;
    NC: TNetConnection;
    jj: Integer;
  begin
    FFLevel := S.ClockLevel + 1;

    // Shared flip-flop's data net is S's input net; must exist.
    Nin := nil;
    for Conn in S.Connections do
      if Conn.Port.Direction in [pdInput, pdInOut] then
      begin
        Nin := Model.Nets[Conn.NetName];
        Break;
      end;
    if Nin = nil then
      Exit;

    for Conn in S.Connections do
      if Conn.Port.Direction = pdOutput then
      begin
        OutNet := Model.Nets[Conn.NetName];
        FF_br := nil;
        for NC in OutNet.Connections do
          if not NC.IsDriver then
            FF_br := NC.Gate;
        if FF_br = nil then
          Continue;
        OutNet2 := nil;
        for CC in FF_br.Connections do
          if CC.Port.Direction = pdOutput then
            OutNet2 := Model.Nets[CC.NetName];
        if OutNet2 = nil then
          Continue;

        // Move OutNet2's loads onto OutNet (drop the consumed flip-flop),
        // deleting each entry as it goes so OutNet2 keeps no stale records.
        for jj := OutNet2.Connections.Count - 1 downto 0 do
          if not OutNet2.Connections[jj].IsDriver then
          begin
            LoadPin := OutNet2.Connections[jj].PinName;
            for CC in OutNet2.Connections[jj].Gate.Connections do
              if SameText(CC.NetName, OutNet2.Name) then
                CC.NetName := OutNet.Name;
            NC.Gate := OutNet2.Connections[jj].Gate;
            NC.PinName := LoadPin;
            NC.IsDriver := False;
            OutNet.Connections.Add(NC);
            OutNet2.Connections.Delete(jj);
          end;
        // What remains on OutNet2 is just the consumed flip-flop's own driver
        // entry; drop it too so Phase 3 can reclaim the now-floating net.
        OutNet2.Connections.Clear;

        // Drop the consumed flip-flop's own entries, then remove it.
        for jj := OutNet.Connections.Count - 1 downto 0 do
          if OutNet.Connections[jj].Gate = FF_br then
            OutNet.Connections.Delete(jj);
        for jj := Model.Nets[ClockNetName].Connections.Count - 1 downto 0 do
          if Model.Nets[ClockNetName].Connections[jj].Gate = FF_br then
            Model.Nets[ClockNetName].Connections.Delete(jj);
        InsertedFFs.Remove(FF_br);
        Model.Gates.Remove(FF_br);
      end;

    // Create the shared flip-flop on S's input net.
    Inc(NetCounter);
    ChildName := Format('%s__ff_%d', [Nin.Name, NetCounter]);
    while Model.Nets.ContainsKey(ChildName) do
    begin
      Inc(NetCounter);
      ChildName := Format('%s__ff_%d', [Nin.Name, NetCounter]);
    end;
    Nin2 := Model.FindOrCreateNet(ChildName);
    Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
      ClockNetName, Nin.Name, ChildName, FFLevel);
    Model.Gates.Add(Gate);
    InsertedFFs.Add(Gate, True);

    for jj := Nin.Connections.Count - 1 downto 0 do
      if Nin.Connections[jj].Gate = S then
        Nin.Connections.Delete(jj);
    NC.Gate := Gate;
    NC.PinName := DataPin;
    NC.IsDriver := False;
    Nin.Connections.Add(NC);

    NC.Gate := Gate;
    NC.PinName := ClockPin;
    NC.IsDriver := False;
    Model.Nets[ClockNetName].Connections.Add(NC);

    NC.Gate := Gate;
    NC.PinName := OutputPin;
    NC.IsDriver := True;
    Nin2.Connections.Add(NC);

    for Conn in S.Connections do
      if Conn.Port.Direction in [pdInput, pdInOut] then
      begin
        Conn.NetName := ChildName;
        NC.Gate := S;
        NC.PinName := Conn.PinName;
        NC.IsDriver := False;
        Nin2.Connections.Add(NC);
        Break;
      end;

    S.ClockLevel := FFLevel;
  end;

begin
  Result := 0;
  if (Model = nil) or (Lib = nil) or (FFCellName = '') then
    Exit;
  FFCell := Lib.FindCell(FFCellName);
  if FFCell = nil then
    Exit;
  if not IsFlipFlopCandidate(FFCell, ClockPin, DataPin, OutputPin) then
    Exit;
  if (ClockPin = '') or (DataPin = '') or (OutputPin = '') then
    Exit;

  ClockNetName := ClockNetFor(Model);
  if ClockNetName = '' then
  begin
    ClockNetName := 'clk';
    if not Model.Nets.ContainsKey(ClockNetName) then
    begin
      Model.FindOrCreateNet(ClockNetName);
      Model.Inputs.Add(ClockNetName);
    end;
  end;
  EnsureClockPinsConnected(Model, ClockNetName);

  InsertedFFs := TDictionary<TGateInstance, Boolean>.Create;
  try
    NetCounter := 0;

    // ---- Phase 1: naive backwards pass ----
    Count := Model.Gates.Count;
    for i := Count - 1 downto 0 do
    begin
      B := Model.Gates[i];
      if B.ClockLevel < 0 then
        Continue;
      if CellHasClock(B.Cell) then
        Expected := B.ClockLevel - 1
      else
        Expected := B.ClockLevel;
      if Expected < 0 then
        Continue;

      for j := 0 to B.Connections.Count - 1 do
      begin
        Conn := B.Connections[j];
        if not (Conn.Port.Direction in [pdInput, pdInOut]) then
          Continue;
        if IsClockPinName(Conn.Port.Name) then
          Continue;

        Net := Model.Nets[Conn.NetName];
        LA := 0;
        for NC in Net.Connections do
          if NC.IsDriver then
          begin
            if NC.Gate.ClockLevel > LA then
              LA := NC.Gate.ClockLevel;
            Break;
          end;
        N := Expected - LA;
        if N <= 0 then
          Continue;

        PrevNet := Net;
        for jj := 1 to N do
        begin
          Inc(NetCounter);
          ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          while Model.Nets.ContainsKey(ChildName) do
          begin
            Inc(NetCounter);
            ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          end;
          NewNet := Model.FindOrCreateNet(ChildName);
          Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
            ClockNetName, PrevNet.Name, ChildName, LA + jj);
          Model.Gates.Add(Gate);
          InsertedFFs.Add(Gate, True);

          NC.Gate := Gate;
          NC.PinName := DataPin;
          NC.IsDriver := False;
          PrevNet.Connections.Add(NC);

          NC.Gate := Gate;
          NC.PinName := ClockPin;
          NC.IsDriver := False;
          Model.Nets[ClockNetName].Connections.Add(NC);

          NC.Gate := Gate;
          NC.PinName := OutputPin;
          NC.IsDriver := True;
          NewNet.Connections.Add(NC);

          PrevNet := NewNet;
        end;

        // Retarget B's connection to the chain tail and drop the old entry.
        Conn.NetName := PrevNet.Name;
        NC.Gate := B;
        NC.PinName := Conn.PinName;
        NC.IsDriver := False;
        PrevNet.Connections.Add(NC);
        for jj := Net.Connections.Count - 1 downto 0 do
          if (Net.Connections[jj].Gate = B) and
             SameText(Net.Connections[jj].PinName, Conn.PinName) then
            Net.Connections.Delete(jj);
      end;
    end;

    // ---- Phase 2: iterative merge across splitters ----
    if ADoMerge then
    begin
      repeat
        Merged := False;
        i := 0;
        while (i < Model.Gates.Count) and (not Merged) do
        begin
          S := Model.Gates[i];
          if IsSplitterCell(S.Cell) and (S.ClockLevel >= 0) and CanMerge(S) then
          begin
            DoMerge(S);
            Merged := True;
          end;
          Inc(i);
        end;
      until not Merged;
    end;

    // ---- Phase 3: drop floating (empty) nets ----
    EmptyNets := TList<string>.Create;
    try
      for ChildName in Model.Nets.Keys do
        if Model.Nets[ChildName].Connections.Count = 0 then
          EmptyNets.Add(ChildName);
      for i := 0 to EmptyNets.Count - 1 do
      begin
        Model.Nets.Remove(EmptyNets[i]);
        j := Model.Inputs.IndexOf(EmptyNets[i]);
        if j >= 0 then
          Model.Inputs.Delete(j);
        j := Model.Outputs.IndexOf(EmptyNets[i]);
        if j >= 0 then
          Model.Outputs.Delete(j);
      end;
    finally
      EmptyNets.Free;
    end;

    Result := InsertedFFs.Count;
  finally
    InsertedFFs.Free;
  end;
end;

function PadOutputFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string): Integer;
var
  FFCell: TCell;
  ClockPin, DataPin, OutputPin: string;
  ClockNetName: string;
  OutputName, OutNetName: string;
  Net, EntryNet, OutNet, PrevNet: TNet;
  NC: TNetConnection;
  DriverGate: TGateInstance;
  MaxLevel, LA, N, i, j, jj, NetCounter: Integer;
  Gate: TGateInstance;
  Conn: TPinConnection;
  ChildName: string;
begin
  Result := 0;
  if (Model = nil) or (Lib = nil) or (FFCellName = '') then
    Exit;
  FFCell := Lib.FindCell(FFCellName);
  if FFCell = nil then
    Exit;
  if not IsFlipFlopCandidate(FFCell, ClockPin, DataPin, OutputPin) then
    Exit;
  if (ClockPin = '') or (DataPin = '') or (OutputPin = '') then
    Exit;

  ClockNetName := ClockNetFor(Model);
  if ClockNetName = '' then
  begin
    ClockNetName := 'clk';
    if not Model.Nets.ContainsKey(ClockNetName) then
    begin
      Model.FindOrCreateNet(ClockNetName);
      Model.Inputs.Add(ClockNetName);
    end;
  end;
  EnsureClockPinsConnected(Model, ClockNetName);

  // Find the maximum clock level among all primary output drivers.
  MaxLevel := 0;
  for i := 0 to Model.Outputs.Count - 1 do
  begin
    OutputName := Model.Outputs[i];
    if not Model.Nets.TryGetValue(OutputName, Net) then
      Continue;
    for NC in Net.Connections do
      if NC.IsDriver and (NC.Gate.ClockLevel > MaxLevel) then
        MaxLevel := NC.Gate.ClockLevel;
  end;
  if MaxLevel <= 0 then
    Exit;

  NetCounter := 0;
  for i := 0 to Model.Outputs.Count - 1 do
  begin
    OutputName := Model.Outputs[i];
    if not Model.Nets.TryGetValue(OutputName, Net) then
      Continue;

    // Find the driver gate and its level.
    DriverGate := nil;
    LA := 0;
    for NC in Net.Connections do
      if NC.IsDriver then
      begin
        DriverGate := NC.Gate;
        LA := NC.Gate.ClockLevel;
        Break;
      end;
    if DriverGate = nil then
      Continue;

    N := MaxLevel - LA;
    if N <= 0 then
      Continue;

    // Find the driver's output connection on this net (to retarget it).
    Conn := nil;
    for j := 0 to DriverGate.Connections.Count - 1 do
      if (DriverGate.Connections[j].Port.Direction = pdOutput) and
         SameText(DriverGate.Connections[j].NetName, OutputName) then
      begin
        Conn := DriverGate.Connections[j];
        Break;
      end;
    if Conn = nil then
      Continue;

    // Create a new entry net for the driver's output.
    Inc(NetCounter);
    ChildName := Format('%s__out_entry_%d', [OutputName, NetCounter]);
    while Model.Nets.ContainsKey(ChildName) do
    begin
      Inc(NetCounter);
      ChildName := Format('%s__out_entry_%d', [OutputName, NetCounter]);
    end;
    EntryNet := Model.FindOrCreateNet(ChildName);

    // Remove the driver from the output net.
    for jj := Net.Connections.Count - 1 downto 0 do
      if (Net.Connections[jj].Gate = DriverGate) and Net.Connections[jj].IsDriver then
      begin
        Net.Connections.Delete(jj);
        Break;
      end;

    // Retarget the driver to the entry net.
    Conn.NetName := ChildName;
    NC.Gate := DriverGate;
    NC.PinName := Conn.PinName;
    NC.IsDriver := True;
    EntryNet.Connections.Add(NC);

    // Chain: EntryNet -> FF1 -> net1 -> ... -> FFn -> output net.
    PrevNet := EntryNet;
    for jj := 1 to N do
    begin
      Inc(NetCounter);
      ChildName := Format('%s__out_ff_%d', [OutputName, NetCounter]);
      while Model.Nets.ContainsKey(ChildName) do
      begin
        Inc(NetCounter);
        ChildName := Format('%s__out_ff_%d', [OutputName, NetCounter]);
      end;

      // Last FF drives the original output net; intermediate FFs drive new nets.
      if jj < N then
        OutNetName := ChildName
      else
        OutNetName := OutputName;

      Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
        ClockNetName, PrevNet.Name, OutNetName, LA + jj);
      Model.Gates.Add(Gate);
      Inc(Result);

      // FF data load on PrevNet.
      NC.Gate := Gate;
      NC.PinName := DataPin;
      NC.IsDriver := False;
      PrevNet.Connections.Add(NC);

      // FF clock load.
      NC.Gate := Gate;
      NC.PinName := ClockPin;
      NC.IsDriver := False;
      if Model.Nets.ContainsKey(ClockNetName) then
        Model.Nets[ClockNetName].Connections.Add(NC);

      // FF driver on OutNet.
      OutNet := Model.FindOrCreateNet(OutNetName);
      NC.Gate := Gate;
      NC.PinName := OutputPin;
      NC.IsDriver := True;
      OutNet.Connections.Add(NC);

      PrevNet := OutNet;
    end;
  end;
end;

function InsertTopLevelFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string): Integer;
var
  FFCell: TCell;
  ClockPin, DataPin, OutputPin: string;
  ClockNetName: string;
  MaxTopLevel, i, j, jj, NetCounter: Integer;
  G, Gate: TGateInstance;
  Conn: TPinConnection;
  Net, NewNet: TNet;
  NC: TNetConnection;
  ChildName: string;
begin
  Result := 0;
  if (Model = nil) or (Lib = nil) or (FFCellName = '') then
    Exit;
  FFCell := Lib.FindCell(FFCellName);
  if FFCell = nil then
    Exit;
  if not IsFlipFlopCandidate(FFCell, ClockPin, DataPin, OutputPin) then
    Exit;
  if (ClockPin = '') or (DataPin = '') or (OutputPin = '') then
    Exit;

  ClockNetName := ClockNetFor(Model);
  if ClockNetName = '' then
  begin
    ClockNetName := 'clk';
    if not Model.Nets.ContainsKey(ClockNetName) then
    begin
      Model.FindOrCreateNet(ClockNetName);
      Model.Inputs.Add(ClockNetName);
    end;
  end;
  EnsureClockPinsConnected(Model, ClockNetName);

  // Highest clock level in the circuit.
  MaxTopLevel := 0;
  for i := 0 to Model.Gates.Count - 1 do
    if Model.Gates[i].ClockLevel > MaxTopLevel then
      MaxTopLevel := Model.Gates[i].ClockLevel;

  NetCounter := 0;
  for i := 0 to Model.Gates.Count - 1 do
  begin
    G := Model.Gates[i];
    if G.ClockLevel <> MaxTopLevel then
      Continue;
    // Only an actual flip-flop counts as clocking the signal out;
    // ordinary clocked logic gates (e.g. NOTT/XORT) still need one.
    if G.Cell = FFCell then
      Continue;
    for j := 0 to G.Connections.Count - 1 do
    begin
      Conn := G.Connections[j];
      if Conn.Port.Direction <> pdOutput then
        Continue;
      if not Model.Nets.TryGetValue(Conn.NetName, Net) then
        Continue;

      Inc(NetCounter);
      ChildName := Format('%s__top_ff_%d', [Net.Name, NetCounter]);
      while Model.Nets.ContainsKey(ChildName) do
      begin
        Inc(NetCounter);
        ChildName := Format('%s__top_ff_%d', [Net.Name, NetCounter]);
      end;
      NewNet := Model.FindOrCreateNet(ChildName);

      // Retarget the gate's driver onto the entry net.
      for jj := Net.Connections.Count - 1 downto 0 do
        if (Net.Connections[jj].Gate = G) and Net.Connections[jj].IsDriver then
        begin
          Net.Connections.Delete(jj);
          Break;
        end;
      Conn.NetName := ChildName;
      NC.Gate := G;
      NC.PinName := Conn.PinName;
      NC.IsDriver := True;
      NewNet.Connections.Add(NC);

      // Flip-flop from the entry net back onto the original net, on the
      // same highest level so all outputs stay aligned.
      Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
        ClockNetName, NewNet.Name, Net.Name, MaxTopLevel);
      Model.Gates.Add(Gate);
      Inc(Result);

      NC.Gate := Gate;
      NC.PinName := DataPin;
      NC.IsDriver := False;
      NewNet.Connections.Add(NC);

      NC.Gate := Gate;
      NC.PinName := ClockPin;
      NC.IsDriver := False;
      if Model.Nets.ContainsKey(ClockNetName) then
        Model.Nets[ClockNetName].Connections.Add(NC);

      NC.Gate := Gate;
      NC.PinName := OutputPin;
      NC.IsDriver := True;
      Net.Connections.Add(NC);
    end;
  end;
end;

function InsertDelayLevelizedFFs(Model: TBlifModel; Lib: TLibrary;
  const FFCellName: string; ThresholdPs: Double): Integer;
var
  FFCell: TCell;
  ClockPin, DataPin, OutputPin: string;
  ClockNetName: string;
  InsertedFFs: TDictionary<TGateInstance, Boolean>;
  CellDelays: TDictionary<string, Double>;
  Arrival: TDictionary<TGateInstance, Double>;
  Resolved: TDictionary<TGateInstance, Boolean>;
  Worklist: TList<TGateInstance>;
  Visited: TDictionary<TGateInstance, Boolean>;
  i, j, jj, NetCounter: Integer;
  G, Gate, LoadGate: TGateInstance;
  Conn: TPinConnection;
  Net, NewNet, PrevNet: TNet;
  NC: TNetConnection;
  ChildName: string;
  InputArrival, ArrTime, Dly, PathDelay: Double;
  k: Integer;
  C: TPinConnection;
  N2: TNet;
  NC2: TNetConnection;
  EmptyNets: TList<string>;
  Count, LA, Expected, N: Integer;
  B: TGateInstance;
  Errors: TStringList;
  Merged: Boolean;
  S, FF_br: TGateInstance;
  OutNet, OutNet2, Nin, Nin2: TNet;
  FFLevel: Integer;
  LoadPin: string;
  PathMemo: TDictionary<string, Double>;
  SplitterDelay, MaxPath, FfOutPath: Double;
  FfOutNet: TNet;

  function CellDelayOfLocal(ACell: TCell): Double;
  var
    Timing: TCellTiming;
    ii: Integer;
  begin
    if CellDelays.TryGetValue(ACell.Name, Result) then
      Exit;
    Result := 0;
    for ii := 0 to ACell.SourceFiles.Count - 1 do
      if SameText(ExtractFileExt(ACell.SourceFiles[ii]), '.v') then
      begin
        Timing := ParseVerilogTiming(ACell.SourceFiles[ii]);
        if Timing <> nil then
        begin
          Result := Timing.OutputDelayPs;
          if Result < 0 then
            Result := 0;
          Timing.Free;
          Break;
        end;
      end;
    CellDelays.AddOrSetValue(ACell.Name, Result);
  end;

  // Check whether all non-clocked data-input drivers of G have been resolved.
  function AllDriversReady(G: TGateInstance): Boolean;
  var
    ck: Integer;
    CC: TPinConnection;
    NN2: TNet;
    NNC: TNetConnection;
  begin
    Result := True;
    for ck := 0 to G.Connections.Count - 1 do
    begin
      CC := G.Connections[ck];
      if CC.Port.Direction <> pdInput then
        Continue;
      if IsClockPinName(CC.Port.Name) then
        Continue;
      if not Model.Nets.TryGetValue(CC.NetName, NN2) then
        Continue;
      for NNC in NN2.Connections do
        if NNC.IsDriver then
        begin
          // Clocked drivers are always ready.
          if CellHasClock(NNC.Gate.Cell) then
            Continue;
          // PI-driven nets have no gate driver — always ready.
          if not Resolved.ContainsKey(NNC.Gate) then
            Exit(False);
        end;
    end;
  end;

  // ---- Phase 4 helpers: delay-levelized splitter merge ----

  function PathFromNetToNextClocked(const ANetName: string): Double;
  var
    LoadNC: TNetConnection;
    LoadN: TNet;
    ChildPath, MaxChild, GateDly: Double;
    OutConn: TPinConnection;
  begin
    if PathMemo.TryGetValue(ANetName, Result) then
      Exit;
    Result := 0;
    if not Model.Nets.TryGetValue(ANetName, LoadN) then
      Exit;
    for LoadNC in LoadN.Connections do
    begin
      if LoadNC.IsDriver then
        Continue;
      if CellHasClock(LoadNC.Gate.Cell) then
        Continue;
      GateDly := CellDelayOfLocal(LoadNC.Gate.Cell);
      MaxChild := 0;
      for OutConn in LoadNC.Gate.Connections do
      begin
        if OutConn.Port.Direction <> pdOutput then
          Continue;
        ChildPath := PathFromNetToNextClocked(OutConn.NetName);
        if ChildPath > MaxChild then
          MaxChild := ChildPath;
      end;
      GateDly := GateDly + MaxChild;
      if GateDly > Result then
        Result := GateDly;
    end;
    PathMemo.Add(ANetName, Result);
  end;

  function CanMergeDelay(S: TGateInstance): Boolean;
  var
    Conn2: TPinConnection;
    Net2: TNet;
    NC2: TNetConnection;
    LoadCount, OutCount: Integer;
    FF_Gate: TGateInstance;
    OutConn: TPinConnection;
  begin
    OutCount := 0;
    SplitterDelay := CellDelayOfLocal(S.Cell);
    MaxPath := 0;
    for Conn2 in S.Connections do
      if Conn2.Port.Direction = pdOutput then
      begin
        Inc(OutCount);
        if not Model.Nets.TryGetValue(Conn2.NetName, Net2) then
          Exit(False);
        LoadCount := 0;
        FF_Gate := nil;
        for NC2 in Net2.Connections do
          if not NC2.IsDriver then
          begin
            Inc(LoadCount);
            if NC2.Gate.Cell <> FFCell then
              Exit(False);
            if NC2.Gate.ClockLevel <> S.ClockLevel + 1 then
              Exit(False);
            FF_Gate := NC2.Gate;
          end;
        if LoadCount <> 1 then
          Exit(False);
        if FF_Gate = nil then
          Exit(False);
        FfOutNet := nil;
        for OutConn in FF_Gate.Connections do
          if OutConn.Port.Direction = pdOutput then
          begin
            if Model.Nets.TryGetValue(OutConn.NetName, FfOutNet) then
              Break;
          end;
        if FfOutNet = nil then
          Exit(False);
        FfOutPath := PathFromNetToNextClocked(FfOutNet.Name);
        if FfOutPath > MaxPath then
          MaxPath := FfOutPath;
      end;
    Result := (OutCount >= 2) and
      (CellDelayOfLocal(FFCell) + SplitterDelay + MaxPath <= ThresholdPs);
  end;

  procedure DoMergeDelay(S: TGateInstance);
  var
    Conn, CC: TPinConnection;
    NC3: TNetConnection;
    jj: Integer;
  begin
    FFLevel := S.ClockLevel + 1;

    Nin := nil;
    for Conn in S.Connections do
      if Conn.Port.Direction in [pdInput, pdInOut] then
      begin
        Nin := Model.Nets[Conn.NetName];
        Break;
      end;
    if Nin = nil then
      Exit;

    for Conn in S.Connections do
      if Conn.Port.Direction = pdOutput then
      begin
        if not Model.Nets.TryGetValue(Conn.NetName, OutNet) then
          Continue;
        FF_br := nil;
        for NC3 in OutNet.Connections do
          if not NC3.IsDriver then
            FF_br := NC3.Gate;
        if FF_br = nil then
          Continue;
        OutNet2 := nil;
        for CC in FF_br.Connections do
          if CC.Port.Direction = pdOutput then
          begin
            if Model.Nets.TryGetValue(CC.NetName, OutNet2) then
              Break;
          end;
        if OutNet2 = nil then
          Continue;

        for jj := OutNet2.Connections.Count - 1 downto 0 do
          if not OutNet2.Connections[jj].IsDriver then
          begin
            LoadPin := OutNet2.Connections[jj].PinName;
            for CC in OutNet2.Connections[jj].Gate.Connections do
              if SameText(CC.NetName, OutNet2.Name) then
                CC.NetName := OutNet.Name;
            NC3.Gate := OutNet2.Connections[jj].Gate;
            NC3.PinName := LoadPin;
            NC3.IsDriver := False;
            OutNet.Connections.Add(NC3);
            OutNet2.Connections.Delete(jj);
          end;
        OutNet2.Connections.Clear;

        for jj := OutNet.Connections.Count - 1 downto 0 do
          if OutNet.Connections[jj].Gate = FF_br then
            OutNet.Connections.Delete(jj);
        if Model.Nets.ContainsKey(ClockNetName) then
          for jj := Model.Nets[ClockNetName].Connections.Count - 1 downto 0 do
            if Model.Nets[ClockNetName].Connections[jj].Gate = FF_br then
              Model.Nets[ClockNetName].Connections.Delete(jj);
        InsertedFFs.Remove(FF_br);
        Model.Gates.Remove(FF_br);
      end;

    Inc(NetCounter);
    ChildName := Format('%s__ff_%d', [Nin.Name, NetCounter]);
    while Model.Nets.ContainsKey(ChildName) do
    begin
      Inc(NetCounter);
      ChildName := Format('%s__ff_%d', [Nin.Name, NetCounter]);
    end;
    Nin2 := Model.FindOrCreateNet(ChildName);
    Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
      ClockNetName, Nin.Name, ChildName, FFLevel);
    Model.Gates.Add(Gate);
    InsertedFFs.Add(Gate, True);

    for jj := Nin.Connections.Count - 1 downto 0 do
      if Nin.Connections[jj].Gate = S then
        Nin.Connections.Delete(jj);
    NC3.Gate := Gate;
    NC3.PinName := DataPin;
    NC3.IsDriver := False;
    Nin.Connections.Add(NC3);

    NC3.Gate := Gate;
    NC3.PinName := ClockPin;
    NC3.IsDriver := False;
    if Model.Nets.ContainsKey(ClockNetName) then
      Model.Nets[ClockNetName].Connections.Add(NC3);

    NC3.Gate := Gate;
    NC3.PinName := OutputPin;
    NC3.IsDriver := True;
    Nin2.Connections.Add(NC3);

    for Conn in S.Connections do
      if Conn.Port.Direction in [pdInput, pdInOut] then
      begin
        Conn.NetName := ChildName;
        NC3.Gate := S;
        NC3.PinName := Conn.PinName;
        NC3.IsDriver := False;
        Nin2.Connections.Add(NC3);
        Break;
      end;

    S.ClockLevel := FFLevel;
  end;

begin
  Result := 0;
  if (Model = nil) or (Lib = nil) or (FFCellName = '') then
    Exit;
  if ThresholdPs <= 0 then
    Exit;
  FFCell := Lib.FindCell(FFCellName);
  if FFCell = nil then
    Exit;
  if not IsFlipFlopCandidate(FFCell, ClockPin, DataPin, OutputPin) then
    Exit;
  if (ClockPin = '') or (DataPin = '') or (OutputPin = '') then
    Exit;

  ClockNetName := ClockNetFor(Model);
  if ClockNetName = '' then
  begin
    ClockNetName := 'clk';
    if not Model.Nets.ContainsKey(ClockNetName) then
    begin
      Model.FindOrCreateNet(ClockNetName);
      Model.Inputs.Add(ClockNetName);
    end;
  end;
  EnsureClockPinsConnected(Model, ClockNetName);

  CellDelays := TDictionary<string, Double>.Create;
  Arrival := TDictionary<TGateInstance, Double>.Create;
  InsertedFFs := TDictionary<TGateInstance, Boolean>.Create;
  Resolved := TDictionary<TGateInstance, Boolean>.Create;
  Worklist := TList<TGateInstance>.Create;
  Visited := TDictionary<TGateInstance, Boolean>.Create;
  try
    NetCounter := 0;

    // Seed worklist with gates whose drivers are all ready.
    for i := 0 to Model.Gates.Count - 1 do
    begin
      G := Model.Gates[i];
      if CellHasClock(G.Cell) or AllDriversReady(G) then
        Worklist.Add(G);
    end;

    // Process gates in worklist order (topological).
    i := 0;
    while i < Worklist.Count do
    begin
      G := Worklist[i];
      Inc(i);

      if Visited.ContainsKey(G) then
        Continue;
      Visited.Add(G, True);

      // Compute arrival from data-input drivers.
      InputArrival := 0;
      for k := 0 to G.Connections.Count - 1 do
      begin
        C := G.Connections[k];
        if C.Port.Direction <> pdInput then
          Continue;
        if IsClockPinName(C.Port.Name) then
          Continue;
        if not Model.Nets.TryGetValue(C.NetName, N2) then
          Continue;
        for NC2 in N2.Connections do
          if NC2.IsDriver then
          begin
            if CellHasClock(NC2.Gate.Cell) then
              ArrTime := CellDelayOfLocal(NC2.Gate.Cell)
            else if not Arrival.TryGetValue(NC2.Gate, ArrTime) then
              ArrTime := 0;
            if ArrTime > InputArrival then
              InputArrival := ArrTime;
          end;
      end;

      Dly := CellDelayOfLocal(G.Cell);

      // Path delay: from the last clocked boundary (counting that gate's own
      // clock-to-output delay) through non-clocked children, ending at this
      // gate's input (not inclusive of this gate's own delay).
      if CellHasClock(G.Cell) then
        PathDelay := InputArrival
      else
        PathDelay := InputArrival + Dly;

      // Insert DFFs on every non-clocked data input when path is too long.
      if PathDelay > ThresholdPs then
      begin
        for j := 0 to G.Connections.Count - 1 do
        begin
          Conn := G.Connections[j];
          if not (Conn.Port.Direction in [pdInput, pdInOut]) then
            Continue;
          if IsClockPinName(Conn.Port.Name) then
            Continue;

          if not Model.Nets.TryGetValue(Conn.NetName, Net) then
            Continue;

          // Find the driver; skip only if absent (primary input).
          NC2 := Default(TNetConnection);
          for NC in Net.Connections do
            if NC.IsDriver then
            begin
              NC2 := NC;
              Break;
            end;
          if NC2.Gate = nil then
            Continue;

          // Create DFF: original net -> DFF -> new net.
          Inc(NetCounter);
          ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          while Model.Nets.ContainsKey(ChildName) do
          begin
            Inc(NetCounter);
            ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          end;
          NewNet := Model.FindOrCreateNet(ChildName);

          Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
            ClockNetName, Conn.NetName, ChildName, 0);
          Model.Gates.Add(Gate);
          InsertedFFs.Add(Gate, True);

          // DFF reads from original net.
          NC.Gate := Gate;
          NC.PinName := DataPin;
          NC.IsDriver := False;
          Net.Connections.Add(NC);

          // DFF clock.
          NC.Gate := Gate;
          NC.PinName := ClockPin;
          NC.IsDriver := False;
          if Model.Nets.ContainsKey(ClockNetName) then
            Model.Nets[ClockNetName].Connections.Add(NC);

          // DFF drives new net.
          NC.Gate := Gate;
          NC.PinName := OutputPin;
          NC.IsDriver := True;
          NewNet.Connections.Add(NC);

          // Retarget G's input to the new net.
          Conn.NetName := ChildName;
          NC.Gate := G;
          NC.PinName := Conn.PinName;
          NC.IsDriver := False;
          NewNet.Connections.Add(NC);

          // Remove G's old load entry from original net.
          for jj := Net.Connections.Count - 1 downto 0 do
            if (Net.Connections[jj].Gate = G) and
               SameText(Net.Connections[jj].PinName, Conn.PinName) then
            begin
              Net.Connections.Delete(jj);
              Break;
            end;
        end;

        // After DFF insertion the long paths restart at the new clocked
        // DFFs, so recompute the arrival from the current inputs.
        InputArrival := 0;
        for k := 0 to G.Connections.Count - 1 do
        begin
          C := G.Connections[k];
          if C.Port.Direction <> pdInput then
            Continue;
          if IsClockPinName(C.Port.Name) then
            Continue;
          if not Model.Nets.TryGetValue(C.NetName, N2) then
            Continue;
          for NC2 in N2.Connections do
            if NC2.IsDriver then
            begin
              if CellHasClock(NC2.Gate.Cell) then
                ArrTime := CellDelayOfLocal(NC2.Gate.Cell)
              else if not Arrival.TryGetValue(NC2.Gate, ArrTime) then
                ArrTime := 0;
              if ArrTime > InputArrival then
                InputArrival := ArrTime;
            end;
        end;
      end;

      // Store arrival. Clocked gates start the next path with their own
      // clock-to-output delay.
      if CellHasClock(G.Cell) then
        Arrival.Add(G, CellDelayOfLocal(G.Cell))
      else
        Arrival.Add(G, InputArrival + Dly);

      Resolved.Add(G, True);

      // Enqueue any load gates that are now fully resolved.
      for k := 0 to G.Connections.Count - 1 do
      begin
        C := G.Connections[k];
        if C.Port.Direction <> pdOutput then
          Continue;
        if not Model.Nets.TryGetValue(C.NetName, N2) then
          Continue;
        for NC2 in N2.Connections do
          if not NC2.IsDriver then
          begin
            LoadGate := NC2.Gate;
            if Visited.ContainsKey(LoadGate) then
              Continue;
            if Worklist.IndexOf(LoadGate) >= 0 then
              Continue;
            if CellHasClock(LoadGate.Cell) or AllDriversReady(LoadGate) then
              Worklist.Add(LoadGate);
          end;
      end;
    end;

    // ---- Drop floating (empty) nets ----
    EmptyNets := TList<string>.Create;
    try
      for ChildName in Model.Nets.Keys do
        if Model.Nets[ChildName].Connections.Count = 0 then
          EmptyNets.Add(ChildName);
      for i := 0 to EmptyNets.Count - 1 do
      begin
        Model.Nets.Remove(EmptyNets[i]);
        j := Model.Inputs.IndexOf(EmptyNets[i]);
        if j >= 0 then
          Model.Inputs.Delete(j);
        j := Model.Outputs.IndexOf(EmptyNets[i]);
        if j >= 0 then
          Model.Outputs.Delete(j);
      end;
    finally
      EmptyNets.Free;
    end;

    // ---- Compute clock levels after breakup ----
    Errors := TStringList.Create;
    try
      ComputeClockLevels(Model, Errors);
    finally
      Errors.Free;
    end;

    // ---- Gap-fill: insert N DFFs in series to close clock level gaps ----
    Count := Model.Gates.Count;
    for i := Count - 1 downto 0 do
    begin
      B := Model.Gates[i];
      if B.ClockLevel < 0 then
        Continue;
      if CellHasClock(B.Cell) then
        Expected := B.ClockLevel - 1
      else
        Expected := B.ClockLevel;
      if Expected < 0 then
        Continue;

      for j := 0 to B.Connections.Count - 1 do
      begin
        Conn := B.Connections[j];
        if not (Conn.Port.Direction in [pdInput, pdInOut]) then
          Continue;
        if IsClockPinName(Conn.Port.Name) then
          Continue;

        if not Model.Nets.TryGetValue(Conn.NetName, Net) then
          Continue;
        LA := 0;
        for NC in Net.Connections do
          if NC.IsDriver then
          begin
            if NC.Gate.ClockLevel > LA then
              LA := NC.Gate.ClockLevel;
            Break;
          end;
        N := Expected - LA;
        if N <= 0 then
          Continue;

        PrevNet := Net;
        for jj := 1 to N do
        begin
          Inc(NetCounter);
          ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          while Model.Nets.ContainsKey(ChildName) do
          begin
            Inc(NetCounter);
            ChildName := Format('%s__ff_%d', [Conn.NetName, NetCounter]);
          end;
          NewNet := Model.FindOrCreateNet(ChildName);
          Gate := CreateFF(FFCell, FFCellName, DataPin, OutputPin, ClockPin,
            ClockNetName, PrevNet.Name, ChildName, LA + jj);
          Model.Gates.Add(Gate);
          InsertedFFs.Add(Gate, True);

          NC.Gate := Gate;
          NC.PinName := DataPin;
          NC.IsDriver := False;
          PrevNet.Connections.Add(NC);

          NC.Gate := Gate;
          NC.PinName := ClockPin;
          NC.IsDriver := False;
          if Model.Nets.ContainsKey(ClockNetName) then
            Model.Nets[ClockNetName].Connections.Add(NC);

          NC.Gate := Gate;
          NC.PinName := OutputPin;
          NC.IsDriver := True;
          NewNet.Connections.Add(NC);

          PrevNet := NewNet;
        end;

        // Retarget B's input to the chain tail.
        Conn.NetName := PrevNet.Name;
        NC.Gate := B;
        NC.PinName := Conn.PinName;
        NC.IsDriver := False;
        PrevNet.Connections.Add(NC);
        for jj := Net.Connections.Count - 1 downto 0 do
          if (Net.Connections[jj].Gate = B) and
             SameText(Net.Connections[jj].PinName, Conn.PinName) then
          begin
            Net.Connections.Delete(jj);
            Break;
          end;
      end;
    end;

    // ---- Recompute clock levels after gap-fill ----
    Errors := TStringList.Create;
    try
      ComputeClockLevels(Model, Errors);
    finally
      Errors.Free;
    end;

    // ---- Phase 4: iterative splitter merge ----
    PathMemo := TDictionary<string, Double>.Create;
    try
      repeat
        Merged := False;
        PathMemo.Clear;
        i := 0;
        while (i < Model.Gates.Count) and (not Merged) do
        begin
          S := Model.Gates[i];
          if IsSplitterCell(S.Cell) and (S.ClockLevel >= 0) and CanMergeDelay(S) then
          begin
            DoMergeDelay(S);
            Merged := True;
          end;
          Inc(i);
        end;
      until not Merged;
    finally
      PathMemo.Free;
    end;

    Result := InsertedFFs.Count;
  finally
    InsertedFFs.Free;
    Arrival.Free;
    CellDelays.Free;
    Resolved.Free;
    Worklist.Free;
    Visited.Free;
  end;
end;

end.

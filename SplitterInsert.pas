unit SplitterInsert;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  System.StrUtils,
  LefLibrary,
  BlifLibrary;

type
  // One cell usable as a splitter: how many outputs it fans out to and its
  // input -> output propagation delay in ps (from the cell's .v file).
  TSplitterType = record
    CellName: string;
    OutputCount: Integer;
    DelayPs: Double;
  end;

  // Inserts a delay-optimal splitter tree into every net of Model whose fanout
  // exceeds one. For each net the tree is chosen by dynamic programming over
  // the available splitter types (dp[s] = min over K of DelayPs(K) + dp[ceil(s/K)]),
  // then the tree is materialised as real gate instances + new nets. Returns
  // the number of splitter instances created. Returns 0 if Model or SplitterTypes
  // is empty, no net needs splitting, or any splitter cell is missing from Lib.
  function InsertSplitters(Model: TBlifModel; Lib: TLibrary;
    const SplitterTypes: TArray<TSplitterType>): Integer;

  // Same tree construction as InsertSplitters, but for a single named net of
  // Model (e.g. a clock distribution net): the net's loads are re-hung under
  // a delay-optimal splitter tree rooted at the net itself. The net keeps its
  // existing driver(s). Returns the number of splitter instances created.
  function InsertSplitterTreeForNet(Model: TBlifModel; Lib: TLibrary;
    const NetName: string; const SplitterTypes: TArray<TSplitterType>): Integer;

implementation

type
  TNetLoad = record
    Gate: TGateInstance;
    PinName: string;
    Conn: TPinConnection; // the gate connection to retarget onto the leaf net
  end;

  TSplitterDP = record
    Cost: Double;   // best worst-case delay to serve this many loads
    Choice: Integer; // index into SplitterTypes, or -1
  end;

function CountLoads(Net: TNet): Integer;
var
  NC: TNetConnection;
begin
  Result := 0;
  for NC in Net.Connections do
    if not NC.IsDriver then
      Inc(Result);
end;

function FindGateConn(Gate: TGateInstance; const PinName, NetName: string): TPinConnection;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to Gate.Connections.Count - 1 do
    if SameText(Gate.Connections[i].PinName, PinName) then
    begin
      if SameText(Gate.Connections[i].NetName, NetName) then
        Exit(Gate.Connections[i]);
      if Result = nil then
        Result := Gate.Connections[i];
    end;
end;

procedure ComputeDP(const SplitterTypes: TArray<TSplitterType>; MaxS: Integer;
  var DP: TArray<TSplitterDP>);
var
  s, t: Integer;
  K: Integer;
  Cost: Double;
begin
  SetLength(DP, MaxS + 1);
  if MaxS < 1 then
    Exit;
  DP[1].Cost := 0;
  DP[1].Choice := -1;
  for s := 2 to MaxS do
  begin
    DP[s].Choice := -1;
    DP[s].Cost := 0;
    for t := 0 to Length(SplitterTypes) - 1 do
    begin
      K := SplitterTypes[t].OutputCount;
      if K < 2 then
        Continue;
      Cost := SplitterTypes[t].DelayPs + DP[(s + K - 1) div K].Cost;
      if (DP[s].Choice < 0) or (Cost < DP[s].Cost) then
      begin
        DP[s].Cost := Cost;
        DP[s].Choice := t;
      end;
    end;
  end;
end;

procedure BuildSubtree(Model: TBlifModel; Lib: TLibrary;
  const ParentNetName: string; const Loads: TList<TNetLoad>;
  const SplitterTypes: TArray<TSplitterType>; const DP: TArray<TSplitterDP>;
  const RootName: string; var NetCounter: Integer; var SplitterCount: Integer);
var
  s, t, K, Base, Rem, j, Idx, Share: Integer;
  Cell: TCell;
  Gate: TGateInstance;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  InputPort: TPort;
  OutputPins: TList<TPort>;
  ChildName: string;
  ChildLoads: TList<TNetLoad>;
begin
  s := Loads.Count;
  if s = 1 then
  begin
    Loads[0].Conn.NetName := ParentNetName;
    Net := Model.FindOrCreateNet(ParentNetName);
    NC.Gate := Loads[0].Gate;
    NC.PinName := Loads[0].PinName;
    NC.IsDriver := False;
    Net.Connections.Add(NC);
    Exit;
  end;

  t := DP[s].Choice;
  if t < 0 then
    Exit;

  Cell := Lib.FindCell(SplitterTypes[t].CellName);
  if Cell = nil then
    Exit;

  InputPort := nil;
  for j := 0 to Cell.Ports.Count - 1 do
    if Cell.Ports[j].Direction = pdInput then
    begin
      InputPort := Cell.Ports[j];
      Break;
    end;
  if InputPort = nil then
    Exit;

  OutputPins := TList<TPort>.Create;
  try
    for j := 0 to Cell.Ports.Count - 1 do
      if Cell.Ports[j].Direction = pdOutput then
        OutputPins.Add(Cell.Ports[j]);

    K := SplitterTypes[t].OutputCount;
    if OutputPins.Count < K then
      K := OutputPins.Count;
    if K < 2 then
      Exit;

    Gate := TGateInstance.Create;
    Gate.CellName := Cell.Name;
    Gate.Cell := Cell;

    Conn := TPinConnection.Create;
    Conn.PinName := InputPort.Name;
    Conn.NetName := ParentNetName;
    Conn.Port := InputPort;
    Gate.Connections.Add(Conn);
    Net := Model.FindOrCreateNet(ParentNetName);
    NC.Gate := Gate;
    NC.PinName := InputPort.Name;
    NC.IsDriver := False;
    Net.Connections.Add(NC);

    Base := s div K;
    Rem := s mod K;
    Idx := 0;
    ChildLoads := TList<TNetLoad>.Create;
    try
      for j := 0 to K - 1 do
      begin
        Share := Base;
        if j < Rem then
          Inc(Share);
        if Share = 0 then
          Continue; // unused output: leave it unconnected

        Inc(NetCounter);
        ChildName := Format('%s__spl_%d', [RootName, NetCounter]);
        while Model.Nets.ContainsKey(ChildName) do
        begin
          Inc(NetCounter);
          ChildName := Format('%s__spl_%d', [RootName, NetCounter]);
        end;

        Conn := TPinConnection.Create;
        Conn.PinName := OutputPins[j].Name;
        Conn.NetName := ChildName;
        Conn.Port := OutputPins[j];
        Gate.Connections.Add(Conn);
        Net := Model.FindOrCreateNet(ChildName);
        NC.Gate := Gate;
        NC.PinName := OutputPins[j].Name;
        NC.IsDriver := True;
        Net.Connections.Add(NC);

        ChildLoads.Clear;
        while Idx < s do
        begin
          ChildLoads.Add(Loads[Idx]);
          Inc(Idx);
          if ChildLoads.Count = Share then
            Break;
        end;
        BuildSubtree(Model, Lib, ChildName, ChildLoads, SplitterTypes, DP,
          RootName, NetCounter, SplitterCount);
      end;
    finally
      ChildLoads.Free;
    end;

    Model.Gates.Add(Gate);
    Inc(SplitterCount);
  finally
    OutputPins.Free;
  end;
end;

function InsertSplitters(Model: TBlifModel; Lib: TLibrary;
  const SplitterTypes: TArray<TSplitterType>): Integer;
var
  MaxS, NetCounter, SplitterCount: Integer;
  DP: TArray<TSplitterDP>;
  NetsToFix: TList<string>;
  Net: TNet;
  NetName: string;
  NC: TNetConnection;
  Loads: TList<TNetLoad>;
  Load: TNetLoad;
  i, j, t: Integer;
begin
  Result := 0;
  if (Model = nil) or (Length(SplitterTypes) = 0) then
    Exit;

  for t := 0 to Length(SplitterTypes) - 1 do
    if Lib.FindCell(SplitterTypes[t].CellName) = nil then
      Exit;

  MaxS := 0;
  for Net in Model.Nets.Values do
  begin
    j := CountLoads(Net);
    if j > MaxS then
      MaxS := j;
  end;
  if MaxS < 2 then
    Exit;

  ComputeDP(SplitterTypes, MaxS, DP);

  NetsToFix := TList<string>.Create;
  try
    for Net in Model.Nets.Values do
      if (CountLoads(Net) > 1) and (DP[CountLoads(Net)].Choice >= 0) then
        NetsToFix.Add(Net.Name);

    NetCounter := 0;
    SplitterCount := 0;
    Loads := TList<TNetLoad>.Create;
    try
      for i := 0 to NetsToFix.Count - 1 do
      begin
        NetName := NetsToFix[i];
        Net := Model.Nets[NetName];
        Loads.Clear;
        for NC in Net.Connections do
          if not NC.IsDriver then
          begin
            Load.Gate := NC.Gate;
            Load.PinName := NC.PinName;
            Load.Conn := FindGateConn(Load.Gate, Load.PinName, NetName);
            Loads.Add(Load);
          end;

        for j := Net.Connections.Count - 1 downto 0 do
          if not Net.Connections[j].IsDriver then
            Net.Connections.Delete(j);

        if Loads.Count > 0 then
          BuildSubtree(Model, Lib, NetName, Loads, SplitterTypes, DP, NetName,
            NetCounter, SplitterCount);
      end;
    finally
      Loads.Free;
    end;
    Result := SplitterCount;
  finally
    NetsToFix.Free;
  end;
end;

function InsertSplitterTreeForNet(Model: TBlifModel; Lib: TLibrary;
  const NetName: string; const SplitterTypes: TArray<TSplitterType>): Integer;
var
  MaxS, NetCounter, SplitterCount, j, t: Integer;
  DP: TArray<TSplitterDP>;
  Net: TNet;
  NC: TNetConnection;
  Loads: TList<TNetLoad>;
  Load: TNetLoad;
begin
  Result := 0;
  if (Model = nil) or (Length(SplitterTypes) = 0) then
    Exit;
  if not Model.Nets.TryGetValue(NetName, Net) then
    Exit;

  for t := 0 to Length(SplitterTypes) - 1 do
    if Lib.FindCell(SplitterTypes[t].CellName) = nil then
      Exit;

  MaxS := CountLoads(Net);
  if MaxS < 2 then
    Exit; // single load: connect directly, no tree needed

  ComputeDP(SplitterTypes, MaxS, DP);
  if DP[MaxS].Choice < 0 then
    Exit;

  Loads := TList<TNetLoad>.Create;
  try
    for NC in Net.Connections do
      if not NC.IsDriver then
      begin
        Load.Gate := NC.Gate;
        Load.PinName := NC.PinName;
        Load.Conn := FindGateConn(Load.Gate, Load.PinName, Net.Name);
        Loads.Add(Load);
      end;

    for j := Net.Connections.Count - 1 downto 0 do
      if not Net.Connections[j].IsDriver then
        Net.Connections.Delete(j);

    NetCounter := 0;
    SplitterCount := 0;
    BuildSubtree(Model, Lib, Net.Name, Loads, SplitterTypes, DP, Net.Name,
      NetCounter, SplitterCount);
    Result := SplitterCount;
  finally
    Loads.Free;
  end;
end;

end.

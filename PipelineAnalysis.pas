unit PipelineAnalysis;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  LefLibrary,
  BlifLibrary,
  PipelineConfig;

// Computes each gate's ClockLevel = the maximum number of clocked cells along
// any path from a primary input to that gate. A clocked cell (CellHasClock)
// adds 1; every other cell, including splitters, adds 0 and simply inherits
// its predecessor's level. The netlist must be a DAG; if a cycle is found an
// error is appended to Errors, the walk stops, and False is returned (gates
// reached before the cycle keep their levels; the rest stay at -1).
function ComputeClockLevels(Model: TBlifModel; Errors: TStrings): Boolean;

implementation

function ComputeClockLevels(Model: TBlifModel; Errors: TStrings): Boolean;
var
  State: TDictionary<TGateInstance, Integer>;
  CycleFound: Boolean;
  CycleGate: string;

  // Returns the clock level of Gate, memoised in State (0 unvisited,
  // 1 visiting, 2 done). Sets CycleFound on a back edge.
  function ClockLevelOf(Gate: TGateInstance): Integer;
  var
    i: Integer;
    Conn: TPinConnection;
    Net: TNet;
    NC: TNetConnection;
    PredLevel: Integer;
  begin
    if State[Gate] = 2 then
      Exit(Gate.ClockLevel);
    if State[Gate] = 1 then
    begin
      CycleFound := True;
      CycleGate := Gate.CellName;
      Exit(0);
    end;
    State[Gate] := 1;
    Result := 0;
    for i := 0 to Gate.Connections.Count - 1 do
    begin
      Conn := Gate.Connections[i];
      if not (Conn.Port.Direction in [pdInput, pdInOut]) then
        Continue;
      // Clock-pin predecessors are not data ancestry: a gate fed by the
      // clock network must not inherit levels from it.
      if IsClockPinName(Conn.Port.Name) then
        Continue;
      if Model.Nets.TryGetValue(Conn.NetName, Net) then
        for NC in Net.Connections do
          if NC.IsDriver then
          begin
            PredLevel := ClockLevelOf(NC.Gate);
            if CycleFound then
              Exit(0);
            if PredLevel > Result then
              Result := PredLevel;
            Break;
          end;
      if CycleFound then
        Exit(0);
    end;
    if CellHasClock(Gate.Cell) then
      Inc(Result);
    Gate.ClockLevel := Result;
    State[Gate] := 2;
  end;

var
  Gate: TGateInstance;
begin
  Result := True;
  State := TDictionary<TGateInstance, Integer>.Create;
  try
    for Gate in Model.Gates do
      State.Add(Gate, 0);
    CycleFound := False;
    CycleGate := '';
    for Gate in Model.Gates do
    begin
      ClockLevelOf(Gate);
      if CycleFound then
      begin
        Errors.Add(Format(
          'Clock level analysis: cycle detected (back edge into gate "%s"); pipeline levels were not computed.',
          [CycleGate]));
        Result := False;
        Break;
      end;
    end;
  finally
    State.Free;
  end;
end;

end.

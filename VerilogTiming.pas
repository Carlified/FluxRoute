unit VerilogTiming;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.StrUtils,
  System.IOUtils;

type
  // One timing arc (input -> output) with its propagation delay in picoseconds.
  TArcDelay = record
    FromPin: string;
    ToPin: string;
    DelayPs: Double;
  end;

  // Timing extracted from a single TimEx-style Verilog cell file.
  TCellTiming = class
  public
    CellName: string;
    FileName: string;
    Arcs: TList<TArcDelay>; // one entry per distinct (from,to); delay is the max over states
    constructor Create;
    destructor Destroy; override;
    // Worst-case input -> output propagation delay in ps (0 if no arcs).
    function OutputDelayPs: Double;
    function FindArcDelay(const FromPin, ToPin: string; out DelayPs: Double): Boolean;
  end;

  // Parses the specify block of a Verilog cell file. Returns nil if the file
  // has no specify block / no arcs (e.g. the ALWAYS0 cells) or can't be read.
  function ParseVerilogTiming(const FileName: string): TCellTiming;

implementation

function StripLineComment(const Line: string): string;
var
  P: Integer;
begin
  P := Pos('//', Line);
  if P > 0 then
    Result := Copy(Line, 1, P - 1)
  else
    Result := Line;
end;

{ TCellTiming }

constructor TCellTiming.Create;
begin
  Arcs := TList<TArcDelay>.Create;
end;

destructor TCellTiming.Destroy;
begin
  Arcs.Free;
  inherited;
end;

function TCellTiming.OutputDelayPs: Double;
var
  Arc: TArcDelay;
begin
  Result := 0;
  for Arc in Arcs do
    if Arc.DelayPs > Result then
      Result := Arc.DelayPs;
end;

function TCellTiming.FindArcDelay(const FromPin, ToPin: string;
  out DelayPs: Double): Boolean;
var
  Arc: TArcDelay;
begin
  Result := False;
  DelayPs := 0;
  for Arc in Arcs do
    if SameText(Arc.FromPin, FromPin) and SameText(Arc.ToPin, ToPin) then
    begin
      if (not Result) or (Arc.DelayPs > DelayPs) then
      begin
        Result := True;
        DelayPs := Arc.DelayPs;
      end;
    end;
end;

{ ParseVerilogTiming }

function ParseVerilogTiming(const FileName: string): TCellTiming;
var
  Lines: TStringList;
  SpecParams: TDictionary<string, Double>;
  Arcs: TList<TArcDelay>;
  Inv: TFormatSettings;
  i: Integer;
  Clean: string;
  Name, ValueStr, RHS: string;
  Value: Double;
  P, Q: Integer;
  InSpecify: Boolean;
  FromPin, ToPin: string;
  Arc: TArcDelay;
  Parts: TArray<string>;
  ModuleName: string;
  Existing: TArcDelay;
  j: Integer;
begin
  Result := nil;
  if not TFile.Exists(FileName) then
    Exit;

  Inv := TFormatSettings.Invariant;
  ModuleName := '';
  SpecParams := TDictionary<string, Double>.Create;
  Arcs := TList<TArcDelay>.Create;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    InSpecify := False;
    for i := 0 to Lines.Count - 1 do
    begin
      Clean := Trim(StripLineComment(Lines[i]));
      if Clean = '' then
        Continue;

      if ModuleName = '' then
      begin
        if StartsText('module', Clean) then
        begin
          Parts := Clean.Split([' '], TStringSplitOptions.ExcludeEmpty);
          if Length(Parts) > 1 then
            ModuleName := Parts[1];
        end;
      end;

      if StartsText('specify', Clean) then
      begin
        InSpecify := True;
        Continue;
      end;
      if InSpecify and StartsText('endspecify', Clean) then
        Break;
      if not InSpecify then
        Continue;

      if StartsText('specparam', Clean) then
      begin
        Name := Trim(Copy(Clean, Length('specparam') + 1, MaxInt));
        P := Pos('=', Name);
        if P > 0 then
        begin
          ValueStr := Trim(Copy(Name, P + 1, MaxInt));
          Name := Trim(Copy(Name, 1, P - 1));
          Q := Pos(';', ValueStr);
          if Q > 0 then
            ValueStr := Trim(Copy(ValueStr, 1, Q - 1));
          if TryStrToFloat(ValueStr, Value, Inv) then
            SpecParams.AddOrSetValue(Name, Value);
        end;
        Continue;
      end;

      P := Pos('=>', Clean);
      if P > 0 then
      begin
        Q := P - 1;
        while (Q > 0) and (Clean[Q] <> '(') do
          Dec(Q);
        if Q = 0 then
          Continue;
        FromPin := Trim(Copy(Clean, Q + 1, P - Q - 1));

        Q := P + 2;
        while (Q <= Length(Clean)) and (Clean[Q] <> ')') do
          Inc(Q);
        if Q > Length(Clean) then
          Continue;
        ToPin := Trim(Copy(Clean, P + 2, Q - P - 2));

        P := PosEx('=', Clean, Q + 1);
        if P = 0 then
          Continue;
        RHS := Trim(Copy(Clean, P + 1, MaxInt));
        Q := Pos(';', RHS);
        if Q > 0 then
          RHS := Trim(Copy(RHS, 1, Q - 1));
        if RHS = '' then
          Continue;

        if not SpecParams.TryGetValue(RHS, Value) then
          if not TryStrToFloat(RHS, Value, Inv) then
            Continue;

        Arc.FromPin := FromPin;
        Arc.ToPin := ToPin;
        Arc.DelayPs := Value;
        Arcs.Add(Arc);
      end;
    end;
  finally
    Lines.Free;
  end;

  if Arcs.Count = 0 then
  begin
    Arcs.Free;
    SpecParams.Free;
    Exit;
  end;

  Result := TCellTiming.Create;
  Result.CellName := ModuleName;
  Result.FileName := FileName;
  for Arc in Arcs do
  begin
    if Result.FindArcDelay(Arc.FromPin, Arc.ToPin, Value) then
    begin
      for j := 0 to Result.Arcs.Count - 1 do
        if SameText(Result.Arcs[j].FromPin, Arc.FromPin) and
           SameText(Result.Arcs[j].ToPin, Arc.ToPin) then
          if Arc.DelayPs > Result.Arcs[j].DelayPs then
          begin
            Existing := Result.Arcs[j];
            Existing.DelayPs := Arc.DelayPs;
            Result.Arcs[j] := Existing;
          end;
    end
    else
      Result.Arcs.Add(Arc);
  end;

  Arcs.Free;
  SpecParams.Free;
end;

end.

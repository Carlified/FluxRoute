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
    // Setup, hold and minimum input-to-input spacing (ps) from the $hold set.
    SetupPs: Double;
    HoldPs: Double;
    InputSpacingPs: Double;
    constructor Create;
    destructor Destroy; override;
    // Worst-case input -> output propagation delay in ps (0 if no arcs).
    function OutputDelayPs: Double;
    function FindArcDelay(const FromPin, ToPin: string; out DelayPs: Double): Boolean;
  end;

  // Parses the specify block of a Verilog cell file. Returns nil if the file
  // has no specify block / no arcs (e.g. the ALWAYS0 cells) or can't be read.
  function ParseVerilogTiming(const FileName: string): TCellTiming;

  // Greatest SETUP, greatest HOLD and minimum data-to-data input spacing (ps)
  // across the cell's specparam-backed $hold lines. TimEx emits $hold for both
  // cases: with the clock as the reference edge (clock first) it is a hold, with
  // the clock as the data pin (pin first) it is a setup. A $hold with no clock
  // (a JTL's "a, a", or an NDROT's "a, b") is input-to-input spacing; we keep
  // the largest. Conditional (&&&) qualifiers are ignored, exactly as the arc
  // parser ignores if(...) conditional delays. Each defaults to 0.
  procedure ParseTimingConstraints(const FileName: string;
    out SetupPs, HoldPs, InputSpacingPs: Double);

implementation

uses
  PipelineConfig;

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
  Value, SetupTmp, HoldTmp, SpacingTmp: Double;
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
  if Result <> nil then
  begin
    SetupTmp := 0;
    HoldTmp := 0;
    SpacingTmp := 0;
    ParseTimingConstraints(FileName, SetupTmp, HoldTmp, SpacingTmp);
    Result.SetupPs := SetupTmp;
    Result.HoldPs := HoldTmp;
    Result.InputSpacingPs := SpacingTmp;
  end;
end;

procedure ParseTimingConstraints(const FileName: string;
  out SetupPs, HoldPs, InputSpacingPs: Double);
var
  Lines: TStringList;
  SpecParams: TDictionary<string, Double>;
  Inv: TFormatSettings;
  i, P, Q, R: Integer;
  Clean, Body, Tok, ValStr: string;
  Args: TArray<string>;
  V: Double;
  InSpecify: Boolean;

  // The pin label of an argument: drop any "&&& condition" and the
  // posedge/negedge keyword, keep the trailing identifier.
  function LabelOf(const AArg: string): string;
  var
    A: string;
    Toks: TArray<string>;
    K: Integer;
  begin
    Result := '';
    A := AArg;
    K := Pos('&&&', A);
    if K > 0 then
      A := Copy(A, 1, K - 1);
    Toks := Trim(A).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    if Length(Toks) > 0 then
      Result := Toks[High(Toks)];
  end;

  // Clock pin per the pipeline config, with a plain "clk" fallback for when the
  // config has not been loaded yet.
  function IsClockLabel(const S: string): Boolean;
  begin
    Result := (S <> '') and (IsClockPinName(S) or StartsText('clk', S));
  end;

begin
  SetupPs := 0;
  HoldPs := 0;
  InputSpacingPs := 0;
  if not TFile.Exists(FileName) then
    Exit;

  Inv := TFormatSettings.Invariant;
  SpecParams := TDictionary<string, Double>.Create;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    InSpecify := False;
    for i := 0 to Lines.Count - 1 do
    begin
      Clean := Trim(StripLineComment(Lines[i]));
      if Clean = '' then
        Continue;
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
        Body := Trim(Copy(Clean, Length('specparam') + 1, MaxInt));
        P := Pos('=', Body);
        if P > 0 then
        begin
          ValStr := Trim(Copy(Body, P + 1, MaxInt));
          Tok := Trim(Copy(Body, 1, P - 1));
          Q := Pos(';', ValStr);
          if Q > 0 then
            ValStr := Trim(Copy(ValStr, 1, Q - 1));
          if TryStrToFloat(ValStr, V, Inv) then
            SpecParams.AddOrSetValue(Tok, V);
        end;
        Continue;
      end;

      P := Pos('$hold', LowerCase(Clean));
      if P = 0 then
        Continue;
      Q := PosEx('(', Clean, P);
      if Q = 0 then
        Continue;
      R := PosEx(')', Clean, Q + 1);
      if R = 0 then
        Continue;
      Body := Copy(Clean, Q + 1, R - Q - 1);
      Args := Body.Split([','], TStringSplitOptions.ExcludeEmpty);
      if Length(Args) < 3 then
        Continue;
      ValStr := Trim(Args[2]);
      if not SpecParams.TryGetValue(ValStr, V) then
        if not TryStrToFloat(ValStr, V, Inv) then
          Continue;
      Tok := LabelOf(Args[0]);
      ValStr := LabelOf(Args[1]);
      if IsClockLabel(Tok) and (not IsClockLabel(ValStr)) then
      begin
        // Clock is the reference edge: clk -> a is a hold.
        if V > HoldPs then
          HoldPs := V;
      end
      else if IsClockLabel(ValStr) and (not IsClockLabel(Tok)) then
      begin
        // Clock is the data pin: a -> clk is a setup.
        if V > SetupPs then
          SetupPs := V;
      end
      else
      begin
        // No clock edge involved: data-to-data (a, a / a, b) and clock-on-itself
        // (clk, clk = minimum period) are both input spacing. Keep the largest.
        if V > InputSpacingPs then
          InputSpacingPs := V;
      end;
    end;
  finally
    Lines.Free;
    SpecParams.Free;
  end;
end;

end.

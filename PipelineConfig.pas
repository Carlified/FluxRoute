unit PipelineConfig;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IniFiles,
  System.StrUtils,
  LefLibrary;

// Wave-pipelining configuration, loaded from pipeline_config.ini (see
// PipelineConfigFile). If the file is missing a template with the current
// defaults is written next to the executable and the defaults are used.

// Path of the configuration file actually in use ('' if none could be
// found or created). Other units should reuse this path when adding their
// own sections to the config.
function PipelineConfigFile: string;

// True if PinName looks like a clock input (prefixes from the config file,
// e.g. clk, clock, clkin, clk_in, ...).
function IsClockPinName(const PinName: string): Boolean;

// True if any input pin of Cell is a clock pin (per the config file).
function CellHasClock(const Cell: TCell): Boolean;

// A flip-flop is a cell whose input/output counts match the config file
// (default: 2 inputs, 1 output) where one input is a clock pin (see
// IsClockPinName). Fills ClockPin, DataPin and OutputPin on success;
// returns False otherwise.
function IsFlipFlopCandidate(const Cell: TCell;
  out ClockPin, DataPin, OutputPin: string): Boolean;

implementation

uses
  System.IOUtils;

const
  ConfigFileName = 'pipeline_config.ini';
  DefaultPrefixes = 'clk,clock';
  DefaultMinInputs = 2;
  DefaultMaxInputs = 2;
  DefaultOutputs = 1;
  Section = 'FlipFlop';

var
  ClockPrefixes: TStringList;
  MinInputs: Integer;
  MaxInputs: Integer;
  RequiredOutputs: Integer;
  FConfigPath: string;

function PipelineConfigFile: string;
begin
  Result := FConfigPath;
end;

function FindConfigFile: string;
var
  Cand: string;
begin
  Result := '';
  Cand := IncludeTrailingPathDelimiter(GetCurrentDir) + ConfigFileName;
  if TFile.Exists(Cand) then
    Exit(Cand);
  Cand := ExtractFilePath(GetModuleName(HInstance)) + ConfigFileName;
  if TFile.Exists(Cand) then
    Exit(Cand);
end;

procedure WriteDefaultConfig(const Path: string);
var
  Tpl: string;
begin
  Tpl :=
    '; FluxRoute pipeline configuration' + sLineBreak +
    '; Editable values for wave-pipelining. Changes take effect on restart.' + sLineBreak +
    sLineBreak +
    '[' + Section + ']' + sLineBreak +
    '; Pin-name prefixes treated as a clock input (case-insensitive).' + sLineBreak +
    'ClockPinPrefixes=' + DefaultPrefixes + sLineBreak +
    '; A flip-flop has between MinInputs and MaxInputs input pins' + sLineBreak +
    '; and exactly Outputs output pins.' + sLineBreak +
    'MinInputs=' + IntToStr(DefaultMinInputs) + sLineBreak +
    'MaxInputs=' + IntToStr(DefaultMaxInputs) + sLineBreak +
    'Outputs=' + IntToStr(DefaultOutputs) + sLineBreak;
  TFile.WriteAllText(Path, Tpl);
end;

function CreateDefaultConfig: string;
var
  Path: string;
begin
  Result := '';
  Path := ExtractFilePath(GetModuleName(HInstance)) + ConfigFileName;
  try
    WriteDefaultConfig(Path);
  except
    try
      Path := IncludeTrailingPathDelimiter(GetCurrentDir) + ConfigFileName;
      WriteDefaultConfig(Path);
    except
      Exit;
    end;
  end;
  Result := Path;
end;

procedure LoadConfig;
var
  Ini: TIniFile;
  Path: string;
  i: Integer;
begin
  FConfigPath := '';
  ClockPrefixes.CommaText := DefaultPrefixes;
  MinInputs := DefaultMinInputs;
  MaxInputs := DefaultMaxInputs;
  RequiredOutputs := DefaultOutputs;

  Path := FindConfigFile;
  if Path = '' then
    Path := CreateDefaultConfig;
  if Path = '' then
    Exit;

  Ini := TIniFile.Create(Path);
  try
    FConfigPath := Path;
    MinInputs := Ini.ReadInteger(Section, 'MinInputs', DefaultMinInputs);
    MaxInputs := Ini.ReadInteger(Section, 'MaxInputs', DefaultMaxInputs);
    RequiredOutputs := Ini.ReadInteger(Section, 'Outputs', DefaultOutputs);
    ClockPrefixes.CommaText :=
      Ini.ReadString(Section, 'ClockPinPrefixes', DefaultPrefixes);
    if ClockPrefixes.Count = 0 then
      ClockPrefixes.CommaText := DefaultPrefixes;
    for i := ClockPrefixes.Count - 1 downto 0 do
      if Trim(ClockPrefixes[i]) = '' then
        ClockPrefixes.Delete(i);
  finally
    Ini.Free;
  end;
end;

function IsClockPinName(const PinName: string): Boolean;
var
  L: string;
  i: Integer;
begin
  L := LowerCase(PinName);
  Result := False;
  for i := 0 to ClockPrefixes.Count - 1 do
    if StartsText(Trim(ClockPrefixes[i]), L) then
      Exit(True);
end;

function CellHasClock(const Cell: TCell): Boolean;
var
  Port: TPort;
begin
  Result := False;
  if Cell = nil then
    Exit;
  for Port in Cell.Ports do
    if (Port.Direction = pdInput) and IsClockPinName(Port.Name) then
      Exit(True);
end;

function IsFlipFlopCandidate(const Cell: TCell;
  out ClockPin, DataPin, OutputPin: string): Boolean;
var
  Port: TPort;
  NumInputs: Integer;
  NumOutputs: Integer;
begin
  Result := False;
  ClockPin := '';
  DataPin := '';
  OutputPin := '';
  if Cell = nil then
    Exit;
  NumInputs := 0;
  NumOutputs := 0;
  for Port in Cell.Ports do
    case Port.Direction of
      pdInput:
      begin
        Inc(NumInputs);
        if IsClockPinName(Port.Name) then
          ClockPin := Port.Name
        else
          DataPin := Port.Name;
      end;
      pdOutput:
      begin
        Inc(NumOutputs);
        OutputPin := Port.Name;
      end;
    end;
  Result := (NumInputs >= MinInputs) and (NumInputs <= MaxInputs) and
            (NumOutputs = RequiredOutputs) and (ClockPin <> '');
end;

initialization
  ClockPrefixes := TStringList.Create;
  LoadConfig;

finalization
  ClockPrefixes.Free;

end.

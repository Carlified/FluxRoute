unit ProjectData;

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.IOUtils;

// A FluxRoute project captures everything needed to reconstruct a session:
// the input files (LEF, cell folder, BLIF), the component cells the user
// chose (splitters / single flip-flop / buffers), which pipeline stages have
// already been completed, and the page the user was last on. Paths are kept
// exactly as given by the dialogs; loading a project re-parses the inputs, so
// the file itself never has to embed derived netlists.

type
  TProjectFile = class
  private
    FLefFile: string;
    FCellFolder: string;
    FBlifFile: string;
    FSplitters: TStringList;
    FBuffers: TStringList;
    FFlipFlop: string;
    FSplittersInserted: Boolean;
    FLastTab: Integer;
    FSliderPos: Integer;
    procedure LoadFromJson(Root: TJSONObject);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFromFile(const Path: string);
    procedure SaveToFile(const Path: string);
    property LefFile: string read FLefFile write FLefFile;
    property CellFolder: string read FCellFolder write FCellFolder;
    property BlifFile: string read FBlifFile write FBlifFile;
    property Splitters: TStringList read FSplitters;
    property Buffers: TStringList read FBuffers;
    property FlipFlop: string read FFlipFlop write FFlipFlop;
    property SplittersInserted: Boolean read FSplittersInserted write FSplittersInserted;
    property LastTab: Integer read FLastTab write FLastTab;
    property SliderPos: Integer read FSliderPos write FSliderPos;
  end;

// Path of the small "recent projects" preferences file. Kept next to the
// executable, mirroring the pipeline_config.ini convention.
function RecentProjectsFile: string;

// Recent holds up to MaxRecentProjects entries, most recent first.
procedure LoadRecentProjects(var LastProject: string; Recent: TStrings);
procedure SaveRecentProjects(const LastProject: string; Recent: TStrings);

const
  MaxRecentProjects = 8;

implementation

function RecentProjectsFile: string;
begin
  Result := ExtractFilePath(GetModuleName(HInstance)) + 'recent_projects.json';
end;

constructor TProjectFile.Create;
begin
  inherited Create;
  FSplitters := TStringList.Create;
  FBuffers := TStringList.Create;
  Clear;
end;

destructor TProjectFile.Destroy;
begin
  FSplitters.Free;
  FBuffers.Free;
  inherited Destroy;
end;

procedure TProjectFile.Clear;
begin
  FLefFile := '';
  FCellFolder := '';
  FBlifFile := '';
  FSplitters.Clear;
  FBuffers.Clear;
  FFlipFlop := '';
  FSplittersInserted := False;
  FLastTab := 0;
  FSliderPos := 0;
end;

procedure TProjectFile.LoadFromJson(Root: TJSONObject);
var
  Arr: TJSONArray;
  i: Integer;
begin
  if Root = nil then
    Exit;
  if Root.GetValue('lef') is TJSONValue then
    FLefFile := Root.GetValue<string>('lef');
  if Root.GetValue('cellFolder') is TJSONValue then
    FCellFolder := Root.GetValue<string>('cellFolder');
  if Root.GetValue('blif') is TJSONValue then
    FBlifFile := Root.GetValue<string>('blif');
  if Root.GetValue('flipFlop') is TJSONValue then
    FFlipFlop := Root.GetValue<string>('flipFlop');
  if Root.GetValue('splittersInserted') is TJSONValue then
    FSplittersInserted := Root.GetValue<Boolean>('splittersInserted');
  if Root.GetValue('lastTab') is TJSONValue then
    FLastTab := Root.GetValue<Integer>('lastTab');
  if Root.GetValue('sliderPos') is TJSONValue then
    FSliderPos := Root.GetValue<Integer>('sliderPos');

  FSplitters.Clear;
  Arr := Root.GetValue('splitters') as TJSONArray;
  if Arr <> nil then
    for i := 0 to Arr.Count - 1 do
      FSplitters.Add(Arr.Items[i].Value);

  FBuffers.Clear;
  Arr := Root.GetValue('buffers') as TJSONArray;
  if Arr <> nil then
    for i := 0 to Arr.Count - 1 do
      FBuffers.Add(Arr.Items[i].Value);
end;

procedure TProjectFile.LoadFromFile(const Path: string);
var
  Root: TJSONValue;
begin
  Clear;
  Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path));
  try
    if Root is TJSONObject then
      LoadFromJson(Root as TJSONObject)
    else
      raise Exception.Create('Not a FluxRoute project file.');
  finally
    Root.Free;
  end;
end;

procedure TProjectFile.SaveToFile(const Path: string);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('format', 'fluxroute-1');
    Root.AddPair('lef', FLefFile);
    Root.AddPair('cellFolder', FCellFolder);
    Root.AddPair('blif', FBlifFile);
    Root.AddPair('flipFlop', FFlipFlop);
    Root.AddPair('splittersInserted', FSplittersInserted);
    Root.AddPair('lastTab', FLastTab);
    Root.AddPair('sliderPos', FSliderPos);

    Arr := TJSONArray.Create;
    for i := 0 to FSplitters.Count - 1 do
      Arr.Add(FSplitters[i]);
    Root.AddPair('splitters', Arr);

    Arr := TJSONArray.Create;
    for i := 0 to FBuffers.Count - 1 do
      Arr.Add(FBuffers[i]);
    Root.AddPair('buffers', Arr);

    TFile.WriteAllText(Path, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure LoadRecentProjects(var LastProject: string; Recent: TStrings);
var
  Root: TJSONValue;
  Arr: TJSONArray;
  i: Integer;
  Path: string;
begin
  LastProject := '';
  Recent.Clear;
  Path := RecentProjectsFile;
  if not TFile.Exists(Path) then
    Exit;
  try
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path));
  except
    Exit;
  end;
  try
    if not (Root is TJSONObject) then
      Exit;
    LastProject := (Root as TJSONObject).GetValue<string>('last');
    Arr := (Root as TJSONObject).GetValue('recent') as TJSONArray;
    if Arr <> nil then
      for i := 0 to Arr.Count - 1 do
        Recent.Add(Arr.Items[i].Value);
  finally
    Root.Free;
  end;
end;

procedure SaveRecentProjects(const LastProject: string; Recent: TStrings);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  i: Integer;
  Path: string;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('last', LastProject);
    Arr := TJSONArray.Create;
    for i := 0 to Recent.Count - 1 do
      Arr.Add(Recent[i]);
    Root.AddPair('recent', Arr);
    Path := RecentProjectsFile;
    TFile.WriteAllText(Path, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

end.

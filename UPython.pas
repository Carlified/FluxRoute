unit UPython;

// Locates a Python 3 interpreter and runs scripts (used by the cell viewer's GDS
// parsing and the export's GDS writer). Both depend on `gdstk` being installed.
// Extracted from CellViewer.pas so the export page and the viewer share one
// runner instead of duplicating the discovery/process plumbing.

interface

uses
  System.SysUtils;

// First matching interpreter: common hardcoded Windows paths, then PATH (the
// WindowsApps shim is skipped - it is not a real interpreter).
function FindPythonExe: string;

// Finds `AScriptName` next to the current dir/executable, walking up a few
// levels (IDE runs have the working dir at the project root, the exe deep in
// Win32\Debug).
function LocateScript(const AScriptName: string): string;

// Runs Exe with Args, redirecting stdout+stderr to StdErrFile (one file). Takes
// the exit code; on non-zero fills ErrMsg from the captured output.
function RunProcess(const Exe, Args, StdErrFile: string;
  out ErrMsg: string): Integer;

// Convenience: runs `<python> <LocateScript(Name)> <Args>`.
function RunPythonScript(const AScriptName, Args, StderrFile: string;
  out ErrMsg: string): Integer;

implementation

uses
  System.IOUtils,
  {$IF DEFINED(MSWINDOWS)}
  Winapi.Windows
  {$ELSE}
  Posix.Unistd, Posix.SysWait
  {$ENDIF};

function FindPythonExe: string;
var
  Cand, PathStr: string;
  Dirs: TArray<string>;
  D: string;
{$IF DEFINED(MSWINDOWS)}
  Local: string;
{$ENDIF}
begin
  Result := '';
  {$IF DEFINED(MSWINDOWS)}
  Local := GetEnvironmentVariable('LOCALAPPDATA');

  Cand := Local + '\Python\pythoncore-3.14-64\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := Local + '\Programs\Python\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := 'C:\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);
  Cand := 'C:\Python\Python314\python.exe';
  if FileExists(Cand) then Exit(Cand);

  PathStr := GetEnvironmentVariable('PATH');
  Dirs := PathStr.Split([';'], TStringSplitOptions.ExcludeEmpty);
  for D in Dirs do
  begin
    if UpperCase(D).IndexOf('WINDOWSAPPS') >= 0 then
      Continue; // app-execution alias shim, not a real interpreter
    Cand := TPath.Combine(D, 'python.exe');
    if FileExists(Cand) then Exit(Cand);
  end;
  {$ELSE}
  Cand := '/opt/homebrew/bin/python3';
  if FileExists(Cand) then Exit(Cand);
  Cand := '/usr/local/bin/python3';
  if FileExists(Cand) then Exit(Cand);
  Cand := '/usr/bin/python3';
  if FileExists(Cand) then Exit(Cand);

  PathStr := GetEnvironmentVariable('PATH');
  Dirs := PathStr.Split([':'], TStringSplitOptions.ExcludeEmpty);
  for D in Dirs do
  begin
    Cand := TPath.Combine(D, 'python3');
    if FileExists(Cand) then Exit(Cand);
  end;
  {$ENDIF}
end;

function LocateScript(const AScriptName: string): string;
var
  Dir: string;
  i: Integer;
begin
  Result := '';
  // running from the IDE usually means the working directory is the project
  Dir := IncludeTrailingPathDelimiter(GetCurrentDir);
  if FileExists(Dir + AScriptName) then
    Exit(Dir + AScriptName);
  // otherwise walk up from the exe (Win32\Debug -> Win32 -> project root, ...)
  Dir := ExtractFilePath(GetModuleName(HInstance));
  for i := 0 to 6 do
  begin
    if FileExists(Dir + AScriptName) then
      Exit(Dir + AScriptName);
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
    if Dir = '' then
      Break;
  end;
end;

function RunProcess(const Exe, Args, StdErrFile: string;
  out ErrMsg: string): Integer;
{$IF DEFINED(MSWINDOWS)}
var
  CmdLine: string;
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  HErr: THandle;
  ExitCode: Cardinal;
begin
  Result := -1;
  ErrMsg := '';
  CmdLine := '"' + Exe + '" ' + Args;

  SA.nLength := SizeOf(SA);
  SA.lpSecurityDescriptor := nil;
  SA.bInheritHandle := True;

  HErr := CreateFile(PChar(StdErrFile), GENERIC_WRITE, FILE_SHARE_WRITE, @SA,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if HErr = INVALID_HANDLE_VALUE then
  begin
    ErrMsg := 'Could not create output file: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := HErr;
  SI.hStdError := HErr;

  FillChar(PI, SizeOf(PI), 0);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, nil, SI, PI) then
  begin
    CloseHandle(HErr);
    ErrMsg := 'CreateProcess failed: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  CloseHandle(HErr);
  WaitForSingleObject(PI.hProcess, INFINITE);
  GetExitCodeProcess(PI.hProcess, ExitCode);
  Result := Integer(ExitCode);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);

  if Result <> 0 then
  begin
    if FileExists(StdErrFile) then
      ErrMsg := Trim(TFile.ReadAllText(StdErrFile))
    else
      ErrMsg := Format('Python exited with code %d.', [Result]);
  end;
end;
{$ELSE}
var
  CmdLine: string;
  PID, Status: Integer;
begin
  Result := -1;
  ErrMsg := '';
  // /bin/sh performs the stderr redirection for us; the caller already
  // wraps every path argument in double quotes.
  CmdLine := Format('%s %s 2>"%s"', [Exe, Args, StdErrFile]);

  PID := fork;
  if PID < 0 then
  begin
    ErrMsg := 'fork failed.';
    Exit;
  end;
  if PID = 0 then
  begin
    execl(PAnsiChar(UTF8String('/bin/sh')),
      PAnsiChar(UTF8String('sh')),
      PAnsiChar(UTF8String('-c')),
      PAnsiChar(UTF8String(CmdLine)),
      nil);
    _exit(127); // exec never returns on success
  end;

  waitpid(PID, @Status, 0);
  if (Status and $7F) = 0 then
    Result := (Status shr 8) and $FF // WEXITSTATUS
  else
    Result := -1;

  if Result <> 0 then
  begin
    if FileExists(StdErrFile) then
      ErrMsg := Trim(TFile.ReadAllText(StdErrFile))
    else
      ErrMsg := Format('Python exited with code %d.', [Result]);
  end;
end;
{$ENDIF}

function RunPythonScript(const AScriptName, Args, StderrFile: string;
  out ErrMsg: string): Integer;
var
  PyExe, Script: string;
begin
  Result := -1;
  ErrMsg := '';
  PyExe := FindPythonExe;
  if PyExe = '' then
  begin
    ErrMsg := 'Python 3 (with gdstk) was not found - install it to export GDS.';
    Exit;
  end;
  Script := LocateScript(AScriptName);
  if Script = '' then
  begin
    ErrMsg := AScriptName + ' was not found next to the application.';
    Exit;
  end;
  Result := RunProcess(PyExe,
    Format('"%s" %s', [Script, Args]), StderrFile, ErrMsg);
end;

end.

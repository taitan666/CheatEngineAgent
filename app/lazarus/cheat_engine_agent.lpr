program cheat_engine_agent;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, SysUtils, cea_results, cea_application_runtime,
  cea_main_form;

{$R *.res}

{ Returns True when the switch appears anywhere on the command line. }
function HasSwitch(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), AName) then
      Exit(True);
  Result := False;
end;

{ Returns the argument that follows the switch, or an empty string. }
function SwitchValue(const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), AName) then
      Exit(ParamStr(I + 1));
end;

var
  DataDirectory: string;
  SelfTest: Boolean;

begin
  RequireDerivedFormResource := False;

  SelfTest := HasSwitch('--self-test');
  DataDirectory := SwitchValue('--data-dir');
  if DataDirectory <> '' then
  begin
    if not ForceDirectories(DataDirectory) then
    begin
      WriteLn('Could not create data directory: ', DataDirectory);
      Halt(22);
    end;
    CeaDatabasePathOverride := IncludeTrailingPathDelimiter(DataDirectory) +
      'agentos.sqlite3';
  end;

  if SelfTest then
  begin
    with TCEAStandaloneRuntime.Create do
    try
      if Start.Failed then
        Halt(20);
      if Pos('ready', HandleMCP(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
        '"params":{"name":"cea.health","arguments":{}}}')) = 0 then
        Halt(21);
      Stop;
    finally
      Free;
    end;
    Halt(0);
  end;

  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TCEAMainForm, CEAMainForm);
  Application.Run;
end.

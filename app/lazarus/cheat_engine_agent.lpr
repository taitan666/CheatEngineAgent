program cheat_engine_agent;

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, SysUtils, cea_results, cea_application_runtime,
  cea_main_form;

{$R *.res}

begin
  RequireDerivedFormResource := False;
  if (ParamCount = 1) and SameText(ParamStr(1), '--self-test') then
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

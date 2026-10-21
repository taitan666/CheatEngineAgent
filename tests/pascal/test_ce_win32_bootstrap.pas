program test_ce_win32_bootstrap;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_results, cea_win32_engine_runtime,
  cea_win32_engine_bootstrap;

var
  R: TCEAResult;

begin
  StopWin32Engine;
  R := StartWin32Engine;
  Assert(R.Code = rcOk, 'Win32 read-only composition starts');
  Assert(EngineRegistered,
    'bootstrap publishes registered runtime');
  R := EngineRuntime.Processes.ListProcesses;
  Assert(R.Code = rcOk, 'bootstrapped runtime enumerates processes');
  Assert(Pos(IntToStr(GetCurrentProcessId), R.DataJson) > 0,
    'bootstrapped process list includes its host');

  R := StartWin32Engine;
  Assert(R.Code = rcConflict, 'bootstrap refuses duplicate startup');
  StopWin32Engine;
  Assert(not EngineRegistered,
    'bootstrap stops and releases runtime');
  WriteLn('CE_WIN32_BOOTSTRAP=PASS');
end.

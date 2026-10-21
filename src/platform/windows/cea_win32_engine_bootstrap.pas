unit cea_win32_engine_bootstrap;

{$mode objfpc}{$H+}

interface

uses
  cea_results;

function StartWin32Engine: TCEAResult;
procedure StopWin32Engine;

implementation

uses
  SysUtils, cea_windows_sha256, cea_win32_readonly_backend,
  cea_win32_engine_runtime;

var
  GHasher: TCEAWindowsSha256 = nil;
  GBackend: TCEAWin32ReadOnlyBackend = nil;

function StartWin32Engine: TCEAResult;
begin
  if EngineRegistered or (GHasher <> nil) or (GBackend <> nil) then
    Exit(TCEAResult.Error(rcConflict,
      'engine_already_registered', '{}'));
  try
    GHasher := TCEAWindowsSha256.Create;
    GBackend := TCEAWin32ReadOnlyBackend.Create(GHasher);
    Result := RegisterEngine(GBackend, GHasher);
    if Result.Failed then
    begin
      FreeAndNil(GBackend);
      FreeAndNil(GHasher);
    end;
  except
    on E: Exception do
    begin
      UnregisterEngine;
      FreeAndNil(GBackend);
      FreeAndNil(GHasher);
      Result := TCEAResult.Error(rcInternalError,
        'win32_engine_bootstrap_failed', '{}');
    end;
  end;
end;

procedure StopWin32Engine;
begin
  UnregisterEngine;
  FreeAndNil(GBackend);
  FreeAndNil(GHasher);
end;

finalization
  StopWin32Engine;

end.

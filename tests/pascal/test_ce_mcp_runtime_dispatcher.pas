program test_ce_mcp_runtime_dispatcher;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, cea_results, cea_mcp_registry,
  cea_win32_selftest_backend, cea_test_ports, cea_win32_engine_runtime,
  cea_engine_mcp_dispatcher;

type
  TDispatchWorker = class(TThread)
  private
    FDispatcher: IMCPToolDispatcher;
  protected
    procedure Execute; override;
  public
    Completed: Boolean;
    DispatchResult: TCEAResult;
    constructor Create(const ADispatcher: IMCPToolDispatcher);
  end;

constructor TDispatchWorker.Create(const ADispatcher: IMCPToolDispatcher);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FDispatcher := ADispatcher;
end;

procedure TDispatchWorker.Execute;
begin
  DispatchResult := FDispatcher.DispatchTool('cea.list_processes', '{}');
  Completed := True;
end;

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  Dispatcher: IMCPToolDispatcher;
  Worker: TDispatchWorker;
  R: TCEAResult;
  Deadline: QWord;

begin
  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Hasher := TCEATestHasher.Create;
  try
    R := RegisterEngine(Backend, Hasher);
    Assert(R.Code = rcOk, 'runtime registers');
    Dispatcher := TCEAMCPRuntimeDispatcher.Create(EngineRuntime,
      5000);
    R := Dispatcher.DispatchTool('cea.health', '{}');
    Assert(R.Code = rcOk, 'owner-thread MCP health executes directly');
    R := Dispatcher.DispatchTool('cea.get_scan_status',
      '{"scan_id":"missing"}');
    Assert(R.Code <> rcNotImplemented,
      'declared scan status tool is routed to the runtime');

    Worker := TDispatchWorker.Create(Dispatcher);
    try
      Worker.Start;
      Deadline := GetTickCount64 + 5000;
      while (not Worker.Completed) and (GetTickCount64 < Deadline) do
      begin
        EngineRuntime.PumpCommands(8);
        Sleep(1);
      end;
      Worker.WaitFor;
      Assert(Worker.Completed, 'background MCP dispatch completes');
      Assert(Worker.DispatchResult.Code = rcOk,
        'background MCP dispatch is executed by owner-thread queue');
      Assert(Pos(IntToStr(GetCurrentProcessId),
        Worker.DispatchResult.DataJson) > 0,
        'background MCP process list returns self-test process');
    finally
      Worker.Free;
    end;
    R := Dispatcher.DispatchTool('cea.request_memory_write', '{}');
    Assert(R.Code = rcNotImplemented,
      'write tool remains unavailable in read-only phase');
    WriteLn('CE_MCP_RUNTIME_DISPATCHER=PASS');
  finally
    Dispatcher := nil;
    UnregisterEngine;
    Hasher.Free;
    Backend.Free;
  end;
end.

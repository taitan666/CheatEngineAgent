unit cea_engine_mcp_dispatcher;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Windows, cea_results, cea_mcp_registry, cea_owner_thread_queue,
  cea_win32_engine_runtime;

type
  TCEAMCPRuntimeDispatcher = class(TObject, IMCPToolDispatcher)
  private
    FRuntime: TCEAEngineRuntime;
    FTimeoutMs: Cardinal;
    function CapabilityForTool(const AToolName: string): string;
  public
    constructor Create(const ARuntime: TCEAEngineRuntime;
      const ATimeoutMs: Cardinal);
    function DispatchTool(const AToolName,
      AArgumentsJson: string): TCEAResult;
  end;

implementation

constructor TCEAMCPRuntimeDispatcher.Create(const ARuntime: TCEAEngineRuntime;
  const ATimeoutMs: Cardinal);
begin
  inherited Create;
  FRuntime := ARuntime;
  FTimeoutMs := ATimeoutMs;
end;

function TCEAMCPRuntimeDispatcher.CapabilityForTool(
  const AToolName: string): string;
begin
  if AToolName = 'cea.health' then Exit('runtime_health');
  if AToolName = 'cea.get_runtime_state' then Exit('runtime_health');
  if AToolName = 'cea.list_processes' then Exit('process_list');
  if AToolName = 'cea.attach_process' then Exit('process_attach');
  if AToolName = 'cea.detach_process' then Exit('process_detach');
  if AToolName = 'cea.read_memory' then Exit('memory_read');
  if AToolName = 'cea.list_modules' then Exit('module_list');
  if AToolName = 'cea.start_scan' then Exit('memory_scan_start');
  if AToolName = 'cea.refine_scan' then Exit('memory_scan_refine');
  if AToolName = 'cea.get_scan_status' then Exit('memory_scan_status');
  if AToolName = 'cea.cancel_scan' then Exit('memory_scan_cancel');
  if AToolName = 'cea.disassemble' then Exit('disassemble');
  Result := '';
end;

function TCEAMCPRuntimeDispatcher.DispatchTool(const AToolName,
  AArgumentsJson: string): TCEAResult;
var
  CapabilityId: string;
  Ticket: TCEACommandTicket;
  ReleaseResult: TCEAResult;
begin
  if FRuntime = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'engine_runtime_dispatcher_missing_runtime', '{}'));
  CapabilityId := CapabilityForTool(AToolName);
  if CapabilityId = '' then
    Exit(TCEAResult.Error(rcNotImplemented,
      'engine_mcp_tool_not_implemented', '{"tool":"' + AToolName + '"}'));
  if GetCurrentThreadId = FRuntime.CommandQueue.OwnerThreadId then
    Exit(FRuntime.Execute(CapabilityId, AArgumentsJson));
  Ticket := FRuntime.CommandQueue.Submit(CapabilityId, AArgumentsJson);
  if Ticket = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'engine_command_submit_failed', '{}'));
  Result := FRuntime.CommandQueue.WaitFor(Ticket, FTimeoutMs);
  if Ticket.State in [qsCompleted, qsCancelled, qsTimedOut] then
  begin
    ReleaseResult := FRuntime.CommandQueue.Release(Ticket);
    if ReleaseResult.Failed and not Result.Failed then
      Result := ReleaseResult;
  end;
end;

end.

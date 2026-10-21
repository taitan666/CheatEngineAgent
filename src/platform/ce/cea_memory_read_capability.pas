unit cea_memory_read_capability;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_runtime_backend_ports, cea_process_capability;

type
  TCEAMemoryReadCapability = class
  private
    FBackend: ICEAReadOnlyRuntimeBackend;
    FProcesses: TCEAProcessCapability;
    FMaxBytesPerRead: Cardinal;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AProcesses: TCEAProcessCapability;
      const AMaxBytesPerRead: Cardinal);
    function Read(const ARequest: TCEMemoryReadRequest;
      const AIdentity: TCEProcessIdentity): TCEAResult;
  end;

implementation

constructor TCEAMemoryReadCapability.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AProcesses: TCEAProcessCapability;
  const AMaxBytesPerRead: Cardinal);
begin
  inherited Create;
  FBackend := ABackend;
  FProcesses := AProcesses;
  FMaxBytesPerRead := AMaxBytesPerRead;
end;

function TCEAMemoryReadCapability.Read(
  const ARequest: TCEMemoryReadRequest;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
begin
  if (FBackend = nil) or (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'memory_read_dependencies_missing', '{}'));
  if (ARequest.TaskId = '') or (ARequest.ProcessIdentityId = '') or
     (ARequest.LeaseId = '') or (ARequest.Address = 0) or
     (ARequest.ByteCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_read_request_invalid', '{}'));
  if (FMaxBytesPerRead = 0) or
     (ARequest.ByteCount > FMaxBytesPerRead) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'memory_read_budget_exceeded', '{}'));
  if ARequest.Address > High(QWord) - QWord(ARequest.ByteCount - 1) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_read_address_range_invalid', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then
    Exit;
  if (ARequest.ProcessIdentityId <> CurrentIdentity.Id) or
     (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'memory_read_target_changed', '{}'));
  if (CurrentIdentity.Architecture = caX86) and
     (ARequest.Address + QWord(ARequest.ByteCount - 1) > High(Cardinal)) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_read_address_width_invalid', '{}'));
  Result := FBackend.ReadMemory(ARequest.Address, ARequest.ByteCount);
end;

end.

unit cea_disassembly_capability;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability;

type
  TCEADisassemblyCapability = class
  private
    FBackend: ICEAReadOnlyRuntimeBackend;
    FProcesses: TCEAProcessCapability;
    FMaxBytes: Cardinal;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AProcesses: TCEAProcessCapability;
      const AMaxBytes: Cardinal);
    function Disassemble(const ARequest: TCEDisassembleRequest;
      const AIdentity: TCEProcessIdentity): TCEAResult;
  end;

implementation

constructor TCEADisassemblyCapability.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AProcesses: TCEAProcessCapability;
  const AMaxBytes: Cardinal);
begin
  inherited Create;
  FBackend := ABackend;
  FProcesses := AProcesses;
  FMaxBytes := AMaxBytes;
end;

function TCEADisassemblyCapability.Disassemble(
  const ARequest: TCEDisassembleRequest;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
begin
  if (FBackend = nil) or (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'disassembly_dependencies_missing', '{}'));
  if (ARequest.TaskId = '') or (ARequest.ProcessIdentityId = '') or
     (ARequest.LeaseId = '') or (ARequest.Address = 0) or
     (ARequest.ByteCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'disassembly_request_invalid', '{}'));
  if (FMaxBytes = 0) or (ARequest.ByteCount > FMaxBytes) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'disassembly_budget_exceeded', '{}'));
  if ARequest.Address > High(QWord) - QWord(ARequest.ByteCount - 1) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'disassembly_address_range_invalid', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then
    Exit;
  if (ARequest.ProcessIdentityId <> CurrentIdentity.Id) or
     (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'disassembly_target_changed', '{}'));
  if (CurrentIdentity.Architecture = caX86) and
     (ARequest.Address + QWord(ARequest.ByteCount - 1) > High(Cardinal)) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'disassembly_address_width_invalid', '{}'));
  Result := FBackend.Disassemble(ARequest.Address, ARequest.ByteCount);
end;

end.

unit cea_module_capability;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability;

type
  TCEAModuleCapability = class
  private
    FBackend: ICEAReadOnlyRuntimeBackend;
    FProcesses: TCEAProcessCapability;
    FMaxResults: Cardinal;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AProcesses: TCEAProcessCapability;
      const AMaxResults: Cardinal);
    function ListModules(const ATaskId, ALeaseId: string;
      const AIdentity: TCEProcessIdentity;
      const AMaxResults: Cardinal): TCEAResult;
  end;

implementation

constructor TCEAModuleCapability.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AProcesses: TCEAProcessCapability;
  const AMaxResults: Cardinal);
begin
  inherited Create;
  FBackend := ABackend;
  FProcesses := AProcesses;
  FMaxResults := AMaxResults;
end;

function TCEAModuleCapability.ListModules(const ATaskId, ALeaseId: string;
  const AIdentity: TCEProcessIdentity;
  const AMaxResults: Cardinal): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
begin
  if (FBackend = nil) or (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'module_dependencies_missing', '{}'));
  if (ATaskId = '') or (ALeaseId = '') or (AIdentity.Id = '') or
     (AMaxResults = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'module_request_invalid', '{}'));
  if (FMaxResults = 0) or (AMaxResults > FMaxResults) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'module_result_budget_exceeded', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then
    Exit;
  if (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'module_target_changed', '{}'));
  Result := FBackend.ListModules(CurrentIdentity.Pid, AMaxResults);
end;

end.

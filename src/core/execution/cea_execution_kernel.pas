unit cea_execution_kernel;

{$mode objfpc}{$H+}

interface

uses
  cea_ports, cea_results, cea_types;

type
  TCEAExecutionKernel = class
  private
    FProcessPort: ICEProcessPort;
    FMemoryPort: IMemoryPort;
  public
    constructor Create(const AProcessPort: ICEProcessPort;
      const AMemoryPort: IMemoryPort);
    function Attach(const ARequest: TCEAttachRequest): TCEAResult;
    function WriteMemory(const ARequest: TCEMemoryWriteRequest): TCEAResult;
  end;

implementation

constructor TCEAExecutionKernel.Create(const AProcessPort: ICEProcessPort;
  const AMemoryPort: IMemoryPort);
begin
  inherited Create;
  FProcessPort := AProcessPort;
  FMemoryPort := AMemoryPort;
end;

function TCEAExecutionKernel.Attach(const ARequest: TCEAttachRequest): TCEAResult;
begin
  if (ARequest.TaskId = '') or (ARequest.LeaseId = '') or (ARequest.Pid = 0) then
    Exit(CEAResult(rcInvalidArgument, 'task, lease, and PID are required'));
  if not ARequest.OperatorAttestsAuthorizedDebugging then
    Exit(CEAResult(rcRejected, 'operator authorization attestation is required'));
  if FProcessPort = nil then
    Exit(CEAResult(rcRejected, 'process port is required'));
  Result := FProcessPort.Attach(ARequest);
end;

function TCEAExecutionKernel.WriteMemory(
  const ARequest: TCEMemoryWriteRequest): TCEAResult;
begin
  if (ARequest.TaskId = '') or (ARequest.ProcessIdentityId = '') or
     (ARequest.LeaseId = '') or (ARequest.ApprovalId = '') or
     (ARequest.IdempotencyKey = '') then
    Exit(CEAResult(rcInvalidArgument,
      'task, process identity, lease, approval, and idempotency key are required'));
  if FMemoryPort = nil then
    Exit(CEAResult(rcRejected, 'memory port is required'));
  Result := FMemoryPort.WriteMemory(ARequest);
end;

end.


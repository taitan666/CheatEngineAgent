unit cea_test_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports;

type
  TCEATestClock = class(TObject, ICEAClock)
  public
    CurrentTime: string;
    function UtcNowIso8601: string;
  end;

  TCEATestHasher = class(TObject, ICEAHasher)
  public
    function HashUtf8(const AValue: string): string;
  end;

  TCEATestGovernanceStore = class(TObject, IGovernanceStore)
  private
    FLease: TCEALease;
    FEffect: TCEAEffect;
    FReceipt: TCEAReceipt;
    FProof: TCEAProof;
    FApproval: TCEAApprovalDecision;
    FHasLease: Boolean;
    FHasEffect: Boolean;
    FHasReceipt: Boolean;
    FHasProof: Boolean;
    FHasApproval: Boolean;
  public
    function SaveLease(const ALease: TCEALease): TCEAResult;
    function LoadLease(const ALeaseId: string;
      out ALease: TCEALease): TCEAResult;
    function ConsumeLeaseCall(const ALeaseId: string): TCEAResult;
    function RevokeAllLeases: TCEAResult;
    function RejectPlannedEffects(const AUpdatedAt: string): TCEAResult;
    function ReconcileExecutingEffects(
      const AUpdatedAt: string): TCEAResult;
    function SaveApproval(
      const ADecision: TCEAApprovalDecision): TCEAResult;
    function LoadApproval(const AEffectId: string;
      out ADecision: TCEAApprovalDecision): TCEAResult;
    function SaveEffect(const AEffect: TCEAEffect): TCEAResult;
    function LoadEffect(const AEffectId: string;
      out AEffect: TCEAEffect): TCEAResult;
    function SaveReceipt(const AReceipt: TCEAReceipt): TCEAResult;
    function LoadReceipt(const AReceiptId: string;
      out AReceipt: TCEAReceipt): TCEAResult;
    function SaveProof(const AProof: TCEAProof): TCEAResult;
    function LoadProof(const AProofId: string;
      out AProof: TCEAProof): TCEAResult;
    procedure AddLease(const ALease: TCEALease);
    function LastEffect: TCEAEffect;
    function LastReceipt: TCEAReceipt;
    function LastProof: TCEAProof;
  end;

  TCEATestApprovalPort = class(TObject, IApprovalPort)
  private
    FDecision: TCEAApprovalDecision;
    FHasDecision: Boolean;
  public
    function FindDecision(const AEffectId: string;
      out ADecision: TCEAApprovalDecision): TCEAResult;
    procedure AddDecision(const ADecision: TCEAApprovalDecision);
  end;

  TCEATestCapabilityPort = class(TObject, ICEACapabilityPort)
  private
    FLastInvokedEffect: TCEAEffect;
  public
    ExecutionCount: Cardinal;
    NextResult: TCEAResult;
    function Invoke(const ACapabilityId,
      ARequestJson: string): TCEAResult;
    function InvokeEffect(const AEffect: TCEAEffect): TCEAResult;
    property LastInvokedEffect: TCEAEffect read FLastInvokedEffect;
  end;

  TCEATestStateStore = class(TObject, IStateStore)
  public
    EventCount: Cardinal;
    LastEventJson: string;
    function Initialize: TCEAResult;
    function AppendEvent(const AEnvelopeJson: string): TCEAResult;
  end;

implementation

function TCEATestClock.UtcNowIso8601: string;
begin
  Result := CurrentTime;
end;

function TCEATestHasher.HashUtf8(const AValue: string): string;
var
  I: Integer;
  Value: QWord;
begin
  Value := QWord($CBF29CE484222325);
  for I := 1 to Length(AValue) do
  begin
    Value := Value xor Ord(AValue[I]);
    Value := Value * QWord($100000001B3);
  end;
  Result := 'sha256:' + LowerCase(IntToHex(Value, 16)) +
    StringOfChar('0', 48);
end;

function TCEATestGovernanceStore.SaveLease(
  const ALease: TCEALease): TCEAResult;
begin
  FLease := ALease;
  FHasLease := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.LoadLease(const ALeaseId: string;
  out ALease: TCEALease): TCEAResult;
begin
  if (not FHasLease) or (FLease.Id <> ALeaseId) then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_not_found', '{}'));
  ALease := FLease;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.ConsumeLeaseCall(
  const ALeaseId: string): TCEAResult;
begin
  if (not FHasLease) or (FLease.Id <> ALeaseId) then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_not_found', '{}'));
  if FLease.RemainingCalls = 0 then
    Exit(TCEAResult.Error(rcBudgetExceeded, 'lease_calls_exhausted', '{}'));
  Dec(FLease.RemainingCalls);
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.RevokeAllLeases: TCEAResult;
begin
  if FHasLease then FLease.Revoked := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.RejectPlannedEffects(
  const AUpdatedAt: string): TCEAResult;
begin
  if FHasEffect and (FEffect.State = esPlanned) then
  begin
    FEffect.State := esRejected;
    FEffect.UpdatedAt := AUpdatedAt;
    FEffect.ResultJson := '{"reason":"emergency_stop"}';
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.ReconcileExecutingEffects(
  const AUpdatedAt: string): TCEAResult;
begin
  if FHasEffect and (FEffect.State = esExecuting) then
  begin
    FEffect.State := esUnknown;
    FEffect.UpdatedAt := AUpdatedAt;
    FEffect.ResultJson := '{"reason":"startup_reconciliation_required"}';
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.SaveApproval(
  const ADecision: TCEAApprovalDecision): TCEAResult;
begin
  FApproval := ADecision;
  FHasApproval := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.LoadApproval(const AEffectId: string;
  out ADecision: TCEAApprovalDecision): TCEAResult;
begin
  if (not FHasApproval) or (FApproval.EffectId <> AEffectId) then
    Exit(TCEAResult.Error(rcApprovalRequired, 'approval_required', '{}'));
  ADecision := FApproval;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.SaveEffect(
  const AEffect: TCEAEffect): TCEAResult;
begin
  FEffect := AEffect;
  FHasEffect := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.LoadEffect(const AEffectId: string;
  out AEffect: TCEAEffect): TCEAResult;
begin
  if (not FHasEffect) or (FEffect.Id <> AEffectId) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'effect_not_found', '{}'));
  AEffect := FEffect;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.SaveReceipt(
  const AReceipt: TCEAReceipt): TCEAResult;
begin
  FReceipt := AReceipt;
  FHasReceipt := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.LoadReceipt(const AReceiptId: string;
  out AReceipt: TCEAReceipt): TCEAResult;
begin
  if (not FHasReceipt) or (FReceipt.Id <> AReceiptId) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'receipt_not_found', '{}'));
  AReceipt := FReceipt;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.SaveProof(
  const AProof: TCEAProof): TCEAResult;
begin
  FProof := AProof;
  FHasProof := True;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestGovernanceStore.LoadProof(const AProofId: string;
  out AProof: TCEAProof): TCEAResult;
begin
  if (not FHasProof) or (FProof.Id <> AProofId) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'proof_not_found', '{}'));
  AProof := FProof;
  Result := TCEAResult.Ok('{}');
end;

procedure TCEATestGovernanceStore.AddLease(const ALease: TCEALease);
begin
  SaveLease(ALease);
end;

function TCEATestGovernanceStore.LastEffect: TCEAEffect;
begin
  Result := FEffect;
end;

function TCEATestGovernanceStore.LastReceipt: TCEAReceipt;
begin
  Result := FReceipt;
end;

function TCEATestGovernanceStore.LastProof: TCEAProof;
begin
  Result := FProof;
end;

function TCEATestApprovalPort.FindDecision(const AEffectId: string;
  out ADecision: TCEAApprovalDecision): TCEAResult;
begin
  if (not FHasDecision) or (FDecision.EffectId <> AEffectId) then
    Exit(TCEAResult.Error(rcApprovalRequired, 'approval_required', '{}'));
  ADecision := FDecision;
  Result := TCEAResult.Ok('{}');
end;

procedure TCEATestApprovalPort.AddDecision(
  const ADecision: TCEAApprovalDecision);
begin
  FDecision := ADecision;
  FHasDecision := True;
end;

function TCEATestCapabilityPort.Invoke(const ACapabilityId,
  ARequestJson: string): TCEAResult;
begin
  Inc(ExecutionCount);
  Result := NextResult;
end;

function TCEATestCapabilityPort.InvokeEffect(
  const AEffect: TCEAEffect): TCEAResult;
begin
  FLastInvokedEffect := AEffect;
  Inc(ExecutionCount);
  Result := NextResult;
end;

function TCEATestStateStore.Initialize: TCEAResult;
begin
  Result := TCEAResult.Ok('{}');
end;

function TCEATestStateStore.AppendEvent(
  const AEnvelopeJson: string): TCEAResult;
begin
  Inc(EventCount);
  LastEventJson := AEnvelopeJson;
  Result := TCEAResult.Ok('{}');
end;

end.

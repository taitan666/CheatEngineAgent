unit cea_win32_governed_capability_port;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, fpjson, jsonparser, cea_types, cea_results, cea_ports,
  cea_effect_backend_ports, cea_win32_engine_runtime, cea_save_ports;

type
  TCEAWin32GovernedCapabilityPort = class(TObject, ICEACapabilityPort)
  private
    FRuntime: TCEAEngineRuntime;
    FEffectBackend: ICEAMemoryEffectBackend;
    FHasher: ICEAHasher;
    FSaveEffects: ICEASaveFileEffects;
  public
    constructor Create(const ARuntime: TCEAEngineRuntime;
      const AEffectBackend: ICEAMemoryEffectBackend;
      const AHasher: ICEAHasher;
      const ASaveEffects: ICEASaveFileEffects = nil);
    function Invoke(const ACapabilityId,
      ARequestJson: string): TCEAResult;
    function InvokeEffect(const AEffect: TCEAEffect): TCEAResult;
  end;

implementation

function TryParseHexAddress(const AText: string; out AValue: QWord): Boolean;
begin
  Result := (Length(AText) > 2) and
    (LowerCase(Copy(AText, 1, 2)) = '0x') and
    TryStrToQWord('$' + Copy(AText, 3, MaxInt), AValue) and
    (AValue <> 0);
end;

constructor TCEAWin32GovernedCapabilityPort.Create(
  const ARuntime: TCEAEngineRuntime;
  const AEffectBackend: ICEAMemoryEffectBackend;
  const AHasher: ICEAHasher;
  const ASaveEffects: ICEASaveFileEffects);
begin
  inherited Create;
  FRuntime := ARuntime;
  FEffectBackend := AEffectBackend;
  FHasher := AHasher;
  FSaveEffects := ASaveEffects;
end;

function TCEAWin32GovernedCapabilityPort.Invoke(
  const ACapabilityId, ARequestJson: string): TCEAResult;
begin
  if FRuntime = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'governed_runtime_missing', '{}'));
  if ACapabilityId = 'memory_write' then
    Exit(TCEAResult.Error(rcApprovalRequired,
      'memory_write_effect_required', '{}'));
  Result := FRuntime.Execute(ACapabilityId, ARequestJson);
end;

function TCEAWin32GovernedCapabilityPort.InvokeEffect(
  const AEffect: TCEAEffect): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Identity: TCEProcessIdentity;
  Address: QWord;
  TaskId, ProcessIdentityRef, LeaseRef: string;
  ExpectedHex, ReplacementHex, EvidenceHash: string;
begin
  if AEffect.ResourceKind = rkSaveFile then
  begin
    if FSaveEffects = nil then
      Exit(TCEAResult.Error(rcNotImplemented,
        'save_effect_port_missing', '{}'));
    Exit(FSaveEffects.InvokeEffect(AEffect));
  end;
  if (FRuntime = nil) or (FEffectBackend = nil) or (FHasher = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'governed_effect_dependencies_missing', '{}'));
  if AEffect.State <> esExecuting then
    Exit(TCEAResult.Error(rcConflict,
      'effect_not_executing', '{}'));
  if AEffect.ApprovalId = '' then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_approval_required', '{}'));
  if AEffect.TargetClassification <> tcSinglePlayerOffline then
    Exit(TCEAResult.Error(rcTargetNotOffline,
      'target_not_offline', '{}'));
  if AEffect.CapabilityId <> 'memory_write' then
    Exit(TCEAResult.Error(rcNotImplemented,
      'governed_effect_not_implemented', '{}'));

  Result := FRuntime.Processes.Current(Identity);
  if Result.Failed then
    Exit;
  if (Identity.Id <> AEffect.ProcessIdentityId) or
     (Identity.Epoch <> AEffect.Epoch) or
     (Identity.TargetClassification <> tcSinglePlayerOffline) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'effect_target_changed', '{}'));

  Data := nil;
  try
    try
      Data := GetJSON(AEffect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'memory_effect_json_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'memory_effect_object_required', '{}'));
    Obj := TJSONObject(Data);
    TaskId := Obj.Get('task_id', '');
    ProcessIdentityRef := Obj.Get('process_identity_ref', '');
    LeaseRef := Obj.Get('lease_ref', '');
    ExpectedHex := LowerCase(Obj.Get('expected_original_bytes', ''));
    ReplacementHex := LowerCase(Obj.Get('replacement_bytes', ''));
    if (TaskId = '') or (TaskId <> AEffect.TaskId) or
       (ProcessIdentityRef <> AEffect.ProcessIdentityId) or
       (LeaseRef = '') or (LeaseRef <> AEffect.LeaseId) then
      Exit(TCEAResult.Error(rcUnauthorized,
        'memory_effect_envelope_mismatch', '{}'));
    if not TryParseHexAddress(Obj.Get('address', ''), Address) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'memory_effect_address_invalid', '{}'));

    Result := FEffectBackend.CompareWriteReadback(Identity.Pid, Address,
      ExpectedHex, ReplacementHex);
    EvidenceHash := FHasher.HashUtf8(AEffect.Id + #0 +
      AEffect.ApprovalId + #0 + AEffect.RequestHash + #0 +
      Result.StableCode + #0 + Result.DataJson);
    Result.ReceiptId := 'receipt-' + Copy(EvidenceHash, 8, 32);
    Result.ProofId := 'proof-' + Copy(FHasher.HashUtf8(
      Result.ReceiptId + #0 + Result.DataJson), 8, 32);
  finally
    Data.Free;
  end;
end;

end.

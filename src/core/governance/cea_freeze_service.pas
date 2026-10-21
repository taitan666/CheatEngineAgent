unit cea_freeze_service;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_effect_backend_ports,
  cea_effect_service, cea_lease_service;

type
  TCEAFreezeService = class
  private
    FStore: IGovernanceStore;
    FClock: ICEAClock;
    FHasher: ICEAHasher;
    FEffects: TCEAEffectService;
    FLeases: TCEALeaseService;
    FBackend: ICEAMemoryEffectBackend;
    FActiveEffectId: string;
    FAddress: QWord;
    FExpectedHex: string;
    FReplacementHex: string;
    FExpiresAt: string;
    FIntervalMs: Cardinal;
    FMaxWrites: Cardinal;
    FWriteCount: Cardinal;
    function Finish(var AEffect: TCEAEffect; const AState: TCEAEffectState;
      const AReason: string): TCEAResult;
    function PersistAttempt(const AEffect: TCEAEffect;
      const AAttempt: Cardinal; const AInvocation: TCEAResult): TCEAResult;
  public
    constructor Create(const AStore: IGovernanceStore;
      const AClock: ICEAClock; const AHasher: ICEAHasher;
      const AEffects: TCEAEffectService; const ALeases: TCEALeaseService;
      const ABackend: ICEAMemoryEffectBackend);
    function Activate(const AEffectId: string;
      const AIdentity: TCEProcessIdentity): TCEAResult;
    function Tick(const AIdentity: TCEProcessIdentity): TCEAResult;
    function Stop(const AReason: string): TCEAResult;
    function Active: Boolean;
    property ActiveEffectId: string read FActiveEffectId;
    property IntervalMs: Cardinal read FIntervalMs;
  end;

implementation

uses
  FPJSON, JSONParser;

function TryParseHexAddress(const AText: string; out AValue: QWord): Boolean;
begin
  Result := (Length(AText) > 2) and
    (LowerCase(Copy(AText, 1, 2)) = '0x') and
    TryStrToQWord('$' + Copy(AText, 3, MaxInt), AValue) and (AValue <> 0);
end;

constructor TCEAFreezeService.Create(const AStore: IGovernanceStore;
  const AClock: ICEAClock; const AHasher: ICEAHasher;
  const AEffects: TCEAEffectService; const ALeases: TCEALeaseService;
  const ABackend: ICEAMemoryEffectBackend);
begin
  inherited Create;
  FStore := AStore;
  FClock := AClock;
  FHasher := AHasher;
  FEffects := AEffects;
  FLeases := ALeases;
  FBackend := ABackend;
end;

function TCEAFreezeService.Active: Boolean;
begin
  Result := FActiveEffectId <> '';
end;

function TCEAFreezeService.Finish(var AEffect: TCEAEffect;
  const AState: TCEAEffectState; const AReason: string): TCEAResult;
begin
  AEffect.State := AState;
  AEffect.UpdatedAt := FClock.UtcNowIso8601;
  AEffect.ResultJson := '{"freeze_active":false,"reason":"' +
    AReason + '","writes":' + IntToStr(FWriteCount) +
    ',"automatic_resume":false,"automatic_restore":false}';
  Result := FStore.SaveEffect(AEffect);
  FActiveEffectId := '';
  if not Result.Failed then Result := TCEAResult.Ok(AEffect.ResultJson);
end;

function TCEAFreezeService.PersistAttempt(const AEffect: TCEAEffect;
  const AAttempt: Cardinal; const AInvocation: TCEAResult): TCEAResult;
var
  Receipt: TCEAReceipt;
  Proof: TCEAProof;
  EvidenceSeed: string;
begin
  FillChar(Receipt, SizeOf(Receipt), 0);
  EvidenceSeed := AEffect.Id + #0 + IntToStr(AAttempt) + #0 +
    AInvocation.StableCode + #0 + AInvocation.DataJson;
  Receipt.Id := 'receipt-' + Copy(FHasher.HashUtf8(EvidenceSeed), 8, 32);
  Receipt.EffectId := AEffect.Id;
  Receipt.Attempt := AAttempt;
  Receipt.RecordedAt := FClock.UtcNowIso8601;
  if AInvocation.Code = rcOk then Receipt.Outcome := roApplied
  else if AInvocation.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
    Receipt.Outcome := roUnknown
  else Receipt.Outcome := roRejected;
  Receipt.ResponseHash := FHasher.HashUtf8(AInvocation.StableCode + #0 +
    AInvocation.DataJson);
  Receipt.DetailsJson := AInvocation.DataJson;
  Result := FStore.SaveReceipt(Receipt);
  if Result.Failed then Exit;

  FillChar(Proof, SizeOf(Proof), 0);
  Proof.Id := 'proof-' + Copy(FHasher.HashUtf8(Receipt.Id + #0 +
    Receipt.ResponseHash), 8, 32);
  Proof.EffectId := AEffect.Id;
  Proof.ReceiptId := Receipt.Id;
  Proof.RecordedAt := Receipt.RecordedAt;
  if AInvocation.Code = rcOk then Proof.Outcome := poPass
  else if AInvocation.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
    Proof.Outcome := poInconclusive
  else Proof.Outcome := poFail;
  Proof.VerificationHash := FHasher.HashUtf8(Receipt.ResponseHash + #0 +
    AInvocation.DataJson);
  Proof.DetailsJson := AInvocation.DataJson;
  Result := FStore.SaveProof(Proof);
  if Result.Failed then Exit;
  Result := AInvocation;
  Result.ReceiptId := Receipt.Id;
  Result.ProofId := Proof.Id;
end;

function TCEAFreezeService.Activate(const AEffectId: string;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  Effect: TCEAEffect;
  Data: TJSONData;
  Obj: TJSONObject;
  TargetPid: Cardinal;
begin
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) or
     (FEffects = nil) or (FLeases = nil) or (FBackend = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'freeze_dependencies_missing', '{}'));
  if Active then
    Exit(TCEAResult.Error(rcConflict, 'freeze_session_running', '{}'));
  Result := FStore.LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  if (Effect.CapabilityId <> 'memory_freeze') or
     (Effect.State <> esPlanned) then
    Exit(TCEAResult.Error(rcConflict, 'freeze_effect_not_planned', '{}'));
  if (Effect.ProcessIdentityId <> AIdentity.Id) or
     (Effect.Epoch <> AIdentity.Epoch) or
     (AIdentity.TargetClassification <> tcSinglePlayerOffline) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'freeze_target_changed', '{}'));
  Result := FEffects.ValidateLocalApproval(Effect);
  if Result.Failed then Exit;
  Result := FLeases.Validate(Effect.LeaseId, Effect.CapabilityId,
    Effect.ProcessIdentityId, Effect.Epoch, False);
  if Result.Failed then Exit;

  Data := nil;
  try
    try
      Data := GetJSON(Effect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'freeze_request_json_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'freeze_request_object_required', '{}'));
    Obj := TJSONObject(Data);
    TargetPid := Obj.Get('target_pid', 0);
    FExpectedHex := LowerCase(Obj.Get('expected_original_bytes', ''));
    FReplacementHex := LowerCase(Obj.Get('replacement_bytes', ''));
    FIntervalMs := Obj.Get('interval_ms', 0);
    FMaxWrites := Obj.Get('max_writes', 0);
    FExpiresAt := Obj.Get('expires_at', '');
    if (TargetPid <> AIdentity.Pid) or
       (Obj.Get('target_started_at', '') <> AIdentity.StartedAt) or
       (Obj.Get('target_executable_sha256', '') <>
        AIdentity.ExecutableSha256) or
       not TryParseHexAddress(Obj.Get('address', ''), FAddress) or
       (FExpectedHex = '') or Odd(Length(FExpectedHex)) or
       (Length(FExpectedHex) <> Length(FReplacementHex)) or
       (FExpectedHex = FReplacementHex) or
       (FIntervalMs < 100) or (FIntervalMs > 60000) or
       (FMaxWrites = 0) or (FMaxWrites > 10000) or
       (FExpiresAt = '') or (FExpiresAt <= FClock.UtcNowIso8601) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'freeze_request_invalid', '{}'));
  finally
    Data.Free;
  end;
  Effect.State := esExecuting;
  Effect.UpdatedAt := FClock.UtcNowIso8601;
  Effect.ResultJson := '{"freeze_active":true,"writes":0,' +
    '"automatic_resume":false}';
  Result := FStore.SaveEffect(Effect);
  if Result.Failed then Exit;
  FWriteCount := 0;
  FActiveEffectId := Effect.Id;
  Result := TCEAResult.Ok(Effect.ResultJson);
end;

function TCEAFreezeService.Tick(
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  Effect: TCEAEffect;
  Observation, Invocation: TCEAResult;
  Data: TJSONData;
  CurrentHex: string;
begin
  if not Active then
    Exit(TCEAResult.Error(rcConflict, 'freeze_session_not_active', '{}'));
  Result := FStore.LoadEffect(FActiveEffectId, Effect);
  if Result.Failed then Exit;
  if Effect.State <> esExecuting then
  begin
    FActiveEffectId := '';
    Exit(TCEAResult.Error(rcConflict, 'freeze_effect_not_executing', '{}'));
  end;
  if (Effect.ProcessIdentityId <> AIdentity.Id) or
     (Effect.Epoch <> AIdentity.Epoch) or
     (AIdentity.TargetClassification <> tcSinglePlayerOffline) then
  begin
    Result := Finish(Effect, esRejected, 'target_changed');
    if Result.Failed then Exit;
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'freeze_target_changed', '{}'));
  end;
  if FClock.UtcNowIso8601 >= FExpiresAt then
    Exit(Finish(Effect, esApplied, 'expired'));
  if FWriteCount >= FMaxWrites then
    Exit(Finish(Effect, esApplied, 'max_writes_reached'));

  Observation := FBackend.ReadCurrentHex(AIdentity.Pid, FAddress,
    Length(FExpectedHex) div 2);
  if Observation.Failed then
  begin
    Finish(Effect, esUnknown, 'observation_failed');
    Exit(Observation);
  end;
  Data := nil;
  try
    try
      Data := GetJSON(Observation.DataJson);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        raise Exception.Create('observation object required');
      CurrentHex := LowerCase(TJSONObject(Data).Get('current', ''));
    except
      Finish(Effect, esUnknown, 'observation_invalid');
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'freeze_observation_invalid', '{}'));
    end;
  finally
    Data.Free;
  end;
  if CurrentHex = FReplacementHex then
  begin
    Result := TCEAResult.Ok('{"freeze_active":true,' +
      '"value_already_set":true,"writes":' + IntToStr(FWriteCount) + '}');
    Result.StableCode := 'freeze_value_already_set';
    Exit;
  end;
  if CurrentHex <> FExpectedHex then
  begin
    Finish(Effect, esRejected, 'current_value_not_permitted');
    Exit(TCEAResult.Error(rcVerificationFailed,
      'freeze_current_value_not_permitted',
      '{"current":"' + CurrentHex + '"}'));
  end;

  Result := FLeases.Validate(Effect.LeaseId, Effect.CapabilityId,
    Effect.ProcessIdentityId, Effect.Epoch, True);
  if Result.Failed then
  begin
    Finish(Effect, esRejected, Result.StableCode);
    Exit;
  end;
  Inc(FWriteCount);
  Invocation := FBackend.CompareWriteReadback(AIdentity.Pid, FAddress,
    FExpectedHex, FReplacementHex);
  Result := PersistAttempt(Effect, FWriteCount, Invocation);
  if Result.Failed then
  begin
    if Invocation.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
      Finish(Effect, esUnknown, Invocation.StableCode)
    else
      Finish(Effect, esRejected, Invocation.StableCode);
    Exit;
  end;
  if FWriteCount >= FMaxWrites then
    Finish(Effect, esApplied, 'max_writes_reached')
  else
  begin
    Effect.UpdatedAt := FClock.UtcNowIso8601;
    Effect.ResultJson := '{"freeze_active":true,"writes":' +
      IntToStr(FWriteCount) + '}';
    if FStore.SaveEffect(Effect).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'freeze_progress_persist_failed', '{}'));
  end;
end;

function TCEAFreezeService.Stop(const AReason: string): TCEAResult;
var
  Effect: TCEAEffect;
  Reason: string;
begin
  if not Active then
    Exit(TCEAResult.Error(rcConflict, 'freeze_session_not_active', '{}'));
  Result := FStore.LoadEffect(FActiveEffectId, Effect);
  if Result.Failed then Exit;
  Reason := Trim(AReason);
  if Reason = '' then Reason := 'stopped_by_local_user';
  Result := Finish(Effect, esApplied, Reason);
end;

end.

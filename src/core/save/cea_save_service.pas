unit cea_save_service;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_save_types,
  cea_save_ports, cea_governance_gateway;

type
  TCEASaveService = class
  private
    FReader: ICEASaveReader;
    FStore: IGovernanceStore;
    FClock: ICEAClock;
    FHasher: ICEAHasher;
    FGateway: TCEAGovernanceGateway;
    FCodec: ICEASaveCodec;
  public
    constructor Create(const AReader: ICEASaveReader;
      const AStore: IGovernanceStore = nil;
      const AClock: ICEAClock = nil; const AHasher: ICEAHasher = nil;
      const AGateway: TCEAGovernanceGateway = nil;
      const ACodec: ICEASaveCodec = nil);
    function Inspect(const ATaskId, ASelectedPath: string;
      out ASnapshot: TCEASaveSnapshot): TCEAResult;
    function GetFields(const ASnapshot: TCEASaveSnapshot;
      out AFields: TCEASaveFieldArray): TCEAResult;
    function ProposeFieldEdit(const ASnapshot: TCEASaveSnapshot;
      const AFieldPath, AExpectedJson, ANewJson: string;
      out AProposal: TCEASaveEditProposal): TCEAResult;
    function RequestBackup(const ATaskId: string;
      const ASnapshot: TCEASaveSnapshot; const AExpiresAt: string;
      out AEffectId: string): TCEAResult;
    function PlanEdit(const ATaskId: string;
      const ASnapshot: TCEASaveSnapshot;
      const AProposal: TCEASaveEditProposal;
      const ABackupEffectId, AExpiresAt: string;
      out AEffectId: string): TCEAResult;
    function PlanRestore(const ATaskId: string;
      const ACurrent: TCEASaveSnapshot;
      const ABackupEffectId, AExpectedCurrentHash, AExpiresAt: string;
      out AEffectId: string): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function BytesToString(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], Result[1], Length(ABytes));
end;

constructor TCEASaveService.Create(const AReader: ICEASaveReader;
  const AStore: IGovernanceStore; const AClock: ICEAClock;
  const AHasher: ICEAHasher; const AGateway: TCEAGovernanceGateway;
  const ACodec: ICEASaveCodec);
begin
  inherited Create;
  FReader := AReader;
  FStore := AStore;
  FClock := AClock;
  FHasher := AHasher;
  FGateway := AGateway;
  FCodec := ACodec;
end;

function TCEASaveService.GetFields(const ASnapshot: TCEASaveSnapshot;
  out AFields: TCEASaveFieldArray): TCEAResult;
var
  Bytes: TBytes;
  Descriptor: TCEASaveFormatDescriptor;
  I: Integer;
begin
  SetLength(AFields, 0);
  if (FReader = nil) or (FCodec = nil) or
     (ASnapshot.FormatDescriptor.Id = '') then
    Exit(TCEAResult.Error(rcNotImplemented,
      'save_format_unknown', '{}'));
  Result := FReader.ReadVerified(ASnapshot, Bytes);
  if Result.Failed then Exit;
  Result := FCodec.Probe(Bytes, Descriptor);
  if Result.Failed then Exit;
  if (Descriptor.Id <> ASnapshot.FormatDescriptor.Id) or
     (Descriptor.Version <> ASnapshot.FormatDescriptor.Version) then
    Exit(TCEAResult.Error(rcConflict, 'save_format_changed', '{}'));
  Result := FCodec.Decode(Bytes, AFields);
  if Result.Failed then Exit;
  for I := 0 to High(AFields) do
    AFields[I].SourceSnapshotId := ASnapshot.Id;
end;

function TCEASaveService.ProposeFieldEdit(
  const ASnapshot: TCEASaveSnapshot;
  const AFieldPath, AExpectedJson, ANewJson: string;
  out AProposal: TCEASaveEditProposal): TCEAResult;
var
  BeforeFields, AfterFields: TCEASaveFieldArray;
  Original, Candidate: TBytes;
  I, MatchIndex: Integer;
  Projection: TJSONObject;
begin
  FillChar(AProposal, SizeOf(AProposal), 0);
  if (FCodec = nil) or (FReader = nil) or (FHasher = nil) or
     (ASnapshot.FormatDescriptor.Id = '') then
    Exit(TCEAResult.Error(rcNotImplemented, 'save_edit_format_unknown', '{}'));
  if (AFieldPath = '') or (AExpectedJson = ANewJson) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_edit_no_change', '{}'));
  Result := GetFields(ASnapshot, BeforeFields);
  if Result.Failed then Exit;
  MatchIndex := -1;
  for I := 0 to High(BeforeFields) do
    if BeforeFields[I].Path = AFieldPath then MatchIndex := I;
  if MatchIndex < 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_field_unknown', '{}'));
  if BeforeFields[MatchIndex].ValueJson <> AExpectedJson then
    Exit(TCEAResult.Error(rcConflict, 'save_expected_value_changed', '{}'));
  AProposal.SnapshotId := ASnapshot.Id;
  AProposal.FieldPath := AFieldPath;
  AProposal.ExpectedJson := AExpectedJson;
  AProposal.NewJson := ANewJson;
  AProposal.ContentHash := FHasher.HashUtf8(ASnapshot.Id + #0 +
    ASnapshot.Sha256 + #0 + ASnapshot.FormatDescriptor.AdapterHash + #0 +
    AFieldPath + #0 + AExpectedJson + #0 + ANewJson);
  AProposal.Id := 'proposal-' + Copy(AProposal.ContentHash, 8, 32);
  Result := FReader.ReadVerified(ASnapshot, Original);
  if Result.Failed then Exit;
  Result := FCodec.Encode(Original, AProposal, Candidate);
  if Result.Failed then Exit;
  Result := FCodec.Decode(Candidate, AfterFields);
  if Result.Failed then Exit;
  if Length(AfterFields) <> Length(BeforeFields) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'save_roundtrip_field_count_changed', '{}'));
  for I := 0 to High(BeforeFields) do
    if (AfterFields[I].Path <> BeforeFields[I].Path) or
       ((I = MatchIndex) and (AfterFields[I].ValueJson <> ANewJson)) or
       ((I <> MatchIndex) and
        (AfterFields[I].ValueJson <> BeforeFields[I].ValueJson)) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'save_roundtrip_field_mismatch', '{}'));
  Projection := TJSONObject.Create;
  try
    Projection.Add('schema_version', '1.0');
    Projection.Add('id', AProposal.Id);
    Projection.Add('snapshot_id', AProposal.SnapshotId);
    Projection.Add('field_path', AProposal.FieldPath);
    Projection.Add('expected_json', AProposal.ExpectedJson);
    Projection.Add('new_json', AProposal.NewJson);
    Projection.Add('content_hash', AProposal.ContentHash);
    Projection.Add('authority', 'none');
    Result := TCEAResult.Ok(Projection.AsJSON);
  finally
    Projection.Free;
  end;
end;

function TCEASaveService.RequestBackup(const ATaskId: string;
  const ASnapshot: TCEASaveSnapshot; const AExpiresAt: string;
  out AEffectId: string): TCEAResult;
var
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  Request: TJSONObject;
  Data: TJSONData;
  Current: TCEASaveSnapshot;
  Key: string;
begin
  AEffectId := '';
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) or
     (FGateway = nil) or (FReader = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'save_effect_dependencies_missing', '{}'));
  if (ATaskId = '') or (ASnapshot.Id = '') or
     (ASnapshot.FileIdentityId = '') or
     (AExpiresAt <= FClock.UtcNowIso8601) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_backup_plan_invalid', '{}'));
  Result := FReader.Inspect(ASnapshot.CanonicalPath, Current);
  if Result.Failed then Exit;
  if (Current.FileIdentityId <> ASnapshot.FileIdentityId) or
     (Current.Sha256 <> ASnapshot.Sha256) then
    Exit(TCEAResult.Error(rcConflict, 'save_snapshot_stale', '{}'));
  Key := 'save-backup-' + Copy(FHasher.HashUtf8(ATaskId + #0 +
    ASnapshot.Id + #0 + ASnapshot.Sha256), 8, 32);
  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := ATaskId;
  Context.LeaseId := 'lease-' + Key;
  Context.ResourceKind := rkSaveFile;
  Context.ResourceIdentityId := ASnapshot.FileIdentityId;
  Context.PolicySnapshotId := 'policy:single-player-save-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := 1;
  Context.RequesterOrigin := aoLocalUserInterface;
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'save_backup';
  Lease.ResourceKind := rkSaveFile;
  Lease.ResourceIdentityId := ASnapshot.FileIdentityId;
  Lease.Epoch := Context.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := AExpiresAt;
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := ASnapshot.ByteCount;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;
  Request := TJSONObject.Create;
  try
    Request.Add('snapshot_id', ASnapshot.Id);
    Request.Add('source_path', ASnapshot.CanonicalPath);
    Request.Add('file_identity_id', ASnapshot.FileIdentityId);
    Request.Add('sha256', ASnapshot.Sha256);
    Request.Add('byte_count', ASnapshot.ByteCount);
    Result := FGateway.RequestEffect('save_backup', Context,
      Request.AsJSON, Key);
  finally
    Request.Free;
  end;
  if Result.Code <> rcApprovalRequired then Exit;
  Data := nil;
  try
    Data := GetJSON(Result.DataJson);
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInternalError, 'backup_effect_ref_invalid', '{}'));
    AEffectId := TJSONObject(Data).Get('effect_id', '');
    if AEffectId = '' then
      Exit(TCEAResult.Error(rcInternalError, 'backup_effect_ref_missing', '{}'));
  finally
    Data.Free;
  end;
end;

function TCEASaveService.PlanEdit(const ATaskId: string;
  const ASnapshot: TCEASaveSnapshot;
  const AProposal: TCEASaveEditProposal;
  const ABackupEffectId, AExpiresAt: string;
  out AEffectId: string): TCEAResult;
var
  BackupEffect: TCEAEffect;
  BackupReceipt: TCEAReceipt;
  BackupProof: TCEAProof;
  BackupData: TJSONData;
  BackupObj, Request: TJSONObject;
  RecheckedProposal: TCEASaveEditProposal;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  ResponseData: TJSONData;
  Key, CandidateHash: string;
  OriginalBytes, CandidateBytes: TBytes;
begin
  AEffectId := '';
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) or
     (FGateway = nil) or (FCodec = nil) or (FReader = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'save_edit_dependencies_missing', '{}'));
  if (ATaskId = '') or (ASnapshot.Id = '') or
     (AProposal.SnapshotId <> ASnapshot.Id) or
     (ABackupEffectId = '') or (AExpiresAt <= FClock.UtcNowIso8601) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_edit_plan_invalid', '{}'));
  Result := ProposeFieldEdit(ASnapshot, AProposal.FieldPath,
    AProposal.ExpectedJson, AProposal.NewJson, RecheckedProposal);
  if Result.Failed then Exit;
  if (RecheckedProposal.ContentHash <> AProposal.ContentHash) or
     (RecheckedProposal.Id <> AProposal.Id) then
    Exit(TCEAResult.Error(rcConflict, 'save_proposal_changed', '{}'));
  Result := FReader.ReadVerified(ASnapshot, OriginalBytes);
  if Result.Failed then Exit;
  Result := FCodec.Encode(OriginalBytes, RecheckedProposal,
    CandidateBytes);
  if Result.Failed then Exit;
  Result := FCodec.Validate(CandidateBytes);
  if Result.Failed then Exit;
  CandidateHash := FHasher.HashUtf8(BytesToString(CandidateBytes));
  Result := FStore.LoadEffect(ABackupEffectId, BackupEffect);
  if Result.Failed then Exit;
  if (BackupEffect.State <> esApplied) or
     (BackupEffect.CapabilityId <> 'save_backup') or
     (BackupEffect.ResourceKind <> rkSaveFile) or
     (BackupEffect.ResourceIdentityId <> ASnapshot.FileIdentityId) then
    Exit(TCEAResult.Error(rcConflict, 'save_backup_not_verified', '{}'));
  BackupData := nil;
  try
    try
      BackupData := GetJSON(BackupEffect.ResultJson);
    except
      Exit(TCEAResult.Error(rcConflict, 'save_backup_result_invalid', '{}'));
    end;
    if (BackupData = nil) or (BackupData.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcConflict, 'save_backup_result_invalid', '{}'));
    BackupObj := TJSONObject(BackupData);
    if (BackupObj.Get('snapshot_id', '') <> ASnapshot.Id) or
       (BackupObj.Get('sha256', '') <> ASnapshot.Sha256) or
       (BackupObj.Get('immutable', False) <> True) then
      Exit(TCEAResult.Error(rcConflict, 'save_backup_mismatch', '{}'));
    Result := FStore.LoadReceipt(BackupObj.Get('receipt_id', ''),
      BackupReceipt);
    if Result.Failed then Exit;
    Result := FStore.LoadProof(BackupObj.Get('proof_id', ''), BackupProof);
    if Result.Failed then Exit;
    if (BackupReceipt.EffectId <> ABackupEffectId) or
       (BackupReceipt.Outcome <> roApplied) or
       (BackupProof.EffectId <> ABackupEffectId) or
       (BackupProof.ReceiptId <> BackupReceipt.Id) or
       (BackupProof.Outcome <> poPass) then
      Exit(TCEAResult.Error(rcConflict, 'save_backup_proof_invalid', '{}'));
  finally
    BackupData.Free;
  end;
  Key := 'save-edit-' + Copy(FHasher.HashUtf8(ATaskId + #0 +
    AProposal.ContentHash + #0 + ABackupEffectId), 8, 32);
  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := ATaskId;
  Context.LeaseId := 'lease-' + Key;
  Context.ResourceKind := rkSaveFile;
  Context.ResourceIdentityId := ASnapshot.FileIdentityId;
  Context.PolicySnapshotId := 'policy:single-player-save-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := 1;
  Context.RequesterOrigin := aoLocalUserInterface;
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'save_edit';
  Lease.ResourceKind := rkSaveFile;
  Lease.ResourceIdentityId := ASnapshot.FileIdentityId;
  Lease.Epoch := Context.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := AExpiresAt;
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := ASnapshot.ByteCount;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;
  Request := TJSONObject.Create;
  try
    Request.Add('snapshot_id', ASnapshot.Id);
    Request.Add('source_path', ASnapshot.CanonicalPath);
    Request.Add('file_identity_id', ASnapshot.FileIdentityId);
    Request.Add('sha256', ASnapshot.Sha256);
    Request.Add('byte_count', ASnapshot.ByteCount);
    Request.Add('format_id', ASnapshot.FormatDescriptor.Id);
    Request.Add('adapter_hash', ASnapshot.FormatDescriptor.AdapterHash);
    Request.Add('proposal_id', AProposal.Id);
    Request.Add('proposal_hash', AProposal.ContentHash);
    Request.Add('field_path', AProposal.FieldPath);
    Request.Add('expected_json', AProposal.ExpectedJson);
    Request.Add('new_json', AProposal.NewJson);
    Request.Add('candidate_sha256', CandidateHash);
    Request.Add('backup_effect_id', ABackupEffectId);
    Result := FGateway.RequestEffect('save_edit', Context,
      Request.AsJSON, Key);
  finally
    Request.Free;
  end;
  if Result.Code <> rcApprovalRequired then Exit;
  ResponseData := nil;
  try
    ResponseData := GetJSON(Result.DataJson);
    if (ResponseData = nil) or (ResponseData.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInternalError, 'save_edit_ref_invalid', '{}'));
    AEffectId := TJSONObject(ResponseData).Get('effect_id', '');
    if AEffectId = '' then
      Exit(TCEAResult.Error(rcInternalError, 'save_edit_ref_missing', '{}'));
  finally
    ResponseData.Free;
  end;
end;

function TCEASaveService.PlanRestore(const ATaskId: string;
  const ACurrent: TCEASaveSnapshot;
  const ABackupEffectId, AExpectedCurrentHash, AExpiresAt: string;
  out AEffectId: string): TCEAResult;
var
  BackupEffect: TCEAEffect;
  BackupReceipt: TCEAReceipt;
  BackupProof: TCEAProof;
  BackupData, BackupRequestData, ResponseData: TJSONData;
  BackupObj, BackupRequestObj, Request: TJSONObject;
  CurrentBytes: TBytes;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  Key: string;
begin
  AEffectId := '';
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) or
     (FGateway = nil) or (FReader = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'save_restore_dependencies_missing', '{}'));
  if (ATaskId = '') or (ACurrent.Id = '') or (ABackupEffectId = '') or
     (AExpectedCurrentHash <> ACurrent.Sha256) or
     (AExpiresAt <= FClock.UtcNowIso8601) then
    Exit(TCEAResult.Error(rcConflict, 'save_restore_current_mismatch', '{}'));
  Result := FReader.ReadVerified(ACurrent, CurrentBytes);
  if Result.Failed then Exit;
  Result := FStore.LoadEffect(ABackupEffectId, BackupEffect);
  if Result.Failed then Exit;
  if (BackupEffect.State <> esApplied) or
     (BackupEffect.CapabilityId <> 'save_backup') or
     (BackupEffect.ResourceKind <> rkSaveFile) then
    Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_invalid', '{}'));
  BackupData := nil;
  BackupRequestData := nil;
  try
    try
      BackupData := GetJSON(BackupEffect.ResultJson);
      BackupRequestData := GetJSON(BackupEffect.RequestJson);
    except
      Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_invalid', '{}'));
    end;
    if (BackupData = nil) or (BackupData.JSONType <> jtObject) or
       (BackupRequestData = nil) or
       (BackupRequestData.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_invalid', '{}'));
    BackupObj := TJSONObject(BackupData);
    BackupRequestObj := TJSONObject(BackupRequestData);
    if (BackupRequestObj.Get('source_path', '') <> ACurrent.CanonicalPath) or
       (BackupRequestObj.Get('file_identity_id', '') <>
        BackupEffect.ResourceIdentityId) or
       (BackupObj.Get('snapshot_id', '') <> BackupRequestObj.Get(
        'snapshot_id', '')) or
       (BackupObj.Get('sha256', '') <> BackupRequestObj.Get('sha256', '')) then
      Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_mismatch', '{}'));
    Result := FStore.LoadReceipt(BackupObj.Get('receipt_id', ''),
      BackupReceipt);
    if Result.Failed then Exit;
    Result := FStore.LoadProof(BackupObj.Get('proof_id', ''), BackupProof);
    if Result.Failed then Exit;
    if (BackupReceipt.EffectId <> ABackupEffectId) or
       (BackupReceipt.Outcome <> roApplied) or
       (BackupProof.EffectId <> ABackupEffectId) or
       (BackupProof.ReceiptId <> BackupReceipt.Id) or
       (BackupProof.Outcome <> poPass) then
      Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_proof_invalid', '{}'));
    Key := 'save-restore-' + Copy(FHasher.HashUtf8(ATaskId + #0 +
      ACurrent.Id + #0 + ABackupEffectId), 8, 32);
    FillChar(Context, SizeOf(Context), 0);
    Context.TaskId := ATaskId;
    Context.LeaseId := 'lease-' + Key;
    Context.ResourceKind := rkSaveFile;
    Context.ResourceIdentityId := ACurrent.FileIdentityId;
    Context.PolicySnapshotId := 'policy:single-player-save-v1';
    Context.TargetClassification := tcSinglePlayerOffline;
    Context.Epoch := 1;
    Context.RequesterOrigin := aoLocalUserInterface;
    FillChar(Lease, SizeOf(Lease), 0);
    Lease.Id := Context.LeaseId;
    Lease.CapabilityId := 'save_restore';
    Lease.ResourceKind := rkSaveFile;
    Lease.ResourceIdentityId := ACurrent.FileIdentityId;
    Lease.Epoch := Context.Epoch;
    Lease.IssuedAt := FClock.UtcNowIso8601;
    Lease.ExpiresAt := AExpiresAt;
    Lease.RemainingCalls := 1;
    Lease.RemainingBytes := ACurrent.ByteCount;
    Result := FStore.SaveLease(Lease);
    if Result.Failed then Exit;
    Request := TJSONObject.Create;
    try
      Request.Add('current_snapshot_id', ACurrent.Id);
      Request.Add('source_path', ACurrent.CanonicalPath);
      Request.Add('current_file_identity_id', ACurrent.FileIdentityId);
      Request.Add('current_sha256', ACurrent.Sha256);
      Request.Add('current_byte_count', ACurrent.ByteCount);
      Request.Add('backup_effect_id', ABackupEffectId);
      Request.Add('backup_snapshot_id', BackupObj.Get('snapshot_id', ''));
      Request.Add('backup_sha256', BackupObj.Get('sha256', ''));
      Result := FGateway.RequestEffect('save_restore', Context,
        Request.AsJSON, Key);
    finally
      Request.Free;
    end;
  finally
    BackupRequestData.Free;
    BackupData.Free;
  end;
  if Result.Code <> rcApprovalRequired then Exit;
  ResponseData := nil;
  try
    ResponseData := GetJSON(Result.DataJson);
    if (ResponseData = nil) or (ResponseData.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInternalError, 'save_restore_ref_invalid', '{}'));
    AEffectId := TJSONObject(ResponseData).Get('effect_id', '');
    if AEffectId = '' then
      Exit(TCEAResult.Error(rcInternalError, 'save_restore_ref_missing', '{}'));
  finally
    ResponseData.Free;
  end;
end;

function TCEASaveService.Inspect(const ATaskId, ASelectedPath: string;
  out ASnapshot: TCEASaveSnapshot): TCEAResult;
var
  Bytes: TBytes;
  Descriptor: TCEASaveFormatDescriptor;
begin
  FillChar(ASnapshot, SizeOf(ASnapshot), 0);
  if (Trim(ATaskId) = '') or (Trim(ASelectedPath) = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_selection_required', '{}'));
  if FReader = nil then
    Exit(TCEAResult.Error(rcInternalError, 'save_reader_missing', '{}'));
  Result := FReader.Inspect(ASelectedPath, ASnapshot);
  if Result.Failed then Exit;
  ASnapshot.TargetId := 'target-' + ASnapshot.FileIdentityId;
  if FCodec <> nil then
  begin
    Result := FReader.ReadVerified(ASnapshot, Bytes);
    if Result.Failed then Exit;
    if not FCodec.Probe(Bytes, Descriptor).Failed then
      ASnapshot.FormatDescriptor := Descriptor;
  end;
  Result := TCEAResult.Ok('{}');
end;

end.

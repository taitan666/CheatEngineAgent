unit cea_sqlite_store;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, DB, SQLDB, SQLite3Conn, cea_ports, cea_results,
  cea_types;

type
  TCEASaveEffectIdArray = array of string;

  TCEASqliteStore = class(TObject, IStateStore, IGovernanceStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function AppendEvent(const AEnvelopeJson: string): TCEAResult;
    function EventExists(const AEventId: string): Boolean;
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
    function ListUnsettledSaveEffectIds(
      out AIds: TCEASaveEffectIdArray): TCEAResult;
    function SaveRecoveryCase(const AEffectId, AAssessment,
      AObservedHash, AOwner, ADeadline, ANextCheck: string): TCEAResult;
    function LoadRecoveryCase(const AEffectId: string;
      out AAssessment, AObservedHash: string): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser, SQLite3Dyn;

procedure ExecuteConnectionPragma(const AConnection: TSQLite3Connection;
  const ASql: string);
var
  ErrorText: PChar;
  ReturnCode: Integer;
  MessageText: string;
begin
  ErrorText := nil;
  ReturnCode := sqlite3_exec(psqlite3(AConnection.Handle), PChar(ASql),
    nil, nil, @ErrorText);
  if ReturnCode <> SQLITE_OK then
  begin
    if ErrorText <> nil then
      MessageText := StrPas(ErrorText)
    else
      MessageText := 'SQLite pragma failed with code ' + IntToStr(ReturnCode);
    if ErrorText <> nil then
      sqlite3_free(ErrorText);
    raise Exception.Create(MessageText);
  end;
end;

constructor TCEASqliteStore.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEASqliteStore.Destroy;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
  if FConnection.Connected then
    FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEASqliteStore.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'database_path_required', '{}'));
  if not FConnection.Connected then
  begin
    FConnection.DatabaseName := FDatabasePath;
    try
      FConnection.Open;
    except
      on E: Exception do
        Exit(TCEAResult.Error(rcInternalError, 'database_open_failed',
          '{"message":"' + StringReplace(E.Message, '"', '\"',
          [rfReplaceAll]) + '"}'));
    end;
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEASqliteStore.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then
    Exit;
  try
    if FTransaction.Active then
      FTransaction.Rollback;
    ExecuteConnectionPragma(FConnection, 'PRAGMA journal_mode=WAL');
    ExecuteConnectionPragma(FConnection, 'PRAGMA foreign_keys=ON');
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS events (' +
      'event_id TEXT PRIMARY KEY, kind TEXT NOT NULL, ' +
      'payload_json TEXT NOT NULL, created_at TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS leases (' +
      'lease_id TEXT PRIMARY KEY, capability_id TEXT NOT NULL, ' +
      'process_identity_id TEXT NOT NULL, epoch INTEGER NOT NULL, ' +
      'issued_at TEXT NOT NULL, expires_at TEXT NOT NULL, ' +
      'remaining_calls INTEGER NOT NULL, remaining_bytes INTEGER NOT NULL, ' +
      'revoked INTEGER NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS approvals (' +
      'approval_id TEXT PRIMARY KEY, effect_id TEXT NOT NULL, ' +
      'payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS effects (' +
      'effect_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, ' +
      'capability_id TEXT NOT NULL, request_hash TEXT NOT NULL, ' +
      'request_json TEXT NOT NULL, process_identity_id TEXT NOT NULL, ' +
      'policy_snapshot_id TEXT NOT NULL, lease_id TEXT NOT NULL, ' +
      'approval_id TEXT NOT NULL, idempotency_key TEXT NOT NULL UNIQUE, ' +
      'epoch INTEGER NOT NULL, ' +
      'state TEXT NOT NULL CHECK(state IN ' +
      '(''planned'',''executing'',''applied'',''rejected'',''unknown'')), ' +
      'created_at TEXT NOT NULL, updated_at TEXT NOT NULL, ' +
      'target_classification INTEGER NOT NULL, result_json TEXT NOT NULL, ' +
      'payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE UNIQUE INDEX IF NOT EXISTS effects_request_hash ' +
      'ON effects(request_hash)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS receipts (' +
      'receipt_id TEXT PRIMARY KEY, effect_id TEXT NOT NULL ' +
      'REFERENCES effects(effect_id), payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS proofs (' +
      'proof_id TEXT PRIMARY KEY, effect_id TEXT NOT NULL ' +
      'REFERENCES effects(effect_id), receipt_id TEXT NOT NULL ' +
      'REFERENCES receipts(receipt_id), payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS idempotency (' +
      'idempotency_key TEXT PRIMARY KEY, effect_id TEXT NOT NULL ' +
      'REFERENCES effects(effect_id), outcome_json TEXT)');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS save_recovery_cases (' +
      'effect_id TEXT PRIMARY KEY REFERENCES effects(effect_id), ' +
      'assessment TEXT NOT NULL, observed_hash TEXT NOT NULL, ' +
      'owner TEXT NOT NULL, deadline TEXT NOT NULL, ' +
      'next_check TEXT NOT NULL)');
    FConnection.ExecuteDirect('UPDATE leases SET payload_json=' +
      '''{"resource_kind":"process","resource_identity_id":"'' || ' +
      'process_identity_id || ''"}'' WHERE payload_json=''{}''');
    FConnection.ExecuteDirect('UPDATE effects SET payload_json=' +
      '''{"resource_kind":"process","resource_identity_id":"'' || ' +
      'process_identity_id || ''"}'' WHERE payload_json=''{}''');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then
        FTransaction.Rollback;
      Result := TCEAResult.Error(rcInternalError, 'database_initialize_failed',
        '{"message":"' + StringReplace(E.Message, '"', '\"',
        [rfReplaceAll]) + '"}');
    end;
  end;
end;

function TCEASqliteStore.AppendEvent(const AEnvelopeJson: string): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  EventId: string;
  EventKind: string;
  Query: TSQLQuery;
begin
  Result := EnsureConnected;
  if Result.Failed then
    Exit;
  Data := nil;
  try
    try
      Data := GetJSON(AEnvelopeJson);
    except
      on E: Exception do
        Exit(TCEAResult.Error(rcInvalidArgument, 'event_json_invalid', '{}'));
    end;
    if Data.JSONType <> jtObject then
      Exit(TCEAResult.Error(rcInvalidArgument, 'event_object_required', '{}'));
    Obj := TJSONObject(Data);
    EventId := Obj.Get('id', '');
    EventKind := Obj.Get('kind', '');
    if EventKind = '' then
      EventKind := Obj.Get('type', '');
    if (EventId = '') or (EventKind = '') then
      Exit(TCEAResult.Error(rcInvalidArgument, 'event_identity_required', '{}'));

    Query := TSQLQuery.Create(nil);
    try
      Query.Database := FConnection;
      Query.Transaction := FTransaction;
      Query.SQL.Text := 'INSERT INTO events ' +
        '(event_id, kind, payload_json, created_at) ' +
        'VALUES (:event_id, :kind, :payload_json, :created_at)';
      Query.Params.ParamByName('event_id').AsString := EventId;
      Query.Params.ParamByName('kind').AsString := EventKind;
      Query.Params.ParamByName('payload_json').AsString := AEnvelopeJson;
      Query.Params.ParamByName('created_at').AsString :=
        FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now);
      try
        if FTransaction.Active then
          FTransaction.Rollback;
        FTransaction.StartTransaction;
        Query.ExecSQL;
        FTransaction.Commit;
        Result := TCEAResult.Ok('{"event_id":"' + EventId + '"}');
      except
        on E: Exception do
        begin
          if FTransaction.Active then
            FTransaction.Rollback;
          if Pos('UNIQUE constraint failed', E.Message) > 0 then
            Result := TCEAResult.Error(rcConflict, 'event_already_exists',
              '{"event_id":"' + EventId + '"}')
          else
            Result := TCEAResult.Error(rcInternalError, 'event_append_failed',
              '{}');
        end;
      end;
    finally
      Query.Free;
    end;
  finally
    Data.Free;
  end;
end;

function TCEASqliteStore.EventExists(const AEventId: string): Boolean;
var
  Query: TSQLQuery;
begin
  Result := False;
  if EnsureConnected.Failed then
    Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT 1 FROM events WHERE event_id = :event_id';
    Query.Params.ParamByName('event_id').AsString := AEventId;
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    Result := not Query.EOF;
    Query.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    Result := False;
  end;
  Query.Free;
end;

function TCEASqliteStore.SaveLease(const ALease: TCEALease): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONObject;
  ResourceIdentity: string;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  ResourceIdentity := ALease.ResourceIdentityId;
  if (ALease.ResourceKind = rkProcess) and (ResourceIdentity = '') then
    ResourceIdentity := ALease.ProcessIdentityId;
  if (ResourceIdentity = '') or
     ((ALease.ResourceKind = rkProcess) and
      (ResourceIdentity <> ALease.ProcessIdentityId)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'lease_resource_invalid', '{}'));
  Payload := TJSONObject.Create;
  if ALease.ResourceKind = rkSaveFile then
    Payload.Add('resource_kind', 'save_file')
  else
    Payload.Add('resource_kind', 'process');
  Payload.Add('resource_identity_id', ResourceIdentity);
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO leases ' +
      '(lease_id, capability_id, process_identity_id, epoch, issued_at, ' +
      'expires_at, remaining_calls, remaining_bytes, revoked, payload_json) ' +
      'VALUES (:lease_id, :capability_id, :process_identity_id, :epoch, ' +
      ':issued_at, :expires_at, :remaining_calls, :remaining_bytes, ' +
      ':revoked, :payload_json)';
    Query.Params.ParamByName('lease_id').AsString := ALease.Id;
    Query.Params.ParamByName('capability_id').AsString := ALease.CapabilityId;
    Query.Params.ParamByName('process_identity_id').AsString :=
      ALease.ProcessIdentityId;
    Query.Params.ParamByName('epoch').AsLargeInt := ALease.Epoch;
    Query.Params.ParamByName('issued_at').AsString := ALease.IssuedAt;
    Query.Params.ParamByName('expires_at').AsString := ALease.ExpiresAt;
    Query.Params.ParamByName('remaining_calls').AsInteger :=
      ALease.RemainingCalls;
    Query.Params.ParamByName('remaining_bytes').AsLargeInt :=
      ALease.RemainingBytes;
    Query.Params.ParamByName('revoked').AsInteger := Ord(ALease.Revoked);
    Query.Params.ParamByName('payload_json').AsString := Payload.AsJSON;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"lease_id":"' + ALease.Id + '"}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcInternalError, 'lease_save_failed',
        '{"message":"' + StringReplace(E.Message, '"', '\"',
        [rfReplaceAll]) + '"}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.LoadLease(const ALeaseId: string;
  out ALease: TCEALease): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONData;
  Obj: TJSONObject;
begin
  FillChar(ALease, SizeOf(ALease), 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  Payload := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT * FROM leases WHERE lease_id=:lease_id';
    Query.Params.ParamByName('lease_id').AsString := ALeaseId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcUnauthorized, 'lease_not_found', '{}')
    else
    begin
      ALease.Id := Query.FieldByName('lease_id').AsString;
      ALease.CapabilityId := Query.FieldByName('capability_id').AsString;
      ALease.ProcessIdentityId := Query.FieldByName(
        'process_identity_id').AsString;
      Payload := GetJSON(Query.FieldByName('payload_json').AsString);
      if Payload.JSONType <> jtObject then
        raise Exception.Create('lease payload invalid');
      Obj := TJSONObject(Payload);
      if Obj.Get('resource_kind', 'process') = 'save_file' then
        ALease.ResourceKind := rkSaveFile
      else
        ALease.ResourceKind := rkProcess;
      ALease.ResourceIdentityId := Obj.Get('resource_identity_id', '');
      if (ALease.ResourceKind = rkProcess) and
         (ALease.ResourceIdentityId = '') then
        ALease.ResourceIdentityId := ALease.ProcessIdentityId;
      ALease.Epoch := Query.FieldByName('epoch').AsLargeInt;
      ALease.IssuedAt := Query.FieldByName('issued_at').AsString;
      ALease.ExpiresAt := Query.FieldByName('expires_at').AsString;
      ALease.RemainingCalls := Query.FieldByName(
        'remaining_calls').AsInteger;
      ALease.RemainingBytes := Query.FieldByName(
        'remaining_bytes').AsLargeInt;
      ALease.Revoked := Query.FieldByName('revoked').AsInteger <> 0;
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'lease_load_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.ConsumeLeaseCall(
  const ALeaseId: string): TCEAResult;
var
  Query: TSQLQuery;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'UPDATE leases SET remaining_calls=remaining_calls-1 ' +
      'WHERE lease_id=:lease_id AND revoked=0 AND remaining_calls>0';
    Query.Params.ParamByName('lease_id').AsString := ALeaseId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    if Query.RowsAffected <> 1 then
    begin
      FTransaction.Rollback;
      Exit(TCEAResult.Error(rcBudgetExceeded, 'lease_calls_exhausted', '{}'));
    end;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'lease_consume_failed', '{}');
    end;
  end;
  Query.Free;
end;

function TCEASqliteStore.RevokeAllLeases: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect('UPDATE leases SET revoked=1 WHERE revoked=0');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"leases_revoked":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'lease_revoke_all_failed', '{}');
  end;
end;

function TCEASqliteStore.RejectPlannedEffects(
  const AUpdatedAt: string): TCEAResult;
var
  Query: TSQLQuery;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'UPDATE effects SET state=''rejected'', ' +
      'updated_at=:updated_at, result_json=' +
      '''{"reason":"emergency_stop"}'' WHERE state=''planned''';
    Query.Params.ParamByName('updated_at').AsString := AUpdatedAt;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"planned_effects_rejected":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'planned_effect_rejection_failed', '{}');
  end;
  Query.Free;
end;

function TCEASqliteStore.ReconcileExecutingEffects(
  const AUpdatedAt: string): TCEAResult;
var
  Query: TSQLQuery;
  ReconciledCount: Int64;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'UPDATE effects SET state=''unknown'', ' +
      'updated_at=:updated_at, result_json=' +
      '''{"reason":"startup_reconciliation_required"}'' ' +
      'WHERE state=''executing''';
    Query.Params.ParamByName('updated_at').AsString := AUpdatedAt;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    ReconciledCount := Query.RowsAffected;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"executing_effects_marked_unknown":' +
      IntToStr(ReconciledCount) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'executing_effect_reconciliation_failed', '{}');
  end;
  Query.Free;
end;

function TCEASqliteStore.SaveApproval(
  const ADecision: TCEAApprovalDecision): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONObject;
  ResourceIdentity: string;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  ResourceIdentity := ADecision.ResourceIdentityId;
  if (ADecision.ResourceKind = rkProcess) and (ResourceIdentity = '') then
    ResourceIdentity := ADecision.ProcessIdentityId;
  if (ADecision.Id = '') or (ADecision.EffectId = '') or
     (ADecision.RequestHash = '') or
     (ResourceIdentity = '') or
     (ADecision.PolicySnapshotId = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'approval_invalid', '{}'));
  Payload := TJSONObject.Create;
  Query := TSQLQuery.Create(nil);
  try
    Payload.Add('request_hash', ADecision.RequestHash);
    Payload.Add('process_identity_id', ADecision.ProcessIdentityId);
    if ADecision.ResourceKind = rkSaveFile then
      Payload.Add('resource_kind', 'save_file')
    else
      Payload.Add('resource_kind', 'process');
    Payload.Add('resource_identity_id', ResourceIdentity);
    Payload.Add('policy_snapshot_id', ADecision.PolicySnapshotId);
    Payload.Add('origin', Ord(ADecision.Origin));
    Payload.Add('outcome', Ord(ADecision.Outcome));
    Payload.Add('decided_at', ADecision.DecidedAt);
    Payload.Add('expires_at', ADecision.ExpiresAt);
    Payload.Add('max_executions', Int64(ADecision.MaxExecutions));
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO approvals ' +
      '(approval_id, effect_id, payload_json) VALUES ' +
      '(:approval_id, :effect_id, :payload_json)';
    Query.Params.ParamByName('approval_id').AsString := ADecision.Id;
    Query.Params.ParamByName('effect_id').AsString := ADecision.EffectId;
    Query.Params.ParamByName('payload_json').AsString := Payload.AsJSON;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"approval_id":"' + ADecision.Id + '"}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome,
        'approval_save_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.LoadApproval(const AEffectId: string;
  out ADecision: TCEAApprovalDecision): TCEAResult;
var
  Query: TSQLQuery;
  Data: TJSONData;
  Obj: TJSONObject;
  OriginValue, OutcomeValue: Integer;
begin
  FillChar(ADecision, SizeOf(ADecision), 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  Data := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT approval_id, payload_json FROM approvals ' +
      'WHERE effect_id=:effect_id ORDER BY rowid DESC LIMIT 1';
    Query.Params.ParamByName('effect_id').AsString := AEffectId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcApprovalRequired,
        'approval_required', '{}')
    else
    begin
      Data := GetJSON(Query.FieldByName('payload_json').AsString);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        raise Exception.Create('approval payload invalid');
      Obj := TJSONObject(Data);
      OriginValue := Obj.Get('origin', -1);
      OutcomeValue := Obj.Get('outcome', -1);
      if (OriginValue < Ord(Low(TCEAApprovalOrigin))) or
         (OriginValue > Ord(High(TCEAApprovalOrigin))) or
         (OutcomeValue < Ord(Low(TCEAApprovalOutcome))) or
         (OutcomeValue > Ord(High(TCEAApprovalOutcome))) then
        raise Exception.Create('approval enum invalid');
      ADecision.Id := Query.FieldByName('approval_id').AsString;
      ADecision.EffectId := AEffectId;
      ADecision.RequestHash := Obj.Get('request_hash', '');
      ADecision.ProcessIdentityId := Obj.Get('process_identity_id', '');
      if Obj.Get('resource_kind', 'process') = 'save_file' then
        ADecision.ResourceKind := rkSaveFile
      else
        ADecision.ResourceKind := rkProcess;
      ADecision.ResourceIdentityId := Obj.Get('resource_identity_id', '');
      if (ADecision.ResourceKind = rkProcess) and
         (ADecision.ResourceIdentityId = '') then
        ADecision.ResourceIdentityId := ADecision.ProcessIdentityId;
      ADecision.PolicySnapshotId := Obj.Get('policy_snapshot_id', '');
      ADecision.Origin := TCEAApprovalOrigin(OriginValue);
      ADecision.Outcome := TCEAApprovalOutcome(OutcomeValue);
      ADecision.DecidedAt := Obj.Get('decided_at', '');
      ADecision.ExpiresAt := Obj.Get('expires_at', '');
      ADecision.MaxExecutions := Obj.Get('max_executions', 0);
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome,
        'approval_load_failed', '{}');
    end;
  end;
  Data.Free;
  Query.Free;
end;

function EffectStateText(const AState: TCEAEffectState): string;
begin
  case AState of
    esPlanned: Result := 'planned';
    esExecuting: Result := 'executing';
    esApplied: Result := 'applied';
    esRejected: Result := 'rejected';
    esUnknown: Result := 'unknown';
  end;
end;

function TextToEffectState(const AState: string): TCEAEffectState;
begin
  if AState = 'executing' then Result := esExecuting
  else if AState = 'applied' then Result := esApplied
  else if AState = 'rejected' then Result := esRejected
  else if AState = 'unknown' then Result := esUnknown
  else Result := esPlanned;
end;

function TCEASqliteStore.SaveEffect(const AEffect: TCEAEffect): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONObject;
  ResourceIdentity: string;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  ResourceIdentity := AEffect.ResourceIdentityId;
  if (AEffect.ResourceKind = rkProcess) and (ResourceIdentity = '') then
    ResourceIdentity := AEffect.ProcessIdentityId;
  if (ResourceIdentity = '') or
     ((AEffect.ResourceKind = rkProcess) and
      (ResourceIdentity <> AEffect.ProcessIdentityId)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'effect_resource_invalid', '{}'));
  Payload := TJSONObject.Create;
  if AEffect.ResourceKind = rkSaveFile then
    Payload.Add('resource_kind', 'save_file')
  else
    Payload.Add('resource_kind', 'process');
  Payload.Add('resource_identity_id', ResourceIdentity);
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO effects ' +
      '(effect_id, task_id, capability_id, request_hash, request_json, ' +
      'process_identity_id, policy_snapshot_id, lease_id, approval_id, ' +
      'idempotency_key, epoch, state, created_at, updated_at, ' +
      'target_classification, result_json, payload_json) VALUES ' +
      '(:effect_id, :task_id, :capability_id, :request_hash, :request_json, ' +
      ':process_identity_id, :policy_snapshot_id, :lease_id, :approval_id, ' +
      ':idempotency_key, :epoch, :state, :created_at, :updated_at, ' +
      ':target_classification, :result_json, :payload_json)';
    Query.Params.ParamByName('effect_id').AsString := AEffect.Id;
    Query.Params.ParamByName('task_id').AsString := AEffect.TaskId;
    Query.Params.ParamByName('capability_id').AsString := AEffect.CapabilityId;
    Query.Params.ParamByName('request_hash').AsString := AEffect.RequestHash;
    Query.Params.ParamByName('request_json').AsString := AEffect.RequestJson;
    Query.Params.ParamByName('process_identity_id').AsString :=
      AEffect.ProcessIdentityId;
    Query.Params.ParamByName('policy_snapshot_id').AsString :=
      AEffect.PolicySnapshotId;
    Query.Params.ParamByName('lease_id').AsString := AEffect.LeaseId;
    Query.Params.ParamByName('approval_id').AsString := AEffect.ApprovalId;
    Query.Params.ParamByName('idempotency_key').AsString :=
      AEffect.IdempotencyKey;
    Query.Params.ParamByName('epoch').AsLargeInt := AEffect.Epoch;
    Query.Params.ParamByName('state').AsString := EffectStateText(AEffect.State);
    Query.Params.ParamByName('created_at').AsString := AEffect.CreatedAt;
    Query.Params.ParamByName('updated_at').AsString := AEffect.UpdatedAt;
    Query.Params.ParamByName('target_classification').AsInteger :=
      Ord(AEffect.TargetClassification);
    Query.Params.ParamByName('result_json').AsString := AEffect.ResultJson;
    Query.Params.ParamByName('payload_json').AsString := Payload.AsJSON;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"effect_id":"' + AEffect.Id + '"}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcInternalError, 'effect_save_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.LoadEffect(const AEffectId: string;
  out AEffect: TCEAEffect): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONData;
  Obj: TJSONObject;
begin
  FillChar(AEffect, SizeOf(AEffect), 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  Payload := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT * FROM effects WHERE effect_id=:effect_id';
    Query.Params.ParamByName('effect_id').AsString := AEffectId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcInvalidArgument, 'effect_not_found', '{}')
    else
    begin
      AEffect.Id := Query.FieldByName('effect_id').AsString;
      AEffect.TaskId := Query.FieldByName('task_id').AsString;
      AEffect.CapabilityId := Query.FieldByName('capability_id').AsString;
      AEffect.RequestHash := Query.FieldByName('request_hash').AsString;
      AEffect.RequestJson := Query.FieldByName('request_json').AsString;
      AEffect.ProcessIdentityId := Query.FieldByName(
        'process_identity_id').AsString;
      Payload := GetJSON(Query.FieldByName('payload_json').AsString);
      if Payload.JSONType <> jtObject then
        raise Exception.Create('effect payload invalid');
      Obj := TJSONObject(Payload);
      if Obj.Get('resource_kind', 'process') = 'save_file' then
        AEffect.ResourceKind := rkSaveFile
      else
        AEffect.ResourceKind := rkProcess;
      AEffect.ResourceIdentityId := Obj.Get('resource_identity_id', '');
      if (AEffect.ResourceKind = rkProcess) and
         (AEffect.ResourceIdentityId = '') then
        AEffect.ResourceIdentityId := AEffect.ProcessIdentityId;
      AEffect.PolicySnapshotId := Query.FieldByName(
        'policy_snapshot_id').AsString;
      AEffect.LeaseId := Query.FieldByName('lease_id').AsString;
      AEffect.ApprovalId := Query.FieldByName('approval_id').AsString;
      AEffect.IdempotencyKey := Query.FieldByName(
        'idempotency_key').AsString;
      AEffect.Epoch := Query.FieldByName('epoch').AsLargeInt;
      AEffect.State := TextToEffectState(Query.FieldByName('state').AsString);
      AEffect.CreatedAt := Query.FieldByName('created_at').AsString;
      AEffect.UpdatedAt := Query.FieldByName('updated_at').AsString;
      AEffect.TargetClassification := TCETargetClassification(
        Query.FieldByName('target_classification').AsInteger);
      AEffect.ResultJson := Query.FieldByName('result_json').AsString;
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'effect_load_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.SaveReceipt(
  const AReceipt: TCEAReceipt): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONObject;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  if (AReceipt.Id = '') or (AReceipt.EffectId = '') or
     (AReceipt.Attempt = 0) or (AReceipt.ResponseHash = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'receipt_invalid', '{}'));
  Payload := TJSONObject.Create;
  Query := TSQLQuery.Create(nil);
  try
    Payload.Add('attempt', Int64(AReceipt.Attempt));
    Payload.Add('recorded_at', AReceipt.RecordedAt);
    Payload.Add('outcome', Ord(AReceipt.Outcome));
    Payload.Add('response_hash', AReceipt.ResponseHash);
    Payload.Add('details_json', AReceipt.DetailsJson);
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO receipts ' +
      '(receipt_id, effect_id, payload_json) VALUES ' +
      '(:receipt_id, :effect_id, :payload_json)';
    Query.Params.ParamByName('receipt_id').AsString := AReceipt.Id;
    Query.Params.ParamByName('effect_id').AsString := AReceipt.EffectId;
    Query.Params.ParamByName('payload_json').AsString := Payload.AsJSON;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"receipt_id":"' + AReceipt.Id + '"}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'receipt_save_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.LoadReceipt(const AReceiptId: string;
  out AReceipt: TCEAReceipt): TCEAResult;
var
  Query: TSQLQuery;
  Data: TJSONData;
  Obj: TJSONObject;
  OutcomeValue: Integer;
begin
  FillChar(AReceipt, SizeOf(AReceipt), 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  Data := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT effect_id, payload_json FROM receipts ' +
      'WHERE receipt_id=:receipt_id';
    Query.Params.ParamByName('receipt_id').AsString := AReceiptId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcInvalidArgument, 'receipt_not_found', '{}')
    else
    begin
      Data := GetJSON(Query.FieldByName('payload_json').AsString);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        raise Exception.Create('receipt payload invalid');
      Obj := TJSONObject(Data);
      OutcomeValue := Obj.Get('outcome', -1);
      if (OutcomeValue < Ord(Low(TCEAReceiptOutcome))) or
         (OutcomeValue > Ord(High(TCEAReceiptOutcome))) then
        raise Exception.Create('receipt outcome invalid');
      AReceipt.Id := AReceiptId;
      AReceipt.EffectId := Query.FieldByName('effect_id').AsString;
      AReceipt.Attempt := Obj.Get('attempt', 0);
      AReceipt.RecordedAt := Obj.Get('recorded_at', '');
      AReceipt.Outcome := TCEAReceiptOutcome(OutcomeValue);
      AReceipt.ResponseHash := Obj.Get('response_hash', '');
      AReceipt.DetailsJson := Obj.Get('details_json', '{}');
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'receipt_load_failed', '{}');
    end;
  end;
  Data.Free;
  Query.Free;
end;

function TCEASqliteStore.SaveProof(const AProof: TCEAProof): TCEAResult;
var
  Query: TSQLQuery;
  Payload: TJSONObject;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  if (AProof.Id = '') or (AProof.EffectId = '') or
     (AProof.ReceiptId = '') or (AProof.VerificationHash = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'proof_invalid', '{}'));
  Payload := TJSONObject.Create;
  Query := TSQLQuery.Create(nil);
  try
    Payload.Add('recorded_at', AProof.RecordedAt);
    Payload.Add('outcome', Ord(AProof.Outcome));
    Payload.Add('verification_hash', AProof.VerificationHash);
    Payload.Add('details_json', AProof.DetailsJson);
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO proofs ' +
      '(proof_id, effect_id, receipt_id, payload_json) VALUES ' +
      '(:proof_id, :effect_id, :receipt_id, :payload_json)';
    Query.Params.ParamByName('proof_id').AsString := AProof.Id;
    Query.Params.ParamByName('effect_id').AsString := AProof.EffectId;
    Query.Params.ParamByName('receipt_id').AsString := AProof.ReceiptId;
    Query.Params.ParamByName('payload_json').AsString := Payload.AsJSON;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"proof_id":"' + AProof.Id + '"}');
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'proof_save_failed', '{}');
    end;
  end;
  Query.Free;
  Payload.Free;
end;

function TCEASqliteStore.LoadProof(const AProofId: string;
  out AProof: TCEAProof): TCEAResult;
var
  Query: TSQLQuery;
  Data: TJSONData;
  Obj: TJSONObject;
  OutcomeValue: Integer;
begin
  FillChar(AProof, SizeOf(AProof), 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  Data := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT effect_id, receipt_id, payload_json FROM proofs ' +
      'WHERE proof_id=:proof_id';
    Query.Params.ParamByName('proof_id').AsString := AProofId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcInvalidArgument, 'proof_not_found', '{}')
    else
    begin
      Data := GetJSON(Query.FieldByName('payload_json').AsString);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        raise Exception.Create('proof payload invalid');
      Obj := TJSONObject(Data);
      OutcomeValue := Obj.Get('outcome', -1);
      if (OutcomeValue < Ord(Low(TCEAProofOutcome))) or
         (OutcomeValue > Ord(High(TCEAProofOutcome))) then
        raise Exception.Create('proof outcome invalid');
      AProof.Id := AProofId;
      AProof.EffectId := Query.FieldByName('effect_id').AsString;
      AProof.ReceiptId := Query.FieldByName('receipt_id').AsString;
      AProof.RecordedAt := Obj.Get('recorded_at', '');
      AProof.Outcome := TCEAProofOutcome(OutcomeValue);
      AProof.VerificationHash := Obj.Get('verification_hash', '');
      AProof.DetailsJson := Obj.Get('details_json', '{}');
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    on E: Exception do
    begin
      if FTransaction.Active then FTransaction.Rollback;
      Result := TCEAResult.Error(rcUnknownOutcome, 'proof_load_failed', '{}');
    end;
  end;
  Data.Free;
  Query.Free;
end;

function TCEASqliteStore.ListUnsettledSaveEffectIds(
  out AIds: TCEASaveEffectIdArray): TCEAResult;
var
  Query: TSQLQuery;
begin
  SetLength(AIds, 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT effect_id FROM effects WHERE state=''unknown'' ' +
      'AND capability_id IN (''save_backup'',''save_edit'',''save_restore'')';
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    while not Query.EOF do
    begin
      SetLength(AIds, Length(AIds) + 1);
      AIds[High(AIds)] := Query.FieldByName('effect_id').AsString;
      Query.Next;
    end;
    Query.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'save_recovery_list_failed', '{}');
  end;
  Query.Free;
end;

function TCEASqliteStore.SaveRecoveryCase(const AEffectId,
  AAssessment, AObservedHash, AOwner, ADeadline, ANextCheck: string): TCEAResult;
var
  Query: TSQLQuery;
begin
  if (AEffectId = '') or (AAssessment = '') or (AOwner = '') or
     (ADeadline = '') or (ANextCheck = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'save_recovery_case_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'INSERT OR REPLACE INTO save_recovery_cases ' +
      '(effect_id,assessment,observed_hash,owner,deadline,next_check) ' +
      'VALUES (:effect_id,:assessment,:observed_hash,:owner,:deadline,' +
      ':next_check)';
    Query.Params.ParamByName('effect_id').AsString := AEffectId;
    Query.Params.ParamByName('assessment').AsString := AAssessment;
    Query.Params.ParamByName('observed_hash').AsString := AObservedHash;
    Query.Params.ParamByName('owner').AsString := AOwner;
    Query.Params.ParamByName('deadline').AsString := ADeadline;
    Query.Params.ParamByName('next_check').AsString := ANextCheck;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'save_recovery_case_save_failed', '{}');
  end;
  Query.Free;
end;

function TCEASqliteStore.LoadRecoveryCase(const AEffectId: string;
  out AAssessment, AObservedHash: string): TCEAResult;
var
  Query: TSQLQuery;
begin
  AAssessment := '';
  AObservedHash := '';
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT assessment,observed_hash FROM ' +
      'save_recovery_cases WHERE effect_id=:effect_id';
    Query.Params.ParamByName('effect_id').AsString := AEffectId;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
      Result := TCEAResult.Error(rcInvalidArgument,
        'save_recovery_case_not_found', '{}')
    else
    begin
      AAssessment := Query.FieldByName('assessment').AsString;
      AObservedHash := Query.FieldByName('observed_hash').AsString;
      Result := TCEAResult.Ok('{}');
    end;
    Query.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome,
      'save_recovery_case_load_failed', '{}');
  end;
  Query.Free;
end;

end.

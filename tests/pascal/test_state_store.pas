program test_state_store;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_sqlite_store, cea_schema_validator,
  cea_event_store;

var
  DatabasePath: string;
  SchemaRoot: string;
  Store: TCEASqliteStore;
  Validator: TCEASchemaValidator;
  EventStore: TCEAEventStore;
  R: TCEAResult;
  LeaseToSave: TCEALease;
  LeaseLoaded: TCEALease;
  EffectToSave: TCEAEffect;
  EffectLoaded: TCEAEffect;
  ReceiptToSave, ReceiptLoaded: TCEAReceipt;
  ProofToSave, ProofLoaded: TCEAProof;
  ApprovalToSave, ApprovalLoaded: TCEAApprovalDecision;

begin
  DatabasePath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-state-' + IntToStr(GetProcessID) + '.sqlite3';
  DeleteFile(DatabasePath);
  Store := TCEASqliteStore.Create(DatabasePath);
  try
    R := Store.Initialize;
    if R.Code <> rcOk then
      WriteLn('STORE_INIT_DIAGNOSTIC stable=', R.StableCode,
        ' message=', R.MessageText, ' data=', R.DataJson);
    Assert(R.Code = rcOk, 'store initialization');
    Assert(Store.AppendEvent('{"id":"evt-1","kind":"test"}').Code = rcOk,
      'first event append');
    Assert(Store.AppendEvent('{"id":"evt-1","kind":"test"}').Code = rcConflict,
      'duplicate event must conflict');
    Assert(Store.EventExists('evt-1'), 'event must exist before reopen');

    FillChar(LeaseToSave, SizeOf(LeaseToSave), 0);
    LeaseToSave.Id := 'lease-persisted';
    LeaseToSave.CapabilityId := 'memory_read';
    LeaseToSave.ProcessIdentityId := 'process-persisted';
    LeaseToSave.Epoch := 9;
    LeaseToSave.IssuedAt := '2026-09-12T10:00:00.000Z';
    LeaseToSave.ExpiresAt := '2026-09-12T10:10:00.000Z';
    LeaseToSave.RemainingCalls := 2;
    LeaseToSave.RemainingBytes := 4096;
    Assert(Store.SaveLease(LeaseToSave).Code = rcOk, 'lease save');
    Assert(Store.ConsumeLeaseCall(LeaseToSave.Id).Code = rcOk,
      'lease consume');
    Assert(Store.LoadLease(LeaseToSave.Id, LeaseLoaded).Code = rcOk);
    Assert(LeaseLoaded.ResourceKind = rkProcess);
    Assert(LeaseLoaded.ResourceIdentityId = LeaseToSave.ProcessIdentityId,
      'legacy lease identity migrates to process resource');

    FillChar(EffectToSave, SizeOf(EffectToSave), 0);
    EffectToSave.Id := 'effect-persisted';
    EffectToSave.TaskId := 'task-persisted';
    EffectToSave.CapabilityId := 'memory_write';
    EffectToSave.RequestHash := 'sha256:' + StringOfChar('a', 64);
    EffectToSave.RequestJson := '{"value":1}';
    EffectToSave.ProcessIdentityId := 'process-persisted';
    EffectToSave.PolicySnapshotId := 'policy-persisted';
    EffectToSave.LeaseId := LeaseToSave.Id;
    EffectToSave.IdempotencyKey := 'write-persisted';
    EffectToSave.Epoch := 9;
    EffectToSave.State := esPlanned;
    EffectToSave.CreatedAt := '2026-09-12T10:00:00.000Z';
    EffectToSave.UpdatedAt := EffectToSave.CreatedAt;
    EffectToSave.TargetClassification := tcSinglePlayerOffline;
    Assert(Store.SaveEffect(EffectToSave).Code = rcOk, 'effect save');

    FillChar(ApprovalToSave, SizeOf(ApprovalToSave), 0);
    ApprovalToSave.Id := 'approval-persisted';
    ApprovalToSave.EffectId := EffectToSave.Id;
    ApprovalToSave.RequestHash := EffectToSave.RequestHash;
    ApprovalToSave.ProcessIdentityId := EffectToSave.ProcessIdentityId;
    ApprovalToSave.PolicySnapshotId := EffectToSave.PolicySnapshotId;
    ApprovalToSave.Origin := aoLocalUserInterface;
    ApprovalToSave.Outcome := adApproved;
    ApprovalToSave.DecidedAt := EffectToSave.UpdatedAt;
    ApprovalToSave.ExpiresAt := '2026-09-12T10:01:00.000Z';
    ApprovalToSave.MaxExecutions := 1;
    Assert(Store.SaveApproval(ApprovalToSave).Code = rcOk,
      'approval save');

    FillChar(ReceiptToSave, SizeOf(ReceiptToSave), 0);
    ReceiptToSave.Id := 'receipt-persisted';
    ReceiptToSave.EffectId := EffectToSave.Id;
    ReceiptToSave.Attempt := 1;
    ReceiptToSave.RecordedAt := EffectToSave.UpdatedAt;
    ReceiptToSave.Outcome := roApplied;
    ReceiptToSave.ResponseHash := 'sha256:' + StringOfChar('b', 64);
    ReceiptToSave.DetailsJson := '{"readback_verified":true}';
    Assert(Store.SaveReceipt(ReceiptToSave).Code = rcOk, 'receipt save');

    FillChar(ProofToSave, SizeOf(ProofToSave), 0);
    ProofToSave.Id := 'proof-persisted';
    ProofToSave.EffectId := EffectToSave.Id;
    ProofToSave.ReceiptId := ReceiptToSave.Id;
    ProofToSave.RecordedAt := EffectToSave.UpdatedAt;
    ProofToSave.Outcome := poPass;
    ProofToSave.VerificationHash := 'sha256:' + StringOfChar('c', 64);
    ProofToSave.DetailsJson := '{"compare_write_readback":true}';
    Assert(Store.SaveProof(ProofToSave).Code = rcOk, 'proof save');
  finally
    Store.Free;
  end;

  Store := TCEASqliteStore.Create(DatabasePath);
  try
    Assert(Store.Initialize.Code = rcOk, 'store reopen');
    Assert(Store.EventExists('evt-1'), 'event must survive reopen');
    Assert(Store.LoadLease(LeaseToSave.Id, LeaseLoaded).Code = rcOk,
      'lease survives reopen');
    Assert(LeaseLoaded.RemainingCalls = 1, 'lease decrement persists');
    Assert(Store.LoadEffect(EffectToSave.Id, EffectLoaded).Code = rcOk,
      'effect survives reopen');
    Assert(EffectLoaded.RequestHash = EffectToSave.RequestHash,
      'effect hash survives reopen');
    EffectLoaded.State := esExecuting;
    EffectLoaded.UpdatedAt := '2026-09-12T10:00:30.000Z';
    Assert(Store.SaveEffect(EffectLoaded).Code = rcOk,
      'executing crash-window effect saved');
    Assert(Store.ReconcileExecutingEffects(
      '2026-09-12T10:02:00.000Z').Code = rcOk,
      'startup reconciliation marks interrupted effects');
    Assert(Store.LoadEffect(EffectToSave.Id, EffectLoaded).Code = rcOk,
      'reconciled effect reloads');
    Assert((EffectLoaded.State = esUnknown) and
      (Pos('startup_reconciliation_required', EffectLoaded.ResultJson) > 0),
      'interrupted executing effect becomes unknown, never auto-retried');
    Assert(Store.LoadApproval(EffectToSave.Id, ApprovalLoaded).Code = rcOk,
      'approval survives reopen');
    Assert(ApprovalLoaded.RequestHash = EffectToSave.RequestHash,
      'approval remains bound to request hash');
    Assert(Store.LoadReceipt(ReceiptToSave.Id, ReceiptLoaded).Code = rcOk,
      'receipt survives reopen');
    Assert(ReceiptLoaded.ResponseHash = ReceiptToSave.ResponseHash,
      'receipt response hash survives reopen');
    Assert(Store.LoadProof(ProofToSave.Id, ProofLoaded).Code = rcOk,
      'proof survives reopen');
    Assert(ProofLoaded.ReceiptId = ReceiptToSave.Id,
      'proof remains bound to receipt');
  finally
    Store.Free;
  end;

  SchemaRoot := ExpandFileName(IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0))) + '..\..\schemas');
  if not DirectoryExists(SchemaRoot) then
    SchemaRoot := ExpandFileName('schemas');
  Validator := TCEASchemaValidator.Create(SchemaRoot);
  try
    R := Validator.Validate('mcp/tool-result.schema.json',
      '{"stable_code":"ok","is_error":false,"data":{}}');
    Assert(R.Code = rcOk, 'valid MCP result');
    R := Validator.Validate('mcp/tool-result.schema.json',
      '{"stable_code":"ok","is_error":false,"data":{},"unexpected":1}');
    Assert(R.Code = rcInvalidArgument, 'unknown field must fail');
    Assert(Pos('/unexpected', R.DataJson) > 0, 'error includes JSON pointer');
    Assert(Validator.Validate('mcp/missing.schema.json', '{}').Code =
      rcInvalidArgument, 'unknown schema must fail');

    Store := TCEASqliteStore.Create(DatabasePath);
    try
      Assert(Store.Initialize.Code = rcOk, 'event store database reopen');
      EventStore := TCEAEventStore.Create(Store, Validator);
      try
        R := EventStore.AppendValidated('agentos/envelope.schema.json',
          '{"id":"evt-invalid","type":"audit"}');
        Assert(R.Code = rcInvalidArgument, 'invalid envelope rejected');
        Assert(not Store.EventExists('evt-invalid'),
          'invalid envelope is not persisted');
        R := EventStore.AppendValidated('agentos/envelope.schema.json',
          '{"id":"evt-2","type":"audit","schema_version":"1.0",' +
          '"tenant_id":"local","actor_id":"test",' +
          '"created_at":"2026-09-12T00:00:00Z",' +
          '"payload":{},"provenance":{}}');
        Assert(R.Code = rcOk, 'valid envelope appended');
        Assert(Store.EventExists('evt-2'), 'valid envelope persisted');
      finally
        EventStore.Free;
      end;
    finally
      Store.Free;
    end;
  finally
    Validator.Free;
  end;

  DeleteFile(DatabasePath);
  DeleteFile(DatabasePath + '-wal');
  DeleteFile(DatabasePath + '-shm');
  WriteLn('STATE_STORE_AND_SCHEMA=PASS');
end.

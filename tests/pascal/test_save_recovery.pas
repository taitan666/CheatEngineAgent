program test_save_recovery;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, cea_types, cea_results, cea_save_types,
  cea_windows_sha256, cea_application_runtime, cea_sqlite_store;

function FixtureBytes(const Hp, Gold: Integer): string;
var
  Body: string;
  Hasher: TCEAWindowsSha256;
begin
  Body := 'CEA-SAVE-1' + #10 + '{"hp":' + IntToStr(Hp) +
    ',"gold":' + IntToStr(Gold) + '}';
  Hasher := TCEAWindowsSha256.Create;
  try
    Result := Body + #10 + Hasher.HashUtf8(Body) + #10;
  finally
    Hasher.Free;
  end;
end;

var
  RootPath, SavePath, DatabasePath, EscapePath, Raw: string;
  Stream: TFileStream;
  Runtime: TCEAStandaloneRuntime;
  Store: TCEASqliteStore;
  Original, Edited, Restored: TCEASaveSnapshot;
  Proposal: TCEASaveEditProposal;
  Fields: TCEASaveFieldArray;
  BackupId, EditId, RestoreId: string;
  R: TCEAResult;
  Unsettled: TCEAEffect;
  Assessment, ObservedHash: string;
begin
  Randomize;
  RootPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-save-restore-' + IntToStr(GetProcessID) + '-' +
    IntToStr(Random(MaxInt));
  ForceDirectories(RootPath);
  SavePath := IncludeTrailingPathDelimiter(RootPath) + 'slot.sav';
  DatabasePath := IncludeTrailingPathDelimiter(RootPath) + 'state.sqlite3';
  Raw := FixtureBytes(400, 900);
  Stream := TFileStream.Create(SavePath, fmCreate);
  try Stream.WriteBuffer(Raw[1], Length(Raw)) finally Stream.Free end;
  Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
    30000 + Word(GetProcessID mod 20000));
  try
    R := Runtime.Start;
    Assert(R.Code = rcOk, R.StableCode);
    Assert(Runtime.InspectSaveFile('restore-test', SavePath,
      Original).Code = rcOk);
    Assert(Runtime.RequestSaveBackup('restore-test', Original,
      BackupId).Code = rcApprovalRequired);
    Assert(Runtime.ApproveAndExecute(BackupId).Code = rcOk);
    Assert(Runtime.ProposeSaveFieldEdit(Original, '/hp', '400', '500',
      Proposal).Code = rcOk);
    Assert(Runtime.PlanSaveEdit('restore-test', Original, Proposal,
      BackupId, EditId).Code = rcApprovalRequired);
    Assert(Runtime.ApproveAndExecute(EditId).Code = rcOk);
    Assert(Runtime.InspectSaveFile('restore-current', SavePath,
      Edited).Code = rcOk);
    Assert(Runtime.PlanSaveRestore('restore-test', Edited, BackupId,
      'sha256:wrong', RestoreId).Code = rcConflict);
    Assert(Runtime.PlanSaveRestore('restore-test', Edited, BackupId,
      Edited.Sha256, RestoreId).Code = rcApprovalRequired);
    Assert(Runtime.ExecuteSaveEdit(RestoreId).Code = rcApprovalRequired);
    R := Runtime.ApproveAndExecute(RestoreId);
    Assert((R.Code = rcOk) and (R.ReceiptId <> '') and
      (R.ProofId <> ''), 'explicit restore has independent proof');
    Assert(Runtime.InspectSaveFile('restore-readback', SavePath,
      Restored).Code = rcOk);
    Assert(Restored.Sha256 = Original.Sha256);
    Assert(Runtime.GetSaveFields(Restored, Fields).Code = rcOk);
    Assert((Fields[0].ValueJson = '400') and (Fields[1].ValueJson = '900'));
  finally
    Runtime.Free;
  end;
  Store := TCEASqliteStore.Create(DatabasePath);
  try
    Assert(Store.Initialize.Code = rcOk);
    FillChar(Unsettled, SizeOf(Unsettled), 0);
    Unsettled.Id := 'effect-unsettled-save-test';
    Unsettled.TaskId := 'restore-test';
    Unsettled.CapabilityId := 'save_edit';
    Unsettled.RequestHash := 'sha256:' + StringOfChar('a', 64);
    Unsettled.RequestJson := '{"source_path":"' +
      StringReplace(SavePath, '\', '\\', [rfReplaceAll]) + '"}';
    Unsettled.ResourceKind := rkSaveFile;
    Unsettled.ResourceIdentityId := Restored.FileIdentityId;
    Unsettled.PolicySnapshotId := 'policy:single-player-save-v1';
    Unsettled.LeaseId := 'lease-test';
    Unsettled.IdempotencyKey := 'unsettled-save-key';
    Unsettled.State := esExecuting;
    Unsettled.TargetClassification := tcSinglePlayerOffline;
    Assert(Store.SaveEffect(Unsettled).Code = rcOk);
    EscapePath := IncludeTrailingPathDelimiter(RootPath) + 'escape.bak';
    Stream := TFileStream.Create(EscapePath, fmCreate);
    try Stream.WriteBuffer(Raw[1], Length(Raw)) finally Stream.Free end;
    Unsettled.Id := 'effect-unsettled-escape-test';
    Unsettled.CapabilityId := 'save_backup';
    Unsettled.RequestHash := 'sha256:' + StringOfChar('b', 64);
    Unsettled.IdempotencyKey := 'unsettled-escape-key';
    Unsettled.RequestJson := '{"snapshot_id":"..\\escape",' +
      '"sha256":"' + Original.Sha256 + '"}';
    Assert(Store.SaveEffect(Unsettled).Code = rcOk);
    Unsettled.Id := 'effect-unsettled-applied-test';
    Unsettled.CapabilityId := 'save_edit';
    Unsettled.RequestHash := 'sha256:' + StringOfChar('c', 64);
    Unsettled.IdempotencyKey := 'unsettled-applied-key';
    Unsettled.RequestJson := '{"source_path":"' +
      StringReplace(SavePath, '\', '\\', [rfReplaceAll]) +
      '","sha256":"sha256:before",' +
      '"candidate_sha256":"' + Restored.Sha256 + '"}';
    Assert(Store.SaveEffect(Unsettled).Code = rcOk);
  finally
    Store.Free;
  end;
  Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
    30000 + Word(GetProcessID mod 20000));
  try
    R := Runtime.Start;
    Assert(R.Code = rcOk, R.StableCode);
    R := Runtime.LoadEffect('effect-unsettled-save-test', Unsettled);
    Assert(R.Code = rcOk, R.StableCode);
    Assert(Unsettled.State = esUnknown,
      'startup never retries an interrupted save write');
    Assert(Runtime.RequestSaveBackup('after-unknown', Restored,
      BackupId).Code = rcConflict,
      'unsettled save target blocks a new Effect');
    Assert(Runtime.GetSaveRecoveryCase(Unsettled.Id, Assessment,
      ObservedHash).Code = rcOk);
    Assert((Assessment = 'unknown') or
      (Assessment = 'observed_not_applied') or
      (Assessment = 'observed_applied'));
    Assert(Runtime.GetSaveRecoveryCase('effect-unsettled-escape-test',
      Assessment, ObservedHash).Code = rcOk);
    Assert((Assessment = 'unknown') and (ObservedHash = ''),
      'recovery must not inspect path escaped from backup directory');
    Assert(Runtime.GetSaveRecoveryCase('effect-unsettled-applied-test',
      Assessment, ObservedHash).Code = rcOk);
    Assert((Assessment = 'observed_applied') and
      (ObservedHash = Restored.Sha256),
      'read-only recovery can identify the planned candidate hash');
  finally
    Runtime.Free;
  end;
  WriteLn('SAVE_RECOVERY=PASS');
end.

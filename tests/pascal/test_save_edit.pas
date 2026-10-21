program test_save_edit;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, cea_results, cea_save_types, cea_windows_sha256,
  cea_application_runtime;

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
  RootPath, SavePath, DatabasePath, BeforeText, AfterText: string;
  Stream: TFileStream;
  Runtime: TCEAStandaloneRuntime;
  Snapshot, AfterSnapshot: TCEASaveSnapshot;
  Proposal: TCEASaveEditProposal;
  R: TCEAResult;
  BackupEffectId, EditEffectId: string;
  SecondBackupId, StaleEditId: string;
  SecondProposal: TCEASaveEditProposal;
  FirstReceiptId, FirstProofId: string;
  Fields: TCEASaveFieldArray;
begin
  RootPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-save-edit-' + IntToStr(GetProcessID);
  ForceDirectories(RootPath);
  SavePath := IncludeTrailingPathDelimiter(RootPath) + 'slot.sav';
  DatabasePath := IncludeTrailingPathDelimiter(RootPath) + 'state.sqlite3';
  BeforeText := FixtureBytes(400, 900);
  Stream := TFileStream.Create(SavePath, fmCreate);
  try
    Stream.WriteBuffer(BeforeText[1], Length(BeforeText));
  finally
    Stream.Free;
  end;
  Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
    30000 + Word(GetProcessID mod 20000));
  try
    Assert(Runtime.Start.Code = rcOk);
    R := Runtime.InspectSaveFile('save-edit-test', SavePath, Snapshot);
    Assert(R.Code = rcOk, R.StableCode);
    Assert(Snapshot.FormatDescriptor.Id = 'cea-fixture-save');
    R := Runtime.ProposeSaveFieldEdit(Snapshot, '/hp', '400', '500', Proposal);
    Assert((R.Code = rcOk) and (Proposal.ContentHash <> ''));
    R := Runtime.PlanSaveEdit('save-edit-test', Snapshot, Proposal,
      'nonexistent-backup', EditEffectId);
    Assert(R.Code <> rcApprovalRequired, 'edit requires verified backup');
    Assert(Runtime.RequestSaveBackup('save-edit-test', Snapshot,
      BackupEffectId).Code = rcApprovalRequired);
    R := Runtime.ApproveAndExecute(BackupEffectId);
    Assert((R.Code = rcOk) and (R.ProofId <> ''));
    R := Runtime.PlanSaveEdit('save-edit-test', Snapshot, Proposal,
      BackupEffectId, EditEffectId);
    Assert((R.Code = rcApprovalRequired) and (EditEffectId <> ''));
    Assert(Runtime.ExecuteSaveEdit(EditEffectId).Code = rcApprovalRequired,
      'execution without local approval is denied');
    R := Runtime.ApproveAndExecute(EditEffectId);
    Assert((R.Code = rcOk) and (R.ReceiptId <> '') and
      (R.ProofId <> ''), 'approved fixture edit has receipt and proof');
    FirstReceiptId := R.ReceiptId;
    FirstProofId := R.ProofId;
    R := Runtime.ApproveAndExecute(EditEffectId);
    Assert((R.Code = rcOk) and (R.ReceiptId = FirstReceiptId) and
      (R.ProofId = FirstProofId), 'applied effect reuses stored proof');
    Assert(Runtime.InspectSaveFile('readback', SavePath,
      AfterSnapshot).Code = rcOk);
    Assert(AfterSnapshot.Sha256 <> Snapshot.Sha256);
    Assert(Runtime.GetSaveFields(AfterSnapshot, Fields).Code = rcOk);
    Assert((Fields[0].ValueJson = '500') and
      (Fields[1].ValueJson = '900'), 'readback preserves unedited field');
    Assert(Runtime.RequestSaveBackup('save-edit-test-2', AfterSnapshot,
      SecondBackupId).Code = rcApprovalRequired);
    Assert(Runtime.ApproveAndExecute(SecondBackupId).Code = rcOk);
    Assert(Runtime.ProposeSaveFieldEdit(AfterSnapshot, '/hp', '500', '600',
      SecondProposal).Code = rcOk);
    Assert(Runtime.PlanSaveEdit('save-edit-test-2', AfterSnapshot,
      SecondProposal, SecondBackupId, StaleEditId).Code = rcApprovalRequired);
    AfterText := FixtureBytes(501, 900);
    Stream := TFileStream.Create(SavePath, fmCreate);
    try Stream.WriteBuffer(AfterText[1], Length(AfterText)) finally Stream.Free end;
    R := Runtime.ApproveAndExecute(StaleEditId);
    Assert(R.Code = rcConflict, 'changed source blocks stale edit');
    Assert(Runtime.InspectSaveFile('stale-readback', SavePath,
      AfterSnapshot).Code = rcOk);
    Assert(Runtime.GetSaveFields(AfterSnapshot, Fields).Code = rcOk);
    Assert(Fields[0].ValueJson = '501',
      'stale edit never overwrites concurrent change');
  finally
    Runtime.Free;
  end;
  WriteLn('SAVE_EDIT=PASS');
end.

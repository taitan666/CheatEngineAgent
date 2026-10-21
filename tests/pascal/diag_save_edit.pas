program diag_save_edit;

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

procedure Report(const AStep: string; const AR: TCEAResult);
begin
  WriteLn(Format('%-28s code=%d stable=%s data=%s',
    [AStep, Ord(AR.Code), AR.StableCode, Copy(AR.DataJson, 1, 200)]));
end;

var
  RootPath, SavePath, DatabasePath, BeforeText: string;
  Stream: TFileStream;
  Runtime: TCEAStandaloneRuntime;
  Snapshot: TCEASaveSnapshot;
  Proposal: TCEASaveEditProposal;
  R: TCEAResult;
  BackupEffectId, EditEffectId: string;
begin
  RootPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-diag-save-edit-' + IntToStr(GetProcessID);
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
    Report('Start', Runtime.Start);
    Report('InspectSaveFile', Runtime.InspectSaveFile('save-edit-test',
      SavePath, Snapshot));
    Report('ProposeSaveFieldEdit', Runtime.ProposeSaveFieldEdit(Snapshot,
      '/hp', '400', '500', Proposal));
    Report('PlanSaveEdit(bad backup)', Runtime.PlanSaveEdit('save-edit-test',
      Snapshot, Proposal, 'nonexistent-backup', EditEffectId));
    Report('RequestSaveBackup', Runtime.RequestSaveBackup('save-edit-test',
      Snapshot, BackupEffectId));
    WriteLn('  backup_effect_id=', BackupEffectId);
    Report('ApproveAndExecute(backup)',
      Runtime.ApproveAndExecute(BackupEffectId));
    Report('PlanSaveEdit(real backup)', Runtime.PlanSaveEdit('save-edit-test',
      Snapshot, Proposal, BackupEffectId, EditEffectId));
    WriteLn('  edit_effect_id=', EditEffectId);
    Report('ExecuteSaveEdit(no approval)',
      Runtime.ExecuteSaveEdit(EditEffectId));
    Report('ApproveAndExecute(edit)', Runtime.ApproveAndExecute(EditEffectId));
  finally
    Runtime.Stop;
    Runtime.Free;
  end;
end.

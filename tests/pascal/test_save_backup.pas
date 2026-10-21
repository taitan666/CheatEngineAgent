program test_save_backup;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, cea_results, cea_save_types,
  cea_application_runtime, cea_windows_sha256, cea_types,
  cea_win32_save_reader, cea_win32_save_effect_port;

var
  RootPath, SavePath, DatabasePath: string;
  Stream: TFileStream;
  Runtime: TCEAStandaloneRuntime;
  Snapshot: TCEASaveSnapshot;
  OriginalSnapshot: TCEASaveSnapshot;
  R: TCEAResult;
  EffectId, BackupPath: string;
  RepeatedEffectId: string;
  OriginalHash: string;
  Hasher: TCEAWindowsSha256;
  DirectReader: TCEAWin32SaveReader;
  DirectPort: TCEAWin32SaveEffectPort;
  Forged: TCEAEffect;
  EscapePath: string;
  EscapeCreated: Boolean;
begin
  RootPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-save-backup-' + IntToStr(GetProcessID);
  ForceDirectories(RootPath);
  SavePath := IncludeTrailingPathDelimiter(RootPath) + 'slot.sav';
  DatabasePath := IncludeTrailingPathDelimiter(RootPath) + 'state.sqlite3';
  Stream := TFileStream.Create(SavePath, fmCreate);
  try
    Stream.WriteBuffer('test-save-data'[1], 14);
  finally
    Stream.Free;
  end;
  Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
    30000 + Word(GetProcessID mod 20000));
  try
    Assert(Runtime.Start.Code = rcOk);
    Assert(Runtime.InspectSaveFile('save-backup-test', SavePath,
      Snapshot).Code = rcOk);
    OriginalHash := Snapshot.Sha256;
    OriginalSnapshot := Snapshot;
    R := Runtime.RequestSaveBackup('save-backup-test', Snapshot, EffectId);
    Assert(R.Code = rcApprovalRequired, 'backup is an effect');
    Assert(EffectId <> '');
    BackupPath := IncludeTrailingPathDelimiter(RootPath) + 'backups' +
      PathDelim + Snapshot.Id + '.bak';
    Assert(not FileExists(BackupPath), 'planning creates no backup file');
    R := Runtime.ApproveAndExecute(EffectId);
    Assert((R.Code = rcOk) and (R.ReceiptId <> '') and (R.ProofId <> ''),
      'backup has receipt and proof');
    Assert(FileExists(BackupPath), 'backup was written outside save folder');
    Assert((GetFileAttributesW(PWideChar(UTF8Decode(BackupPath))) and
      FILE_ATTRIBUTE_READONLY) <> 0,
      'verified backup is protected against accidental overwrite');
    Assert(Runtime.InspectSaveFile('check-backup', BackupPath,
      Snapshot).Code = rcOk, 'backup readback succeeds');
    Assert(Snapshot.Sha256 = OriginalHash, 'backup matches original bytes');
    Hasher := TCEAWindowsSha256.Create;
    try
      Assert(Hasher.HashFile(SavePath) = OriginalHash,
        'backup leaves original unchanged');
    finally
      Hasher.Free;
    end;
    Assert(Runtime.RequestSaveBackup('save-backup-test', OriginalSnapshot,
      RepeatedEffectId).Code = rcApprovalRequired);
    Assert(RepeatedEffectId = EffectId,
      'same snapshot and task reuse the planned effect');
    DirectReader := TCEAWin32SaveReader.Create;
    Hasher := TCEAWindowsSha256.Create;
    DirectPort := TCEAWin32SaveEffectPort.Create(DirectReader, Hasher,
      IncludeTrailingPathDelimiter(RootPath) + 'backups');
    try
      FillChar(Forged, SizeOf(Forged), 0);
      Forged.Id := 'effect-forged';
      Forged.CapabilityId := 'save_backup';
      Forged.ResourceKind := rkSaveFile;
      Forged.ResourceIdentityId := OriginalSnapshot.FileIdentityId;
      Forged.State := esExecuting;
      Forged.ApprovalId := 'approval-forged';
      Forged.RequestJson := '{"snapshot_id":"..\\escape",' +
        '"source_path":"' + StringReplace(SavePath, '\', '\\',
        [rfReplaceAll]) + '","file_identity_id":"' +
        OriginalSnapshot.FileIdentityId + '","sha256":"' +
        OriginalSnapshot.Sha256 + '","byte_count":14}';
      EscapePath := IncludeTrailingPathDelimiter(RootPath) + 'escape.bak';
      R := DirectPort.InvokeEffect(Forged);
      EscapeCreated := FileExists(EscapePath);
      if EscapeCreated then SysUtils.DeleteFile(EscapePath);
      Assert(R.Code <> rcOk, 'forged backup identifier rejected');
      Assert(not EscapeCreated, 'forged ID cannot escape backup directory');
    finally
      DirectPort.Free;
      Hasher.Free;
      DirectReader.Free;
    end;
  finally
    Runtime.Free;
  end;
  WriteLn('SAVE_BACKUP=PASS');
end.

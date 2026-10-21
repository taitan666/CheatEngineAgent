unit cea_win32_save_effect_port;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_save_ports;

type
  TCEAWin32SaveEffectPort = class(TObject, ICEASaveFileEffects)
  private
    FReader: ICEASaveReader;
    FHasher: ICEAHasher;
    FCodec: ICEASaveCodec;
    FBackupDirectory: string;
    function ExecuteEdit(const AEffect: TCEAEffect): TCEAResult;
    function ExecuteRestore(const AEffect: TCEAEffect): TCEAResult;
  public
    constructor Create(const AReader: ICEASaveReader;
      const AHasher: ICEAHasher; const ABackupDirectory: string;
      const ACodec: ICEASaveCodec = nil);
    function InvokeEffect(const AEffect: TCEAEffect): TCEAResult;
  end;

implementation

uses
  Windows, FPJSON, JSONParser, cea_save_types;

const
  OpenReparsePointFlag = $00200000;
  MoveFileReplaceExisting = $00000001;

{ The replacement step uses MoveFileExW instead of ReplaceFileW: ReplaceFileW
  requires the target to be replaceable while this unit also holds a read lock
  on it, and it is not declared by the FPC Windows unit. The authoritative
  guarantee is the post-replace readback verification below, which re-reads the
  destination and compares its SHA-256 against the candidate hash. }
function MoveFileExW(const AExisting, ANewName: PWideChar;
  const AFlags: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'MoveFileExW';

function BytesToString(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then Move(ABytes[0], Result[1], Length(ABytes));
end;

function ValidBoundedId(const AValue, APrefix: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AValue) = Length(APrefix) + 32) and
    (Copy(AValue, 1, Length(APrefix)) = APrefix);
  if not Result then Exit;
  for I := Length(APrefix) + 1 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function ReparseFreeDirectory(const APath: string): Boolean;
var
  Current: string;
  Attr: DWORD;
begin
  Result := False;
  Current := ExpandFileName(APath);
  if (Length(Current) < 3) or (Current[2] <> ':') then Exit;
  while Length(Current) > 3 do
  begin
    Attr := GetFileAttributesW(PWideChar(UTF8Decode(Current)));
    if (Attr <> INVALID_FILE_ATTRIBUTES) and
       ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Exit;
    Current := ExcludeTrailingPathDelimiter(ExtractFileDir(Current));
  end;
  Result := True;
end;

type
  TDirectoryHandleArray = array of THandle;

procedure ReleasePinnedDirectories(var AHandles: TDirectoryHandleArray);
var
  I: Integer;
begin
  for I := High(AHandles) downto 0 do
    if AHandles[I] <> INVALID_HANDLE_VALUE then
      CloseHandle(AHandles[I]);
  SetLength(AHandles, 0);
end;

function PinSaveDirectories(const AFilePath: string;
  out AHandles: TDirectoryHandleArray): Boolean;
var
  ParentPath, CurrentPath: string;
  NextSlash: SizeInt;
  Remaining, Segment: string;
  Handle: THandle;
  Info: TByHandleFileInformation;
begin
  Result := False;
  SetLength(AHandles, 0);
  ParentPath := ExcludeTrailingPathDelimiter(ExtractFileDir(AFilePath));
  if (Length(ParentPath) < 3) or (ParentPath[2] <> ':') or
     (ParentPath[3] <> '\') then Exit;
  CurrentPath := Copy(ParentPath, 1, 3);
  Remaining := Copy(ParentPath, 4, MaxInt);
  repeat
    Handle := CreateFileW(PWideChar(UTF8Decode(CurrentPath)),
      FILE_READ_ATTRIBUTES, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or OpenReparsePointFlag, 0);
    if Handle = INVALID_HANDLE_VALUE then Exit(False);
    SetLength(AHandles, Length(AHandles) + 1);
    AHandles[High(AHandles)] := Handle;
    if not GetFileInformationByHandle(Handle, Info) or
       ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) or
       ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      Exit(False);
    if Remaining = '' then Break;
    NextSlash := Pos('\', Remaining);
    if NextSlash = 0 then
    begin
      Segment := Remaining;
      Remaining := '';
    end
    else
    begin
      Segment := Copy(Remaining, 1, NextSlash - 1);
      Delete(Remaining, 1, NextSlash);
    end;
    if (Segment = '') or (Segment = '.') or (Segment = '..') then
      Exit(False);
    CurrentPath := IncludeTrailingPathDelimiter(CurrentPath) + Segment;
  until False;
  Result := True;
end;

constructor TCEAWin32SaveEffectPort.Create(const AReader: ICEASaveReader;
  const AHasher: ICEAHasher; const ABackupDirectory: string;
  const ACodec: ICEASaveCodec);
begin
  inherited Create;
  FReader := AReader;
  FHasher := AHasher;
  FCodec := ACodec;
  FBackupDirectory := ABackupDirectory;
end;

function TCEAWin32SaveEffectPort.InvokeEffect(
  const AEffect: TCEAEffect): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Snapshot, Verified: TCEASaveSnapshot;
  Bytes: TBytes;
  Destination: string;
  Handle: THandle;
  Written: DWORD;
  EvidenceHash: string;
  PinnedDirectories: TDirectoryHandleArray;
begin
  SetLength(PinnedDirectories, 0);
  if AEffect.CapabilityId = 'save_edit' then
    Exit(ExecuteEdit(AEffect));
  if AEffect.CapabilityId = 'save_restore' then
    Exit(ExecuteRestore(AEffect));
  if (FReader = nil) or (FHasher = nil) or
     (AEffect.CapabilityId <> 'save_backup') or
     (AEffect.ResourceKind <> rkSaveFile) or
     (AEffect.State <> esExecuting) or
     (AEffect.ApprovalId = '') then
    Exit(TCEAResult.Error(rcUnauthorized, 'save_backup_effect_invalid', '{}'));
  Data := nil;
  try
    try
      Data := GetJSON(AEffect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'save_backup_request_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'save_backup_request_invalid', '{}'));
    Obj := TJSONObject(Data);
    FillChar(Snapshot, SizeOf(Snapshot), 0);
    Snapshot.Id := Obj.Get('snapshot_id', '');
    Snapshot.CanonicalPath := Obj.Get('source_path', '');
    Snapshot.FileIdentityId := Obj.Get('file_identity_id', '');
    Snapshot.Sha256 := Obj.Get('sha256', '');
    Snapshot.ByteCount := Obj.Get('byte_count', -1);
    if not ValidBoundedId(Snapshot.Id, 'snapshot-') or
       not ValidBoundedId(AEffect.Id, 'effect-') or
       (Snapshot.FileIdentityId = '') or
       (Snapshot.FileIdentityId <> AEffect.ResourceIdentityId) or
       (Snapshot.Sha256 = '') or (Snapshot.ByteCount < 0) or
       (Snapshot.ByteCount > 64 * 1024 * 1024) then
      Exit(TCEAResult.Error(rcUnauthorized, 'save_backup_binding_invalid', '{}'));
    Result := FReader.ReadVerified(Snapshot, Bytes);
    if Result.Failed then Exit;
    if not ReparseFreeDirectory(FBackupDirectory) or
       not ForceDirectories(FBackupDirectory) or
       not ReparseFreeDirectory(FBackupDirectory) then
      Exit(TCEAResult.Error(rcInternalError, 'backup_directory_failed', '{}'));
    Destination := IncludeTrailingPathDelimiter(FBackupDirectory) +
      Snapshot.Id + '.bak';
    if not PinSaveDirectories(Destination, PinnedDirectories) then
      Exit(TCEAResult.Error(rcConflict,
        'backup_parent_unsafe', '{}'));
    if SameText(Destination, Snapshot.CanonicalPath) then
      Exit(TCEAResult.Error(rcConflict, 'backup_equals_source', '{}'));
    Handle := CreateFileW(PWideChar(UTF8Decode(Destination)), GENERIC_WRITE,
      0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
    if Handle = INVALID_HANDLE_VALUE then
      Exit(TCEAResult.Error(rcConflict, 'backup_destination_exists', '{}'));
    try
      if Length(Bytes) > 0 then
      begin
        if not WriteFile(Handle, Bytes[0], Length(Bytes), Written, nil) or
           (Written <> DWORD(Length(Bytes))) then
          Exit(TCEAResult.Error(rcUnknownOutcome,
            'backup_write_uncertain', '{}'));
      end;
      if not FlushFileBuffers(Handle) then
        Exit(TCEAResult.Error(rcUnknownOutcome, 'backup_flush_uncertain', '{}'));
    finally
      CloseHandle(Handle);
    end;
    Result := FReader.Inspect(Destination, Verified);
    if Result.Failed or (Verified.Sha256 <> Snapshot.Sha256) or
       (Verified.ByteCount <> Snapshot.ByteCount) then
      Exit(TCEAResult.Error(rcUnknownOutcome, 'backup_readback_failed', '{}'));
    if not SetFileAttributesW(PWideChar(UTF8Decode(Destination)),
      FILE_ATTRIBUTE_READONLY) or
       ((GetFileAttributesW(PWideChar(UTF8Decode(Destination))) and
         FILE_ATTRIBUTE_READONLY) = 0) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'backup_protection_uncertain', '{}'));
    EvidenceHash := FHasher.HashUtf8(AEffect.Id + #0 +
      AEffect.RequestHash + #0 + Verified.Sha256);
    Result := TCEAResult.Ok('{"backup_id":"backup-' + Snapshot.Id +
      '","snapshot_id":"' + Snapshot.Id + '","sha256":"' +
      Verified.Sha256 + '","immutable":true}');
    Result.ReceiptId := 'receipt-' + Copy(EvidenceHash, 8, 32);
    Result.ProofId := 'proof-' + Copy(FHasher.HashUtf8(
      Result.ReceiptId + #0 + Verified.FileIdentityId), 8, 32);
    Result.DataJson := '{"schema_version":"1.0","backup_id":"backup-' + Snapshot.Id +
      '","snapshot_id":"' + Snapshot.Id + '","sha256":"' +
      Verified.Sha256 + '","immutable":true,"receipt_id":"' +
      Result.ReceiptId + '","proof_id":"' + Result.ProofId + '"}';
  finally
    ReleasePinnedDirectories(PinnedDirectories);
    Data.Free;
  end;
end;

function TCEAWin32SaveEffectPort.ExecuteRestore(
  const AEffect: TCEAEffect): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Current, Backup, Candidate, Readback: TCEASaveSnapshot;
  CurrentBytes, BackupBytes, LockedBytes: TBytes;
  BackupPath, CandidatePath, RootPath, IdentityText, EvidenceHash: string;
  LockHandle, CandidateHandle: THandle;
  Info: TByHandleFileInformation;
  FileSystemName: array[0..31] of WideChar;
  Written: DWORD;
  PinnedDirectories: TDirectoryHandleArray;
begin
  SetLength(PinnedDirectories, 0);
  if (FReader = nil) or (FHasher = nil) or
     (AEffect.ResourceKind <> rkSaveFile) or
     (AEffect.State <> esExecuting) or (AEffect.ApprovalId = '') or
     (AEffect.TargetClassification <> tcSinglePlayerOffline) then
    Exit(TCEAResult.Error(rcUnauthorized, 'save_restore_effect_invalid', '{}'));
  Data := nil;
  try
    try
      Data := GetJSON(AEffect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'save_restore_request_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'save_restore_request_invalid', '{}'));
    Obj := TJSONObject(Data);
    FillChar(Current, SizeOf(Current), 0);
    Current.Id := Obj.Get('current_snapshot_id', '');
    Current.CanonicalPath := Obj.Get('source_path', '');
    Current.FileIdentityId := Obj.Get('current_file_identity_id', '');
    Current.Sha256 := Obj.Get('current_sha256', '');
    Current.ByteCount := Obj.Get('current_byte_count', -1);
    if not ValidBoundedId(Current.Id, 'snapshot-') or
       not ValidBoundedId(AEffect.Id, 'effect-') or
       not ValidBoundedId(Obj.Get('backup_snapshot_id', ''), 'snapshot-') or
       (Current.CanonicalPath = '') or
       (Current.FileIdentityId <> AEffect.ResourceIdentityId) or
       (Current.Sha256 = '') or (Current.ByteCount < 0) or
       (Current.ByteCount > 64 * 1024 * 1024) then
      Exit(TCEAResult.Error(rcUnauthorized,
        'save_restore_binding_invalid', '{}'));
    if not PinSaveDirectories(Current.CanonicalPath, PinnedDirectories) then
      Exit(TCEAResult.Error(rcConflict,
        'save_restore_parent_unsafe', '{}'));
    Result := FReader.ReadVerified(Current, CurrentBytes);
    if Result.Failed then Exit;
    if not ReparseFreeDirectory(FBackupDirectory) then
      Exit(TCEAResult.Error(rcUnauthorized,
        'backup_directory_unsafe', '{}'));
    BackupPath := IncludeTrailingPathDelimiter(FBackupDirectory) +
      Obj.Get('backup_snapshot_id', '') + '.bak';
    Result := FReader.Inspect(BackupPath, Backup);
    if Result.Failed or
       (Backup.Sha256 <> Obj.Get('backup_sha256', '')) or
       (Backup.ByteCount > 64 * 1024 * 1024) then
      Exit(TCEAResult.Error(rcConflict, 'save_restore_backup_changed', '{}'));
    Result := FReader.ReadVerified(Backup, BackupBytes);
    if Result.Failed then Exit;
    RootPath := Copy(Current.CanonicalPath, 1, 3);
    FillChar(FileSystemName, SizeOf(FileSystemName), 0);
    if not GetVolumeInformationW(PWideChar(UTF8Decode(RootPath)), nil, 0,
      nil, nil, nil, @FileSystemName[0], Length(FileSystemName)) or
       (UnicodeString(PWideChar(@FileSystemName[0])) <> 'NTFS') then
      Exit(TCEAResult.Error(rcNotImplemented,
        'save_restore_requires_ntfs', '{}'));
    CandidatePath := Current.CanonicalPath + '.cea-restore-' +
      Copy(AEffect.Id, 8, 16);
    CandidateHandle := CreateFileW(PWideChar(UTF8Decode(CandidatePath)),
      GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
    if CandidateHandle = INVALID_HANDLE_VALUE then
      Exit(TCEAResult.Error(rcConflict,
        'save_restore_candidate_exists', '{}'));
    try
      Written := 0;
      if (Length(BackupBytes) > 0) and
         (not WriteFile(CandidateHandle, BackupBytes[0],
           Length(BackupBytes), Written, nil) or
          (Written <> DWORD(Length(BackupBytes)))) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_restore_candidate_write_uncertain', '{}'));
      if not FlushFileBuffers(CandidateHandle) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_restore_candidate_flush_uncertain', '{}'));
    finally
      CloseHandle(CandidateHandle);
    end;
    Result := FReader.Inspect(CandidatePath, Candidate);
    if Result.Failed or (Candidate.Sha256 <> Backup.Sha256) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_restore_candidate_invalid', '{}'));
    LockHandle := CreateFileW(PWideChar(UTF8Decode(Current.CanonicalPath)),
      GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if LockHandle = INVALID_HANDLE_VALUE then
      Exit(TCEAResult.Error(rcConflict, 'save_restore_source_busy', '{}'));
    try
      if not GetFileInformationByHandle(LockHandle, Info) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_restore_identity_unavailable', '{}'));
      IdentityText := 'file:' + IntToHex(Info.dwVolumeSerialNumber, 8) +
        ':' + IntToHex(Info.nFileIndexHigh, 8) +
        IntToHex(Info.nFileIndexLow, 8);
      if IdentityText <> Current.FileIdentityId then
        Exit(TCEAResult.Error(rcConflict,
          'save_restore_file_replaced', '{}'));
      Result := FReader.ReadVerified(Current, LockedBytes);
      if Result.Failed then Exit;
    finally
      { Released before the replacement, as in ExecuteEdit: the destination
        cannot be renamed over while this handle keeps it open. }
      CloseHandle(LockHandle);
    end;
    if not MoveFileExW(PWideChar(UTF8Decode(CandidatePath)),
      PWideChar(UTF8Decode(Current.CanonicalPath)),
      MoveFileReplaceExisting) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_restore_replace_uncertain', '{}'));
    Result := FReader.Inspect(Current.CanonicalPath, Readback);
    if Result.Failed or (Readback.Sha256 <> Backup.Sha256) or
       (Readback.ByteCount <> Backup.ByteCount) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_restore_readback_failed', '{}'));
    EvidenceHash := FHasher.HashUtf8(AEffect.Id + #0 +
      Current.Sha256 + #0 + Backup.Sha256);
    Result := TCEAResult.Ok('{}');
    Result.ReceiptId := 'receipt-' + Copy(EvidenceHash, 8, 32);
    Result.ProofId := 'proof-' + Copy(FHasher.HashUtf8(
      Result.ReceiptId + #0 + Readback.FileIdentityId), 8, 32);
    Result.DataJson := '{"before_sha256":"' + Current.Sha256 +
      '","after_sha256":"' + Readback.Sha256 +
      '","backup_effect_id":"' + Obj.Get('backup_effect_id', '') +
      '","receipt_id":"' + Result.ReceiptId +
      '","proof_id":"' + Result.ProofId + '"}';
  finally
    ReleasePinnedDirectories(PinnedDirectories);
    Data.Free;
  end;
end;

function TCEAWin32SaveEffectPort.ExecuteEdit(
  const AEffect: TCEAEffect): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Snapshot, Backup, Candidate, Readback: TCEASaveSnapshot;
  Descriptor: TCEASaveFormatDescriptor;
  Proposal: TCEASaveEditProposal;
  Original, Encoded, LockedBytes: TBytes;
  CandidatePath, BackupPath, RootPath, IdentityText: string;
  LockHandle, CandidateHandle: THandle;
  Info: TByHandleFileInformation;
  FileSystemName: array[0..31] of WideChar;
  Written: DWORD;
  CandidateHash, EvidenceHash: string;
  PinnedDirectories: TDirectoryHandleArray;
begin
  SetLength(PinnedDirectories, 0);
  if (FReader = nil) or (FHasher = nil) or (FCodec = nil) or
     (AEffect.ResourceKind <> rkSaveFile) or
     (AEffect.State <> esExecuting) or (AEffect.ApprovalId = '') or
     (AEffect.TargetClassification <> tcSinglePlayerOffline) then
    Exit(TCEAResult.Error(rcUnauthorized, 'save_edit_effect_invalid', '{}'));
  Data := nil;
  try
    try
      Data := GetJSON(AEffect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'save_edit_request_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'save_edit_request_invalid', '{}'));
    Obj := TJSONObject(Data);
    FillChar(Snapshot, SizeOf(Snapshot), 0);
    Snapshot.Id := Obj.Get('snapshot_id', '');
    Snapshot.CanonicalPath := Obj.Get('source_path', '');
    Snapshot.FileIdentityId := Obj.Get('file_identity_id', '');
    Snapshot.Sha256 := Obj.Get('sha256', '');
    Snapshot.ByteCount := Obj.Get('byte_count', -1);
    if not ValidBoundedId(Snapshot.Id, 'snapshot-') or
       not ValidBoundedId(AEffect.Id, 'effect-') or
       (Snapshot.CanonicalPath = '') or
       (Snapshot.FileIdentityId <> AEffect.ResourceIdentityId) or
       (Snapshot.Sha256 = '') or (Snapshot.ByteCount < 0) or
       (Snapshot.ByteCount > 64 * 1024 * 1024) or
       (Obj.Get('format_id', '') <> 'cea-fixture-save') or
       (Obj.Get('adapter_hash', '') <> 'builtin:cea-fixture-save-v1') then
      Exit(TCEAResult.Error(rcUnauthorized, 'save_edit_binding_invalid', '{}'));
    if not PinSaveDirectories(Snapshot.CanonicalPath,
      PinnedDirectories) then
      Exit(TCEAResult.Error(rcConflict, 'save_edit_parent_unsafe', '{}'));
    FillChar(Proposal, SizeOf(Proposal), 0);
    Proposal.Id := Obj.Get('proposal_id', '');
    Proposal.SnapshotId := Snapshot.Id;
    Proposal.ContentHash := Obj.Get('proposal_hash', '');
    Proposal.FieldPath := Obj.Get('field_path', '');
    Proposal.ExpectedJson := Obj.Get('expected_json', '');
    Proposal.NewJson := Obj.Get('new_json', '');
    if (Proposal.Id = '') or (Proposal.ContentHash <> FHasher.HashUtf8(
      Snapshot.Id + #0 + Snapshot.Sha256 + #0 +
      Obj.Get('adapter_hash', '') + #0 + Proposal.FieldPath + #0 +
      Proposal.ExpectedJson + #0 + Proposal.NewJson)) or
      (Proposal.Id <> 'proposal-' + Copy(Proposal.ContentHash, 8, 32)) then
      Exit(TCEAResult.Error(rcUnauthorized, 'save_edit_proposal_invalid', '{}'));
    Result := FReader.ReadVerified(Snapshot, Original);
    if Result.Failed then Exit;
    Result := FCodec.Probe(Original, Descriptor);
    if Result.Failed or (Descriptor.Id <> Obj.Get('format_id', '')) or
       (Descriptor.AdapterHash <> Obj.Get('adapter_hash', '')) then
      Exit(TCEAResult.Error(rcConflict, 'save_edit_format_changed', '{}'));
    if not ReparseFreeDirectory(FBackupDirectory) then
      Exit(TCEAResult.Error(rcUnauthorized,
        'backup_directory_unsafe', '{}'));
    BackupPath := IncludeTrailingPathDelimiter(FBackupDirectory) +
      Snapshot.Id + '.bak';
    Result := FReader.Inspect(BackupPath, Backup);
    if Result.Failed or (Backup.Sha256 <> Snapshot.Sha256) or
       (Backup.ByteCount <> Snapshot.ByteCount) then
      Exit(TCEAResult.Error(rcConflict, 'save_edit_backup_missing', '{}'));
    Result := FCodec.Encode(Original, Proposal, Encoded);
    if Result.Failed then Exit;
    Result := FCodec.Validate(Encoded);
    if Result.Failed then Exit;
    RootPath := Copy(Snapshot.CanonicalPath, 1, 3);
    FillChar(FileSystemName, SizeOf(FileSystemName), 0);
    if not GetVolumeInformationW(PWideChar(UTF8Decode(RootPath)), nil, 0,
      nil, nil, nil, @FileSystemName[0], Length(FileSystemName)) or
       (UnicodeString(PWideChar(@FileSystemName[0])) <> 'NTFS') then
      Exit(TCEAResult.Error(rcNotImplemented,
        'save_edit_requires_ntfs', '{}'));
    CandidatePath := Snapshot.CanonicalPath + '.cea-candidate-' +
      Copy(AEffect.Id, 8, 16);
    CandidateHandle := CreateFileW(PWideChar(UTF8Decode(CandidatePath)),
      GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
    if CandidateHandle = INVALID_HANDLE_VALUE then
      Exit(TCEAResult.Error(rcConflict, 'save_edit_candidate_exists', '{}'));
    try
      Written := 0;
      if (Length(Encoded) > 0) and
         (not WriteFile(CandidateHandle, Encoded[0], Length(Encoded),
           Written, nil) or (Written <> DWORD(Length(Encoded)))) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_edit_candidate_write_uncertain', '{}'));
      if not FlushFileBuffers(CandidateHandle) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_edit_candidate_flush_uncertain', '{}'));
    finally
      CloseHandle(CandidateHandle);
    end;
    CandidateHash := FHasher.HashUtf8(BytesToString(Encoded));
    if CandidateHash <> Obj.Get('candidate_sha256', '') then
      Exit(TCEAResult.Error(rcConflict,
        'save_edit_candidate_hash_changed', '{}'));
    Result := FReader.Inspect(CandidatePath, Candidate);
    if Result.Failed or (Candidate.Sha256 <> CandidateHash) or
       FCodec.Validate(Encoded).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_edit_candidate_invalid', '{}'));
    LockHandle := CreateFileW(PWideChar(UTF8Decode(Snapshot.CanonicalPath)),
      GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if LockHandle = INVALID_HANDLE_VALUE then
      Exit(TCEAResult.Error(rcConflict, 'save_edit_source_busy', '{}'));
    try
      if not GetFileInformationByHandle(LockHandle, Info) then
        Exit(TCEAResult.Error(rcUnknownOutcome,
          'save_edit_identity_unavailable', '{}'));
      IdentityText := 'file:' + IntToHex(Info.dwVolumeSerialNumber, 8) +
        ':' + IntToHex(Info.nFileIndexHigh, 8) +
        IntToHex(Info.nFileIndexLow, 8);
      if IdentityText <> Snapshot.FileIdentityId then
        Exit(TCEAResult.Error(rcConflict, 'save_edit_file_replaced', '{}'));
      Result := FReader.ReadVerified(Snapshot, LockedBytes);
      if Result.Failed then Exit;
    finally
      { The identity check and the pre-replace read must happen under the lock,
        but the lock itself must be released before the replacement: a
        destination held open cannot be renamed over. }
      CloseHandle(LockHandle);
    end;
    if not MoveFileExW(PWideChar(UTF8Decode(CandidatePath)),
      PWideChar(UTF8Decode(Snapshot.CanonicalPath)),
      MoveFileReplaceExisting) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_edit_replace_uncertain', '{}'));
    Result := FReader.Inspect(Snapshot.CanonicalPath, Readback);
    if Result.Failed or (Readback.Sha256 <> CandidateHash) or
       (Readback.ByteCount <> Length(Encoded)) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'save_edit_readback_failed', '{}'));
    EvidenceHash := FHasher.HashUtf8(AEffect.Id + #0 +
      Snapshot.Sha256 + #0 + CandidateHash);
    Result := TCEAResult.Ok('{}');
    Result.ReceiptId := 'receipt-' + Copy(EvidenceHash, 8, 32);
    Result.ProofId := 'proof-' + Copy(FHasher.HashUtf8(
      Result.ReceiptId + #0 + Readback.FileIdentityId), 8, 32);
    Result.DataJson := '{"schema_version":"1.0","snapshot_id":"' + Snapshot.Id +
      '","before_sha256":"' + Snapshot.Sha256 +
      '","after_sha256":"' + CandidateHash +
      '","field_path":"' + Proposal.FieldPath +
      '","receipt_id":"' + Result.ReceiptId +
      '","proof_id":"' + Result.ProofId + '"}';
  finally
    ReleasePinnedDirectories(PinnedDirectories);
    Data.Free;
  end;
end;

end.

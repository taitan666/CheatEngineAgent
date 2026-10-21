unit cea_win32_save_discovery;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, cea_results, cea_save_discovery_types;

type
  TCEADiscoveryCancelCheck = function: Boolean of object;

  TCEAWin32SaveDiscovery = class
  public
    function ValidateRoot(const APath: string; out ACanonical: string): TCEAResult;
    function Enumerate(const AScope: TCEADiscoveryScope;
      const ACancelled: TCEADiscoveryCancelCheck;
      out ACandidates: TCEASaveCandidateArray;
      out AComplete: Boolean; out AReason: string): TCEAResult;
    function ValidateCandidate(const AScope: TCEADiscoveryScope;
      const ACandidate: TCEASaveCandidate;
      out ACanonicalPath: string): TCEAResult;
  end;

implementation

const
  OpenReparsePointFlag = $00200000;
  CloudRecallOnOpen = $00040000;
  CloudRecallOnDataAccess = $00400000;

function FileIdentity(const AInfo: TByHandleFileInformation): string;
begin
  Result := 'file:' + IntToHex(AInfo.dwVolumeSerialNumber, 8) + ':' +
    IntToHex(AInfo.nFileIndexHigh, 8) +
    IntToHex(AInfo.nFileIndexLow, 8);
end;

function FileTimeAsDateTime(const AValue: TFileTime): TDateTime;
var
  LocalValue: TFileTime;
  SystemValue: TSystemTime;
begin
  Result := 0;
  if FileTimeToLocalFileTime(AValue, LocalValue) and
     FileTimeToSystemTime(LocalValue, SystemValue) then
    try
      Result := EncodeDate(SystemValue.wYear, SystemValue.wMonth,
        SystemValue.wDay) + EncodeTime(SystemValue.wHour,
        SystemValue.wMinute, SystemValue.wSecond,
        SystemValue.wMilliseconds);
    except
      Result := 0;
    end;
end;

function TCEAWin32SaveDiscovery.ValidateRoot(const APath: string;
  out ACanonical: string): TCEAResult;
var
  Current: string;
  Attr: DWORD;
begin
  ACanonical := '';
  Result := CEAResult(rcInvalidArgument, 'invalid discovery root');
  if (Trim(APath) = '') or (Pos('*', APath) <> 0) or
     (Pos('?', APath) <> 0) or (Copy(APath, 1, 2) = '\\') then Exit;
  Current := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  if (Length(Current) <= 3) or (Current[2] <> ':') or
     (Current[3] <> '\') then Exit;
  if GetDriveTypeW(PWideChar(UTF8Decode(Copy(Current, 1, 3)))) <> DRIVE_FIXED then Exit;
  ACanonical := Current;
  while Length(Current) > 3 do
  begin
    Attr := GetFileAttributesW(PWideChar(UTF8Decode(Current)));
    if (Attr = INVALID_FILE_ATTRIBUTES) or
       ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Exit;
    Current := ExcludeTrailingPathDelimiter(ExtractFileDir(Current));
  end;
  Attr := GetFileAttributesW(PWideChar(UTF8Decode(ACanonical)));
  if (Attr = INVALID_FILE_ATTRIBUTES) or
     ((Attr and FILE_ATTRIBUTE_DIRECTORY) = 0) then Exit;
  Result := TCEAResult.Ok('{}');
end;

function TCEAWin32SaveDiscovery.Enumerate(const AScope: TCEADiscoveryScope;
  const ACancelled: TCEADiscoveryCancelCheck;
  out ACandidates: TCEASaveCandidateArray;
  out AComplete: Boolean; out AReason: string): TCEAResult;
var
  Started: QWord;
  Canonical: string;
  function Walk(const ADir, ARelative: string; ADepth: Integer): Boolean;
  var
    FindData: TWin32FindDataW;
    FindHandle: THandle;
    ChildPath, Relative, EntryName: string;
    Attr: DWORD;
    Handle, FileHandle: THandle;
    Info: TByHandleFileInformation;
    Candidate: TCEASaveCandidate;
    NewId: TGUID;
  begin
    Result := False;
    if ACancelled() then begin AReason := 'cancelled'; Exit; end;
    if QWord(GetTickCount64) - Started >= AScope.Budget.MaxDurationMs then
      begin AReason := 'time_limit'; Exit; end;
    Handle := CreateFileW(PWideChar(UTF8Decode(ADir)), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS or OpenReparsePointFlag, 0);
    if Handle = INVALID_HANDLE_VALUE then
      begin AReason := 'directory_unavailable'; Exit; end;
    try
      if (not GetFileInformationByHandle(Handle, Info)) or
         ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) or
         ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0) then
        begin AReason := 'directory_changed'; Exit; end;
      FindHandle := FindFirstFileW(PWideChar(UTF8Decode(
        IncludeTrailingPathDelimiter(ADir) + '*')), FindData);
      if FindHandle = INVALID_HANDLE_VALUE then
        begin AReason := 'directory_unavailable'; Exit; end;
      try
        repeat
          EntryName := UTF8Encode(WideString(FindData.cFileName));
          if (EntryName = '.') or (EntryName = '..') then Continue;
          if ACancelled() then begin AReason := 'cancelled'; Exit; end;
          if QWord(GetTickCount64) - Started >= AScope.Budget.MaxDurationMs then
            begin AReason := 'time_limit'; Exit; end;
          ChildPath := IncludeTrailingPathDelimiter(ADir) + EntryName;
          Attr := GetFileAttributesW(PWideChar(UTF8Decode(ChildPath)));
          if Attr = INVALID_FILE_ATTRIBUTES then
            begin AReason := 'entry_changed'; Exit; end;
          if (Attr and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_OFFLINE or CloudRecallOnOpen or
              CloudRecallOnDataAccess)) <> 0 then
            begin AReason := 'skipped_reparse_or_cloud'; Continue; end;
          Relative := ARelative + EntryName;
          if (Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          begin
            if ADepth >= AScope.Budget.MaxDepth then
              AReason := 'depth_limit'
            else if not Walk(ChildPath, Relative + '\', ADepth + 1) then Exit;
          end
          else
          begin
            if Length(ACandidates) >= AScope.Budget.MaxFiles then
              begin AReason := 'file_limit'; Exit; end;
            FileHandle := CreateFileW(PWideChar(UTF8Decode(ChildPath)),
              FILE_READ_ATTRIBUTES,
              FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
              nil, OPEN_EXISTING, OpenReparsePointFlag, 0);
            if FileHandle = INVALID_HANDLE_VALUE then
            begin
              AReason := 'entry_unavailable';
              Continue;
            end;
            try
              if not GetFileInformationByHandle(FileHandle, Info) or
                 ((Info.dwFileAttributes and
                   (FILE_ATTRIBUTE_REPARSE_POINT or
                    FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_OFFLINE or
                    CloudRecallOnOpen or CloudRecallOnDataAccess)) <> 0) then
              begin
                AReason := 'entry_changed';
                Continue;
              end;
            finally
              CloseHandle(FileHandle);
            end;
            FillChar(Candidate, SizeOf(Candidate), 0);
            CreateGUID(NewId);
            Candidate.Id := GUIDToString(NewId);
            Candidate.ScopeId := AScope.Id;
            Candidate.RelativePath := Relative;
            Candidate.ByteCount := (Int64(Info.nFileSizeHigh) shl 32) or
              Info.nFileSizeLow;
            Candidate.ModifiedAt := FileTimeAsDateTime(Info.ftLastWriteTime);
            Candidate.FileIdentityId := FileIdentity(Info);
            Candidate.LastWriteHigh := Info.ftLastWriteTime.dwHighDateTime;
            Candidate.LastWriteLow := Info.ftLastWriteTime.dwLowDateTime;
            Candidate.SourceRuleVersion := 'user_directory:v1';
            Candidate.InspectionRequired := True;
            SetLength(ACandidates, Length(ACandidates) + 1);
            ACandidates[High(ACandidates)] := Candidate;
            if Length(ACandidates) >= AScope.Budget.MaxFiles then
              begin AReason := 'file_limit'; Exit; end;
          end;
        until not FindNextFileW(FindHandle, FindData);
      finally
        Windows.FindClose(FindHandle);
      end;
    finally
      CloseHandle(Handle);
    end;
    Result := True;
  end;
begin
  SetLength(ACandidates, 0);
  AReason := '';
  AComplete := False;
  Result := ValidateRoot(AScope.RootPath, Canonical);
  if Result.Failed then Exit;
  Started := GetTickCount64;
  AComplete := Walk(Canonical, '', 0);
  if AReason <> '' then AComplete := False;
  Result := TCEAResult.Ok('{}');
end;

function TCEAWin32SaveDiscovery.ValidateCandidate(
  const AScope: TCEADiscoveryScope;
  const ACandidate: TCEASaveCandidate;
  out ACanonicalPath: string): TCEAResult;
var
  CanonicalRoot, CanonicalParent, FullPath: string;
  Handle: THandle;
  Info: TByHandleFileInformation;
  FileSize: Int64;
begin
  ACanonicalPath := '';
  if (ACandidate.ScopeId <> AScope.Id) or
     (ACandidate.RelativePath = '') or
     (Pos(':', ACandidate.RelativePath) > 0) or
     (Pos('..', ACandidate.RelativePath) > 0) or
     (Copy(ACandidate.RelativePath, 1, 1) = '\') then
    Exit(TCEAResult.Error(rcConflict,
      'save_candidate_path_invalid', '{}'));
  Result := ValidateRoot(AScope.RootPath, CanonicalRoot);
  if Result.Failed then Exit;
  FullPath := IncludeTrailingPathDelimiter(CanonicalRoot) +
    ACandidate.RelativePath;
  Result := ValidateRoot(ExtractFileDir(FullPath), CanonicalParent);
  if Result.Failed then Exit;
  if not SameText(CanonicalParent, CanonicalRoot) and
     (Pos(LowerCase(IncludeTrailingPathDelimiter(CanonicalRoot)),
       LowerCase(IncludeTrailingPathDelimiter(CanonicalParent))) <> 1) then
    Exit(TCEAResult.Error(rcConflict,
      'save_candidate_outside_scope', '{}'));
  Handle := CreateFileW(PWideChar(UTF8Decode(FullPath)),
    FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, OpenReparsePointFlag, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcConflict,
      'save_candidate_unavailable', '{}'));
  try
    if not GetFileInformationByHandle(Handle, Info) then
      Exit(TCEAResult.Error(rcConflict,
        'save_candidate_identity_failed', '{}'));
    FileSize := (Int64(Info.nFileSizeHigh) shl 32) or
      Info.nFileSizeLow;
    if ((Info.dwFileAttributes and
         (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY or
          FILE_ATTRIBUTE_OFFLINE or CloudRecallOnOpen or
          CloudRecallOnDataAccess)) <> 0) or
       (FileIdentity(Info) <> ACandidate.FileIdentityId) or
       (FileSize <> ACandidate.ByteCount) or
       (Info.ftLastWriteTime.dwHighDateTime <>
         ACandidate.LastWriteHigh) or
       (Info.ftLastWriteTime.dwLowDateTime <>
         ACandidate.LastWriteLow) then
      Exit(TCEAResult.Error(rcConflict,
        'save_candidate_stale', '{}'));
  finally
    CloseHandle(Handle);
  end;
  ACanonicalPath := FullPath;
  Result := TCEAResult.Ok('{}');
end;

end.

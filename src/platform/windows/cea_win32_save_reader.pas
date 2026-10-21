unit cea_win32_save_reader;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, Windows, cea_results, cea_save_types, cea_save_ports;

type
  TCEAWin32SaveReader = class(TObject, ICEASaveReader)
  private
    function ReadBounded(const APath: string; out ASnapshot: TCEASaveSnapshot;
      out ABytes: TBytes): TCEAResult;
  public
    function Inspect(const APath: string;
      out ASnapshot: TCEASaveSnapshot): TCEAResult;
    function ReadVerified(const ASnapshot: TCEASaveSnapshot;
      out ABytes: TBytes): TCEAResult;
  end;

implementation

uses
  cea_windows_sha256;

const
  MaxSaveBytes = 64 * 1024 * 1024;
  OpenReparsePointFlag = $00200000;

function GetFinalPathNameByHandleW(const AHandle: THandle;
  ABuffer: PWideChar; const ABufferLength, AFlags: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'GetFinalPathNameByHandleW';

function GetLongPathNameW(AShortPath, ALongPath: PWideChar;
  const ABufferLength: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'GetLongPathNameW';

function HandleMatchesSelectedPath(const AHandle: THandle;
  const ASelectedPath: string): Boolean;
var
  Buffer: array[0..32767] of WideChar;
  LongBuffer: array[0..32767] of WideChar;
  Count: DWORD;
  FinalPath, SelectedLongPath: string;
begin
  Result := False;
  FillChar(Buffer, SizeOf(Buffer), 0);
  Count := GetFinalPathNameByHandleW(AHandle, @Buffer[0],
    Length(Buffer), 0);
  if (Count = 0) or (Count >= DWORD(Length(Buffer))) then Exit;
  FinalPath := UTF8Encode(UnicodeString(PWideChar(@Buffer[0])));
  if Copy(FinalPath, 1, 4) = '\\?\' then
    Delete(FinalPath, 1, 4);
  FillChar(LongBuffer, SizeOf(LongBuffer), 0);
  Count := GetLongPathNameW(PWideChar(UTF8Decode(ASelectedPath)),
    @LongBuffer[0], Length(LongBuffer));
  if (Count = 0) or (Count >= DWORD(Length(LongBuffer))) then Exit;
  SelectedLongPath := UTF8Encode(
    UnicodeString(PWideChar(@LongBuffer[0])));
  Result := SameText(ExpandFileName(FinalPath),
    ExpandFileName(SelectedLongPath));
end;

function SafeAbsoluteFilePath(const APath: string; out AFull: string): Boolean;
var
  Current: string;
  Attr: DWORD;
begin
  Result := False;
  AFull := '';
  if (Trim(APath) = '') or (Pos('*', APath) > 0) or
     (Pos('?', APath) > 0) then Exit;
  AFull := ExpandFileName(APath);
  if (Length(AFull) < 4) or (AFull[2] <> ':') or
     (AFull[3] <> '\') then Exit;
  Current := AFull;
  while Length(Current) > 3 do
  begin
    Attr := GetFileAttributesW(PWideChar(UTF8Decode(Current)));
    if (Attr = INVALID_FILE_ATTRIBUTES) or
       ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then Exit;
    Current := ExcludeTrailingPathDelimiter(ExtractFileDir(Current));
  end;
  Attr := GetFileAttributesW(PWideChar(UTF8Decode(AFull)));
  Result := (Attr <> INVALID_FILE_ATTRIBUTES) and
    ((Attr and FILE_ATTRIBUTE_DIRECTORY) = 0) and
    ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) = 0);
end;

function SameInfo(const A, B: TByHandleFileInformation): Boolean;
begin
  Result := (A.dwVolumeSerialNumber = B.dwVolumeSerialNumber) and
    (A.nFileIndexHigh = B.nFileIndexHigh) and
    (A.nFileIndexLow = B.nFileIndexLow) and
    (A.nFileSizeHigh = B.nFileSizeHigh) and
    (A.nFileSizeLow = B.nFileSizeLow) and
    (A.ftLastWriteTime.dwHighDateTime = B.ftLastWriteTime.dwHighDateTime) and
    (A.ftLastWriteTime.dwLowDateTime = B.ftLastWriteTime.dwLowDateTime);
end;

function TCEAWin32SaveReader.ReadBounded(const APath: string;
  out ASnapshot: TCEASaveSnapshot; out ABytes: TBytes): TCEAResult;
var
  FullPath, Raw: string;
  Handle: THandle;
  BeforeInfo, AfterInfo: TByHandleFileInformation;
  ByteCount: Int64;
  Done, Got: DWORD;
  Hasher: TCEAWindowsSha256;
begin
  FillChar(ASnapshot, SizeOf(ASnapshot), 0);
  SetLength(ABytes, 0);
  if not SafeAbsoluteFilePath(APath, FullPath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'save_path_unsafe', '{}'));
  Handle := CreateFileW(PWideChar(UTF8Decode(FullPath)),
    GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    OpenReparsePointFlag or FILE_FLAG_SEQUENTIAL_SCAN, 0);
  if Handle = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcConflict, 'save_open_failed', '{}'));
  try
    if not GetFileInformationByHandle(Handle, BeforeInfo) then
      Exit(TCEAResult.Error(rcUnknownOutcome, 'save_identity_failed', '{}'));
    if not HandleMatchesSelectedPath(Handle, FullPath) then
      Exit(TCEAResult.Error(rcConflict,
        'save_final_path_changed', '{}'));
    if (BeforeInfo.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      Exit(TCEAResult.Error(rcInvalidArgument, 'save_reparse_denied', '{}'));
    ByteCount := (Int64(BeforeInfo.nFileSizeHigh) shl 32) or
      BeforeInfo.nFileSizeLow;
    if ByteCount > MaxSaveBytes then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'save_size_limit', '{}'));
    SetLength(Raw, ByteCount);
    Done := 0;
    while Done < DWORD(ByteCount) do
    begin
      Got := 0;
      if not ReadFile(Handle, Raw[Done + 1],
        DWORD(ByteCount) - Done, Got, nil) then
        Exit(TCEAResult.Error(rcUnknownOutcome, 'save_read_failed', '{}'));
      if Got = 0 then
        Exit(TCEAResult.Error(rcConflict, 'save_changed_during_read', '{}'));
      Inc(Done, Got);
    end;
    if not GetFileInformationByHandle(Handle, AfterInfo) or
       not SameInfo(BeforeInfo, AfterInfo) then
      Exit(TCEAResult.Error(rcConflict, 'save_changed_during_read', '{}'));
    Hasher := TCEAWindowsSha256.Create;
    try
      ASnapshot.Sha256 := Hasher.HashUtf8(Raw);
    finally
      Hasher.Free;
    end;
    ASnapshot.CanonicalPath := FullPath;
    ASnapshot.FileIdentityId := 'file:' +
      IntToHex(BeforeInfo.dwVolumeSerialNumber, 8) + ':' +
      IntToHex(BeforeInfo.nFileIndexHigh, 8) +
      IntToHex(BeforeInfo.nFileIndexLow, 8);
    ASnapshot.ByteCount := ByteCount;
    ASnapshot.ReadCoverage := ByteCount;
    Hasher := TCEAWindowsSha256.Create;
    try
      ASnapshot.Id := 'snapshot-' + Copy(Hasher.HashUtf8(
        ASnapshot.FileIdentityId + #0 + ASnapshot.Sha256), 8, 32);
    finally
      Hasher.Free;
    end;
    ASnapshot.Editable := False;
    SetLength(ABytes, ByteCount);
    if ByteCount > 0 then Move(Raw[1], ABytes[0], ByteCount);
    Result := TCEAResult.Ok('{}');
  finally
    CloseHandle(Handle);
  end;
end;

function TCEAWin32SaveReader.Inspect(const APath: string;
  out ASnapshot: TCEASaveSnapshot): TCEAResult;
var
  Bytes: TBytes;
begin
  Result := ReadBounded(APath, ASnapshot, Bytes);
end;

function TCEAWin32SaveReader.ReadVerified(const ASnapshot: TCEASaveSnapshot;
  out ABytes: TBytes): TCEAResult;
var
  Current: TCEASaveSnapshot;
begin
  SetLength(ABytes, 0);
  if (ASnapshot.CanonicalPath = '') or (ASnapshot.FileIdentityId = '') or
     (ASnapshot.Sha256 = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'snapshot_invalid', '{}'));
  Result := ReadBounded(ASnapshot.CanonicalPath, Current, ABytes);
  if Result.Failed then Exit;
  if (Current.FileIdentityId <> ASnapshot.FileIdentityId) or
     (Current.Sha256 <> ASnapshot.Sha256) or
     (Current.ByteCount <> ASnapshot.ByteCount) then
  begin
    SetLength(ABytes, 0);
    Exit(TCEAResult.Error(rcConflict, 'save_snapshot_stale', '{}'));
  end;
end;

end.

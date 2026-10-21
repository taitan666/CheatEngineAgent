program diag_replace3;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  GENERIC_READ = $80000000;
  GENERIC_WRITE = $40000000;
  CREATE_NEW = 1;
  OPEN_EXISTING = 3;
  FILE_ATTRIBUTE_NORMAL = $00000080;
  MOVEFILE_REPLACE_EXISTING = $00000001;
  INVALID_HANDLE_VALUE = THandle(-1);
  SHARE_READ = $00000001;
  SHARE_WRITE = $00000002;
  SHARE_DELETE = $00000004;

function MoveFileExW(lpExistingFileName, lpNewFileName: PWideChar;
  dwFlags: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'MoveFileExW';

function MakeFile(const APath, AText: string): Boolean;
var
  Handle: THandle;
  Written: DWORD;
begin
  SysUtils.DeleteFile(APath);
  Handle := CreateFileW(PWideChar(UTF8Decode(APath)), GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then Exit(False);
  WriteFile(Handle, AText[1], Length(AText), Written, nil);
  FlushFileBuffers(Handle);
  CloseHandle(Handle);
  Result := True;
end;

procedure TryShares(const ALabel, ADir: string; const AShare: DWORD);
var
  Dest, Cand: string;
  LockHandle: THandle;
  Ok: Boolean;
begin
  Dest := IncludeTrailingPathDelimiter(ADir) + 's-' + ALabel + '.sav';
  Cand := IncludeTrailingPathDelimiter(ADir) + 'sc-' + ALabel + '.sav';
  if not MakeFile(Dest, 'original-content-0123456789') then Exit;
  if not MakeFile(Cand, 'replacement-content-9876543210') then Exit;
  LockHandle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    AShare, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  SetLastError(0);
  Ok := MoveFileExW(PWideChar(UTF8Decode(Cand)),
    PWideChar(UTF8Decode(Dest)), MOVEFILE_REPLACE_EXISTING);
  WriteLn(ALabel, ': shares=0x', IntToHex(AShare, 2),
    ' lockValid=', LockHandle <> INVALID_HANDLE_VALUE,
    ' moveOk=', Ok, ' err=', GetLastError);
  CloseHandle(LockHandle);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
end;

var
  WorkDir: string;
begin
  WorkDir := ExpandFileName('.');
  TryShares('readonly', WorkDir, SHARE_READ or SHARE_DELETE);
  TryShares('all', WorkDir, SHARE_READ or SHARE_WRITE or SHARE_DELETE);
  TryShares('deleteonly', WorkDir, SHARE_DELETE);
end.

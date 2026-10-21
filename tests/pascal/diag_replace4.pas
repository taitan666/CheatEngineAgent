program diag_replace4;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  GENERIC_READ = $80000000;
  GENERIC_WRITE = $40000000;
  DELETE = $00010000;
  CREATE_NEW = 1;
  OPEN_EXISTING = 3;
  FILE_ATTRIBUTE_NORMAL = $00000080;
  MOVEFILE_REPLACE_EXISTING = $00000001;
  INVALID_HANDLE_VALUE = THandle(-1);

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

procedure CaseA(const ALabel, ADir: string; const AAccess, AShare: DWORD);
var
  Dest, Cand: string;
  LockHandle: THandle;
  Ok: Boolean;
begin
  Dest := IncludeTrailingPathDelimiter(ADir) + 'a-' + ALabel + '.sav';
  Cand := IncludeTrailingPathDelimiter(ADir) + 'ac-' + ALabel + '.sav';
  if not MakeFile(Dest, 'original-content-0123456789') then Exit;
  if not MakeFile(Cand, 'replacement-content-9876543210') then Exit;
  LockHandle := CreateFileW(PWideChar(UTF8Decode(Dest)), AAccess,
    AShare, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  SetLastError(0);
  Ok := MoveFileExW(PWideChar(UTF8Decode(Cand)),
    PWideChar(UTF8Decode(Dest)), MOVEFILE_REPLACE_EXISTING);
  WriteLn(ALabel, ': access=0x', IntToHex(AAccess, 4),
    ' share=0x', IntToHex(AShare, 2),
    ' lockValid=', LockHandle <> INVALID_HANDLE_VALUE,
    ' moveOk=', Ok, ' err=', GetLastError);
  CloseHandle(LockHandle);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
end;

procedure CaseCloseFirst(const ALabel, ADir: string);
var
  Dest, Cand: string;
  LockHandle: THandle;
  Ok: Boolean;
begin
  Dest := IncludeTrailingPathDelimiter(ADir) + 'c-' + ALabel + '.sav';
  Cand := IncludeTrailingPathDelimiter(ADir) + 'cc-' + ALabel + '.sav';
  if not MakeFile(Dest, 'original-content-0123456789') then Exit;
  if not MakeFile(Cand, 'replacement-content-9876543210') then Exit;
  LockHandle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    $00000001 or $00000004, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  CloseHandle(LockHandle);
  SetLastError(0);
  Ok := MoveFileExW(PWideChar(UTF8Decode(Cand)),
    PWideChar(UTF8Decode(Dest)), MOVEFILE_REPLACE_EXISTING);
  WriteLn(ALabel, ': lock closed first moveOk=', Ok, ' err=', GetLastError);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
end;

var
  WorkDir: string;
begin
  WorkDir := ExpandFileName('.');
  CaseA('readonly', WorkDir, GENERIC_READ, $00000001 or $00000004);
  CaseA('read-delete', WorkDir, GENERIC_READ or DELETE,
    $00000001 or $00000002 or $00000004);
  CaseA('read-delete-shareless', WorkDir, GENERIC_READ or DELETE, 0);
  CaseCloseFirst('closed', WorkDir);
end.

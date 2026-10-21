program diag_replace2;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  GENERIC_READ = $80000000;
  GENERIC_WRITE = $40000000;
  CREATE_NEW = 1;
  OPEN_EXISTING = 3;
  FILE_ATTRIBUTE_NORMAL = $00000080;
  FILE_FLAG_WRITE_THROUGH = $80000000;
  MOVEFILE_REPLACE_EXISTING = $00000001;
  INVALID_HANDLE_VALUE = THandle(-1);
  REPLACEFILE_WRITE_THROUGH = $00000001;

function ReplaceFileW(lpReplacedFileName, lpReplacementFileName,
  lpBackupFileName: PWideChar; dwReplaceFlags: DWORD;
  lpExclude, lpReserved: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'ReplaceFileW';

function MoveFileExW(lpExistingFileName, lpNewFileName: PWideChar;
  dwFlags: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'MoveFileExW';

function MakeFile(const APath, AText: string;
  const AFlags: Cardinal): Boolean;
var
  Handle: THandle;
  Written: DWORD;
begin
  Handle := CreateFileW(PWideChar(UTF8Decode(APath)), GENERIC_WRITE, 0, nil,
    CREATE_NEW, AFlags, 0);
  if Handle = INVALID_HANDLE_VALUE then
  begin
    WriteLn('  create failed err=', GetLastError);
    Exit(False);
  end;
  WriteFile(Handle, AText[1], Length(AText), Written, nil);
  FlushFileBuffers(Handle);
  CloseHandle(Handle);
  Result := True;
end;

procedure Trial(const ALabel, ADir: string; const ACandFlags: Cardinal;
  const AReplaceFlags: DWORD);
var
  Dest, Cand: string;
  Ok: Boolean;
begin
  Dest := IncludeTrailingPathDelimiter(ADir) + 'target-' + ALabel + '.sav';
  Cand := IncludeTrailingPathDelimiter(ADir) + 'cand-' + ALabel + '.sav';
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
  if not MakeFile(Dest, 'original-content-0123456789',
    FILE_ATTRIBUTE_NORMAL) then Exit;
  if not MakeFile(Cand, 'replacement-content-9876543210',
    ACandFlags) then Exit;
  SetLastError(0);
  Ok := ReplaceFileW(PWideChar(UTF8Decode(Dest)),
    PWideChar(UTF8Decode(Cand)), nil, AReplaceFlags, nil, nil);
  WriteLn(ALabel, ': ReplaceFileW ok=', Ok, ' err=', GetLastError);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);

  MakeFile(Dest, 'original-content-0123456789', FILE_ATTRIBUTE_NORMAL);
  MakeFile(Cand, 'replacement-content-9876543210', ACandFlags);
  SetLastError(0);
  Ok := MoveFileExW(PWideChar(UTF8Decode(Cand)),
    PWideChar(UTF8Decode(Dest)), MOVEFILE_REPLACE_EXISTING);
  WriteLn(ALabel, ': MoveFileExW  ok=', Ok, ' err=', GetLastError);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
end;

procedure TrialLocked(const ALabel, ADir: string);
var
  Dest, Cand: string;
  Ok: Boolean;
  LockHandle: THandle;
begin
  Dest := IncludeTrailingPathDelimiter(ADir) + 'ltarget-' + ALabel + '.sav';
  Cand := IncludeTrailingPathDelimiter(ADir) + 'lcand-' + ALabel + '.sav';
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
  if not MakeFile(Dest, 'original-content-0123456789',
    FILE_ATTRIBUTE_NORMAL) then Exit;
  if not MakeFile(Cand, 'replacement-content-9876543210',
    FILE_ATTRIBUTE_NORMAL) then Exit;
  LockHandle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    $00000001 or $00000004, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn(ALabel, ': lock handle valid=', LockHandle <> INVALID_HANDLE_VALUE);
  SetLastError(0);
  Ok := MoveFileExW(PWideChar(UTF8Decode(Cand)),
    PWideChar(UTF8Decode(Dest)), MOVEFILE_REPLACE_EXISTING);
  WriteLn(ALabel, ': MoveFileExW with lock held ok=', Ok,
    ' err=', GetLastError);
  CloseHandle(LockHandle);
  SysUtils.DeleteFile(Dest);
  SysUtils.DeleteFile(Cand);
end;

var
  TempDir, WorkDir: string;
begin
  TempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-diag-replace2-' + IntToStr(GetProcessID);
  ForceDirectories(TempDir);
  WorkDir := ExpandFileName('.');
  WriteLn('tempdir=', TempDir);
  WriteLn('workdir=', WorkDir);

  WriteLn('--- temp dir, normal flags ---');
  Trial('temp-normal', TempDir, FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('--- temp dir, write-through candidate ---');
  Trial('temp-wt', TempDir, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH,
    0);
  WriteLn('--- temp dir, replace write-through flag ---');
  Trial('temp-rwt', TempDir, FILE_ATTRIBUTE_NORMAL, REPLACEFILE_WRITE_THROUGH);
  WriteLn('--- workspace dir ---');
  Trial('work', WorkDir, FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('--- MoveFileExW with lock held ---');
  TrialLocked('locked', WorkDir);
end.

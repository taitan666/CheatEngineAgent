program diag_replace;

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
  FILE_SHARE_READ = $00000001;
  FILE_SHARE_WRITE = $00000002;
  FILE_SHARE_DELETE = $00000004;
  INVALID_HANDLE_VALUE = THandle(-1);

function ReplaceFileW(lpReplacedFileName, lpReplacementFileName,
  lpBackupFileName: PWideChar; dwReplaceFlags: DWORD;
  lpExclude, lpReserved: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'ReplaceFileW';

var
  Root, Dest, Cand, Text: string;
  Handle: THandle;
  Written: DWORD;
  Ok: Boolean;
begin
  Root := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-diag-replace-' + IntToStr(GetProcessID);
  ForceDirectories(Root);
  Dest := IncludeTrailingPathDelimiter(Root) + 'target.sav';
  Cand := IncludeTrailingPathDelimiter(Root) + 'candidate.sav';

  Text := 'original-content-0123456789';
  Handle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('create dest handle valid=', Handle <> INVALID_HANDLE_VALUE,
    ' err=', GetLastError);
  WriteFile(Handle, Text[1], Length(Text), Written, nil);
  CloseHandle(Handle);

  Text := 'replacement-content-9876543210';
  Handle := CreateFileW(PWideChar(UTF8Decode(Cand)), GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
  WriteLn('create cand handle valid=', Handle <> INVALID_HANDLE_VALUE,
    ' err=', GetLastError);
  WriteFile(Handle, Text[1], Length(Text), Written, nil);
  FlushFileBuffers(Handle);
  CloseHandle(Handle);

  WriteLn('dest exists=', FileExists(Dest), ' cand exists=', FileExists(Cand));

  Handle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('lock handle valid=', Handle <> INVALID_HANDLE_VALUE,
    ' err=', GetLastError);
  CloseHandle(Handle);

  SetLastError(0);
  Ok := ReplaceFileW(PWideChar(UTF8Decode(Dest)), PWideChar(UTF8Decode(Cand)),
    nil, 0, nil, nil);
  WriteLn('ReplaceFileW (no lock held) ok=', Ok, ' err=', GetLastError);

  SetLastError(0);
  Ok := ReplaceFileW(PWideChar(UTF8Decode(Dest)), PWideChar(UTF8Decode(Cand)),
    nil, 0, nil, nil);
  WriteLn('ReplaceFileW (2nd, cand gone) ok=', Ok, ' err=', GetLastError);

  Handle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('lock handle valid=', Handle <> INVALID_HANDLE_VALUE);
  CloseHandle(Handle);
  WriteLn('after: cand exists=', FileExists(Cand));
  Handle := CreateFileW(PWideChar(UTF8Decode(Dest)), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  WriteLn('dest handle valid=', Handle <> INVALID_HANDLE_VALUE);
  Written := GetFileSize(Handle, nil);
  CloseHandle(Handle);
  WriteLn('dest size=', Written);
end.

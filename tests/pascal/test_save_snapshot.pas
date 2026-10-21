program test_save_snapshot;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, cea_results, cea_save_types,
  cea_win32_save_reader, cea_save_service;

var
  DirectoryPath, SavePath, OversizePath: string;
  Stream: TFileStream;
  Bytes: array[0..15] of Byte;
  Reader: TCEAWin32SaveReader;
  Service: TCEASaveService;
  Snapshot: TCEASaveSnapshot;
  R: TCEAResult;
  Readback: TBytes;
  I: Integer;
begin
  DirectoryPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-save-test-' + IntToStr(GetProcessID);
  ForceDirectories(DirectoryPath);
  SavePath := IncludeTrailingPathDelimiter(DirectoryPath) + 'slot.sav';
  Stream := TFileStream.Create(SavePath, fmCreate);
  try
    for I := Low(Bytes) to High(Bytes) do Bytes[I] := I;
    Stream.WriteBuffer(Bytes, SizeOf(Bytes));
  finally
    Stream.Free;
  end;
  Reader := TCEAWin32SaveReader.Create;
  Service := TCEASaveService.Create(Reader);
  try
    R := Service.Inspect('save-task', SavePath, Snapshot);
    Assert(R.Code = rcOk, 'ordinary file inspect');
    Assert(Snapshot.ByteCount = 16);
    Assert(Snapshot.ReadCoverage = 16);
    Assert(Copy(Snapshot.Sha256, 1, 7) = 'sha256:');
    Assert(Snapshot.FileIdentityId <> '');
    Assert(not Snapshot.Editable, 'unknown format never editable');
    Stream := TFileStream.Create(SavePath, fmOpenWrite);
    try
      Bytes[0] := 99;
      Stream.WriteBuffer(Bytes[0], 1);
    finally
      Stream.Free;
    end;
    Assert(Reader.ReadVerified(Snapshot, Readback).Code <> rcOk,
      'changed source invalidates snapshot');
    OversizePath := IncludeTrailingPathDelimiter(DirectoryPath) +
      'too-large.sav';
    Stream := TFileStream.Create(OversizePath, fmCreate);
    try
      Stream.Position := 64 * 1024 * 1024;
      Bytes[0] := 1;
      Stream.WriteBuffer(Bytes[0], 1);
    finally
      Stream.Free;
    end;
    Assert(Service.Inspect('save-task', OversizePath, Snapshot).Code =
      rcBudgetExceeded, '64 MiB limit is enforced');
  finally
    Service.Free;
    Reader.Free;
    DeleteFile(SavePath);
    DeleteFile(OversizePath);
    RemoveDir(DirectoryPath);
  end;
  WriteLn('SAVE_SNAPSHOT=PASS');
end.

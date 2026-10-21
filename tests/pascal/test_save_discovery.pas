program test_save_discovery;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, Process, cea_results, cea_save_discovery_types,
  cea_save_discovery_service;

function CreateDirectoryJunction(const ALinkPath,
  ATargetPath: string): Boolean;
var
  Builder: TProcess;
begin
  Builder := TProcess.Create(nil);
  try
    Builder.Executable := SysUtils.GetEnvironmentVariable('COMSPEC');
    Builder.Parameters.Add('/c');
    Builder.Parameters.Add('mklink');
    Builder.Parameters.Add('/J');
    Builder.Parameters.Add(ALinkPath);
    Builder.Parameters.Add(ATargetPath);
    Builder.Options := [poWaitOnExit, poNoConsole];
    Builder.Execute;
    Result := Builder.ExitStatus = 0;
  finally
    Builder.Free;
  end;
end;

procedure WriteFixture(const APath, AText: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

var
  RootPath, NestedPath, OutsidePath, LinkPath: string;
  Service: TCEASaveDiscoveryService;
  Budget: TCEADiscoveryBudget;
  Scope: TCEADiscoveryScope;
  Candidates: TCEASaveCandidateArray;
  SelectedCandidate: TCEASaveCandidate;
  R: TCEAResult;
  SlotCandidateId, SelectedPath: string;
  I: Integer;
begin
  Randomize;
  RootPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-discovery-' + IntToStr(GetProcessID) + '-' +
    IntToStr(Random(MaxInt));
  NestedPath := IncludeTrailingPathDelimiter(RootPath) + 'nested';
  OutsidePath := RootPath + '-outside';
  Assert(ForceDirectories(NestedPath));
  Assert(ForceDirectories(OutsidePath));
  WriteFixture(IncludeTrailingPathDelimiter(RootPath) + 'slot.sav',
    'private-save-bytes');
  WriteFixture(IncludeTrailingPathDelimiter(NestedPath) + 'second.dat',
    'other-private-bytes');
  WriteFixture(IncludeTrailingPathDelimiter(OutsidePath) + 'outside.sav',
    'must-not-be-enumerated');
  Service := TCEASaveDiscoveryService.Create;
  try
    Assert(not Service.HasAuthorizedScope,
      'construction must not grant a search scope');
    Budget.MaxFiles := 1;
    Budget.MaxDepth := 3;
    Budget.MaxDurationMs := 5000;
    Assert(Service.AuthorizeDirectory('C:\', Budget, Scope).Code =
      rcInvalidArgument, 'drive root is too broad');
    Assert(Service.AuthorizeDirectory('\\server\share', Budget,
      Scope).Code = rcInvalidArgument, 'UNC scope is denied');
    Assert(Service.AuthorizeDirectory(RootPath + '\missing', Budget,
      Scope).Code = rcInvalidArgument, 'missing scope is denied');
    Assert(Service.AuthorizeDirectory(RootPath, Budget,
      Scope).Code = rcOk);
    R := Service.Scan(Scope.Id, Candidates);
    Assert(R.Code = rcOk);
    Assert(Length(Candidates) = 1, 'one-file budget is enforced');
    Assert(Pos('"complete":false', R.DataJson) > 0,
      'budget exit reports partial coverage');
    Assert(Pos('private-save-bytes', R.DataJson) = 0,
      'scan never returns file contents');
    Assert(Pos(RootPath, R.DataJson) = 0,
      'scan result omits absolute root path');
    Assert(Service.Revoke(Scope.Id).Code = rcOk);
    Assert(not Service.HasAuthorizedScope);
    Assert(Service.Scan(Scope.Id, Candidates).Code = rcUnauthorized,
      'revoked scope cannot be reused');
    Budget.MaxFiles := 10;
    LinkPath := IncludeTrailingPathDelimiter(RootPath) + 'outside-link';
    Assert(CreateDirectoryJunction(LinkPath, OutsidePath),
      'directory junction fixture is available');
    Assert(Service.AuthorizeDirectory(RootPath, Budget,
      Scope).Code = rcOk);
    R := Service.Scan(Scope.Id, Candidates);
    Assert((R.Code = rcOk) and (Length(Candidates) = 2) and
      (Pos('"complete":false', R.DataJson) > 0) and
      (Pos('skipped_reparse_or_cloud', R.DataJson) > 0),
      'outside junction is skipped and coverage is partial');
    for I := 0 to High(Candidates) do
      Assert(Pos('outside.sav', Candidates[I].RelativePath) = 0,
        'outside target is never enumerated');
    Assert(RemoveDirectoryW(PWideChar(UTF8Decode(LinkPath))),
      'directory junction fixture removed without touching target');
    Assert(Service.Revoke(Scope.Id).Code = rcOk);
    Assert(Service.AuthorizeDirectory(RootPath, Budget,
      Scope).Code = rcOk);
    R := Service.Scan(Scope.Id, Candidates);
    Assert((R.Code = rcOk) and (Length(Candidates) = 2) and
      (Pos('"complete":true', R.DataJson) > 0),
      'fully covered root yields two metadata candidates after link removal');
    SlotCandidateId := '';
    for I := 0 to High(Candidates) do
      if Candidates[I].RelativePath = 'slot.sav' then
        SlotCandidateId := Candidates[I].Id;
    Assert(SlotCandidateId <> '', 'slot candidate is available');
    Assert(Service.SelectCandidate(Scope.Id, SlotCandidateId,
      SelectedPath, SelectedCandidate).Code = rcOk,
      'unchanged candidate passes metadata identity recheck');
    Assert(SelectedCandidate.FileIdentityId <> '',
      'selection retains observed file identity for the inspector');
    Assert(SameText(SelectedPath,
      IncludeTrailingPathDelimiter(RootPath) + 'slot.sav'),
      'selection resolves only the authorized candidate path');
    Assert(RenameFile(SelectedPath,
      IncludeTrailingPathDelimiter(RootPath) + 'old-slot.sav'),
      'old candidate moved away');
    WriteFixture(SelectedPath, 'private-save-bytes');
    Assert(Service.SelectCandidate(Scope.Id, SlotCandidateId,
      SelectedPath, SelectedCandidate).Code = rcConflict,
      'replacement with same name and bytes cannot inherit candidate');
    Assert(Service.Cancel(Scope.Id).Code = rcOk);
    Assert(Service.Scan(Scope.Id, Candidates).Code = rcCancelled,
      'cancelled scan does not traverse');
  finally
    Service.Free;
  end;
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(RootPath) + 'slot.sav');
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(RootPath) + 'old-slot.sav');
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(NestedPath) + 'second.dat');
  SysUtils.RemoveDir(NestedPath);
  SysUtils.RemoveDir(RootPath);
  SysUtils.DeleteFile(IncludeTrailingPathDelimiter(OutsidePath) + 'outside.sav');
  SysUtils.RemoveDir(OutsidePath);
  WriteLn('SAVE_DISCOVERY=PASS');
end.

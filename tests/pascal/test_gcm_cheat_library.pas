program test_gcm_cheat_library;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, cea_results, cea_ports, cea_gcm_types, cea_gcm_cheat_file,
  cea_gcm_cheat_library, cea_gcm_cheat_publisher, cea_windows_sha256;

var
  TempDir: string;
  TrainersDir: string;
  LibraryDir: string;
  Failures: Integer;

procedure Check(const AName: string; const ACondition: Boolean);
begin
  if ACondition then
    WriteLn('  ok   ', AName)
  else
  begin
    WriteLn('  FAIL ', AName);
    Inc(Failures);
  end;
end;

procedure WriteRawFile(const APath, AContent: string);
var
  Stream: TFileStream;
  Bytes: RawByteString;
begin
  Bytes := AContent;
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

function SampleCheatTable(const ADescription: string): string;
begin
  Result :=
    '<?xml version="1.0" encoding="utf-8"?>' + LineEnding +
    '<CheatTable CheatEngineTableVersion="45">' + LineEnding +
    '  <CheatEntries>' + LineEnding +
    '    <CheatEntry>' + LineEnding +
    '      <ID>0</ID>' + LineEnding +
    '      <Description>"' + ADescription + '"</Description>' + LineEnding +
    '      <VariableType>4 Bytes</VariableType>' + LineEnding +
    '      <Address>0061A000</Address>' + LineEnding +
    '    </CheatEntry>' + LineEnding +
    '  </CheatEntries>' + LineEnding +
    '</CheatTable>' + LineEnding;
end;

procedure TestNameHelpers;
begin
  WriteLn('-- name helpers');
  Check('extension .ct accepted', IsCheatTableFileName('a.ct'));
  Check('extension .CT accepted', IsCheatTableFileName('a.CT'));
  Check('extension .exe rejected', not IsCheatTableFileName('a.exe'));
  Check('published name carries hash prefix',
    Pos(UnicodeString('abcdef123456'), PublishedCheatTableName(
      'sha256:abcdef1234567890', 'Table.ct')) = 1);
  Check('published name keeps .ct',
    SameText(ExtractFileExt(string(PublishedCheatTableName('sha256:abcdef123456',
      'Table.ct'))), '.ct'));
  Check('source name gcm', CheatFileSourceName(cfsGcmLibrary) = 'gcm_library');
  Check('source name import', CheatFileSourceName(cfsUserImport) = 'user_import');
end;

procedure TestPathSafety;
begin
  WriteLn('-- path safety');
  Check('inside root accepted',
    SafeCheatTablePath(TempDir, IncludeTrailingPathDelimiter(TempDir) +
      'x.ct') <> '');
  Check('parent escape rejected',
    SafeCheatTablePath(TempDir, IncludeTrailingPathDelimiter(TempDir) +
      '..\evil.ct') = '');
  Check('grandparent escape rejected',
    SafeCheatTablePath(TempDir, IncludeTrailingPathDelimiter(TempDir) +
      '..\..\evil.ct') = '');
  Check('absolute outside rejected',
    SafeCheatTablePath(TempDir, 'C:\Windows\evil.ct') = '');
  Check('empty root rejected', SafeCheatTablePath('', 'x.ct') = '');
end;

procedure TestGcmLibraryScan;
var
  CheatLibrary: TCEAGcmCheatLibrary;
  Candidates: TCEACheatFileCandidateArray;
  R: TCEAResult;
  I: Integer;
  FoundSupraland: Boolean;
  FoundWithGame: Boolean;
begin
  WriteLn('-- gcm library scan');
  // Two tables in two folders, one folder without a sidecar.
  WriteRawFile(IncludeTrailingPathDelimiter(TrainersDir) +
    '[Csimbi] Trainer\Supraland Trainer.ct',
    SampleCheatTable('Gold'));
  WriteRawFile(IncludeTrailingPathDelimiter(TrainersDir) +
    '[Csimbi] Trainer\gcm_info.json',
    '{"game_name":"Supraland Six Inches Under","origin":"ct_other",' +
    '"version":"2022.1.19"}');
  WriteRawFile(IncludeTrailingPathDelimiter(TrainersDir) +
    'No Sidecar\Orphan.ct', SampleCheatTable('Health'));
  // A non-.ct file must be ignored.
  WriteRawFile(IncludeTrailingPathDelimiter(TrainersDir) +
    'No Sidecar\readme.txt', 'not a table');

  CheatLibrary := TCEAGcmCheatLibrary.Create(TrainersDir);
  try
    R := CheatLibrary.ScanGcmLibrary(Candidates);
    Check('scan ok', not R.Failed);
    Check('two candidates found', Length(Candidates) = 2);
    FoundSupraland := False;
    FoundWithGame := False;
    for I := 0 to High(Candidates) do
    begin
      if Pos('Supraland', string(Candidates[I].FileName)) > 0 then
      begin
        FoundSupraland := True;
        Check('sidecar game name decoded',
          Candidates[I].GameName = UnicodeString('Supraland Six Inches Under'));
        Check('sidecar origin decoded',
          Candidates[I].Origin = UnicodeString('ct_other'));
        Check('sidecar version decoded',
          Candidates[I].Version = UnicodeString('2022.1.19'));
        Check('size recorded', Candidates[I].SizeBytes > 0);
      end;
      if Candidates[I].GameName <> '' then
        FoundWithGame := True;
    end;
    Check('supraland candidate present', FoundSupraland);
    Check('at least one candidate has a game name', FoundWithGame);
  finally
    CheatLibrary.Free;
  end;

  // A missing directory is an empty result, not a failure: never having run
  // GCM is normal.
  CheatLibrary := TCEAGcmCheatLibrary.Create(
    IncludeTrailingPathDelimiter(TempDir) + 'does-not-exist');
  try
    R := CheatLibrary.ScanGcmLibrary(Candidates);
    Check('missing directory is not an error', not R.Failed);
    Check('missing directory yields no candidates', Length(Candidates) = 0);
  finally
    CheatLibrary.Free;
  end;
end;

procedure TestImportFromPath;
var
  CheatLibrary: TCEAGcmCheatLibrary;
  Candidate: TCEACheatFileCandidate;
  R: TCEAResult;
  GoodPath, BadPath, WrongExtPath: string;
begin
  WriteLn('-- import from path');
  GoodPath := IncludeTrailingPathDelimiter(TempDir) + 'manual\Manual.ct';
  WriteRawFile(GoodPath, SampleCheatTable('Mana'));
  BadPath := IncludeTrailingPathDelimiter(TempDir) + 'manual\missing.ct';
  WrongExtPath := IncludeTrailingPathDelimiter(TempDir) + 'manual\table.xml';
  WriteRawFile(WrongExtPath, SampleCheatTable('Mana'));

  CheatLibrary := TCEAGcmCheatLibrary.Create(TrainersDir);
  try
    R := CheatLibrary.ImportFromPath(GoodPath, Candidate);
    Check('valid import accepted', not R.Failed);
    Check('import source tagged', Candidate.Source = cfsUserImport);
    Check('import path absolute', Candidate.FilePath <> '');
    Check('import size recorded', Candidate.SizeBytes > 0);

    R := CheatLibrary.ImportFromPath(BadPath, Candidate);
    Check('missing file rejected', R.Failed);
    Check('missing file stable code',
      R.StableCode = 'cheat_file_not_found');

    R := CheatLibrary.ImportFromPath(WrongExtPath, Candidate);
    Check('wrong extension rejected', R.Failed);
    Check('wrong extension stable code',
      R.StableCode = 'cheat_file_extension_invalid');

    R := CheatLibrary.ImportFromPath('', Candidate);
    Check('empty path rejected', R.Failed);
  finally
    CheatLibrary.Free;
  end;
end;

procedure TestPublish;
var
  CheatLibrary: TCEAGcmCheatLibrary;
  Publisher: TCEAGcmCheatPublisher;
  Candidate: TCEACheatFileCandidate;
  PublishResult: TCEACheatFilePublishResult;
  Candidates: TCEACheatFileCandidateArray;
  Hasher: TCEAWindowsSha256;
  R: TCEAResult;
  GoodPath: string;
begin
  WriteLn('-- publish');
  GoodPath := IncludeTrailingPathDelimiter(TempDir) + 'manual\Manual.ct';
  WriteRawFile(GoodPath, SampleCheatTable('Mana'));

  Hasher := TCEAWindowsSha256.Create;
  CheatLibrary := TCEAGcmCheatLibrary.Create(TrainersDir);
  Publisher := TCEAGcmCheatPublisher.Create(LibraryDir, Hasher);
  try
    R := CheatLibrary.ImportFromPath(GoodPath, Candidate);
    Check('import before publish ok', not R.Failed);

    R := Publisher.Publish(Candidate, PublishResult);
    Check('publish ok', not R.Failed);
    Check('published file exists', FileExists(PublishResult.PublishedPath));
    Check('published path inside CheatLibrary',
      Pos(ExpandFileName(LibraryDir), PublishResult.PublishedPath) = 1);
    Check('published hash is sha256',
      Pos('sha256:', PublishResult.Candidate.ContentHash) = 1);
    Check('metadata written', FileExists(PublishResult.MetadataPath));
    Check('first publish is not a replace', not PublishResult.Replaced);

    // Publishing the same bytes again lands on the same name and is reported
    // as a replacement rather than creating a duplicate.
    R := Publisher.Publish(Candidate, PublishResult);
    Check('republish ok', not R.Failed);
    Check('republish reports replaced', PublishResult.Replaced);

    R := Publisher.ListPublished(Candidates);
    Check('list published ok', not R.Failed);
    Check('one published table', Length(Candidates) = 1);
    if Length(Candidates) = 1 then
      Check('published hash round trips',
        Candidates[0].ContentHash = PublishResult.Candidate.ContentHash);

    // A candidate pointing at a vanished file must not publish.
    Candidate.FilePath := IncludeTrailingPathDelimiter(TempDir) +
      'manual\gone.ct';
    R := Publisher.Publish(Candidate, PublishResult);
    Check('vanished source rejected', R.Failed);
    Check('vanished source stable code',
      R.StableCode = 'cheat_file_not_found');
  finally
    Publisher.Free;
    CheatLibrary.Free;
    Hasher.Free;
  end;
end;

begin
  Failures := 0;
  TempDir := IncludeTrailingPathDelimiter(GetTempDir) + 'cea-gcm-lib-test-' +
    IntToStr(GetProcessID);
  TrainersDir := IncludeTrailingPathDelimiter(TempDir) + 'GCM Trainers';
  LibraryDir := IncludeTrailingPathDelimiter(TempDir) + 'cheat-tables';
  ForceDirectories(TrainersDir);
  ForceDirectories(LibraryDir);
  try
    TestNameHelpers;
    TestPathSafety;
    TestGcmLibraryScan;
    TestImportFromPath;
    TestPublish;
  finally
    // Best effort cleanup; a leftover temp directory must not fail the test.
    if DirectoryExists(TempDir) then
      RemoveDir(TempDir);
  end;
  if Failures = 0 then
  begin
    WriteLn('GCM_CHEAT_LIBRARY=PASS');
    Halt(0);
  end;
  WriteLn('GCM_CHEAT_LIBRARY=FAIL failures=', Failures);
  Halt(1);
end.

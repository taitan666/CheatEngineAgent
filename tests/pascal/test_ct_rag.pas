program test_ct_rag;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, SQLDB, SQLite3Conn, cea_results, cea_windows_sha256,
  cea_ct_model, cea_ct_parser,
  cea_ct_catalog, cea_reverse_types, cea_evidence_service,
  cea_ct_evidence_bridge;

procedure CreateLegacyCatalog(const ADatabasePath: string);
var
  Connection: TSQLite3Connection;
  Transaction: TSQLTransaction;
begin
  Connection := TSQLite3Connection.Create(nil);
  Transaction := TSQLTransaction.Create(nil);
  try
    Connection.Transaction := Transaction;
    Transaction.Database := Connection;
    Connection.DatabaseName := ADatabasePath;
    Connection.Open;
    Transaction.StartTransaction;
    Connection.ExecuteDirect(
      'CREATE TABLE ct_artifacts (' +
      'artifact_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL UNIQUE, ' +
      'source_uri TEXT NOT NULL, parser_version TEXT NOT NULL, ' +
      'table_version TEXT NOT NULL, game_name TEXT NOT NULL, ' +
      'game_version TEXT NOT NULL)');
    Transaction.Commit;
  finally
    if Transaction.Active then Transaction.Rollback;
    if Connection.Connected then Connection.Close;
    Transaction.Free;
    Connection.Free;
  end;
end;

var
  DatabasePath, FixtureRoot: string;
  Hasher: TCEAWindowsSha256;
  Parser: TCTParser;
  Catalog: TCTCatalog;
  Artifact: TCTArtifact;
  R: TCEAResult;
  Evidence: TCEAEvidenceReference;
  Target: TCEATargetBinding;
  EvidenceService: TCEAEvidenceService;
  EvidenceBridge: TCEACTEvidenceBridge;

begin
  DatabasePath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-ct-rag-' + IntToStr(GetProcessID) + '.sqlite3';
  SysUtils.DeleteFile(DatabasePath);
  CreateLegacyCatalog(DatabasePath);
  FixtureRoot := ExpandFileName('tests\fixtures\ct');
  Hasher := TCEAWindowsSha256.Create;
  Parser := TCTParser.Create(Hasher, 16 * 1024 * 1024);
  Catalog := TCTCatalog.Create(DatabasePath);
  try
    Assert(Catalog.Initialize.Code = rcOk,
      'legacy CT catalog migrates license columns');
    Assert(Parser.ParseFile(IncludeTrailingPathDelimiter(FixtureRoot) +
      'aob-and-pointer.ct', 'file://fixtures/aob-and-pointer.ct',
      Artifact).Code = rcOk, 'fixture parses');
    Assert((Artifact.LicenseSpdx = 'NOASSERTION') and
      (Artifact.LicenseStatus = 'unknown') and (Artifact.LicenseUri = ''),
      'missing CT license remains explicitly unknown');
    Assert(Catalog.ImportParsedArtifact(Artifact).Code = rcOk,
      'parsed artifact imports');
    Assert(Catalog.ImportParsedArtifact(Artifact).Code = rcOk,
      'content hash makes duplicate import idempotent');
    Artifact.ContentHash :=
      'sha256:3333333333333333333333333333333333333333333333333333333333333333';
    Artifact.SourceUri := 'file://fixtures/chinese-cheat.ct';
    Artifact.GameName := '示例游戏';
    Artifact.Entries[0].Description := '无限生命';
    Assert(Catalog.ImportParsedArtifact(Artifact).Code = rcOk,
      'Chinese retrieval fixture imports as separate provenance');
    EvidenceService := TCEAEvidenceService.Create;
    EvidenceBridge := TCEACTEvidenceBridge.Create;
    try
      FillChar(Target, SizeOf(Target), 0);
      Assert(EvidenceBridge.BuildCatalogEvidence(Artifact,
        Evidence).Code = rcOk, 'CT artifact bridges to catalog evidence');
      Assert((Evidence.Scope = esCatalog) and
        (Evidence.Kind = ekCTArtifact) and
        (Evidence.ContentHash = Artifact.ContentHash),
        'bridged evidence retains scope, kind and source hash');
      Assert(EvidenceService.Add(Evidence, Target).Code = rcOk,
        'catalog CT evidence is reusable without runtime authority');
    finally
      EvidenceBridge.Free;
      EvidenceService.Free;
    end;

    R := Catalog.SearchText('Synthetic AOB', 10);
    Assert(R.Code = rcOk, 'description search succeeds');
    Assert((Pos('Synthetic AOB', R.DataJson) > 0) and
      (Pos('file://fixtures/aob-and-pointer.ct', R.DataJson) > 0) and
      (Pos(Artifact.ContentHash, R.DataJson) > 0),
      'search result retains description, source, and content hash');
    Assert(Pos('89 83 ?? ?? ?? ??', R.DataJson) > 0,
      'search result exposes AOB as inert evidence');
    Assert((Pos('"license_spdx" : "NOASSERTION"', R.DataJson) > 0) and
      (Pos('"license_status" : "unknown"', R.DataJson) > 0),
      'search result retains conservative license provenance');

    R := Catalog.GetEntry('ct-' + Copy(Artifact.ContentHash, 8, 32) + ':1');
    Assert((R.Code = rcOk) and (Pos('Synthetic AOB', R.DataJson) > 0) and
      (Pos('"authority" : "none"', R.DataJson) > 0),
      'exact CT entry lookup returns inert provenance-bound evidence');
    Assert((Catalog.GetEntry('ct-missing:0').Code = rcInvalidArgument) and
      (Catalog.GetEntry('ct-missing:0').StableCode = 'ct_entry_not_found'),
      'missing CT entry has a stable not-found result');

    R := Catalog.SearchText('Syntetic AOB', 10);
    Assert((R.Code = rcOk) and (Pos('Synthetic AOB', R.DataJson) > 0) and
      (Pos('fuzzy', R.DataJson) > 0),
      'GCM-style typo-tolerant search returns ranked CT evidence');

    R := Catalog.SearchText('wuxianshengming', 10);
    Assert((R.Code = rcOk) and (Pos('无限生命', R.DataJson) > 0) and
      (Pos('pinyin', R.DataJson) > 0),
      'lightweight full-pinyin query retrieves Chinese CT description');
    R := Catalog.SearchText('wxsm', 10);
    Assert((R.Code = rcOk) and (Pos('无限生命', R.DataJson) > 0) and
      (Pos('pinyin_initials', R.DataJson) > 0),
      'lightweight pinyin initials retrieve Chinese CT description');
    R := Catalog.SearchText('生命无限', 10);
    Assert((R.Code = rcOk) and (Pos('无限生命', R.DataJson) > 0) and
      (Pos('lightweight_vector', R.DataJson) > 0),
      'pinyin token sets provide deterministic lightweight vector ranking');
    Assert((Pos('deterministic_pinyin_token_set_v1', R.DataJson) > 0) and
      (Pos('"external_embedding" : false', R.DataJson) > 0),
      'lightweight vector provenance proves no external embedding call');

    R := Catalog.BuildRagContext('SampleOfflineGame', 10);
    Assert((R.Code = rcOk) and (Pos('citations', R.DataJson) > 0),
      'RAG context contains citations');
    Assert(Pos('authority', R.DataJson) > 0,
      'RAG context explicitly carries no authority');
  finally
    Catalog.Free;
  end;
  Catalog := TCTCatalog.Create(DatabasePath);
  try
    Assert(Catalog.Initialize.Code = rcOk, 'CT catalog reopens');
    R := Catalog.SearchText('Synthetic Pointer', 10);
    Assert((R.Code = rcOk) and (Pos('Synthetic Pointer', R.DataJson) > 0),
      'indexed CT survives process-local catalog reopen');
  finally
    Catalog.Free;
    Parser.Free;
    Hasher.Free;
    SysUtils.DeleteFile(DatabasePath);
    SysUtils.DeleteFile(DatabasePath + '-wal');
    SysUtils.DeleteFile(DatabasePath + '-shm');
  end;
  WriteLn('CT_RAG=PASS');
end.

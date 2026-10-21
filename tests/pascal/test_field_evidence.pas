program test_field_evidence;

{$mode objfpc}{$H+}
{$codepage utf8}

{ FR-052 evidence recording. The assertions deliberately pin the *weak* parts
  of the contract: evidence is a record, never a permission. }

uses
  SysUtils, Classes,
  cea_results, cea_types, cea_reverse_types, cea_windows_sha256,
  cea_field_evidence, cea_field_evidence_store;

var
  Directory: string;
  DatabasePath: string;
  Hasher: TCEAWindowsSha256;
  Store: TCEAFieldEvidenceStore;
  Service: TCEAFieldEvidenceService;
  Identity: TCEProcessIdentity;
  Evidence: TCEAFieldEvidence;
  Items: TCEAFieldEvidenceArray;
  Reference: TCEAEvidenceReference;
  R: TCEAResult;
  I: Integer;
  Found: Boolean;

function MakeIdentity(const AEpoch: QWord): TCEProcessIdentity;
begin
  Result := Default(TCEProcessIdentity);
  Result.Id := 'identity-' + IntToStr(AEpoch);
  Result.Pid := 4242;
  Result.ExecutableSha256 := Hasher.HashUtf8('exe');
  Result.ModuleSetHash := Hasher.HashUtf8('modules');
  Result.Epoch := AEpoch;
end;

begin
  Directory := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-field-evidence-' + IntToStr(GetProcessID) + '-' +
    IntToStr(GetTickCount64);
  ForceDirectories(Directory);
  DatabasePath := IncludeTrailingPathDelimiter(Directory) + 'evidence.sqlite3';
  try
    Hasher := TCEAWindowsSha256.Create;
    Identity := MakeIdentity(7);
    Store := TCEAFieldEvidenceStore.Create(DatabasePath);
    try
      R := Store.Initialize;
      Assert(not R.Failed, 'store initializes: ' + R.StableCode);

      Service := TCEAFieldEvidenceService.Create(Hasher, Store);
      try
        { A capture: the value is a fact, the outcome is still pending. }
        R := Service.RecordCapture('player.gold', 'Gold', '0x1000', 'dword',
          '100', '250', '{"source":"capture"}', Identity, '2026-10-21T00:00:00Z',
          Evidence);
        Assert(not R.Failed, 'capture recorded: ' + R.StableCode);
        Assert(Pos('field-evidence-', R.DataJson) > 0, 'result names the evidence: ' + R.DataJson);
        Assert(Evidence.FieldId = 'player.gold', 'record keeps the field id');
        Assert(Evidence.Kind = ekMemoryObservation, 'capture is an observation');
        Assert(Evidence.Outcome = voPending, 'capture has no outcome yet');
        Assert(Evidence.Epoch = 7, 'record keeps the epoch');
        Assert(IsCEAHash(Evidence.ContentHash), 'content hash is a CEA hash: ' + Evidence.ContentHash);
        Assert(Evidence.IsValid, 'record passes its own validity gate');

        { Same values, second capture: the hash must differ, otherwise the store
          would collapse two observations into one artifact. }
        R := Service.RecordCapture('player.gold', 'Gold', '0x1000', 'dword',
          '100', '250', '{"source":"capture"}', Identity, '2026-10-21T00:00:00Z',
          Evidence);
        Assert(not R.Failed, 'second capture recorded');
        Assert(Evidence.EvidenceId = 'field-evidence-00000002',
          'sequence advances: ' + Evidence.EvidenceId);
        Assert(Pos('"deduplicated"', R.DataJson) = 0,
          'identical values still produce a distinct record');

        { A verified write: this one states an outcome. }
        R := Service.RecordVerification('player.gold', 'Gold', '0x1000', 'dword',
          '250', '250', '{"after":"250"}', Identity, voPass,
          '2026-10-21T00:01:00Z', Evidence);
        Assert(not R.Failed, 'verification recorded: ' + R.StableCode);
        Assert(Evidence.Kind = ekVerification, 'verification is its own kind');
        Assert(Evidence.Outcome = voPass, 'verification keeps the outcome');

        { A verification without an outcome is a contradiction. }
        R := Service.RecordVerification('player.gold', 'Gold', '0x1000', 'dword',
          '250', '250', '', Identity, voPending, '2026-10-21T00:02:00Z', Evidence);
        Assert(R.Failed and (R.StableCode = 'evidence_outcome_required'),
          'pending verification rejected: ' + R.StableCode);

        { A user statement says which field a location belongs to. }
        R := Service.RecordUserConfirmation('player.hp', 'HP', '0x2000', 'float',
          '{"declared_by":"operator"}', Identity, '2026-10-21T00:03:00Z', Evidence);
        Assert(not R.Failed, 'user statement recorded: ' + R.StableCode);
        Assert(Evidence.Kind = ekUserStatement, 'statement is user evidence');

        { Hard gate: missing field / target / timestamp. }
        R := Service.RecordCapture('', 'Gold', '0x1000', 'dword', '', '',
          '', Identity, '2026-10-21T00:04:00Z', Evidence);
        Assert(R.Failed and (R.StableCode = 'evidence_field_required'),
          'field id required: ' + R.StableCode);
        R := Service.RecordCapture('player.gold', 'Gold', '0x1000', 'dword', '',
          '', '', MakeIdentity(0), '2026-10-21T00:04:00Z', Evidence);
        Assert(R.Failed and (R.StableCode = 'evidence_target_required'),
          'target required: ' + R.StableCode);
        R := Service.RecordCapture('player.gold', 'Gold', '0x1000', 'dword', '',
          '', '', Identity, '', Evidence);
        Assert(R.Failed and (R.StableCode = 'evidence_timestamp_required'),
          'timestamp required: ' + R.StableCode);

        { Listing: newest first, field filter works, limit is clamped. }
        R := Service.ListForField('player.gold', 50, Items);
        Assert(not R.Failed, 'list succeeds: ' + R.StableCode);
        Assert(Length(Items) = 3, 'three records for player.gold, got ' +
          IntToStr(Length(Items)));
        Assert(Items[0].Kind = ekVerification, 'newest record comes first');
        Assert(Items[2].Kind = ekMemoryObservation, 'oldest record comes last');
        Assert(Items[2].ObservedValueJson = '250', 'payload round-trips: ' +
          Items[2].ObservedValueJson);
        Assert(Items[2].PreviousValueJson = '100', 'previous value round-trips');
        Assert(Items[2].ValueType = 'dword', 'value type round-trips');
        Assert(Items[2].AddressText = '0x1000', 'address round-trips');
        Assert(Items[0].RecordedAt = '2026-10-21T00:01:00Z',
          'timestamp round-trips');

        R := Service.ListForField('player.hp', 50, Items);
        Assert(not R.Failed, 'list by field succeeds');
        Assert(Length(Items) = 1, 'one record for player.hp');
        Assert(Items[0].Kind = ekUserStatement, 'hp record is the statement');

        R := Service.ListForField('', 2, Items);
        Assert(not R.Failed, 'list all succeeds');
        Assert(Length(Items) = 2, 'limit is honoured, got ' + IntToStr(Length(Items)));

        R := Service.ListForField('player.gold', 0, Items);
        Assert(not R.Failed, 'default limit accepted');
        Assert(Length(Items) = 3, 'default limit covers all three');

        R := Service.ListForField('player.missing', 50, Items);
        Assert(not R.Failed, 'unknown field is not an error: ' + R.StableCode);
        Assert(Length(Items) = 0, 'unknown field lists nothing');

        Assert(Service.Count = 4, 'total evidence count, got ' + IntToStr(Service.Count));

        { Conversion into the reverse-domain shape, which is what makes the same
          observation citable by the candidate/recipe pipeline. }
        R := Service.ListForField('player.gold', 1, Items);
        Assert(not R.Failed, 'relist for conversion');
        Reference := Service.ToReference(Items[0]);
        Assert(Reference.IsValid, 'converted reference is valid');
        Assert(Reference.Scope = esRuntime, 'runtime scope');
        Assert(Reference.Kind = Items[0].Kind, 'kind carried over');
        Assert(Reference.Target.ProcessIdentityId = Identity.Id, 'target carried over');
        Assert(Reference.Target.Epoch = 7, 'epoch carried over');
        Assert(Reference.ProducedByCapabilityId = 'memory_read',
          'capability recorded');

        { Write-support gates: FR-052 is a record, not a permission. }
        Assert(IsWriteSupportingKind(ekMemoryObservation), 'observation supports a write claim');
        Assert(IsWriteSupportingKind(ekVerification), 'verification supports a write claim');
        Assert(not IsWriteSupportingKind(ekUserStatement),
          'a user statement names the field but does not prove writability');
        Assert(not IsWriteSupportingKind(ekCTArtifact),
          'a CT artifact is not evidence about this process');
        Assert(not IsWriteSupportingKind(ekDisassembly),
          'disassembly is not a write proof');
        Assert(IsWriteSupportingOutcome(voPass), 'pass supports a write claim');
        Assert(not IsWriteSupportingOutcome(voFail), 'fail contradicts a write claim');
        Assert(not IsWriteSupportingOutcome(voUnknown),
          'unknown outcome cannot support a write claim');

        { Text forms are the persisted contract. }
        Assert(EvidenceKindText(ekVerification) = 'verification', 'kind text');
        Assert(EvidenceKindText(ekUserStatement) = 'user_statement', 'kind text');
        Assert(EvidenceOutcomeText(voInconclusive) = 'inconclusive', 'outcome text');
        Found := TryParseEvidenceKind('memory_observation', Evidence.Kind);
        Assert(Found and (Evidence.Kind = ekMemoryObservation), 'kind round-trip');
        Found := TryParseEvidenceKind('nonsense', Evidence.Kind);
        Assert(not Found, 'unknown kind text is rejected');
        Found := TryParseEvidenceOutcome('pass', Evidence.Outcome);
        Assert(Found and (Evidence.Outcome = voPass), 'outcome round-trip');
        Found := TryParseEvidenceOutcome('nonsense', Evidence.Outcome);
        Assert(not Found, 'unknown outcome text is rejected');
      finally
        Service.Free;
      end;
    finally
      Store.Free;
    end;

    { Reopen: the records must be durable, and the sequence must not restart at
      one or the next record would overwrite an existing row. }
    Store := TCEAFieldEvidenceStore.Create(DatabasePath);
    try
      R := Store.Initialize;
      Assert(not R.Failed, 'reopen initializes');
      Assert(Store.Count = 4, 'records survive a reopen, got ' +
        IntToStr(Store.Count));
      Service := TCEAFieldEvidenceService.Create(Hasher, Store);
      try
        R := Service.RecordCapture('player.gold', 'Gold', '0x1000', 'dword',
          '250', '999', '', MakeIdentity(7), '2026-10-21T00:05:00Z', Evidence);
        Assert(not R.Failed, 'capture after reopen: ' + R.StableCode);
        Assert(Evidence.EvidenceId = 'field-evidence-00000005',
          'sequence resumes after the stored count: ' + Evidence.EvidenceId);
        { The store keys on evidence_id, so a restarted service must not collide
          with an existing row. }
        Assert(Store.Count = 5, 'the new record is distinct, got ' +
          IntToStr(Store.Count));        R := Service.ListForField('player.gold', 50, Items);
        Assert(not R.Failed, 'list after reopen');
        Assert(Length(Items) = 4, 'four records for player.gold after reopen, got ' +
          IntToStr(Length(Items)));
        for I := 0 to High(Items) do
          Assert(Items[I].ObservedValueJson <> '', 'every record keeps its value');
      finally
        Service.Free;
      end;
    finally
      Store.Free;
    end;

    Hasher.Free;
    WriteLn('FIELD_EVIDENCE=PASS');
  finally
    if FileExists(DatabasePath) then
      DeleteFile(DatabasePath);
    if DirectoryExists(Directory) then
      RemoveDir(Directory);
  end;
end.

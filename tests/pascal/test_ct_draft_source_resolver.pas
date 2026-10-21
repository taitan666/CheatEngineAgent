program test_ct_draft_source_resolver;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_reverse_types, cea_reverse_ports,
  cea_ct_draft_types, cea_reverse_repository, cea_ct_draft_source_resolver,
  cea_test_ports;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise Exception.Create(AMessage);
end;

function HashOf(const C: Char): string;
begin
  Result := 'sha256:' + StringOfChar(C, 64);
end;

procedure SaveRun(const Repo: TCEAReverseRepository; const AId, ARecipeId,
  AProofId: string; const AOutcome: TCEAVerificationOutcome;
  const ATarget: TCEATargetBinding);
var
  Run: TCEAVerificationRun;
begin
  FillChar(Run, SizeOf(Run), 0);
  Run.Id := AId;
  Run.SchemaVersion := '1.0';
  Run.ExperimentId := 'experiment:fixture';
  Run.RecipeId := ARecipeId;
  Run.Target := ATarget;
  Run.Outcome := AOutcome;
  Run.ChecksJson := '[{"kind":"readback","outcome":"pass"}]';
  Run.ProofId := AProofId;
  Check(Repo.SaveVerificationRun(Run).Code = rcOk, 'save verification');
end;

var
  DbPath: string;
  Repo: TCEAReverseRepository;
  StorePort: ICEAReverseArtifactStore;
  Gov: TCEATestGovernanceStore;
  GovPort: IGovernanceStore;
  Resolver: TCEACTDraftSourceResolver;
  Recipe, ChangedRecipe: TCEAReverseRecipe;
  Candidate, OtherCandidate, StaleCandidate: TCEACandidateLocation;
  Evidence: TCEAEvidenceReference;
  Identity: TCEProcessIdentity;
  Target: TCEATargetBinding;
  Proposal: TCEACTDraftProposal;
  Bundle: TCEACTDraftSourceBundle;
  Proof: TCEAProof;
  R: TCEAResult;
begin
  DbPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-ct-draft-source-' + IntToStr(GetTickCount64) + '.db';
  Repo := TCEAReverseRepository.Create(DbPath);
  Gov := TCEATestGovernanceStore.Create;
  try
    Check(Repo.Initialize.Code = rcOk, 'repository initialize');
    StorePort := Repo;
    GovPort := Gov;

    Target.ProcessIdentityId := 'process:fixture';
    Target.Epoch := 7;

    FillChar(Identity, SizeOf(Identity), 0);
    Identity.Id := Target.ProcessIdentityId;
    Identity.Pid := 4242;
    Identity.StartedAt := '2026-09-22T00:00:00Z';
    Identity.ExecutablePathHash := HashOf('a');
    Identity.ExecutableSha256 := HashOf('b');
    Identity.Architecture := caX86_64;
    Identity.ModuleSetHash := HashOf('f');
    Identity.Epoch := Target.Epoch;
    Identity.TargetClassification := tcSinglePlayerOffline;
    Check(Repo.SaveTargetIdentity(Identity).Code = rcOk,
      'save authoritative process identity');

    FillChar(Evidence, SizeOf(Evidence), 0);
    Evidence.Id := 'evidence:scan';
    Evidence.SchemaVersion := '1.0';
    Evidence.Scope := esRuntime;
    Evidence.Kind := ekScanSnapshot;
    Evidence.ProvenanceUri := 'runtime://scan/fixture';
    Evidence.ContentHash := HashOf('e');
    Evidence.Target := Target;
    Evidence.ProducedByCapabilityId := 'memory.scan';
    Evidence.ObservedAt := '2026-09-22T00:00:00Z';
    Check(Repo.SaveEvidence(Evidence).Code = rcOk, 'save evidence');

    FillChar(Candidate, SizeOf(Candidate), 0);
    Candidate.Id := 'candidate:health';
    Candidate.SchemaVersion := '1.0';
    Candidate.Kind := ckModuleOffset;
    Candidate.Target := Target;
    Candidate.AddressText := '0x1234';
    Candidate.AddressWidthBits := 64;
    Candidate.ModuleName := 'game.exe';
    Candidate.CompatibilityHash := HashOf('c');
    Candidate.DiscoveryEvidenceId := Evidence.Id;
    Check(Repo.SaveCandidate(Candidate).Code = rcOk, 'save candidate');

    FillChar(Recipe, SizeOf(Recipe), 0);
    Recipe.Id := 'recipe:health';
    Recipe.SchemaVersion := '1.0';
    Recipe.Name := 'Health recipe';
    Recipe.CompatibilityHash := Candidate.CompatibilityHash;
    Recipe.SourceEvidenceIdsJson := '["evidence:scan"]';
    Recipe.RequiredCapabilityIdsJson := '["memory.read"]';
    Recipe.VerificationPlanJson := '{"checks":["readback"]}';
    Check(Repo.SaveRecipe(Recipe).Code = rcOk, 'save recipe');
    Check(Repo.SaveRecipe(Recipe).Code = rcOk, 'identical recipe idempotent');
    ChangedRecipe := Recipe;
    ChangedRecipe.Name := 'Conflicting rewrite';
    Check(Repo.SaveRecipe(ChangedRecipe).StableCode = 'reverse_artifact_conflict',
      'conflicting recipe rewrite rejected');

    FillChar(Proof, SizeOf(Proof), 0);
    Proof.Id := 'proof:health';
    Proof.EffectId := 'effect:verify';
    Proof.ReceiptId := 'receipt:verify';
    Proof.RecordedAt := '2026-09-22T00:00:00Z';
    Proof.Outcome := poPass;
    Proof.VerificationHash := HashOf('e');
    Proof.DetailsJson := '{}';
    Check(Gov.SaveProof(Proof).Code = rcOk, 'save proof');
    SaveRun(Repo, 'verification:pass', Recipe.Id, Proof.Id, voPass, Target);

    FillChar(Proposal, SizeOf(Proposal), 0);
    Proposal.SchemaVersion := '1.0';
    Proposal.RecipeId := Recipe.Id;
    Proposal.VerificationRunId := 'verification:pass';
    Proposal.GameName := 'Fixture Game';
    SetLength(Proposal.Entries, 1);
    Proposal.Entries[0].CandidateId := Candidate.Id;
    Proposal.Entries[0].Description := 'Health';
    Proposal.Entries[0].RequestedKind := deModuleOffset;
    Proposal.Entries[0].RequestedValueType := dvDword;
    Proposal.Entries[0].Order := 0;
    Proposal.Entries[0].EvidenceIdsJson := '["evidence:scan"]';
    Proposal.Entries[0].ProofIdsJson := '["proof:health"]';

    Resolver := TCEACTDraftSourceResolver.Create(StorePort, GovPort);
    try
      R := Resolver.Resolve(Proposal, Bundle);
      Check(R.Code = rcOk, 'verified sources resolve');
      Check((Length(Bundle.Candidates) = 1) and
        (Bundle.Candidates[0].AddressText = '0x1234'),
        'authoritative candidate returned');
      Check((Length(Bundle.Evidence) = 1) and
        (Bundle.Evidence[0].ContentHash = Evidence.ContentHash),
        'authoritative evidence returned');
      Check((Bundle.TargetExecutableSha256 = Identity.ExecutableSha256) and
        (Bundle.ModuleSetHash = Identity.ModuleSetHash),
        'authoritative executable and module hashes returned');

      Proposal.Entries[0].CandidateId := 'candidate:missing';
      R := Resolver.Resolve(Proposal, Bundle);
      Check((R.Code = rcCTDraftSourceMissing) and
        (Pos('/entries/0/candidate_id', R.DataJson) > 0),
        'missing source and pointer');
      Proposal.Entries[0].CandidateId := Candidate.Id;

      SaveRun(Repo, 'verification:inconclusive', Recipe.Id, '',
        voInconclusive, Target);
      Proposal.VerificationRunId := 'verification:inconclusive';
      Check(Resolver.Resolve(Proposal, Bundle).Code =
        rcCTDraftSourceUnverified, 'inconclusive rejected');

      OtherCandidate := Candidate;
      OtherCandidate.Id := 'candidate:other-hash';
      OtherCandidate.CompatibilityHash := HashOf('d');
      Check(Repo.SaveCandidate(OtherCandidate).Code = rcOk,
        'save mismatch candidate');
      Proposal.VerificationRunId := 'verification:pass';
      Proposal.Entries[0].CandidateId := OtherCandidate.Id;
      Check(Resolver.Resolve(Proposal, Bundle).Code =
        rcCTDraftCompatibilityMismatch, 'mixed compatibility rejected');

      StaleCandidate := Candidate;
      StaleCandidate.Id := 'candidate:stale';
      StaleCandidate.Target.Epoch := Target.Epoch - 1;
      Check(Repo.SaveCandidate(StaleCandidate).Code = rcOk,
        'save stale candidate');
      Proposal.Entries[0].CandidateId := StaleCandidate.Id;
      Check(Resolver.Resolve(Proposal, Bundle).Code =
        rcCTDraftStaleRuntimeEvidence, 'stale epoch rejected');

      SaveRun(Repo, 'verification:missing-proof', Recipe.Id,
        'proof:not-stored', voPass, Target);
      Proposal.VerificationRunId := 'verification:missing-proof';
      Proposal.Entries[0].CandidateId := Candidate.Id;
      Check(Resolver.Resolve(Proposal, Bundle).Code =
        rcCTDraftSourceMissing, 'missing governance proof rejected');
    finally
      Resolver.Free;
    end;

    WriteLn('CT_DRAFT_SOURCE_RESOLVER=PASS');
  finally
    StorePort := nil;
    GovPort := nil;
    Gov.Free;
    Repo.Free;
    if FileExists(DbPath) then DeleteFile(DbPath);
  end;
end.

unit cea_ct_draft_source_resolver;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_reverse_types,
  cea_reverse_ports, cea_ct_draft_types, cea_ct_draft_ports;

type
  TCEACTDraftSourceResolver = class(TObject, ICEACTDraftSourceResolver)
  private
    FStore: ICEAReverseArtifactStore;
    FGovernance: IGovernanceStore;
    function Failure(const ACode: TCEAResultCode; const APointer: string): TCEAResult;
  public
    constructor Create(const AStore: ICEAReverseArtifactStore;
      const AGovernance: IGovernanceStore);
    function Resolve(const AProposal: TCEACTDraftProposal;
      out ABundle: TCEACTDraftSourceBundle): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

constructor TCEACTDraftSourceResolver.Create(
  const AStore: ICEAReverseArtifactStore; const AGovernance: IGovernanceStore);
begin
  inherited Create;
  FStore := AStore;
  FGovernance := AGovernance;
end;

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]);
end;

function TCEACTDraftSourceResolver.Failure(const ACode: TCEAResultCode;
  const APointer: string): TCEAResult;
begin
  Result := TCEAResult.Error(ACode, ResultCodeToStableCode(ACode),
    '{"pointer":"' + JsonEscape(APointer) + '"}');
end;

function ParseIdArray(const AJson: string; out AIds: TCEACTDraftStringArray): Boolean;
var D: TJSONData; A: TJSONArray; I: Integer;
begin
  SetLength(AIds, 0); D := nil;
  try
    D := GetJSON(AJson);
    if D.JSONType <> jtArray then Exit(False);
    A := TJSONArray(D);
    SetLength(AIds, A.Count);
    for I := 0 to A.Count - 1 do begin
      if A.Items[I].JSONType <> jtString then Exit(False);
      AIds[I] := A.Strings[I];
      if AIds[I] = '' then Exit(False);
    end;
    Result := True;
  except Result := False;
  end;
  D.Free;
end;

function ContainsId(const AIds: TCEACTDraftStringArray;
  const AId: string): Boolean;
var I: Integer;
begin
  for I := 0 to High(AIds) do if AIds[I] = AId then Exit(True);
  Result := False;
end;

function KindMatches(const ARequested: TCEACTDraftEntryKind;
  const AActual: TCEACandidateKind): Boolean;
begin
  case ARequested of
    deAbsoluteAddress: Result := AActual = ckAbsoluteAddress;
    deModuleOffset: Result := AActual = ckModuleOffset;
    dePointerChain: Result := AActual = ckPointerChain;
    deGroup: Result := False;
  end;
end;

function TCEACTDraftSourceResolver.Resolve(const AProposal: TCEACTDraftProposal;
  out ABundle: TCEACTDraftSourceBundle): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Candidate: TCEACandidateLocation;
  Evidence: TCEAEvidenceReference;
  Proof: TCEAProof;
  RecipeEvidenceIds, EntryEvidenceIds, EntryProofIds: TCEACTDraftStringArray;
  I, J, K: Integer;
  Found: Boolean;
begin
  FillChar(ABundle, SizeOf(ABundle), 0);
  if (FStore = nil) or (FGovernance = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'ct_draft_source_resolver_missing', '{}'));
  if not AProposal.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_draft_proposal_invalid', '{}'));

  Result := FStore.LoadRecipe(AProposal.RecipeId, ABundle.Recipe);
  if Result.Failed then Exit(Failure(rcCTDraftSourceMissing, '/recipe_id'));
  if not ABundle.Recipe.IsPortableDefinition then
    Exit(Failure(rcCTDraftSourceUnverified, '/recipe_id'));
  Result := FStore.LoadVerificationRun(AProposal.VerificationRunId,
    ABundle.Verification);
  if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
    '/verification_run_id'));
  if (ABundle.Verification.RecipeId <> ABundle.Recipe.Id) or
     (ABundle.Verification.Outcome <> voPass) or
     (ABundle.Verification.ProofId = '') then
    Exit(Failure(rcCTDraftSourceUnverified, '/verification_run_id'));

  Result := FGovernance.LoadProof(ABundle.Verification.ProofId, Proof);
  if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
    '/verification_run_id/proof_id'));
  if Proof.Outcome <> poPass then
    Exit(Failure(rcCTDraftSourceUnverified, '/verification_run_id/proof_id'));
  SetLength(ABundle.Proofs, 1);
  ABundle.Proofs[0] := Proof;

  Result := FStore.LoadTargetIdentity(
    ABundle.Verification.Target.ProcessIdentityId, Identity);
  if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
    '/verification_run_id/target'));
  if (Identity.Epoch <> ABundle.Verification.Target.Epoch) or
     (Identity.TargetClassification <> tcSinglePlayerOffline) then
    Exit(Failure(rcCTDraftStaleRuntimeEvidence,
      '/verification_run_id/target'));
  ABundle.TargetExecutableSha256 := Identity.ExecutableSha256;
  ABundle.ModuleSetHash := Identity.ModuleSetHash;

  if not ParseIdArray(ABundle.Recipe.SourceEvidenceIdsJson,
    RecipeEvidenceIds) then
    Exit(Failure(rcCTDraftSourceUnverified, '/recipe_id/source_evidence_ids'));

  for I := 0 to High(AProposal.Entries) do
  begin
    if AProposal.Entries[I].RequestedKind = deGroup then Continue;
    Result := FStore.LoadCandidate(AProposal.Entries[I].CandidateId, Candidate);
    if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
      '/entries/' + IntToStr(I) + '/candidate_id'));
    if not KindMatches(AProposal.Entries[I].RequestedKind, Candidate.Kind) then
      Exit(Failure(rcCTDraftEntryKindUnsupported,
        '/entries/' + IntToStr(I) + '/kind'));
    if Candidate.CompatibilityHash <> ABundle.Recipe.CompatibilityHash then
      Exit(Failure(rcCTDraftCompatibilityMismatch,
        '/entries/' + IntToStr(I) + '/candidate_id'));
    if (Candidate.Target.ProcessIdentityId <> ABundle.Verification.Target.ProcessIdentityId) or
       (Candidate.Target.Epoch <> ABundle.Verification.Target.Epoch) then
      Exit(Failure(rcCTDraftStaleRuntimeEvidence,
        '/entries/' + IntToStr(I) + '/candidate_id'));
    SetLength(ABundle.Candidates, Length(ABundle.Candidates) + 1);
    ABundle.Candidates[High(ABundle.Candidates)] := Candidate;

    if not ParseIdArray(AProposal.Entries[I].EvidenceIdsJson,
      EntryEvidenceIds) then
      Exit(Failure(rcCTDraftSourceMissing,
        '/entries/' + IntToStr(I) + '/evidence_ids'));
    if not ContainsId(EntryEvidenceIds, Candidate.DiscoveryEvidenceId) then
      Exit(Failure(rcCTDraftSourceUnverified,
        '/entries/' + IntToStr(I) + '/evidence_ids'));
    for J := 0 to High(EntryEvidenceIds) do
    begin
      if not ContainsId(RecipeEvidenceIds, EntryEvidenceIds[J]) then
        Exit(Failure(rcCTDraftSourceUnverified,
          '/entries/' + IntToStr(I) + '/evidence_ids/' + IntToStr(J)));
      Result := FStore.LoadEvidence(EntryEvidenceIds[J], Evidence);
      if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
        '/entries/' + IntToStr(I) + '/evidence_ids/' + IntToStr(J)));
      if (Evidence.Scope = esRuntime) and
         ((Evidence.Target.ProcessIdentityId <> ABundle.Verification.Target.ProcessIdentityId) or
          (Evidence.Target.Epoch <> ABundle.Verification.Target.Epoch)) then
        Exit(Failure(rcCTDraftStaleRuntimeEvidence,
          '/entries/' + IntToStr(I) + '/evidence_ids/' + IntToStr(J)));
      Found := False;
      for K := 0 to High(ABundle.Evidence) do
        if ABundle.Evidence[K].Id = Evidence.Id then Found := True;
      if not Found then begin
        SetLength(ABundle.Evidence, Length(ABundle.Evidence) + 1);
        ABundle.Evidence[High(ABundle.Evidence)] := Evidence;
      end;
    end;

    if not ParseIdArray(AProposal.Entries[I].ProofIdsJson, EntryProofIds) then
      Exit(Failure(rcCTDraftSourceMissing,
        '/entries/' + IntToStr(I) + '/proof_ids'));
    if not ContainsId(EntryProofIds, ABundle.Verification.ProofId) then
      Exit(Failure(rcCTDraftSourceUnverified,
        '/entries/' + IntToStr(I) + '/proof_ids'));
    for J := 0 to High(EntryProofIds) do begin
      Result := FGovernance.LoadProof(EntryProofIds[J], Proof);
      if Result.Failed then Exit(Failure(rcCTDraftSourceMissing,
        '/entries/' + IntToStr(I) + '/proof_ids/' + IntToStr(J)));
      if Proof.Outcome <> poPass then Exit(Failure(rcCTDraftSourceUnverified,
        '/entries/' + IntToStr(I) + '/proof_ids/' + IntToStr(J)));
      Found := False;
      for K := 0 to High(ABundle.Proofs) do
        if ABundle.Proofs[K].Id = Proof.Id then Found := True;
      if not Found then begin
        SetLength(ABundle.Proofs, Length(ABundle.Proofs) + 1);
        ABundle.Proofs[High(ABundle.Proofs)] := Proof;
      end;
    end;
  end;
  ABundle.ProofIdsJson := AProposal.Entries[0].ProofIdsJson;
  Result := TCEAResult.Ok('{"resolved":true}');
end;

end.

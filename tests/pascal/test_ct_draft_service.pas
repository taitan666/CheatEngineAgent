program test_ct_draft_service;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, FPJSON, JSONParser, cea_types, cea_results, cea_ports, cea_reverse_types,
  cea_ct_draft_types, cea_ct_draft_ports, cea_ct_draft_service,
  cea_test_ports;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise Exception.Create(AMessage);
end;

function HashOf(const C: Char): string;
begin
  Result := 'sha256:' + StringOfChar(C, 64);
end;

function HasFindingCode(const AJson, ACode: string): Boolean;
var D:TJSONData; A:TJSONArray; I:Integer;
begin
  Result:=False; D:=GetJSON(AJson);
  try
    if D.JSONType<>jtArray then Exit;
    A:=TJSONArray(D);
    for I:=0 to A.Count-1 do
      if (A.Items[I].JSONType=jtObject) and
         (TJSONObject(A.Items[I]).Get('code','')=ACode) then Exit(True);
  finally D.Free; end;
end;

type
  TBundleResolver = class(TObject, ICEACTDraftSourceResolver)
  public
    Bundle: TCEACTDraftSourceBundle;
    NextResult: TCEAResult;
    function Resolve(const AProposal: TCEACTDraftProposal;
      out ABundle: TCEACTDraftSourceBundle): TCEAResult;
  end;

  TMemoryDraftRepository = class(TObject, ICEACTDraftRepository)
  public
    Items: TCEACTDraftArray;
    function SaveDraft(const ADraft: TCEACTDraft): TCEAResult;
    function LoadDraft(const ADraftId: string;
      out ADraft: TCEACTDraft): TCEAResult;
    function ListDrafts(const ALimit: Cardinal;
      out ADrafts: TCEACTDraftArray): TCEAResult;
    function UpdateExportState(const ADraftId, AExpectedHash: string;
      const AState: TCEACTDraftState; const AExportJson: string): TCEAResult;
  end;

function TBundleResolver.Resolve(const AProposal: TCEACTDraftProposal;
  out ABundle: TCEACTDraftSourceBundle): TCEAResult;
begin
  ABundle := Bundle;
  if NextResult.Code = rcOk then Result := TCEAResult.Ok('{"resolved":true}')
  else Result := NextResult;
end;

function TMemoryDraftRepository.SaveDraft(const ADraft: TCEACTDraft): TCEAResult;
var I: Integer;
begin
  for I := 0 to High(Items) do if Items[I].Id = ADraft.Id then begin
    if Items[I].ContentHash = ADraft.ContentHash then Exit(TCEAResult.Ok('{}'));
    Exit(TCEAResult.Error(rcCTDraftRevisionStale,
      'ct_draft_revision_stale', '{}'));
  end;
  SetLength(Items, Length(Items) + 1); Items[High(Items)] := ADraft;
  Result := TCEAResult.Ok('{}');
end;

function TMemoryDraftRepository.LoadDraft(const ADraftId: string;
  out ADraft: TCEACTDraft): TCEAResult;
var I: Integer;
begin
  for I := 0 to High(Items) do if Items[I].Id = ADraftId then begin
    ADraft := Items[I]; Exit(TCEAResult.Ok('{}'));
  end;
  Result := TCEAResult.Error(rcCTDraftSourceMissing,
    'ct_draft_source_missing', '{}');
end;

function TMemoryDraftRepository.ListDrafts(const ALimit: Cardinal;
  out ADrafts: TCEACTDraftArray): TCEAResult;
var I, N: Integer;
begin
  N := Length(Items); if N > Integer(ALimit) then N := ALimit;
  SetLength(ADrafts, N); for I := 0 to N - 1 do ADrafts[I] := Items[I];
  Result := TCEAResult.Ok('{}');
end;

function TMemoryDraftRepository.UpdateExportState(const ADraftId,
  AExpectedHash: string; const AState: TCEACTDraftState;
  const AExportJson: string): TCEAResult;
begin
  Result := TCEAResult.Error(rcNotImplemented, 'not_used', '{}');
end;

procedure SetProposalEntry(var E: TCEACTDraftProposalEntry;
  const AId, ADescription: string; const AKind: TCEACTDraftEntryKind;
  const AValueType: TCEACTDraftValueType; const AOrder: Cardinal);
begin
  E.CandidateId := AId; E.Description := ADescription;
  E.RequestedKind := AKind; E.RequestedValueType := AValueType;
  E.Order := AOrder; E.EvidenceIdsJson := '["evidence:scan"]';
  E.ProofIdsJson := '["proof:pass"]';
end;

var
  Resolver: TBundleResolver;
  ResolverPort: ICEACTDraftSourceResolver;
  Repo: TMemoryDraftRepository;
  RepoPort: ICEACTDraftRepository;
  Hasher: TCEATestHasher;
  HasherPort: ICEAHasher;
  Clock: TCEATestClock;
  ClockPort: ICEAClock;
  Service: TCEACTDraftService;
  Proposal, Bad: TCEACTDraftProposal;
  Draft, RepeatDraft, Revised, Abandoned: TCEACTDraft;
  Candidate: TCEACandidateLocation;
  I: Integer;
  R: TCEAResult;
begin
  Resolver := TBundleResolver.Create; Repo := TMemoryDraftRepository.Create;
  Hasher := TCEATestHasher.Create; Clock := TCEATestClock.Create;
  ResolverPort := Resolver; RepoPort := Repo; HasherPort := Hasher; ClockPort := Clock;
  try
    Resolver.NextResult := TCEAResult.Ok('{}');
    Clock.CurrentTime := '2026-09-22T01:02:03Z';
    Resolver.Bundle.Recipe.Id := 'recipe:fixture';
    Resolver.Bundle.Recipe.SchemaVersion := '1.0';
    Resolver.Bundle.Recipe.Name := 'Fixture';
    Resolver.Bundle.Recipe.CompatibilityHash := HashOf('c');
    Resolver.Bundle.Recipe.SourceEvidenceIdsJson := '["evidence:scan"]';
    Resolver.Bundle.Recipe.RequiredCapabilityIdsJson := '["memory.read"]';
    Resolver.Bundle.Recipe.VerificationPlanJson := '{"checks":["readback"]}';
    Resolver.Bundle.Verification.Id := 'verification:pass';
    Resolver.Bundle.Verification.SchemaVersion := '1.0';
    Resolver.Bundle.Verification.RecipeId := Resolver.Bundle.Recipe.Id;
    Resolver.Bundle.Verification.Target.ProcessIdentityId := 'process:fixture';
    Resolver.Bundle.Verification.Target.Epoch := 9;
    Resolver.Bundle.Verification.Outcome := voPass;
    Resolver.Bundle.Verification.ProofId := 'proof:pass';
    Resolver.Bundle.TargetExecutableSha256 := HashOf('b');
    Resolver.Bundle.ModuleSetHash := HashOf('f');
    Resolver.Bundle.ProofIdsJson := '["proof:pass"]';
    SetLength(Resolver.Bundle.Evidence, 1);
    Resolver.Bundle.Evidence[0].Id := 'evidence:scan';
    Resolver.Bundle.Evidence[0].ContentHash := HashOf('e');
    SetLength(Resolver.Bundle.Proofs, 1);
    Resolver.Bundle.Proofs[0].Id := 'proof:pass';
    Resolver.Bundle.Proofs[0].VerificationHash := HashOf('d');

    SetLength(Resolver.Bundle.Candidates, 3);
    Candidate.Id := 'candidate:absolute'; Candidate.SchemaVersion := '1.0';
    Candidate.Kind := ckAbsoluteAddress; Candidate.Target := Resolver.Bundle.Verification.Target;
    Candidate.AddressText := '0x1000'; Candidate.AddressWidthBits := 64;
    Candidate.CompatibilityHash := HashOf('c'); Candidate.DiscoveryEvidenceId := 'evidence:scan';
    Resolver.Bundle.Candidates[0] := Candidate;
    Candidate.Id := 'candidate:module'; Candidate.Kind := ckModuleOffset;
    Candidate.AddressText := '0x1234'; Candidate.ModuleName := 'C:\Games\GAME.EXE';
    Resolver.Bundle.Candidates[1] := Candidate;
    Candidate.Id := 'candidate:pointer'; Candidate.Kind := ckPointerChain;
    Candidate.AddressText := '0x2000'; Candidate.ModuleName := 'GAME.EXE';
    Candidate.PointerOffsetsJson := '["0x10","0x20"]';
    Candidate.AobEvidenceJson := '["48 8B ??"]';
    Resolver.Bundle.Candidates[2] := Candidate;

    FillChar(Proposal, SizeOf(Proposal), 0);
    Proposal.SchemaVersion := '1.0'; Proposal.RecipeId := 'recipe:fixture';
    Proposal.VerificationRunId := 'verification:pass'; Proposal.GameName := 'Fixture Game';
    SetLength(Proposal.Entries, 4);
    SetProposalEntry(Proposal.Entries[0], '', 'Player', deGroup, dvNone, 0);
    SetProposalEntry(Proposal.Entries[1], 'candidate:absolute', 'Absolute health', deAbsoluteAddress, dvDword, 1);
    SetProposalEntry(Proposal.Entries[2], 'candidate:module', 'Module health', deModuleOffset, dvDword, 2);
    SetProposalEntry(Proposal.Entries[3], 'candidate:pointer', 'Pointer health', dePointerChain, dvDword, 3);

    Service := TCEACTDraftService.Create(ResolverPort, RepoPort, HasherPort, ClockPort);
    try
      R := Service.Propose(Proposal, Draft);
      Check(R.Code = rcOk, 'verified proposal accepted');
      Check(Draft.IsValid and (Draft.Revision = 1) and
        (Draft.State = dsValidated), 'validated revision one');
      Check((Draft.Entries[1].Kind = deAbsoluteAddress) and
        (drNonPortable in Draft.Entries[1].RiskFlags), 'absolute risk');
      Check(HasFindingCode(Draft.FindingsJson,
        'absolute_address_non_portable'), 'absolute warning is structured');
      Check(Draft.Entries[2].ModuleName = 'game.exe', 'module basename normalized');
      Check((Length(Draft.Entries[3].PointerOffsets) = 2) and
        (Draft.Entries[3].AobEvidenceJson = '["48 8B ??"]'),
        'pointer and AOB metadata preserved');
      Check((Pos('evidence:scan', Draft.SourceHashesJson) > 0) and
        (Pos('proof:pass', Draft.SourceHashesJson) > 0),
        'source hashes retained');

      Check(Service.Propose(Proposal, RepeatDraft).Code = rcOk,
        'repeat proposal accepted');
      Check((RepeatDraft.ContentHash = Draft.ContentHash) and
        (RepeatDraft.Id = Draft.Id), 'deterministic content and ID');

      Bad := Proposal; Bad.Entries := Copy(Proposal.Entries);
      Bad.Entries[1].Description := 'bad' + #1 + 'xml';
      R := Service.Propose(Bad, RepeatDraft);
      Check((R.Code = rcCTDraftXmlCharacterInvalid) and
        (Pos('/entries/1/description', R.DataJson) > 0),
        'invalid XML control rejected with pointer');
      Bad := Proposal; Bad.Entries := Copy(Proposal.Entries);
      Bad.Entries[1].Description := StringOfChar('x', 513);
      Check(Service.Propose(Bad, RepeatDraft).Code = rcCTDraftBudgetExceeded,
        'description byte budget');
      Bad := Proposal; Bad.Entries := Copy(Proposal.Entries);
      SetLength(Bad.Entries, 257);
      for I := 0 to 256 do begin
        Bad.Entries[I] := Proposal.Entries[1]; Bad.Entries[I].Order := I;
      end;
      Check(Service.Propose(Bad, RepeatDraft).Code = rcCTDraftBudgetExceeded,
        'entry count budget');

      Resolver.Bundle.Candidates[2].PointerOffsetsJson := '[' +
        '"0x1","0x2","0x3","0x4","0x5","0x6","0x7","0x8",' +
        '"0x9","0xa","0xb","0xc","0xd","0xe","0xf","0x10",' +
        '"0x11","0x12","0x13","0x14","0x15","0x16","0x17","0x18",' +
        '"0x19","0x1a","0x1b","0x1c","0x1d","0x1e","0x1f","0x20","0x21"]';
      Check(Service.Propose(Proposal, RepeatDraft).Code = rcCTDraftBudgetExceeded,
        'pointer depth budget');
      Resolver.Bundle.Candidates[2].PointerOffsetsJson := '["0x10","0x20"]';

      Resolver.Bundle.Candidates[2].PointerOffsetsJson :=
        '["0x1111111111111111111111111111111"]';
      Check(Service.Propose(Proposal, RepeatDraft).Code = rcCTDraftBudgetExceeded,
        'offset text budget');
      Resolver.Bundle.Candidates[2].PointerOffsetsJson := '["0x10","0x20"]';

      Resolver.Bundle.Candidates[0].AddressText := '0x10000000000000000';
      Check(Service.Propose(Proposal, RepeatDraft).Code = rcCTDraftBudgetExceeded,
        'address arithmetic overflow');
      Resolver.Bundle.Candidates[0].AddressText := '0x1000';

      Bad := Proposal; Bad.Entries := Copy(Proposal.Entries);
      Bad.Entries[2].RequestedValueType := dvByteArray;
      Check(Service.Propose(Bad, RepeatDraft).Code =
        rcCTDraftValueTypeUnsupported, 'byte array requires exact length');

      Bad := Proposal; Bad.Entries := Copy(Proposal.Entries);
      Bad.Entries[2] := Bad.Entries[1]; Bad.Entries[2].Order := 2;
      R := Service.Propose(Bad, RepeatDraft);
      Check(R.StableCode = 'ct_draft_duplicate_entry',
        'duplicate semantic locator rejected, got ' + R.StableCode +
        ' ' + R.DataJson);

      Check(Service.Revalidate(Draft.Id, Revised).Code = rcOk,
        'revalidation creates child');
      Check((Revised.Revision = 2) and (Revised.ParentDraftId = Draft.Id) and
        (Draft.Revision = 1), 'old revision remains immutable');
      Check(Service.Abandon(Revised.Id, Abandoned).Code = rcOk,
        'abandon creates child');
      Check((Abandoned.State = dsInvalidated) and
        (Abandoned.Revision = 3) and (Abandoned.ParentDraftId = Revised.Id),
        'abandoned child revision');
    finally Service.Free; end;
    WriteLn('CT_DRAFT_SERVICE=PASS');
  finally
    ResolverPort := nil; RepoPort := nil; HasherPort := nil; ClockPort := nil;
    Clock.Free; Hasher.Free; Repo.Free; Resolver.Free;
  end;
end.

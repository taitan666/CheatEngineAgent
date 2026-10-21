program test_ct_draft_contracts;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_reverse_types, cea_ct_draft_types,
  cea_ct_draft_ports;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create(AMessage);
end;

function HashOf(const C: Char): string;
begin
  Result := 'sha256:' + StringOfChar(C, 64);
end;

var
  Entry: TCEACTDraftEntry;
  Draft: TCEACTDraft;
  Proposal: TCEACTDraftProposal;
  Request: TCEACTDraftExportRequest;
  ExportResult: TCEACTDraftExportResult;
begin
  Check(CTDraftStateText(dsProposed) = 'proposed', 'proposed state text');
  Check(CTDraftStateText(dsExportUnknown) = 'export_unknown',
    'unknown state text');
  Check(TryParseCTDraftState('validated', Draft.State) and
    (Draft.State = dsValidated), 'state round trip');
  Check(CTDraftEntryKindText(dePointerChain) = 'pointer_chain',
    'pointer kind text');
  Check(CTDraftValueTypeText(dvDword) = '4 Bytes', 'CE dword text');
  Check(CTDraftValueTypeText(dvByteArray) = 'Array of byte',
    'CE byte array text');

  FillChar(Entry, SizeOf(Entry), 0);
  Entry.Ordinal := 0;
  Entry.ParentOrdinal := -1;
  Entry.Kind := deModuleOffset;
  Entry.Description := 'Health & lives';
  Entry.ValueType := dvDword;
  Entry.AddressWidthBits := 64;
  Entry.AddressText := '0x1234';
  Entry.ModuleName := 'game.exe';
  Entry.CandidateId := 'candidate:health';
  Entry.EvidenceIdsJson := '["evidence:scan"]';
  Entry.VerificationOutcome := voPass;
  Entry.CompatibilityHash := HashOf('a');
  Check(Entry.IsValid, 'bounded module entry');

  SetLength(Draft.Entries, 1);
  Draft.Entries[0] := Entry;
  Draft.Id := 'ctdraft:one';
  Draft.Revision := 1;
  Draft.SchemaVersion := '1.0';
  Draft.State := dsValidated;
  Draft.GameName := 'Fixture Game';
  Draft.TargetExecutableSha256 := HashOf('b');
  Draft.ModuleSetHash := HashOf('c');
  Draft.CompatibilityHash := HashOf('a');
  Draft.RecipeId := 'recipe:health';
  Draft.VerificationRunId := 'verification:health';
  Draft.EvidenceIdsJson := '["evidence:scan"]';
  Draft.ProofIdsJson := '["proof:health"]';
  Draft.SourceHashesJson := '{"evidence:scan":"' + HashOf('e') + '"}';
  Draft.GeneratorVersion := 'ct-draft-v1';
  Draft.ContentHash := HashOf('d');
  Draft.FindingsJson := '[]';
  Draft.FailureModesJson := '[]';
  Draft.CreatedAt := '2026-09-21T00:00:00Z';
  Draft.UpdatedAt := Draft.CreatedAt;
  Check(Draft.IsValid, 'bounded immutable draft');

  SetLength(Draft.Entries, 257);
  Check(not Draft.IsValid, '257 entries rejected');
  SetLength(Draft.Entries, 1);
  Draft.Entries[0] := Entry;

  FillChar(Proposal, SizeOf(Proposal), 0);
  Proposal.SchemaVersion := '1.0';
  Proposal.RecipeId := Draft.RecipeId;
  Proposal.VerificationRunId := Draft.VerificationRunId;
  Proposal.GameName := Draft.GameName;
  SetLength(Proposal.Entries, 1);
  Proposal.Entries[0].CandidateId := Entry.CandidateId;
  Proposal.Entries[0].Description := Entry.Description;
  Proposal.Entries[0].RequestedKind := deModuleOffset;
  Proposal.Entries[0].RequestedValueType := dvDword;
  Proposal.Entries[0].Order := 0;
  Proposal.Entries[0].EvidenceIdsJson := Entry.EvidenceIdsJson;
  Proposal.Entries[0].ProofIdsJson := Draft.ProofIdsJson;
  Check(Proposal.IsValid, 'authority-free proposal');

  FillChar(Request, SizeOf(Request), 0);
  Request.DraftId := Draft.Id;
  Request.RevisionHash := Draft.ContentHash;
  Request.DestinationPath := 'C:\temp\fixture.ct';
  Request.ExpectedAbsent := True;
  Request.MaxOutputBytes := 4 * 1024 * 1024;
  Request.ExpectedSha256 := HashOf('e');
  Check(Request.IsValid, 'bounded create-new request');

  FillChar(ExportResult, SizeOf(ExportResult), 0);
  ExportResult.DraftId := Draft.Id;
  ExportResult.EffectId := 'effect:export';
  ExportResult.State := dsExported;
  ExportResult.ByteCount := 128;
  ExportResult.ReadbackSha256 := Request.ExpectedSha256;
  ExportResult.ReceiptId := 'receipt:export';
  ExportResult.ProofId := 'proof:export';
  Check(ExportResult.IsValid, 'verified export result');

  Check(ResultCodeToStableCode(rcCTDraftSourceMissing) =
    'ct_draft_source_missing', 'source missing result');
  Check(ResultCodeToStableCode(rcCTDraftSourceUnverified) =
    'ct_draft_source_unverified', 'source unverified result');
  Check(ResultCodeToStableCode(rcCTDraftStaleRuntimeEvidence) =
    'ct_draft_stale_runtime_evidence', 'stale evidence result');
  Check(ResultCodeToStableCode(rcCTDraftCompatibilityMismatch) =
    'ct_draft_compatibility_mismatch', 'compatibility result');
  Check(ResultCodeToStableCode(rcCTDraftEntryKindUnsupported) =
    'ct_draft_entry_kind_unsupported', 'entry kind result');
  Check(ResultCodeToStableCode(rcCTDraftValueTypeUnsupported) =
    'ct_draft_value_type_unsupported', 'value type result');
  Check(ResultCodeToStableCode(rcCTDraftBudgetExceeded) =
    'ct_draft_budget_exceeded', 'budget result');
  Check(ResultCodeToStableCode(rcCTDraftXmlCharacterInvalid) =
    'ct_draft_xml_character_invalid', 'XML result');
  Check(ResultCodeToStableCode(rcCTDraftRevisionStale) =
    'ct_draft_revision_stale', 'revision result');
  Check(ResultCodeToStableCode(rcCTDraftDestinationExists) =
    'ct_draft_destination_exists', 'destination result');
  Check(ResultCodeToStableCode(rcCTDraftExportApprovalRequired) =
    'ct_draft_export_approval_required', 'approval result');
  Check(ResultCodeToStableCode(rcCTDraftExportReadbackMismatch) =
    'ct_draft_export_readback_mismatch', 'readback result');
  Check(ResultCodeToStableCode(rcCTDraftExportUnknown) =
    'ct_draft_export_unknown', 'unknown export result');

  WriteLn('CT_DRAFT_CONTRACTS=PASS');
end.

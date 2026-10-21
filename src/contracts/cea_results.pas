unit cea_results;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

type
  TCEAResultCode = (rcOk, rcRejected, rcUnknown, rcNotImplemented,
    rcInvalidArgument, rcConflict, rcUnauthenticated, rcUnauthorized,
    rcApprovalRequired, rcPolicyDenied, rcTargetNotOffline,
    rcStaleProcessIdentity, rcLeaseExpired, rcBudgetExceeded,
    rcScanRunning, rcAmbiguousMatch, rcVerificationFailed, rcCancelled,
    rcTimeout, rcUnknownOutcome, rcInternalError,
    rcCTDraftSourceMissing, rcCTDraftSourceUnverified,
    rcCTDraftStaleRuntimeEvidence, rcCTDraftCompatibilityMismatch,
    rcCTDraftEntryKindUnsupported, rcCTDraftValueTypeUnsupported,
    rcCTDraftBudgetExceeded, rcCTDraftXmlCharacterInvalid,
    rcCTDraftRevisionStale, rcCTDraftDestinationExists,
    rcCTDraftExportApprovalRequired, rcCTDraftExportReadbackMismatch,
    rcCTDraftExportUnknown);

  TCEAResult = record
    Code: TCEAResultCode;
    StableCode: string;
    MessageText: string;
    DataJson: string;
    ReceiptId: string;
    ProofId: string;
    class function Ok(const ADataJson: string): TCEAResult; static;
    class function Error(const ACode: TCEAResultCode; const AStableCode,
      ADataJson: string): TCEAResult; static;
    function Failed: Boolean;
  end;

function CEAResult(const ACode: TCEAResultCode; const AMessage: string): TCEAResult;
function NotImplementedResult(const ACapability: string): TCEAResult;
function ResultCodeToStableCode(const ACode: TCEAResultCode): string;

{ DataJson is UTF-8 JSON by contract, but every payload that carries non-ASCII
  text is assembled by concatenating string literals, so FPC tags the result
  with DefaultSystemCodePage (936 on a Chinese Windows). GetJSON then transcodes
  those UTF-8 bytes from 936 and a trailing byte such as 0x8F swallows the
  closing quote, which surfaces as a parse error deep inside a caller rather
  than as a bad payload here. Tagging at the source keeps the bytes untouched
  and tells every consumer what they already are. }
function Utf8JsonText(const AValue: string): string;

implementation

function Utf8JsonText(const AValue: string): string;
var
  Raw: RawByteString;
begin
  Raw := AValue;
  SetCodePage(Raw, CP_UTF8, False);
  Result := Raw;
end;

function ResultCodeToStableCode(const ACode: TCEAResultCode): string;
begin
  case ACode of
    rcOk: Result := 'ok';
    rcRejected: Result := 'rejected';
    rcUnknown: Result := 'unknown';
    rcNotImplemented: Result := 'not_implemented';
    rcInvalidArgument: Result := 'invalid_argument';
    rcConflict: Result := 'conflict';
    rcUnauthenticated: Result := 'unauthenticated';
    rcUnauthorized: Result := 'unauthorized';
    rcApprovalRequired: Result := 'approval_required';
    rcPolicyDenied: Result := 'policy_denied';
    rcTargetNotOffline: Result := 'target_not_offline';
    rcStaleProcessIdentity: Result := 'stale_process_identity';
    rcLeaseExpired: Result := 'lease_expired';
    rcBudgetExceeded: Result := 'budget_exceeded';
    rcScanRunning: Result := 'scan_running';
    rcAmbiguousMatch: Result := 'ambiguous_match';
    rcVerificationFailed: Result := 'verification_failed';
    rcCancelled: Result := 'cancelled';
    rcTimeout: Result := 'timeout';
    rcUnknownOutcome: Result := 'unknown_outcome';
    rcInternalError: Result := 'internal_error';
    rcCTDraftSourceMissing: Result := 'ct_draft_source_missing';
    rcCTDraftSourceUnverified: Result := 'ct_draft_source_unverified';
    rcCTDraftStaleRuntimeEvidence: Result := 'ct_draft_stale_runtime_evidence';
    rcCTDraftCompatibilityMismatch: Result := 'ct_draft_compatibility_mismatch';
    rcCTDraftEntryKindUnsupported: Result := 'ct_draft_entry_kind_unsupported';
    rcCTDraftValueTypeUnsupported: Result := 'ct_draft_value_type_unsupported';
    rcCTDraftBudgetExceeded: Result := 'ct_draft_budget_exceeded';
    rcCTDraftXmlCharacterInvalid: Result := 'ct_draft_xml_character_invalid';
    rcCTDraftRevisionStale: Result := 'ct_draft_revision_stale';
    rcCTDraftDestinationExists: Result := 'ct_draft_destination_exists';
    rcCTDraftExportApprovalRequired: Result := 'ct_draft_export_approval_required';
    rcCTDraftExportReadbackMismatch: Result := 'ct_draft_export_readback_mismatch';
    rcCTDraftExportUnknown: Result := 'ct_draft_export_unknown';
  end;
end;

class function TCEAResult.Ok(const ADataJson: string): TCEAResult;
begin
  Result.Code := rcOk;
  Result.StableCode := ResultCodeToStableCode(rcOk);
  Result.MessageText := '';
  Result.DataJson := Utf8JsonText(ADataJson);
  Result.ReceiptId := '';
  Result.ProofId := '';
end;

class function TCEAResult.Error(const ACode: TCEAResultCode;
  const AStableCode, ADataJson: string): TCEAResult;
begin
  Result.Code := ACode;
  if AStableCode <> '' then
    Result.StableCode := AStableCode
  else
    Result.StableCode := ResultCodeToStableCode(ACode);
  Result.MessageText := Result.StableCode;
  Result.DataJson := Utf8JsonText(ADataJson);
  Result.ReceiptId := '';
  Result.ProofId := '';
end;

function TCEAResult.Failed: Boolean;
begin
  Result := Code <> rcOk;
end;

function CEAResult(const ACode: TCEAResultCode; const AMessage: string): TCEAResult;
begin
  Result.Code := ACode;
  Result.StableCode := ResultCodeToStableCode(ACode);
  Result.MessageText := AMessage;
  Result.DataJson := '{}';
  Result.ReceiptId := '';
  Result.ProofId := '';
end;

function NotImplementedResult(const ACapability: string): TCEAResult;
begin
  Result := CEAResult(rcNotImplemented,
    ACapability + ' is declared by the scaffold but has no operational adapter');
end;

end.

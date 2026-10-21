unit cea_verification_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_reverse_types;

type
  TCEAVerificationService = class
  private
    procedure InitializeRun(const AExperimentId: string;
      const ATarget: TCEATargetBinding; const AEvidenceId,
      AProofId: string; out ARun: TCEAVerificationRun);
  public
    function VerifyAobUniqueness(const AExperimentId: string;
      const ATarget: TCEATargetBinding; const AMatchCount,
      AExpectedMatchCount: Cardinal; const AEvidenceId, AProofId: string;
      out ARun: TCEAVerificationRun): TCEAResult;
    function VerifyReadback(const AExperimentId: string;
      const ATarget: TCEATargetBinding; const AExpectedHex, AActualHex: string;
      const AReadResultCode: TCEAResultCode; const AEvidenceId,
      AProofId: string; out ARun: TCEAVerificationRun): TCEAResult;
    function CanRetryAutomatically(
      const ARun: TCEAVerificationRun): Boolean;
  end;

implementation

procedure TCEAVerificationService.InitializeRun(const AExperimentId: string;
  const ATarget: TCEATargetBinding; const AEvidenceId, AProofId: string;
  out ARun: TCEAVerificationRun);
begin
  ARun.Id := 'verification:' + AExperimentId + ':' + AEvidenceId;
  ARun.SchemaVersion := '1.0';
  ARun.ExperimentId := AExperimentId;
  ARun.Target := ATarget;
  ARun.ChecksJson := '[]';
  ARun.ProofId := AProofId;
  ARun.Outcome := voPending;
end;

function TCEAVerificationService.VerifyAobUniqueness(
  const AExperimentId: string; const ATarget: TCEATargetBinding;
  const AMatchCount, AExpectedMatchCount: Cardinal;
  const AEvidenceId, AProofId: string;
  out ARun: TCEAVerificationRun): TCEAResult;
begin
  InitializeRun(AExperimentId, ATarget, AEvidenceId, AProofId, ARun);
  ARun.ChecksJson := Format('[{"kind":"aob_unique","actual":%d,' +
    '"expected":%d}]', [AMatchCount, AExpectedMatchCount]);
  if (AExperimentId = '') or not ATarget.IsValid or (AEvidenceId = '') or
     (AExpectedMatchCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'verification_input_invalid', '{}'));
  if (AMatchCount <> AExpectedMatchCount) or (AMatchCount <> 1) then
  begin
    ARun.Outcome := voInconclusive;
    ARun.ProofId := '';
    Exit(TCEAResult.Error(rcAmbiguousMatch, 'ambiguous_match',
      ARun.ChecksJson));
  end;
  if AProofId = '' then
  begin
    ARun.Outcome := voInconclusive;
    Exit(TCEAResult.Error(rcVerificationFailed,
      'verification_proof_required', ARun.ChecksJson));
  end;
  ARun.Outcome := voPass;
  Result := TCEAResult.Ok(ARun.ChecksJson);
end;

function TCEAVerificationService.VerifyReadback(
  const AExperimentId: string; const ATarget: TCEATargetBinding;
  const AExpectedHex, AActualHex: string; const AReadResultCode: TCEAResultCode;
  const AEvidenceId, AProofId: string;
  out ARun: TCEAVerificationRun): TCEAResult;
begin
  InitializeRun(AExperimentId, ATarget, AEvidenceId, AProofId, ARun);
  if AReadResultCode in [rcUnknown, rcTimeout, rcUnknownOutcome] then
  begin
    ARun.Outcome := voUnknown;
    ARun.ProofId := '';
    Exit(TCEAResult.Error(rcUnknownOutcome, 'unknown_outcome', '{}'));
  end;
  if (AReadResultCode <> rcOk) or (AExpectedHex <> AActualHex) then
  begin
    ARun.Outcome := voFail;
    ARun.ProofId := '';
    Exit(TCEAResult.Error(rcVerificationFailed,
      'readback_mismatch', '{}'));
  end;
  if AProofId = '' then
  begin
    ARun.Outcome := voInconclusive;
    Exit(TCEAResult.Error(rcVerificationFailed,
      'verification_proof_required', '{}'));
  end;
  ARun.Outcome := voPass;
  Result := TCEAResult.Ok('{"readback":"match"}');
end;

function TCEAVerificationService.CanRetryAutomatically(
  const ARun: TCEAVerificationRun): Boolean;
begin
  Result := ARun.Outcome <> voUnknown;
end;

end.

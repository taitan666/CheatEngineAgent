unit cea_hypothesis_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_reverse_types;

type
  TCEAHypothesisService = class
  private
    FItems: array of TCEAHypothesis;
  public
    function Add(const AHypothesis: TCEAHypothesis;
      const ACandidate: TCEACandidateLocation;
      const AEvidence: TCEAEvidenceReference): TCEAResult;
    function Count: Cardinal;
  end;

implementation

function TCEAHypothesisService.Add(const AHypothesis: TCEAHypothesis;
  const ACandidate: TCEACandidateLocation;
  const AEvidence: TCEAEvidenceReference): TCEAResult;
begin
  if (AHypothesis.Id = '') or (AHypothesis.ExperimentId = '') or
     (AHypothesis.StatementText = '') or
     (AHypothesis.ConfidenceBasis = '') or
     (AHypothesis.CandidateId <> ACandidate.Id) or
     (Pos('"' + AEvidence.Id + '"', AHypothesis.EvidenceIdsJson) = 0) or
     not ACandidate.IsValid or not AEvidence.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'hypothesis_invalid', '{}'));
  if (ACandidate.Target.ProcessIdentityId <> AEvidence.Target.ProcessIdentityId) or
     (ACandidate.Target.Epoch <> AEvidence.Target.Epoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'hypothesis_evidence_target_changed', '{}'));
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := AHypothesis;
  Result := TCEAResult.Ok('{"hypothesis_id":"' + AHypothesis.Id + '"}');
end;

function TCEAHypothesisService.Count: Cardinal;
begin
  Result := Length(FItems);
end;

end.

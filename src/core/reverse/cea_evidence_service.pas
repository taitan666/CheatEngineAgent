unit cea_evidence_service;

{$mode objfpc}{$H+}

interface

uses
  cea_results, cea_reverse_types;

type
  TCEAEvidenceService = class
  private
    FItems: array of TCEAEvidenceReference;
  public
    function Add(const AEvidence: TCEAEvidenceReference;
      const ACurrentTarget: TCEATargetBinding): TCEAResult;
    function Find(const AEvidenceId: string;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
    function FindForTarget(const AEvidenceId: string;
      const ACurrentTarget: TCEATargetBinding;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
    function Count: Cardinal;
  end;

implementation

function TCEAEvidenceService.Add(const AEvidence: TCEAEvidenceReference;
  const ACurrentTarget: TCEATargetBinding): TCEAResult;
var
  Existing: TCEAEvidenceReference;
begin
  if not AEvidence.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_invalid', '{}'));
  if (AEvidence.Scope = esRuntime) and
     ((AEvidence.Target.ProcessIdentityId <> ACurrentTarget.ProcessIdentityId) or
      (AEvidence.Target.Epoch <> ACurrentTarget.Epoch)) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'evidence_target_changed', '{}'));
  if not Find(AEvidence.Id, Existing).Failed then
    Exit(TCEAResult.Error(rcConflict, 'evidence_already_exists', '{}'));
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := AEvidence;
  Result := TCEAResult.Ok('{"evidence_id":"' + AEvidence.Id + '"}');
end;

function TCEAEvidenceService.Find(const AEvidenceId: string;
  out AEvidence: TCEAEvidenceReference): TCEAResult;
var
  Index: Integer;
begin
  for Index := Low(FItems) to High(FItems) do
    if FItems[Index].Id = AEvidenceId then
    begin
      AEvidence := FItems[Index];
      Exit(TCEAResult.Ok('{}'));
    end;
  Result := TCEAResult.Error(rcInvalidArgument, 'evidence_not_found', '{}');
end;

function TCEAEvidenceService.FindForTarget(const AEvidenceId: string;
  const ACurrentTarget: TCEATargetBinding;
  out AEvidence: TCEAEvidenceReference): TCEAResult;
begin
  Result := Find(AEvidenceId, AEvidence);
  if Result.Failed then
    Exit;
  if (AEvidence.Scope = esRuntime) and
     ((AEvidence.Target.ProcessIdentityId <> ACurrentTarget.ProcessIdentityId) or
      (AEvidence.Target.Epoch <> ACurrentTarget.Epoch)) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'evidence_target_changed', '{}'));
end;

function TCEAEvidenceService.Count: Cardinal;
begin
  Result := Length(FItems);
end;

end.

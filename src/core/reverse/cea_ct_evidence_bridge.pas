unit cea_ct_evidence_bridge;

{$mode objfpc}{$H+}

interface

uses
  cea_results, cea_ct_model, cea_reverse_types;

type
  TCEACTEvidenceBridge = class
  public
    function BuildCatalogEvidence(const AArtifact: TCTArtifact;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
  end;

implementation

function TCEACTEvidenceBridge.BuildCatalogEvidence(
  const AArtifact: TCTArtifact;
  out AEvidence: TCEAEvidenceReference): TCEAResult;
begin
  FillChar(AEvidence, SizeOf(AEvidence), 0);
  if (AArtifact.ContentHash = '') or (AArtifact.SourceUri = '') or
     (AArtifact.ParserVersion = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_evidence_artifact_invalid', '{}'));
  AEvidence.Id := 'evidence-ct-' + Copy(AArtifact.ContentHash, 8, 32);
  AEvidence.SchemaVersion := '1.0';
  AEvidence.Scope := esCatalog;
  AEvidence.Kind := ekCTArtifact;
  AEvidence.ProvenanceUri := AArtifact.SourceUri;
  AEvidence.ContentHash := AArtifact.ContentHash;
  AEvidence.ProducedByCapabilityId := 'ct_import';
  if not AEvidence.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_evidence_reference_invalid', '{}'));
  Result := TCEAResult.Ok('{"evidence_id":"' + AEvidence.Id +
    '","scope":"catalog","authority":"none"}');
end;

end.

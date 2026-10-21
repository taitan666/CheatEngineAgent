unit cea_ct_rag;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_ports, cea_results, cea_types, cea_ct_parser, cea_ct_catalog;

type
  TCTKnowledgeAdapter = class(TObject, ICTKnowledgePort)
  private
    FParser: TCTParser;
    FCatalog: TCTCatalog;
  public
    constructor Create(const AParser: TCTParser; const ACatalog: TCTCatalog);
    function ImportArtifact(const ARequest: TCTImportRequest): TCEAResult;
    function Search(const AQuery: TCTRetrievalQuery): TCEAResult;
    function BuildContext(const AQuery: TCTRetrievalQuery): TCEAResult;
  end;

implementation

uses
  SysUtils, cea_ct_model;

constructor TCTKnowledgeAdapter.Create(const AParser: TCTParser;
  const ACatalog: TCTCatalog);
begin
  inherited Create;
  FParser := AParser;
  FCatalog := ACatalog;
end;

function TCTKnowledgeAdapter.ImportArtifact(
  const ARequest: TCTImportRequest): TCEAResult;
var
  Artifact: TCTArtifact;
begin
  if (FParser = nil) or (FCatalog = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'ct_adapter_dependencies_missing', '{}'));
  if not FileExists(ARequest.SourceId) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_local_file_required', '{}'));
  Result := FParser.ParseFile(ARequest.SourceId, ARequest.ProvenanceUri,
    Artifact);
  if Result.Failed then Exit;
  if (ARequest.ContentHash <> '') and
     (ARequest.ContentHash <> Artifact.ContentHash) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'ct_content_hash_mismatch', '{}'));
  Result := FCatalog.ImportParsedArtifact(Artifact);
end;

function TCTKnowledgeAdapter.Search(
  const AQuery: TCTRetrievalQuery): TCEAResult;
begin
  if FCatalog = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ct_catalog_missing', '{}'));
  Result := FCatalog.SearchText(AQuery.Text, AQuery.MaxResults);
end;

function TCTKnowledgeAdapter.BuildContext(
  const AQuery: TCTRetrievalQuery): TCEAResult;
begin
  if FCatalog = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ct_catalog_missing', '{}'));
  Result := FCatalog.BuildRagContext(AQuery.Text, AQuery.MaxResults);
end;

end.

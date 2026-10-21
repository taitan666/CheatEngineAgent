unit cea_reverse_repository;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_types, cea_results,
  cea_reverse_types, cea_reverse_ports;

type
  TCEAReverseRepository = class(TObject, ICEAReverseArtifactStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
    function ExistingPayload(const ATable, AIdColumn, AId: string;
      out AFound: Boolean; out APayload: string): TCEAResult;
    function ConflictOrSame(const ATable, AIdColumn, AId,
      APayload: string; out AHandled: Boolean): TCEAResult;
    function LoadPayload(const ATable, AIdColumn, AId: string;
      out APayload: string): TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function SaveTargetIdentity(const AIdentity: TCEProcessIdentity): TCEAResult;
    function LoadTargetIdentity(const AIdentityId: string;
      out AIdentity: TCEProcessIdentity): TCEAResult;
    function SaveCandidate(const ACandidate: TCEACandidateLocation): TCEAResult;
    function LoadCandidate(const ACandidateId: string;
      out ACandidate: TCEACandidateLocation): TCEAResult;
    function SaveEvidence(const AEvidence: TCEAEvidenceReference): TCEAResult;
    function LoadEvidence(const AEvidenceId: string;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
    function SaveRecipe(const ARecipe: TCEAReverseRecipe): TCEAResult;
    function LoadRecipe(const ARecipeId: string;
      out ARecipe: TCEAReverseRecipe): TCEAResult;
    function SaveVerificationRun(const ARun: TCEAVerificationRun): TCEAResult;
    function LoadVerificationRun(const ARunId: string;
      out ARun: TCEAVerificationRun): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function IdentityJson(const A: TCEProcessIdentity): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id); O.Add('pid', A.Pid); O.Add('started_at', A.StartedAt);
    O.Add('executable_path_hash', A.ExecutablePathHash);
    O.Add('executable_sha256', A.ExecutableSha256);
    O.Add('architecture', Ord(A.Architecture));
    O.Add('module_set_hash', A.ModuleSetHash); O.Add('epoch', A.Epoch);
    O.Add('target_classification', Ord(A.TargetClassification));
    Result := O.AsJSON;
  finally O.Free; end;
end;

function CandidateJson(const A: TCEACandidateLocation): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id); O.Add('schema_version', A.SchemaVersion);
    O.Add('kind', Ord(A.Kind));
    O.Add('process_identity_id', A.Target.ProcessIdentityId);
    O.Add('epoch', A.Target.Epoch); O.Add('address', A.AddressText);
    O.Add('address_width_bits', A.AddressWidthBits);
    O.Add('module_name', A.ModuleName);
    O.Add('pointer_offsets_json', A.PointerOffsetsJson);
    O.Add('aob_evidence_json', A.AobEvidenceJson);
    O.Add('observed_byte_length', A.ObservedByteLength);
    O.Add('compatibility_hash', A.CompatibilityHash);
    O.Add('discovery_evidence_id', A.DiscoveryEvidenceId);
    Result := O.AsJSON;
  finally O.Free; end;
end;

function EvidenceJson(const A: TCEAEvidenceReference): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id); O.Add('schema_version', A.SchemaVersion);
    O.Add('scope', Ord(A.Scope)); O.Add('kind', Ord(A.Kind));
    O.Add('provenance_uri', A.ProvenanceUri); O.Add('content_hash', A.ContentHash);
    O.Add('process_identity_id', A.Target.ProcessIdentityId);
    O.Add('epoch', A.Target.Epoch);
    O.Add('produced_by_capability_id', A.ProducedByCapabilityId);
    O.Add('observed_at', A.ObservedAt); Result := O.AsJSON;
  finally O.Free; end;
end;

function RecipeJson(const A: TCEAReverseRecipe): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id); O.Add('schema_version', A.SchemaVersion);
    O.Add('name', A.Name); O.Add('compatibility_hash', A.CompatibilityHash);
    O.Add('source_evidence_ids_json', A.SourceEvidenceIdsJson);
    O.Add('required_capability_ids_json', A.RequiredCapabilityIdsJson);
    O.Add('verification_plan_json', A.VerificationPlanJson);
    O.Add('approval_id', A.ApprovalId); Result := O.AsJSON;
  finally O.Free; end;
end;

function VerificationJson(const A: TCEAVerificationRun): string;
var O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id); O.Add('schema_version', A.SchemaVersion);
    O.Add('experiment_id', A.ExperimentId); O.Add('recipe_id', A.RecipeId);
    O.Add('process_identity_id', A.Target.ProcessIdentityId);
    O.Add('epoch', A.Target.Epoch); O.Add('outcome', Ord(A.Outcome));
    O.Add('checks_json', A.ChecksJson); O.Add('proof_id', A.ProofId);
    Result := O.AsJSON;
  finally O.Free; end;
end;

constructor TCEAReverseRepository.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAReverseRepository.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free; FConnection.Free;
  inherited Destroy;
end;

function TCEAReverseRepository.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'reverse_database_path_required', '{}'));
  try
    if not FConnection.Connected then begin
      FConnection.DatabaseName := FDatabasePath; FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'reverse_database_open_failed', '{}');
  end;
end;

function TCEAReverseRepository.Initialize: TCEAResult;
begin
  Result := EnsureConnected; if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS reverse_target_identities ('+
      'identity_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL, executable_sha256 TEXT NOT NULL,'+
      'module_set_hash TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS reverse_recipes ('+
      'recipe_id TEXT PRIMARY KEY, compatibility_hash TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS reverse_candidates ('+
      'candidate_id TEXT PRIMARY KEY, process_identity_id TEXT NOT NULL, epoch INTEGER NOT NULL,'+
      'compatibility_hash TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS reverse_evidence ('+
      'evidence_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS reverse_verification_runs ('+
      'verification_id TEXT PRIMARY KEY, recipe_id TEXT NOT NULL, outcome INTEGER NOT NULL,'+
      'proof_id TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'reverse_repository_initialize_failed', '{}');
  end;
end;

function TCEAReverseRepository.ExistingPayload(const ATable, AIdColumn,
  AId: string; out AFound: Boolean; out APayload: string): TCEAResult;
var Q: TSQLQuery;
begin
  AFound := False; APayload := '';
  Result := EnsureConnected; if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection; Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM ' + ATable +
      ' WHERE ' + AIdColumn + '=:id';
    Q.Params.ParamByName('id').AsString := AId; Q.Open;
    if not Q.EOF then begin AFound := True; APayload := Q.Fields[0].AsString; end;
    Q.Close; FTransaction.Commit; Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'reverse_repository_read_failed', '{}');
  end;
  Q.Free;
end;

function TCEAReverseRepository.ConflictOrSame(const ATable, AIdColumn,
  AId, APayload: string; out AHandled: Boolean): TCEAResult;
var Found: Boolean; Existing: string;
begin
  AHandled := False;
  Result := ExistingPayload(ATable, AIdColumn, AId, Found, Existing);
  if Result.Failed then Exit;
  if Found then begin
    AHandled := True;
    if Existing = APayload then Result := TCEAResult.Ok('{"deduplicated":true}')
    else Result := TCEAResult.Error(rcConflict, 'reverse_artifact_conflict',
      '{"id":"' + AId + '"}');
  end;
end;

function TCEAReverseRepository.LoadPayload(const ATable, AIdColumn,
  AId: string; out APayload: string): TCEAResult;
var Found: Boolean;
begin
  Result := ExistingPayload(ATable, AIdColumn, AId, Found, APayload);
  if not Result.Failed and not Found then
    Result := TCEAResult.Error(rcCTDraftSourceMissing, 'ct_draft_source_missing',
      '{"id":"' + AId + '"}');
end;

function TCEAReverseRepository.SaveTargetIdentity(
  const AIdentity: TCEProcessIdentity): TCEAResult;
var Q: TSQLQuery; P: string; Handled: Boolean;
begin
  if (AIdentity.Id = '') or (AIdentity.Epoch = 0) or
     not IsCEAHash(AIdentity.ExecutableSha256) or not IsCEAHash(AIdentity.ModuleSetHash) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'reverse_target_identity_invalid', '{}'));
  P := IdentityJson(AIdentity);
  Result := ConflictOrSame('reverse_target_identities','identity_id',AIdentity.Id,P,Handled);
  if Result.Failed or Handled then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database:=FConnection; Q.Transaction:=FTransaction;
    Q.SQL.Text:='INSERT INTO reverse_target_identities VALUES(:id,:epoch,:exe,:mods,:payload)';
    Q.Params.ParamByName('id').AsString:=AIdentity.Id;
    Q.Params.ParamByName('epoch').AsLargeInt:=AIdentity.Epoch;
    Q.Params.ParamByName('exe').AsString:=AIdentity.ExecutableSha256;
    Q.Params.ParamByName('mods').AsString:=AIdentity.ModuleSetHash;
    Q.Params.ParamByName('payload').AsString:=P;
    FTransaction.StartTransaction; Q.ExecSQL; FTransaction.Commit; Result:=TCEAResult.Ok('{}');
  except if FTransaction.Active then FTransaction.Rollback; Result:=TCEAResult.Error(rcInternalError,'reverse_repository_write_failed','{}'); end;
  Q.Free;
end;

function TCEAReverseRepository.SaveCandidate(const ACandidate: TCEACandidateLocation): TCEAResult;
var Q:TSQLQuery; P:string; Handled:Boolean;
begin
  if not ACandidate.IsValid then Exit(TCEAResult.Error(rcInvalidArgument,'reverse_candidate_invalid','{}'));
  P:=CandidateJson(ACandidate); Result:=ConflictOrSame('reverse_candidates','candidate_id',ACandidate.Id,P,Handled);
  if Result.Failed or Handled then Exit;
  Q:=TSQLQuery.Create(nil); try Q.Database:=FConnection; Q.Transaction:=FTransaction;
    Q.SQL.Text:='INSERT INTO reverse_candidates VALUES(:id,:process,:epoch,:compat,:payload)';
    Q.Params.ParamByName('id').AsString:=ACandidate.Id; Q.Params.ParamByName('process').AsString:=ACandidate.Target.ProcessIdentityId;
    Q.Params.ParamByName('epoch').AsLargeInt:=ACandidate.Target.Epoch; Q.Params.ParamByName('compat').AsString:=ACandidate.CompatibilityHash;
    Q.Params.ParamByName('payload').AsString:=P; FTransaction.StartTransaction; Q.ExecSQL; FTransaction.Commit; Result:=TCEAResult.Ok('{}');
  except if FTransaction.Active then FTransaction.Rollback; Result:=TCEAResult.Error(rcInternalError,'reverse_repository_write_failed','{}'); end; Q.Free;
end;

function TCEAReverseRepository.SaveEvidence(const AEvidence: TCEAEvidenceReference): TCEAResult;
var Q:TSQLQuery; P:string; Handled:Boolean;
begin
  if not AEvidence.IsValid then Exit(TCEAResult.Error(rcInvalidArgument,'reverse_evidence_invalid','{}'));
  P:=EvidenceJson(AEvidence); Result:=ConflictOrSame('reverse_evidence','evidence_id',AEvidence.Id,P,Handled); if Result.Failed or Handled then Exit;
  Q:=TSQLQuery.Create(nil); try Q.Database:=FConnection; Q.Transaction:=FTransaction; Q.SQL.Text:='INSERT INTO reverse_evidence VALUES(:id,:hash,:payload)';
    Q.Params.ParamByName('id').AsString:=AEvidence.Id; Q.Params.ParamByName('hash').AsString:=AEvidence.ContentHash; Q.Params.ParamByName('payload').AsString:=P;
    FTransaction.StartTransaction; Q.ExecSQL; FTransaction.Commit; Result:=TCEAResult.Ok('{}');
  except if FTransaction.Active then FTransaction.Rollback; Result:=TCEAResult.Error(rcInternalError,'reverse_repository_write_failed','{}'); end; Q.Free;
end;

function TCEAReverseRepository.SaveRecipe(const ARecipe: TCEAReverseRecipe): TCEAResult;
var Q:TSQLQuery; P:string; Handled:Boolean;
begin
  if not ARecipe.IsPortableDefinition then Exit(TCEAResult.Error(rcInvalidArgument,'recipe_invalid','{}'));
  P:=RecipeJson(ARecipe); Result:=ConflictOrSame('reverse_recipes','recipe_id',ARecipe.Id,P,Handled); if Result.Failed or Handled then Exit;
  Q:=TSQLQuery.Create(nil); try Q.Database:=FConnection; Q.Transaction:=FTransaction; Q.SQL.Text:='INSERT INTO reverse_recipes VALUES(:id,:compat,:payload)';
    Q.Params.ParamByName('id').AsString:=ARecipe.Id; Q.Params.ParamByName('compat').AsString:=ARecipe.CompatibilityHash; Q.Params.ParamByName('payload').AsString:=P;
    FTransaction.StartTransaction; Q.ExecSQL; FTransaction.Commit; Result:=TCEAResult.Ok('{}');
  except if FTransaction.Active then FTransaction.Rollback; Result:=TCEAResult.Error(rcInternalError,'reverse_repository_write_failed','{}'); end; Q.Free;
end;

function TCEAReverseRepository.SaveVerificationRun(const ARun: TCEAVerificationRun): TCEAResult;
var Q:TSQLQuery; P:string; Handled:Boolean;
begin
  if (ARun.Id='') or (ARun.SchemaVersion='') or (ARun.RecipeId='') or not ARun.Target.IsValid or (ARun.ChecksJson='') then
    Exit(TCEAResult.Error(rcInvalidArgument,'reverse_verification_invalid','{}'));
  P:=VerificationJson(ARun); Result:=ConflictOrSame('reverse_verification_runs','verification_id',ARun.Id,P,Handled); if Result.Failed or Handled then Exit;
  Q:=TSQLQuery.Create(nil); try Q.Database:=FConnection; Q.Transaction:=FTransaction; Q.SQL.Text:='INSERT INTO reverse_verification_runs VALUES(:id,:recipe,:outcome,:proof,:payload)';
    Q.Params.ParamByName('id').AsString:=ARun.Id; Q.Params.ParamByName('recipe').AsString:=ARun.RecipeId; Q.Params.ParamByName('outcome').AsInteger:=Ord(ARun.Outcome);
    Q.Params.ParamByName('proof').AsString:=ARun.ProofId; Q.Params.ParamByName('payload').AsString:=P; FTransaction.StartTransaction; Q.ExecSQL; FTransaction.Commit; Result:=TCEAResult.Ok('{}');
  except if FTransaction.Active then FTransaction.Rollback; Result:=TCEAResult.Error(rcInternalError,'reverse_repository_write_failed','{}'); end; Q.Free;
end;

function ParseObject(const P: string; out D:TJSONData; out O:TJSONObject):Boolean;
begin
  D:=nil; O:=nil; try D:=GetJSON(P); Result:=D.JSONType=jtObject; if Result then O:=TJSONObject(D); except Result:=False; end;
end;

function TCEAReverseRepository.LoadTargetIdentity(const AIdentityId:string; out AIdentity:TCEProcessIdentity):TCEAResult;
var P:string; D:TJSONData; O:TJSONObject;
begin FillChar(AIdentity,SizeOf(AIdentity),0); Result:=LoadPayload('reverse_target_identities','identity_id',AIdentityId,P); if Result.Failed then Exit;
  if not ParseObject(P,D,O) then Exit(TCEAResult.Error(rcInternalError,'reverse_repository_payload_invalid','{}'));
  try AIdentity.Id:=O.Get('id',''); AIdentity.Pid:=O.Get('pid',0); AIdentity.StartedAt:=O.Get('started_at',''); AIdentity.ExecutablePathHash:=O.Get('executable_path_hash','');
    AIdentity.ExecutableSha256:=O.Get('executable_sha256',''); AIdentity.Architecture:=TCEArchitecture(O.Get('architecture',0)); AIdentity.ModuleSetHash:=O.Get('module_set_hash','');
    AIdentity.Epoch:=QWord(O.Get('epoch',Int64(0))); AIdentity.TargetClassification:=TCETargetClassification(O.Get('target_classification',0)); Result:=TCEAResult.Ok('{}'); finally D.Free; end;
end;

function TCEAReverseRepository.LoadCandidate(const ACandidateId:string; out ACandidate:TCEACandidateLocation):TCEAResult;
var P:string; D:TJSONData; O:TJSONObject;
begin FillChar(ACandidate,SizeOf(ACandidate),0); Result:=LoadPayload('reverse_candidates','candidate_id',ACandidateId,P); if Result.Failed then Exit; if not ParseObject(P,D,O) then Exit(TCEAResult.Error(rcInternalError,'reverse_repository_payload_invalid','{}'));
  try ACandidate.Id:=O.Get('id',''); ACandidate.SchemaVersion:=O.Get('schema_version',''); ACandidate.Kind:=TCEACandidateKind(O.Get('kind',0)); ACandidate.Target.ProcessIdentityId:=O.Get('process_identity_id','');
    ACandidate.Target.Epoch:=QWord(O.Get('epoch',Int64(0))); ACandidate.AddressText:=O.Get('address',''); ACandidate.AddressWidthBits:=O.Get('address_width_bits',0); ACandidate.ModuleName:=O.Get('module_name','');
    ACandidate.PointerOffsetsJson:=O.Get('pointer_offsets_json',''); ACandidate.AobEvidenceJson:=O.Get('aob_evidence_json',''); ACandidate.ObservedByteLength:=O.Get('observed_byte_length',0);
    ACandidate.CompatibilityHash:=O.Get('compatibility_hash',''); ACandidate.DiscoveryEvidenceId:=O.Get('discovery_evidence_id',''); Result:=TCEAResult.Ok('{}'); finally D.Free; end;
end;

function TCEAReverseRepository.LoadEvidence(const AEvidenceId:string; out AEvidence:TCEAEvidenceReference):TCEAResult;
var P:string; D:TJSONData; O:TJSONObject;
begin FillChar(AEvidence,SizeOf(AEvidence),0); Result:=LoadPayload('reverse_evidence','evidence_id',AEvidenceId,P); if Result.Failed then Exit; if not ParseObject(P,D,O) then Exit(TCEAResult.Error(rcInternalError,'reverse_repository_payload_invalid','{}'));
  try AEvidence.Id:=O.Get('id',''); AEvidence.SchemaVersion:=O.Get('schema_version',''); AEvidence.Scope:=TCEAEvidenceScope(O.Get('scope',0)); AEvidence.Kind:=TCEAEvidenceKind(O.Get('kind',0));
    AEvidence.ProvenanceUri:=O.Get('provenance_uri',''); AEvidence.ContentHash:=O.Get('content_hash',''); AEvidence.Target.ProcessIdentityId:=O.Get('process_identity_id',''); AEvidence.Target.Epoch:=QWord(O.Get('epoch',Int64(0)));
    AEvidence.ProducedByCapabilityId:=O.Get('produced_by_capability_id',''); AEvidence.ObservedAt:=O.Get('observed_at',''); Result:=TCEAResult.Ok('{}'); finally D.Free; end;
end;

function TCEAReverseRepository.LoadRecipe(const ARecipeId:string; out ARecipe:TCEAReverseRecipe):TCEAResult;
var P:string; D:TJSONData; O:TJSONObject;
begin FillChar(ARecipe,SizeOf(ARecipe),0); Result:=LoadPayload('reverse_recipes','recipe_id',ARecipeId,P); if Result.Failed then Exit; if not ParseObject(P,D,O) then Exit(TCEAResult.Error(rcInternalError,'reverse_repository_payload_invalid','{}'));
  try ARecipe.Id:=O.Get('id',''); ARecipe.SchemaVersion:=O.Get('schema_version',''); ARecipe.Name:=O.Get('name',''); ARecipe.CompatibilityHash:=O.Get('compatibility_hash','');
    ARecipe.SourceEvidenceIdsJson:=O.Get('source_evidence_ids_json',''); ARecipe.RequiredCapabilityIdsJson:=O.Get('required_capability_ids_json',''); ARecipe.VerificationPlanJson:=O.Get('verification_plan_json',''); ARecipe.ApprovalId:=O.Get('approval_id',''); Result:=TCEAResult.Ok('{}'); finally D.Free; end;
end;

function TCEAReverseRepository.LoadVerificationRun(const ARunId:string; out ARun:TCEAVerificationRun):TCEAResult;
var P:string; D:TJSONData; O:TJSONObject;
begin FillChar(ARun,SizeOf(ARun),0); Result:=LoadPayload('reverse_verification_runs','verification_id',ARunId,P); if Result.Failed then Exit; if not ParseObject(P,D,O) then Exit(TCEAResult.Error(rcInternalError,'reverse_repository_payload_invalid','{}'));
  try ARun.Id:=O.Get('id',''); ARun.SchemaVersion:=O.Get('schema_version',''); ARun.ExperimentId:=O.Get('experiment_id',''); ARun.RecipeId:=O.Get('recipe_id',''); ARun.Target.ProcessIdentityId:=O.Get('process_identity_id','');
    ARun.Target.Epoch:=QWord(O.Get('epoch',Int64(0))); ARun.Outcome:=TCEAVerificationOutcome(O.Get('outcome',0)); ARun.ChecksJson:=O.Get('checks_json',''); ARun.ProofId:=O.Get('proof_id',''); Result:=TCEAResult.Ok('{}'); finally D.Free; end;
end;

end.

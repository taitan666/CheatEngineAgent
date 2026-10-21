unit cea_field_evidence;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

{ FR-052 evidence recording (P0).

  PRD 6.6 asks that the product save, for every candidate location: the
  address, the data type, the observed change, the process/version it applies
  to, and the verification result. That is a *player-facing* record, and it is
  narrower than the reverse-domain TCEAEvidenceReference (which only carries
  provenance, a content hash and a target binding, with no notion of a field,
  a value type or a previous value).

  This unit keeps both shapes in one place:

  * TCEAFieldEvidence is what the UI lists and what the store persists.
  * ToReference() converts a record into a valid TCEAEvidenceReference so the
    reverse-domain artifact store can hold it too, which is what makes the
    evidence usable by the candidate/recipe pipeline later.

  Safety boundary: evidence is a record of what was observed. It never
  upgrades a field to writable and it is never consulted to decide whether a
  write is allowed. Only a fresh compare-write-readback may do that. }

interface

uses
  SysUtils, cea_results, cea_ports, cea_types, cea_reverse_types;

type
  TCEAFieldEvidence = record
    EvidenceId: string;
    FieldId: string;
    DisplayName: string;
    Kind: TCEAEvidenceKind;
    AddressText: string;
    ValueType: string;
    PreviousValueJson: string;
    ObservedValueJson: string;
    ProcessIdentityId: string;
    Epoch: QWord;
    ExecutableSha256: string;
    ModuleSetHash: string;
    Outcome: TCEAVerificationOutcome;
    DetailJson: string;
    ProvenanceUri: string;
    ContentHash: string;
    RecordedAt: string;
    function IsValid: Boolean;
    function Target: TCEATargetBinding;
  end;

  TCEAFieldEvidenceArray = array of TCEAFieldEvidence;

  ICEAFieldEvidenceStore = interface
    ['{2C4B7E19-5A8D-4F63-9B27-6D1E3A8C5F02}']
    function Initialize: TCEAResult;
    function AppendEvidence(const AEvidence: TCEAFieldEvidence): TCEAResult;
    function ListForField(const AFieldId: string; const ALimit: Cardinal;
      out AItems: TCEAFieldEvidenceArray): TCEAResult;
    function Count: Cardinal;
  end;

  TCEAFieldEvidenceService = class
  private
    FHasher: ICEAHasher;
    FStore: ICEAFieldEvidenceStore;
    FSequence: Int64;
    function NormalizeHash(const AHash: string): string;
    function BuildRecord(const AFieldId, ADisplayName: string;
      const AKind: TCEAEvidenceKind; const AAddressText, AValueType,
      APreviousValueJson, AObservedValueJson: string;
      const AIdentity: TCEProcessIdentity;
      const AOutcome: TCEAVerificationOutcome;
      const ADetailJson, ARecordedAt: string;
      out AEvidence: TCEAFieldEvidence): TCEAResult;
  public
    constructor Create(const AHasher: ICEAHasher;
      const AStore: ICEAFieldEvidenceStore);
    { A capture is a memory observation: no outcome yet, the value is a fact. }
    function RecordCapture(const AFieldId, ADisplayName, AAddressText,
      AValueType, APreviousValueJson, AObservedValueJson, ADetailJson: string;
      const AIdentity: TCEProcessIdentity; const ARecordedAt: string;
      out AEvidence: TCEAFieldEvidence): TCEAResult;
    { A verified write is a verification record: it states an outcome. }
    function RecordVerification(const AFieldId, ADisplayName, AAddressText,
      AValueType, APreviousValueJson, AObservedValueJson, ADetailJson: string;
      const AIdentity: TCEProcessIdentity;
      const AOutcome: TCEAVerificationOutcome; const ARecordedAt: string;
      out AEvidence: TCEAFieldEvidence): TCEAResult;
    { A human declaring which field a location belongs to is user evidence. }
    function RecordUserConfirmation(const AFieldId, ADisplayName,
      AAddressText, AValueType, ADetailJson: string;
      const AIdentity: TCEProcessIdentity; const ARecordedAt: string;
      out AEvidence: TCEAFieldEvidence): TCEAResult;
    function ListForField(const AFieldId: string; const ALimit: Cardinal;
      out AItems: TCEAFieldEvidenceArray): TCEAResult;
    function Count: Cardinal;
    function ToReference(
      const AEvidence: TCEAFieldEvidence): TCEAEvidenceReference;
  end;

const
  CeaFieldEvidenceSchemaVersion = '1.0';
  CeaFieldEvidenceDefaultLimit = 50;
  CeaFieldEvidenceMaxLimit = 500;

{ Text forms are the contract used by JSON payloads, MCP tools and the UI; the
  ordinal is never exposed because reordering the enum would silently relabel
  stored evidence. }
function EvidenceKindText(const AKind: TCEAEvidenceKind): string;
function TryParseEvidenceKind(const AText: string;
  out AKind: TCEAEvidenceKind): Boolean;
function EvidenceOutcomeText(const AOutcome: TCEAVerificationOutcome): string;
function TryParseEvidenceOutcome(const AText: string;
  out AOutcome: TCEAVerificationOutcome): Boolean;
function EvidenceScopeText(const AScope: TCEAEvidenceScope): string;
{ FR-052 is a record, not a permission. These two answer "may this evidence be
  cited when justifying a write?" and both deliberately exclude the weak kinds:
  a user statement names the field but says nothing about writability, and a
  failed/unknown verification says the opposite. }
function IsWriteSupportingKind(const AKind: TCEAEvidenceKind): Boolean;
function IsWriteSupportingOutcome(const AOutcome: TCEAVerificationOutcome): Boolean;

implementation

function EvidenceKindText(const AKind: TCEAEvidenceKind): string;
begin
  case AKind of
    ekCTArtifact: Result := 'ct_artifact';
    ekMemoryObservation: Result := 'memory_observation';
    ekScanSnapshot: Result := 'scan_snapshot';
    ekDisassembly: Result := 'disassembly';
    ekVerification: Result := 'verification';
    ekUserStatement: Result := 'user_statement';
  else
    Result := 'unknown';
  end;
end;

function TryParseEvidenceKind(const AText: string;
  out AKind: TCEAEvidenceKind): Boolean;
begin
  Result := True;
  if AText = 'ct_artifact' then AKind := ekCTArtifact
  else if AText = 'memory_observation' then AKind := ekMemoryObservation
  else if AText = 'scan_snapshot' then AKind := ekScanSnapshot
  else if AText = 'disassembly' then AKind := ekDisassembly
  else if AText = 'verification' then AKind := ekVerification
  else if AText = 'user_statement' then AKind := ekUserStatement
  else
  begin
    AKind := ekMemoryObservation;
    Result := False;
  end;
end;

function EvidenceOutcomeText(const AOutcome: TCEAVerificationOutcome): string;
begin
  case AOutcome of
    voPending: Result := 'pending';
    voPass: Result := 'pass';
    voFail: Result := 'fail';
    voInconclusive: Result := 'inconclusive';
    voUnknown: Result := 'unknown';
  else
    Result := 'unknown';
  end;
end;

function TryParseEvidenceOutcome(const AText: string;
  out AOutcome: TCEAVerificationOutcome): Boolean;
begin
  Result := True;
  if AText = 'pending' then AOutcome := voPending
  else if AText = 'pass' then AOutcome := voPass
  else if AText = 'fail' then AOutcome := voFail
  else if AText = 'inconclusive' then AOutcome := voInconclusive
  else if AText = 'unknown' then AOutcome := voUnknown
  else
  begin
    AOutcome := voUnknown;
    Result := False;
  end;
end;

function EvidenceScopeText(const AScope: TCEAEvidenceScope): string;
begin
  if AScope = esRuntime then
    Result := 'runtime'
  else
    Result := 'catalog';
end;

function IsWriteSupportingKind(const AKind: TCEAEvidenceKind): Boolean;
begin
  Result := AKind in [ekMemoryObservation, ekVerification];
end;

function IsWriteSupportingOutcome(
  const AOutcome: TCEAVerificationOutcome): Boolean;
begin
  Result := AOutcome in [voPass, voInconclusive];
end;

function TCEAFieldEvidence.Target: TCEATargetBinding;
begin
  Result.ProcessIdentityId := ProcessIdentityId;
  Result.Epoch := Epoch;
end;

function TCEAFieldEvidence.IsValid: Boolean;
begin
  Result := (EvidenceId <> '') and (FieldId <> '') and
    (ProcessIdentityId <> '') and (Epoch > 0) and (RecordedAt <> '') and
    (ProvenanceUri <> '') and IsCEAHash(ContentHash);
end;

constructor TCEAFieldEvidenceService.Create(const AHasher: ICEAHasher;
  const AStore: ICEAFieldEvidenceStore);
begin
  inherited Create;
  FHasher := AHasher;
  FStore := AStore;
  FSequence := 0;
end;

function TCEAFieldEvidenceService.NormalizeHash(const AHash: string): string;
begin
  Result := AHash;
  if (Length(Result) <> 71) and (Copy(Result, 1, 7) <> 'sha256:') then
    Result := 'sha256:' + Result;
end;

function TCEAFieldEvidenceService.BuildRecord(const AFieldId,
  ADisplayName: string; const AKind: TCEAEvidenceKind;
  const AAddressText, AValueType, APreviousValueJson, AObservedValueJson: string;
  const AIdentity: TCEProcessIdentity;
  const AOutcome: TCEAVerificationOutcome;
  const ADetailJson, ARecordedAt: string;
  out AEvidence: TCEAFieldEvidence): TCEAResult;
var
  Seed: string;
begin
  AEvidence := Default(TCEAFieldEvidence);
  if AFieldId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_field_required', '{}'));
  if (AIdentity.Id = '') or (AIdentity.Epoch = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_target_required', '{}'));
  if ARecordedAt = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_timestamp_required', '{}'));
  if FHasher = nil then
    Exit(TCEAResult.Error(rcInternalError, 'evidence_hasher_required', '{}'));

  { The store keys on evidence_id, so a restarted service must not start again
    at one: that would collide with an existing row and silently lose the new
    observation. Seeding from the row count keeps ids unique across restarts
    because this store has no delete path. }
  if (FSequence = 0) and (FStore <> nil) then
    FSequence := FStore.Count;

  Inc(FSequence);
  AEvidence.EvidenceId := 'field-evidence-' + IntToHex(FSequence, 8);
  AEvidence.FieldId := AFieldId;
  AEvidence.DisplayName := ADisplayName;
  AEvidence.Kind := AKind;
  AEvidence.AddressText := AAddressText;
  AEvidence.ValueType := AValueType;
  AEvidence.PreviousValueJson := APreviousValueJson;
  AEvidence.ObservedValueJson := AObservedValueJson;
  AEvidence.ProcessIdentityId := AIdentity.Id;
  AEvidence.Epoch := AIdentity.Epoch;
  AEvidence.ExecutableSha256 := AIdentity.ExecutableSha256;
  AEvidence.ModuleSetHash := AIdentity.ModuleSetHash;
  AEvidence.Outcome := AOutcome;
  AEvidence.DetailJson := ADetailJson;
  AEvidence.RecordedAt := ARecordedAt;
  AEvidence.ProvenanceUri := 'cea://runtime/field/' + AFieldId + '/' +
    AEvidence.EvidenceId;

  { The hash covers the sequence number too: two captures of the same value in
    the same epoch are distinct observations and must not collapse into one
    artifact through the store's de-duplication. }
  Seed := AFieldId + #0 + AObservedValueJson + #0 + APreviousValueJson + #0 +
    AIdentity.Id + #0 + IntToStr(AIdentity.Epoch) + #0 + ARecordedAt + #0 +
    AEvidence.EvidenceId;
  AEvidence.ContentHash := NormalizeHash(FHasher.HashUtf8(Seed));

  if not AEvidence.IsValid then
    Exit(TCEAResult.Error(rcInternalError, 'evidence_record_invalid', '{}'));

  if FStore <> nil then
  begin
    Result := FStore.AppendEvidence(AEvidence);
    if Result.Failed then
      Exit(Result);
  end;

  Result := TCEAResult.Ok('{"evidence_id":"' + AEvidence.EvidenceId +
    '","field_id":"' + AFieldId + '","content_hash":"' +
    AEvidence.ContentHash + '"}');
end;

function TCEAFieldEvidenceService.RecordCapture(const AFieldId, ADisplayName,
  AAddressText, AValueType, APreviousValueJson, AObservedValueJson,
  ADetailJson: string; const AIdentity: TCEProcessIdentity;
  const ARecordedAt: string;
  out AEvidence: TCEAFieldEvidence): TCEAResult;
begin
  Result := BuildRecord(AFieldId, ADisplayName, ekMemoryObservation,
    AAddressText, AValueType, APreviousValueJson, AObservedValueJson, AIdentity,
    voPending, ADetailJson, ARecordedAt, AEvidence);
end;

function TCEAFieldEvidenceService.RecordVerification(const AFieldId,
  ADisplayName, AAddressText, AValueType, APreviousValueJson,
  AObservedValueJson, ADetailJson: string;
  const AIdentity: TCEProcessIdentity;
  const AOutcome: TCEAVerificationOutcome; const ARecordedAt: string;
  out AEvidence: TCEAFieldEvidence): TCEAResult;
begin
  if AOutcome = voPending then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_outcome_required', '{}'));
  Result := BuildRecord(AFieldId, ADisplayName, ekVerification,
    AAddressText, AValueType, APreviousValueJson, AObservedValueJson, AIdentity,
    AOutcome, ADetailJson, ARecordedAt, AEvidence);
end;

function TCEAFieldEvidenceService.RecordUserConfirmation(const AFieldId,
  ADisplayName, AAddressText, AValueType, ADetailJson: string;
  const AIdentity: TCEProcessIdentity; const ARecordedAt: string;
  out AEvidence: TCEAFieldEvidence): TCEAResult;
begin
  Result := BuildRecord(AFieldId, ADisplayName, ekUserStatement,
    AAddressText, AValueType, '', '', AIdentity, voInconclusive, ADetailJson,
    ARecordedAt, AEvidence);
end;

function TCEAFieldEvidenceService.ListForField(const AFieldId: string;
  const ALimit: Cardinal; out AItems: TCEAFieldEvidenceArray): TCEAResult;
var
  Limit: Cardinal;
begin
  SetLength(AItems, 0);
  if FStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'evidence_store_required', '{}'));
  Limit := ALimit;
  if Limit = 0 then
    Limit := CeaFieldEvidenceDefaultLimit;
  if Limit > CeaFieldEvidenceMaxLimit then
    Limit := CeaFieldEvidenceMaxLimit;
  Result := FStore.ListForField(AFieldId, Limit, AItems);
end;

function TCEAFieldEvidenceService.Count: Cardinal;
begin
  if FStore = nil then
    Exit(0);
  Result := FStore.Count;
end;

function TCEAFieldEvidenceService.ToReference(
  const AEvidence: TCEAFieldEvidence): TCEAEvidenceReference;
begin
  Result := Default(TCEAEvidenceReference);
  Result.Id := AEvidence.EvidenceId;
  Result.SchemaVersion := CeaFieldEvidenceSchemaVersion;
  Result.Scope := esRuntime;
  Result.Kind := AEvidence.Kind;
  Result.ProvenanceUri := AEvidence.ProvenanceUri;
  Result.ContentHash := AEvidence.ContentHash;
  Result.Target := AEvidence.Target;
  Result.ProducedByCapabilityId := 'memory_read';
  Result.ObservedAt := AEvidence.RecordedAt;
end;

end.

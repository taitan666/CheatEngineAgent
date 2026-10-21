unit cea_mapping_service;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_reverse_types;

type
  // Mapping proposal source (PRD 6.3 / 6.9: separate data from inference)
  TCEAMappingProposalKind = (
    mpUserDeclared,     // user declared manually: may be confirmed directly
    mpAiInferred,       // AI inference: must enter pending state (AC-014)
    mpReverseCandidate, // reverse candidate location: must enter pending (AC-014)
    mpCtEntry           // CT entry import: must enter pending (AC-014)
  );

  // Mapping lifecycle state
  TCEAMappingState = (
    msProposed,   // pending confirmation: not usable for writes
    msConfirmed,  // confirmed: may materialize a field (access starts read_only)
    msRejected,   // rejected: record kept but unusable
    msSuperseded  // replaced by a newer proposal
  );

  // Locator layer (candidate address) -> semantic layer (field) mapping
  TCEAFieldMapping = record
    Id: string;
    FieldId: string;
    DisplayName: string;
    ValueType: string;
    CandidateLocationId: string;
    AddressHex: string;
    ModuleName: string;
    PointerOffsetsJson: string;
    AddressWidthBits: Cardinal;
    Source: TCEAMappingProposalKind;
    State: TCEAMappingState;
    Confidence: Double;
    EvidenceRefsJson: string;
    CreatedAt: string;
    function IsValid: Boolean;
  end;

  TCEAFieldMappingArray = array of TCEAFieldMapping;

  TCEAMappingService = class
  private
    FMappings: TCEAFieldMappingArray;
    FSequence: QWord;
    function FindIndex(const AMappingId: string): Integer;
    function FindByField(const AFieldId: string): Integer;
    function NextId: string;
    function Propose(const AFieldId, ADisplayName, AValueType,
      ACandidateLocationId, AAddressHex, AModuleName,
      APointerOffsetsJson, AEvidenceRefsJson: string;
      const AAddressWidthBits: Cardinal;
      const AKind: TCEAMappingProposalKind;
      const AConfidence: Double; const ACreatedAt: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
  public
    constructor Create;
    // Propose from a reverse candidate location (always pending)
    function ProposeFromCandidate(const ACandidate: TCEACandidateLocation;
      const AFieldId, ADisplayName, AValueType: string;
      const ACreatedAt: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    // AI-inferred proposal (always pending, AC-014)
    function ProposeFromAi(const AFieldId, ADisplayName, AValueType,
      AAddressHex, AEvidenceRefsJson: string; const AConfidence: Double;
      const ACreatedAt: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    // User-declared mapping (may be confirmed directly)
    function ProposeUserDeclared(const AFieldId, ADisplayName, AValueType,
      AAddressHex: string; const ACreatedAt: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    // User-declared pointer chain: the address is resolved on demand, so the
    // field survives a target restart (real-game verification).
    function ProposePointerChain(const AFieldId, ADisplayName, AValueType,
      AModuleName, AOffsetsJson: string;
      const AAddressWidthBits: Cardinal; const ACreatedAt: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    // Confirm a mapping (rejected/superseded proposals cannot be confirmed)
    function Confirm(const AMappingId: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    function Reject(const AMappingId: string;
      out AMapping: TCEAFieldMapping): TCEAResult;
    function GetMapping(const AMappingId: string;
      out AMapping: TCEAFieldMapping): Boolean;
    function GetMappings: TCEAFieldMappingArray;
    function MappingCount: Integer;
    // Materialize a confirmed mapping into a semantic field
    // (access conservatively starts at read_only)
    function MaterializeField(const AMappingId: string;
      const ALastUpdated: string; out AField: TCEAGameField): TCEAResult;
  end;

function MappingProposalKindText(const AKind: TCEAMappingProposalKind): string;
function TryParseMappingProposalKind(const AText: string;
  out AKind: TCEAMappingProposalKind): Boolean;
function MappingStateText(const AState: TCEAMappingState): string;
function TryParseMappingState(const AText: string;
  out AState: TCEAMappingState): Boolean;
// Memory primitive type -> semantic value type (PRD 8.4)
function SemanticValueType(const AValueType: string): string;
function IsSupportedValueType(const AValueType: string): Boolean;

implementation

function MappingProposalKindText(const AKind: TCEAMappingProposalKind): string;
begin
  case AKind of
    mpUserDeclared: Result := 'user_declared';
    mpAiInferred: Result := 'ai_inferred';
    mpReverseCandidate: Result := 'reverse_candidate';
    mpCtEntry: Result := 'ct_entry';
  end;
end;

function TryParseMappingProposalKind(const AText: string;
  out AKind: TCEAMappingProposalKind): Boolean;
var
  K: TCEAMappingProposalKind;
begin
  for K := Low(TCEAMappingProposalKind) to High(TCEAMappingProposalKind) do
    if MappingProposalKindText(K) = AText then
    begin
      AKind := K;
      Exit(True);
    end;
  Result := False;
end;

function MappingStateText(const AState: TCEAMappingState): string;
begin
  case AState of
    msProposed: Result := 'proposed';
    msConfirmed: Result := 'confirmed';
    msRejected: Result := 'rejected';
    msSuperseded: Result := 'superseded';
  end;
end;

function TryParseMappingState(const AText: string;
  out AState: TCEAMappingState): Boolean;
var
  S: TCEAMappingState;
begin
  for S := Low(TCEAMappingState) to High(TCEAMappingState) do
    if MappingStateText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function SemanticValueType(const AValueType: string): string;
begin
  if (AValueType = 'byte') or (AValueType = 'word') or
     (AValueType = 'dword') or (AValueType = 'qword') or
     (AValueType = 'integer') then
    Result := 'integer'
  else if (AValueType = 'single') or (AValueType = 'double') then
    Result := 'single'
  else if AValueType = 'bool' then
    Result := 'bool'
  else if AValueType = 'enum' then
    Result := 'enum'
  else if AValueType = 'string' then
    Result := 'string'
  else
    Result := AValueType;
end;

function IsSupportedValueType(const AValueType: string): Boolean;
begin
  Result := (AValueType = 'byte') or (AValueType = 'word') or
    (AValueType = 'dword') or (AValueType = 'qword') or
    (AValueType = 'integer') or (AValueType = 'single') or
    (AValueType = 'double') or (AValueType = 'bool') or
    (AValueType = 'enum') or (AValueType = 'string');
end;

function TCEAFieldMapping.IsValid: Boolean;
begin
  { A mapping needs a location of some kind: an absolute address, a reverse
    candidate, or a pointer chain (which carries its own module + offsets). }
  Result := (Id <> '') and (FieldId <> '') and (DisplayName <> '') and
    (ValueType <> '') and (CreatedAt <> '') and
    (Confidence >= 0.0) and (Confidence <= 1.0) and
    ((AddressHex <> '') or (CandidateLocationId <> '') or
     ((PointerOffsetsJson <> '') and (ModuleName <> '') and
      (AddressWidthBits in [32, 64])));
end;

constructor TCEAMappingService.Create;
begin
  inherited Create;
  SetLength(FMappings, 0);
  FSequence := 0;
end;

function TCEAMappingService.NextId: string;
begin
  Inc(FSequence);
  Result := 'mapping-' + IntToHex(FSequence, 8);
end;

function TCEAMappingService.FindIndex(const AMappingId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FMappings) do
    if FMappings[I].Id = AMappingId then
      Exit(I);
  Result := -1;
end;

function TCEAMappingService.FindByField(const AFieldId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FMappings) do
    if FMappings[I].FieldId = AFieldId then
      Exit(I);
  Result := -1;
end;

function TCEAMappingService.Propose(const AFieldId, ADisplayName, AValueType,
  ACandidateLocationId, AAddressHex, AModuleName, APointerOffsetsJson,
  AEvidenceRefsJson: string; const AAddressWidthBits: Cardinal;
  const AKind: TCEAMappingProposalKind;
  const AConfidence: Double; const ACreatedAt: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
var
  Existing: Integer;
begin
  FillChar(AMapping, SizeOf(AMapping), 0);
  if (Trim(AFieldId) = '') or (Trim(ADisplayName) = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'mapping_field_required', '{}'));
  if not IsSupportedValueType(AValueType) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'mapping_value_type_unsupported', '{}'));
  if (AConfidence < 0.0) or (AConfidence > 1.0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'mapping_confidence_invalid', '{}'));
  // A chain without a module name cannot be re-resolved after a restart, so it
  // is rejected here rather than materializing a field that only works once.
  if (AAddressWidthBits <> 0) and not (AAddressWidthBits in [32, 64]) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'mapping_address_width_invalid', '{}'));
  if (Trim(APointerOffsetsJson) <> '') and (Trim(AModuleName) = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'mapping_module_name_required', '{}'));
  // A newer proposal for the same field_id supersedes the older one (history kept)
  Existing := FindByField(AFieldId);
  if Existing >= 0 then
    FMappings[Existing].State := msSuperseded;

  AMapping.Id := NextId;
  AMapping.FieldId := AFieldId;
  AMapping.DisplayName := ADisplayName;
  AMapping.ValueType := AValueType;
  AMapping.CandidateLocationId := ACandidateLocationId;
  AMapping.AddressHex := AAddressHex;
  AMapping.ModuleName := AModuleName;
  AMapping.PointerOffsetsJson := APointerOffsetsJson;
  AMapping.AddressWidthBits := AAddressWidthBits;
  AMapping.Source := AKind;
  // AC-014: AI inference / reverse candidate / CT import always enter pending.
  // User-declared may be confirmed directly, but materialized fields still
  // start at read_only.
  if AKind = mpUserDeclared then
    AMapping.State := msConfirmed
  else
    AMapping.State := msProposed;
  AMapping.Confidence := AConfidence;
  AMapping.EvidenceRefsJson := AEvidenceRefsJson;
  AMapping.CreatedAt := ACreatedAt;
  if not AMapping.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'mapping_invalid', '{}'));

  SetLength(FMappings, Length(FMappings) + 1);
  FMappings[High(FMappings)] := AMapping;
  Result := TCEAResult.Ok('{"mapping_id":"' + AMapping.Id + '","state":"' +
    MappingStateText(AMapping.State) + '","source":"' +
    MappingProposalKindText(AMapping.Source) + '"}');
end;

function TCEAMappingService.ProposeFromCandidate(
  const ACandidate: TCEACandidateLocation; const AFieldId, ADisplayName,
  AValueType: string; const ACreatedAt: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
begin
  if not ACandidate.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'candidate_invalid', '{}'));
  Result := Propose(AFieldId, ADisplayName, AValueType, ACandidate.Id,
    ACandidate.AddressText, ACandidate.ModuleName,
    ACandidate.PointerOffsetsJson,
    '["' + ACandidate.DiscoveryEvidenceId + '"]',
    ACandidate.AddressWidthBits,
    mpReverseCandidate, 1.0, ACreatedAt, AMapping);
end;

function TCEAMappingService.ProposeFromAi(const AFieldId, ADisplayName,
  AValueType, AAddressHex, AEvidenceRefsJson: string; const AConfidence: Double;
  const ACreatedAt: string; out AMapping: TCEAFieldMapping): TCEAResult;
begin
  Result := Propose(AFieldId, ADisplayName, AValueType, '', AAddressHex, '',
    '', AEvidenceRefsJson, 0, mpAiInferred, AConfidence, ACreatedAt, AMapping);
end;

function TCEAMappingService.ProposeUserDeclared(const AFieldId, ADisplayName,
  AValueType, AAddressHex: string; const ACreatedAt: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
begin
  Result := Propose(AFieldId, ADisplayName, AValueType, '', AAddressHex, '',
    '', '[]', 0, mpUserDeclared, 1.0, ACreatedAt, AMapping);
end;

function TCEAMappingService.ProposePointerChain(const AFieldId, ADisplayName,
  AValueType, AModuleName, AOffsetsJson: string;
  const AAddressWidthBits: Cardinal; const ACreatedAt: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
begin
  // A chain is user declared because only a human knows which module and
  // offsets describe the field; the resolved address is still verified by the
  // ordinary write -> reread -> match path before any write is allowed.
  Result := Propose(AFieldId, ADisplayName, AValueType, '', '',
    AModuleName, AOffsetsJson, '[]', AAddressWidthBits,
    mpUserDeclared, 1.0, ACreatedAt, AMapping);
end;

function TCEAMappingService.Confirm(const AMappingId: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
var
  I: Integer;
begin
  FillChar(AMapping, SizeOf(AMapping), 0);
  I := FindIndex(AMappingId);
  if I < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'mapping_not_found', '{}'));
  if FMappings[I].State = msRejected then
    Exit(TCEAResult.Error(rcConflict, 'mapping_already_rejected', '{}'));
  if FMappings[I].State = msSuperseded then
    Exit(TCEAResult.Error(rcConflict, 'mapping_superseded', '{}'));
  FMappings[I].State := msConfirmed;
  AMapping := FMappings[I];
  Result := TCEAResult.Ok('{"mapping_id":"' + AMappingId +
    '","state":"confirmed"}');
end;

function TCEAMappingService.Reject(const AMappingId: string;
  out AMapping: TCEAFieldMapping): TCEAResult;
var
  I: Integer;
begin
  FillChar(AMapping, SizeOf(AMapping), 0);
  I := FindIndex(AMappingId);
  if I < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'mapping_not_found', '{}'));
  FMappings[I].State := msRejected;
  AMapping := FMappings[I];
  Result := TCEAResult.Ok('{"mapping_id":"' + AMappingId +
    '","state":"rejected"}');
end;

function TCEAMappingService.GetMapping(const AMappingId: string;
  out AMapping: TCEAFieldMapping): Boolean;
var
  I: Integer;
begin
  I := FindIndex(AMappingId);
  if I < 0 then
  begin
    FillChar(AMapping, SizeOf(AMapping), 0);
    Exit(False);
  end;
  AMapping := FMappings[I];
  Result := True;
end;

function TCEAMappingService.GetMappings: TCEAFieldMappingArray;
begin
  Result := FMappings;
end;

function TCEAMappingService.MappingCount: Integer;
begin
  Result := Length(FMappings);
end;

function TCEAMappingService.MaterializeField(const AMappingId: string;
  const ALastUpdated: string; out AField: TCEAGameField): TCEAResult;
var
  I: Integer;
begin
  FillChar(AField, SizeOf(AField), 0);
  I := FindIndex(AMappingId);
  if I < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'mapping_not_found', '{}'));
  if FMappings[I].State <> msConfirmed then
    Exit(TCEAResult.Error(rcApprovalRequired,
      'mapping_not_confirmed', '{}'));
  AField.FieldId := FMappings[I].FieldId;
  AField.DisplayName := FMappings[I].DisplayName;
  AField.ValueType := FMappings[I].ValueType;
  AField.Source := 'mapping:' + MappingProposalKindText(FMappings[I].Source);
  AField.Confidence := FMappings[I].Confidence;
  // Conservative start: every materialized field begins read_only.
  // It only becomes verified_writable after a write -> reread -> match
  // verification (FR-040/AC-006).
  AField.Access := faReadOnly;
  if FMappings[I].Source = mpAiInferred then
    AField.ValidationStatus := vsHypothesis
  else if FMappings[I].Source = mpUserDeclared then
    AField.ValidationStatus := vsUserConfirmed
  else
    AField.ValidationStatus := vsObserved;
  AField.LastUpdated := ALastUpdated;
  AField.AddressHex := FMappings[I].AddressHex;
  // Chain metadata travels with the field: the runtime re-resolves it, so the
  // stored address is only a snapshot of the last resolution.
  AField.ModuleName := FMappings[I].ModuleName;
  AField.PointerOffsetsJson := FMappings[I].PointerOffsetsJson;
  AField.AddressWidthBits := FMappings[I].AddressWidthBits;
  AField.EvidenceRefsJson := FMappings[I].EvidenceRefsJson;
  if not AField.IsValid then
    Exit(TCEAResult.Error(rcInternalError, 'materialized_field_invalid', '{}'));
  Result := TCEAResult.Ok('{"field_id":"' + AField.FieldId +
    '","access":"read_only"}');
end;

end.

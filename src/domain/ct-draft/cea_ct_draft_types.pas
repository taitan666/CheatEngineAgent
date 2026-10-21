unit cea_ct_draft_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_types, cea_reverse_types;

const
  CECTDraftMaxEntries = 256;
  CECTDraftMaxPointerDepth = 32;
  CECTDraftMaxDescriptionBytes = 512;
  CECTDraftMaxOffsetText = 32;
  CECTDraftMaxXmlBytes = 4 * 1024 * 1024;

type
  TCEACTDraftState = (dsProposed, dsValidated, dsInvalidated,
    dsExportPlanned, dsExported, dsExportUnknown);
  TCEACTDraftEntryKind = (deGroup, deAbsoluteAddress, deModuleOffset,
    dePointerChain);
  TCEACTDraftValueType = (dvNone, dvByte, dvWord, dvDword, dvQword,
    dvSingle, dvDouble, dvByteArray);
  TCEACTDraftRiskFlag = (drNonPortable, drVersionBound,
    drAobEvidenceOnly);
  TCEACTDraftRiskFlags = set of TCEACTDraftRiskFlag;
  TCEACTDraftStringArray = array of string;

  TCEACTDraftEntry = record
    Ordinal: Cardinal;
    ParentOrdinal: Integer;
    Kind: TCEACTDraftEntryKind;
    Description: string;
    ValueType: TCEACTDraftValueType;
    AddressWidthBits: Cardinal;
    AddressText: string;
    ModuleName: string;
    PointerOffsets: TCEACTDraftStringArray;
    ByteArrayLength: Cardinal;
    CandidateId: string;
    EvidenceIdsJson: string;
    VerificationOutcome: TCEAVerificationOutcome;
    CompatibilityHash: string;
    RiskFlags: TCEACTDraftRiskFlags;
    AobEvidenceJson: string;
    function IsValid: Boolean;
  end;
  TCEACTDraftEntryArray = array of TCEACTDraftEntry;

  TCEACTDraft = record
    Id: string;
    ParentDraftId: string;
    Revision: Cardinal;
    SchemaVersion: string;
    State: TCEACTDraftState;
    GameName: string;
    GameVersion: string;
    TargetExecutableSha256: string;
    ModuleSetHash: string;
    CompatibilityHash: string;
    RecipeId: string;
    VerificationRunId: string;
    EvidenceIdsJson: string;
    ProofIdsJson: string;
    SourceHashesJson: string;
    GeneratorVersion: string;
    ContentHash: string;
    Entries: TCEACTDraftEntryArray;
    FindingsJson: string;
    FailureModesJson: string;
    CreatedAt: string;
    UpdatedAt: string;
    function IsValid: Boolean;
  end;
  TCEACTDraftArray = array of TCEACTDraft;

  TCEACTDraftProposalEntry = record
    CandidateId: string;
    Description: string;
    RequestedKind: TCEACTDraftEntryKind;
    RequestedValueType: TCEACTDraftValueType;
    Order: Cardinal;
    EvidenceIdsJson: string;
    ProofIdsJson: string;
    function IsValid: Boolean;
  end;
  TCEACTDraftProposalEntryArray = array of TCEACTDraftProposalEntry;

  TCEACTDraftProposal = record
    SchemaVersion: string;
    RecipeId: string;
    VerificationRunId: string;
    GameName: string;
    GameVersion: string;
    Entries: TCEACTDraftProposalEntryArray;
    function IsValid: Boolean;
  end;

  TCEACTDraftSourceBundle = record
    Recipe: TCEAReverseRecipe;
    Verification: TCEAVerificationRun;
    TargetExecutableSha256: string;
    ModuleSetHash: string;
    Candidates: array of TCEACandidateLocation;
    Evidence: array of TCEAEvidenceReference;
    Proofs: array of TCEAProof;
    ProofIdsJson: string;
  end;

  TCEACTDraftExportRequest = record
    DraftId: string;
    RevisionHash: string;
    DestinationPath: string;
    ExpectedAbsent: Boolean;
    MaxOutputBytes: Cardinal;
    ExpectedSha256: string;
    function IsValid: Boolean;
  end;

  TCEACTDraftExportResult = record
    DraftId: string;
    EffectId: string;
    State: TCEACTDraftState;
    ByteCount: Cardinal;
    ReadbackSha256: string;
    ReceiptId: string;
    ProofId: string;
    DetailsJson: string;
    function IsValid: Boolean;
  end;

function CTDraftStateText(const AState: TCEACTDraftState): string;
function TryParseCTDraftState(const AText: string;
  out AState: TCEACTDraftState): Boolean;
function CTDraftEntryKindText(const AKind: TCEACTDraftEntryKind): string;
function CTDraftValueTypeId(const AType: TCEACTDraftValueType): string;
function CTDraftValueTypeText(const AType: TCEACTDraftValueType): string;

implementation

function IsSchemaVersion(const AValue: string): Boolean;
var
  I, Dots: Integer;
begin
  Result := AValue <> '';
  Dots := 0;
  for I := 1 to Length(AValue) do
    if AValue[I] = '.' then
      Inc(Dots)
    else if not (AValue[I] in ['0'..'9']) then
      Exit(False);
  Result := Result and (Dots = 1) and (AValue[1] <> '.') and
    (AValue[Length(AValue)] <> '.');
end;

function IsHexText(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AValue) > 2) and (Copy(AValue, 1, 2) = '0x');
  if not Result then Exit;
  for I := 3 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

function CTDraftStateText(const AState: TCEACTDraftState): string;
begin
  case AState of
    dsProposed: Result := 'proposed';
    dsValidated: Result := 'validated';
    dsInvalidated: Result := 'invalidated';
    dsExportPlanned: Result := 'export_planned';
    dsExported: Result := 'exported';
    dsExportUnknown: Result := 'export_unknown';
  end;
end;

function TryParseCTDraftState(const AText: string;
  out AState: TCEACTDraftState): Boolean;
var
  State: TCEACTDraftState;
begin
  for State := Low(TCEACTDraftState) to High(TCEACTDraftState) do
    if CTDraftStateText(State) = AText then
    begin
      AState := State;
      Exit(True);
    end;
  Result := False;
end;

function CTDraftEntryKindText(const AKind: TCEACTDraftEntryKind): string;
begin
  case AKind of
    deGroup: Result := 'group';
    deAbsoluteAddress: Result := 'absolute_address';
    deModuleOffset: Result := 'module_offset';
    dePointerChain: Result := 'pointer_chain';
  end;
end;

function CTDraftValueTypeId(const AType: TCEACTDraftValueType): string;
begin
  case AType of
    dvNone: Result := 'none';
    dvByte: Result := 'byte';
    dvWord: Result := 'word';
    dvDword: Result := 'dword';
    dvQword: Result := 'qword';
    dvSingle: Result := 'single';
    dvDouble: Result := 'double';
    dvByteArray: Result := 'byte_array';
  end;
end;

function CTDraftValueTypeText(const AType: TCEACTDraftValueType): string;
begin
  case AType of
    dvNone: Result := '';
    dvByte: Result := 'Byte';
    dvWord: Result := '2 Bytes';
    dvDword: Result := '4 Bytes';
    dvQword: Result := '8 Bytes';
    dvSingle: Result := 'Float';
    dvDouble: Result := 'Double';
    dvByteArray: Result := 'Array of byte';
  end;
end;

function TCEACTDraftEntry.IsValid: Boolean;
var
  I: Integer;
begin
  Result := (Length(Description) > 0) and
    (Length(Description) <= CECTDraftMaxDescriptionBytes) and
    (ParentOrdinal >= -1) and
    ((ParentOrdinal = -1) or (ParentOrdinal < Integer(Ordinal)));
  if not Result then Exit;
  if Kind = deGroup then
    Exit((ValueType = dvNone) and (AddressText = '') and
      (ModuleName = '') and (Length(PointerOffsets) = 0) and
      (CandidateId = ''));
  Result := (ValueType <> dvNone) and
    (AddressWidthBits in [32, 64]) and (CandidateId <> '') and
    (EvidenceIdsJson <> '') and (VerificationOutcome = voPass) and
    IsCEAHash(CompatibilityHash);
  if not Result then Exit;
  if ValueType = dvByteArray then
    Result := ByteArrayLength > 0
  else
    Result := ByteArrayLength = 0;
  if not Result then Exit;
  case Kind of
    deAbsoluteAddress:
      Result := IsHexText(AddressText) and (ModuleName = '') and
        (Length(PointerOffsets) = 0) and (drNonPortable in RiskFlags);
    deModuleOffset:
      Result := IsHexText(AddressText) and (ModuleName <> '') and
        (Length(PointerOffsets) = 0);
    dePointerChain:
      begin
        Result := IsHexText(AddressText) and
          (Length(PointerOffsets) > 0) and
          (Length(PointerOffsets) <= CECTDraftMaxPointerDepth);
        if Result then
          for I := 0 to High(PointerOffsets) do
            if (Length(PointerOffsets[I]) > CECTDraftMaxOffsetText) or
               not IsHexText(PointerOffsets[I]) then
              Exit(False);
      end;
  else
    Result := False;
  end;
end;

function TCEACTDraft.IsValid: Boolean;
var
  I: Integer;
begin
  Result := (Id <> '') and (Revision > 0) and IsSchemaVersion(SchemaVersion) and
    (GameName <> '') and IsCEAHash(TargetExecutableSha256) and
    IsCEAHash(ModuleSetHash) and IsCEAHash(CompatibilityHash) and
    (RecipeId <> '') and (VerificationRunId <> '') and
    (EvidenceIdsJson <> '') and (ProofIdsJson <> '') and
    (SourceHashesJson <> '') and
    (GeneratorVersion <> '') and IsCEAHash(ContentHash) and
    (FindingsJson <> '') and (FailureModesJson <> '') and
    (CreatedAt <> '') and (UpdatedAt <> '') and
    (Length(Entries) > 0) and (Length(Entries) <= CECTDraftMaxEntries);
  if not Result then Exit;
  for I := 0 to High(Entries) do
    if (Entries[I].Ordinal <> Cardinal(I)) or not Entries[I].IsValid then
      Exit(False);
end;

function TCEACTDraftProposalEntry.IsValid: Boolean;
begin
  Result := (Description <> '') and
    (Length(Description) <= CECTDraftMaxDescriptionBytes) and
    (EvidenceIdsJson <> '') and (ProofIdsJson <> '');
  if RequestedKind = deGroup then
    Result := Result and (CandidateId = '') and
      (RequestedValueType = dvNone)
  else
    Result := Result and (CandidateId <> '') and
      (RequestedValueType <> dvNone);
end;

function TCEACTDraftProposal.IsValid: Boolean;
var
  I: Integer;
begin
  Result := IsSchemaVersion(SchemaVersion) and (RecipeId <> '') and
    (VerificationRunId <> '') and (GameName <> '') and
    (Length(Entries) > 0) and (Length(Entries) <= CECTDraftMaxEntries);
  if not Result then Exit;
  for I := 0 to High(Entries) do
    if (Entries[I].Order <> Cardinal(I)) or not Entries[I].IsValid then
      Exit(False);
end;

function TCEACTDraftExportRequest.IsValid: Boolean;
begin
  Result := (DraftId <> '') and IsCEAHash(RevisionHash) and
    (DestinationPath <> '') and ExpectedAbsent and
    (MaxOutputBytes > 0) and (MaxOutputBytes <= CECTDraftMaxXmlBytes) and
    IsCEAHash(ExpectedSha256);
end;

function TCEACTDraftExportResult.IsValid: Boolean;
begin
  Result := (DraftId <> '') and (EffectId <> '') and
    (State in [dsExported, dsExportUnknown]);
  if not Result then Exit;
  if State = dsExported then
    Result := (ByteCount > 0) and IsCEAHash(ReadbackSha256) and
      (ReceiptId <> '') and (ProofId <> '')
  else
    Result := DetailsJson <> '';
end;

end.

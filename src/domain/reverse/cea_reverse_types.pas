unit cea_reverse_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

type
  TCEAExperimentState = (xsPlanned, xsRunning, xsVerifying, xsCompleted,
    xsFailed, xsCancelled);
  TCEAExperimentStepKind = (skObserve, skScan, skRefine, skAnalyze,
    skVerify, skProposeEffect, skSaveRecipe);
  TCEAEvidenceScope = (esCatalog, esRuntime);
  TCEAEvidenceKind = (ekCTArtifact, ekMemoryObservation, ekScanSnapshot,
    ekDisassembly, ekVerification, ekUserStatement);
  TCEACandidateKind = (ckAbsoluteAddress, ckModuleOffset, ckPointerChain,
    ckAobSignature, ckCodeLocation);
  TCEAVerificationOutcome = (voPending, voPass, voFail, voInconclusive,
    voUnknown);
  TCEAPlatformKind = (pkWindowsCE, pkAndroid);

  TCEATargetBinding = record
    ProcessIdentityId: string;
    Epoch: QWord;
    function IsValid: Boolean;
  end;

  TCEAExperiment = record
    Id: string;
    SchemaVersion: string;
    TaskId: string;
    Goal: string;
    Target: TCEATargetBinding;
    State: TCEAExperimentState;
    CreatedAt: string;
    UpdatedAt: string;
  end;

  TCEAExperimentStep = record
    Id: string;
    ExperimentId: string;
    Kind: TCEAExperimentStepKind;
    RequiredCapabilityId: string;
    PreconditionsJson: string;
    AcceptanceJson: string;
    MaxBytes: QWord;
    MaxResults: Cardinal;
    TimeoutMs: Cardinal;
  end;

  TCEAHypothesis = record
    Id: string;
    SchemaVersion: string;
    ExperimentId: string;
    StatementText: string;
    CandidateId: string;
    EvidenceIdsJson: string;
    ConfidenceBasis: string;
  end;

  TCEAEvidenceReference = record
    Id: string;
    SchemaVersion: string;
    Scope: TCEAEvidenceScope;
    Kind: TCEAEvidenceKind;
    ProvenanceUri: string;
    ContentHash: string;
    Target: TCEATargetBinding;
    ProducedByCapabilityId: string;
    ObservedAt: string;
    function IsValid: Boolean;
  end;

  TCEACandidateLocation = record
    Id: string;
    SchemaVersion: string;
    Kind: TCEACandidateKind;
    Target: TCEATargetBinding;
    AddressText: string;
    AddressWidthBits: Cardinal;
    ModuleName: string;
    PointerOffsetsJson: string;
    AobEvidenceJson: string;
    ObservedByteLength: Cardinal;
    CompatibilityHash: string;
    DiscoveryEvidenceId: string;
    function IsValid: Boolean;
  end;

  TCEAReverseRecipe = record
    Id: string;
    SchemaVersion: string;
    Name: string;
    CompatibilityHash: string;
    SourceEvidenceIdsJson: string;
    RequiredCapabilityIdsJson: string;
    VerificationPlanJson: string;
    { Quarantine field for legacy/import validation. Published recipe schemas
      reject this field, and portable definitions require it to be empty. }
    ApprovalId: string;
    function IsPortableDefinition: Boolean;
  end;

  TCEAVerificationRun = record
    Id: string;
    SchemaVersion: string;
    ExperimentId: string;
    RecipeId: string;
    Target: TCEATargetBinding;
    Outcome: TCEAVerificationOutcome;
    ChecksJson: string;
    ProofId: string;
  end;

  TCEACapabilityInvocation = record
    Id: string;
    ExperimentId: string;
    StepId: string;
    CapabilityId: string;
    Target: TCEATargetBinding;
    RequestJson: string;
    LeaseId: string;
    EffectId: string;
  end;

  TCEAPlatformCapabilityDescriptor = record
    Id: string;
    SchemaVersion: string;
    Platform: TCEAPlatformKind;
    RequestSchemaId: string;
    ResultSchemaId: string;
    MutatesExternalState: Boolean;
    function RequiresEffect: Boolean;
  end;

function IsCEAHash(const AValue: string): Boolean;

implementation

function IsCEAHash(const AValue: string): Boolean;
var
  Index: Integer;
begin
  Result := (Length(AValue) = 71) and (Copy(AValue, 1, 7) = 'sha256:');
  if not Result then
    Exit;
  for Index := 8 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function IsSchemaVersion(const AValue: string): Boolean;
var
  DotAt, Index: Integer;
begin
  DotAt := Pos('.', AValue);
  Result := (DotAt > 1) and (DotAt < Length(AValue));
  if not Result then
    Exit;
  for Index := 1 to Length(AValue) do
    if (Index <> DotAt) and not (AValue[Index] in ['0'..'9']) then
      Exit(False);
end;

function IsHexAddress(const AValue: string): Boolean;
var
  Index: Integer;
begin
  Result := (Length(AValue) > 2) and (Copy(AValue, 1, 2) = '0x');
  if not Result then
    Exit;
  for Index := 3 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

function TCEATargetBinding.IsValid: Boolean;
begin
  Result := (ProcessIdentityId <> '') and (Epoch > 0);
end;

function TCEAEvidenceReference.IsValid: Boolean;
begin
  Result := (Id <> '') and IsSchemaVersion(SchemaVersion) and
    (ProvenanceUri <> '') and IsCEAHash(ContentHash);
  if Result and (Scope = esRuntime) then
    Result := Target.IsValid;
end;

function TCEACandidateLocation.IsValid: Boolean;
begin
  Result := (Id <> '') and IsSchemaVersion(SchemaVersion) and
    Target.IsValid and (DiscoveryEvidenceId <> '') and
    (AddressWidthBits in [32, 64]);
  if Result and (Kind in [ckAbsoluteAddress, ckModuleOffset, ckCodeLocation]) then
    Result := IsHexAddress(AddressText);
end;

function TCEAReverseRecipe.IsPortableDefinition: Boolean;
begin
  Result := (Id <> '') and IsSchemaVersion(SchemaVersion) and (Name <> '') and
    IsCEAHash(CompatibilityHash) and (SourceEvidenceIdsJson <> '') and
    (RequiredCapabilityIdsJson <> '') and (VerificationPlanJson <> '') and
    (ApprovalId = '');
end;

function TCEAPlatformCapabilityDescriptor.RequiresEffect: Boolean;
begin
  Result := MutatesExternalState;
end;

end.

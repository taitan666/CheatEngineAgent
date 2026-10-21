unit cea_types;

{$mode objfpc}{$H+}

interface

type
  TCEArchitecture = (caX86, caX86_64, caArm64);
  TCETargetClassification = (tcUnknown, tcSinglePlayerOffline, tcMultiplayerOrOnline);
  TCAScriptLanguage = (slAutoAssembler, slLua);
  TCEAApprovalOrigin = (aoUnknown, aoLocalUserInterface, aoModel, aoMcpClient);
  TCEAApprovalOutcome = (adPending, adApproved, adRejected, adExpired);
  TCEAEffectState = (esPlanned, esExecuting, esApplied, esRejected, esUnknown);
  TCEAReceiptOutcome = (roApplied, roRejected, roUnknown);
  TCEAProofOutcome = (poPass, poFail, poInconclusive);
  TCEAResourceKind = (rkProcess, rkSaveFile);

  TCEACapabilityContext = record
    TaskId: string;
    LeaseId: string;
    ProcessIdentityId: string;
    ResourceKind: TCEAResourceKind;
    ResourceIdentityId: string;
    PolicySnapshotId: string;
    TargetClassification: TCETargetClassification;
    Epoch: QWord;
    RequesterOrigin: TCEAApprovalOrigin;
  end;

  TCEProcessIdentity = record
    Id: string;
    Pid: Cardinal;
    StartedAt: string;
    ExecutablePathHash: string;
    ExecutableSha256: string;
    Architecture: TCEArchitecture;
    ModuleSetHash: string;
    Epoch: QWord;
    TargetClassification: TCETargetClassification;
  end;

  TCEAttachRequest = record
    TaskId: string;
    LeaseId: string;
    Pid: Cardinal;
    OperatorAttestsAuthorizedDebugging: Boolean;
  end;

  TCEScanRange = record
    StartAddress: QWord;
    Size: QWord;
  end;
  TCEScanRangeArray = array of TCEScanRange;

  TCEScanRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    ScanKind: string;
    ValueType: string;
    ScopeId: string;
    ScopePartialReason: string;
    ValueText: string;
    RangeStart: QWord;
    RangeSize: QWord;
    Ranges: TCEScanRangeArray;
    MaxBytes: QWord;
    MaxResults: Cardinal;
    MaxDurationMs: Cardinal;
    MaxRegions: Cardinal;
    Epoch: QWord;
  end;

  TCEMemoryReadRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    Address: QWord;
    ByteCount: Cardinal;
  end;

  TCEMemoryWriteRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    ApprovalId: string;
    Address: QWord;
    ExpectedOriginalHex: string;
    ReplacementHex: string;
    IdempotencyKey: string;
  end;

  TCEDisassembleRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    Address: QWord;
    ByteCount: Cardinal;
  end;

  TCEDebugRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    ApprovalId: string;
    Operation: string;
    Address: QWord;
  end;

  TCEScriptExecutionRequest = record
    TaskId: string;
    ProcessIdentityId: string;
    LeaseId: string;
    ApprovalId: string;
    Language: TCAScriptLanguage;
    ScriptContentHash: string;
    IdempotencyKey: string;
  end;

  TCTImportRequest = record
    TaskId: string;
    SourceId: string;
    ContentHash: string;
    ProvenanceUri: string;
  end;

  TCTRetrievalQuery = record
    TaskId: string;
    Text: string;
    ProcessIdentityId: string;
    MaxResults: Cardinal;
  end;

  TCEAModelInvocationRequest = record
    TaskId: string;
    TaskContractVersion: QWord;
    PolicySnapshotId: string;
    LeaseId: string;
    FeatureSetId: string;
    RagContextManifestId: string;
    InputHash: string;
  end;

  TCEALease = record
    Id: string;
    CapabilityId: string;
    ProcessIdentityId: string;
    ResourceKind: TCEAResourceKind;
    ResourceIdentityId: string;
    Epoch: QWord;
    IssuedAt: string;
    ExpiresAt: string;
    RemainingCalls: Cardinal;
    RemainingBytes: QWord;
    Revoked: Boolean;
  end;

  TCEAApprovalDecision = record
    Id: string;
    EffectId: string;
    RequestHash: string;
    ProcessIdentityId: string;
    ResourceKind: TCEAResourceKind;
    ResourceIdentityId: string;
    PolicySnapshotId: string;
    Origin: TCEAApprovalOrigin;
    Outcome: TCEAApprovalOutcome;
    DecidedAt: string;
    ExpiresAt: string;
    MaxExecutions: Cardinal;
  end;

  TCEAEffect = record
    Id: string;
    TaskId: string;
    CapabilityId: string;
    RequestHash: string;
    RequestJson: string;
    ProcessIdentityId: string;
    ResourceKind: TCEAResourceKind;
    ResourceIdentityId: string;
    PolicySnapshotId: string;
    LeaseId: string;
    ApprovalId: string;
    IdempotencyKey: string;
    Epoch: QWord;
    State: TCEAEffectState;
    CreatedAt: string;
    UpdatedAt: string;
    TargetClassification: TCETargetClassification;
    ResultJson: string;
  end;

  TCEAReceipt = record
    Id: string;
    EffectId: string;
    Attempt: Cardinal;
    RecordedAt: string;
    Outcome: TCEAReceiptOutcome;
    ResponseHash: string;
    DetailsJson: string;
  end;

  TCEAProof = record
    Id: string;
    EffectId: string;
    ReceiptId: string;
    RecordedAt: string;
    Outcome: TCEAProofOutcome;
    VerificationHash: string;
    DetailsJson: string;
  end;

implementation

end.

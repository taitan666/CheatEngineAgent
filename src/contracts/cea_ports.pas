unit cea_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results;

type
  ICEProcessPort = interface
    function ListProcesses: TCEAResult;
    function Attach(const ARequest: TCEAttachRequest): TCEAResult;
    function Detach(const AProcess: TCEProcessIdentity): TCEAResult;
  end;

  IMemoryPort = interface
    function Scan(const ARequest: TCEScanRequest): TCEAResult;
    function ReadMemory(const ARequest: TCEMemoryReadRequest): TCEAResult;
    function WriteMemory(const ARequest: TCEMemoryWriteRequest): TCEAResult;
    function Disassemble(const ARequest: TCEDisassembleRequest): TCEAResult;
  end;

  IDebugPort = interface
    function ChangeDebugState(const ARequest: TCEDebugRequest): TCEAResult;
  end;

  IScriptExecutionPort = interface
    function ExecuteScript(const ARequest: TCEScriptExecutionRequest): TCEAResult;
  end;

  ICTKnowledgePort = interface
    function ImportArtifact(const ARequest: TCTImportRequest): TCEAResult;
    function Search(const AQuery: TCTRetrievalQuery): TCEAResult;
    function BuildContext(const AQuery: TCTRetrievalQuery): TCEAResult;
  end;

  ILLMProvider = interface
    function Invoke(const ARequest: TCEAModelInvocationRequest): TCEAResult;
  end;

  IStateStore = interface
    function Initialize: TCEAResult;
    function AppendEvent(const AEnvelopeJson: string): TCEAResult;
  end;

  IPolicyEngine = interface
    function Evaluate(const ACapabilityId, ATargetClassification: string): TCEAResult;
  end;

  ISecretStore = interface
    function ResolveSecret(const ASecretRef: string): TCEAResult;
  end;

  ISchemaValidator = interface
    function Validate(const ASchemaId, APayloadJson: string): TCEAResult;
  end;

  ICEAClock = interface
    function UtcNowIso8601: string;
  end;

  ICEAEntropy = interface
    function RandomBytes(const ACount: Cardinal;
      out ABytes: TBytes): TCEAResult;
  end;

  IApprovalPort = interface
    function FindDecision(const AEffectId: string;
      out ADecision: TCEAApprovalDecision): TCEAResult;
  end;

  ICEAHasher = interface
    function HashUtf8(const AValue: string): string;
  end;

  IGovernanceStore = interface
    function SaveLease(const ALease: TCEALease): TCEAResult;
    function LoadLease(const ALeaseId: string;
      out ALease: TCEALease): TCEAResult;
    function ConsumeLeaseCall(const ALeaseId: string): TCEAResult;
    function RevokeAllLeases: TCEAResult;
    function RejectPlannedEffects(const AUpdatedAt: string): TCEAResult;
    function ReconcileExecutingEffects(
      const AUpdatedAt: string): TCEAResult;
    function SaveApproval(
      const ADecision: TCEAApprovalDecision): TCEAResult;
    function LoadApproval(const AEffectId: string;
      out ADecision: TCEAApprovalDecision): TCEAResult;
    function SaveEffect(const AEffect: TCEAEffect): TCEAResult;
    function LoadEffect(const AEffectId: string;
      out AEffect: TCEAEffect): TCEAResult;
    function SaveReceipt(const AReceipt: TCEAReceipt): TCEAResult;
    function LoadReceipt(const AReceiptId: string;
      out AReceipt: TCEAReceipt): TCEAResult;
    function SaveProof(const AProof: TCEAProof): TCEAResult;
    function LoadProof(const AProofId: string;
      out AProof: TCEAProof): TCEAResult;
  end;

  ICEACapabilityPort = interface
    function Invoke(const ACapabilityId,
      ARequestJson: string): TCEAResult;
    function InvokeEffect(const AEffect: TCEAEffect): TCEAResult;
  end;

implementation

end.

unit cea_reverse_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_types, cea_results, cea_reverse_types;

type
  ICEAExperimentStore = interface
    function SaveExperiment(const AExperiment: TCEAExperiment): TCEAResult;
    function LoadExperiment(const AExperimentId: string;
      out AExperiment: TCEAExperiment): TCEAResult;
  end;

  ICEAEvidenceStore = interface
    function AppendEvidence(const AEvidence: TCEAEvidenceReference): TCEAResult;
    function FindEvidence(const AEvidenceId: string;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
  end;

  ICEARecipeStore = interface
    function SaveRecipe(const ARecipe: TCEAReverseRecipe): TCEAResult;
    function LoadRecipe(const ARecipeId: string;
      out ARecipe: TCEAReverseRecipe): TCEAResult;
  end;

  ICEAReverseArtifactStore = interface
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

  ICEAReversePlanner = interface
    function PlanExperiment(const AGoal, ATargetIdentityId: string;
      const AEpoch: QWord): TCEAResult;
  end;

  ICEAReverseCapabilityPort = interface
    function Invoke(const AContext: TCEACapabilityContext;
      const AInvocation: TCEACapabilityInvocation): TCEAResult;
  end;

  ICEARecipeVerifier = interface
    function Verify(const AContext: TCEACapabilityContext;
      const ARecipe: TCEAReverseRecipe): TCEAResult;
  end;

implementation

end.

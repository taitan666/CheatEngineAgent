program test_reverse_orchestrator;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_policy_model,
  cea_lease_service, cea_effect_service, cea_governance_gateway,
  cea_reverse_types, cea_experiment_service, cea_evidence_service,
  cea_hypothesis_service, cea_recipe_service, cea_verification_service,
  cea_test_ports;

const
  ValidHash = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

procedure InstallLease(const AStore: TCEATestGovernanceStore;
  const AContext: TCEACapabilityContext; const ACapability: string;
  const ACalls: Cardinal);
var
  Lease: TCEALease;
begin
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := AContext.LeaseId;
  Lease.CapabilityId := ACapability;
  Lease.ProcessIdentityId := AContext.ProcessIdentityId;
  Lease.Epoch := AContext.Epoch;
  Lease.IssuedAt := '2026-09-13T09:59:00.000Z';
  Lease.ExpiresAt := '2026-09-13T10:05:00.000Z';
  Lease.RemainingCalls := ACalls;
  Lease.RemainingBytes := 1048576;
  AStore.AddLease(Lease);
end;

var
  Clock: TCEATestClock;
  Hasher: TCEATestHasher;
  Store: TCEATestGovernanceStore;
  Audit: TCEATestStateStore;
  Approvals: TCEATestApprovalPort;
  Capabilities: TCEATestCapabilityPort;
  Policy: TCEAPolicyModel;
  Leases: TCEALeaseService;
  Effects: TCEAEffectService;
  Gateway: TCEAGovernanceGateway;
  Experiments: TCEAExperimentService;
  CompletionExperiments: TCEAExperimentService;
  EvidenceService: TCEAEvidenceService;
  Hypotheses: TCEAHypothesisService;
  Recipes: TCEARecipeService;
  Verifier: TCEAVerificationService;
  Context: TCEACapabilityContext;
  Experiment: TCEAExperiment;
  Step: TCEAExperimentStep;
  Evidence: TCEAEvidenceReference;
  FoundEvidence: TCEAEvidenceReference;
  StaleTarget: TCEATargetBinding;
  Candidate: TCEACandidateLocation;
  Hypothesis: TCEAHypothesis;
  Recipe: TCEAReverseRecipe;
  Run: TCEAVerificationRun;
  ResultValue: TCEAResult;
  ExecutionCountBefore: Cardinal;

begin
  Clock := TCEATestClock.Create;
  Hasher := TCEATestHasher.Create;
  Store := TCEATestGovernanceStore.Create;
  Audit := TCEATestStateStore.Create;
  Approvals := TCEATestApprovalPort.Create;
  Capabilities := TCEATestCapabilityPort.Create;
  Policy := TCEAPolicyModel.Create;
  Leases := TCEALeaseService.Create(Store, Clock);
  Effects := TCEAEffectService.Create(Store, Clock, Approvals, Hasher);
  Gateway := TCEAGovernanceGateway.Create(Policy, Leases, Effects,
    Capabilities);
  Experiments := TCEAExperimentService.Create(Gateway, Audit);
  CompletionExperiments := TCEAExperimentService.Create(Gateway, Audit);
  EvidenceService := TCEAEvidenceService.Create;
  Hypotheses := TCEAHypothesisService.Create;
  Recipes := TCEARecipeService.Create;
  Verifier := TCEAVerificationService.Create;
  try
    Clock.CurrentTime := '2026-09-13T10:00:00.000Z';
    FillChar(Context, SizeOf(Context), 0);
    Context.TaskId := 'task:reverse-1';
    Context.LeaseId := 'lease:reverse-1';
    Context.ProcessIdentityId := 'process:self-test';
    Context.PolicySnapshotId := 'policy:single-player';
    Context.TargetClassification := tcSinglePlayerOffline;
    Context.Epoch := 4;
    Context.RequesterOrigin := aoLocalUserInterface;

    FillChar(Experiment, SizeOf(Experiment), 0);
    Experiment.Id := 'experiment:health';
    Experiment.SchemaVersion := '1.0';
    Experiment.TaskId := Context.TaskId;
    Experiment.Goal := 'Locate the changing health value';
    Experiment.Target.ProcessIdentityId := Context.ProcessIdentityId;
    Experiment.Target.Epoch := Context.Epoch;
    Experiment.State := xsPlanned;
    Experiment.CreatedAt := Clock.CurrentTime;
    Experiment.UpdatedAt := Clock.CurrentTime;
    Assert(Experiments.Start(Experiment).Code = rcOk,
      'valid experiment starts');

    FillChar(Step, SizeOf(Step), 0);
    Step.Id := 'step:scan';
    Step.ExperimentId := Experiment.Id;
    Step.Kind := skScan;
    Step.RequiredCapabilityId := 'memory_scan';
    Step.MaxBytes := 1048576;
    Step.MaxResults := 100;
    Step.TimeoutMs := 5000;
    InstallLease(Store, Context, 'memory_scan', 2);
    Capabilities.NextResult := TCEAResult.Ok('{"scan_id":"scan:1","matches":8}');
    Assert(Experiments.RunReadStep(Context, Step,
      '{"mode":"exact","value":100}').Code = rcOk,
      'exact scan executes through governance');

    Step.Id := 'step:refine';
    Step.Kind := skRefine;
    Capabilities.NextResult := TCEAResult.Ok('{"scan_id":"scan:1","matches":1}');
    Assert(Experiments.RunReadStep(Context, Step,
      '{"mode":"decreased","scan_id":"scan:1"}').Code = rcOk,
      'refine scan executes through governance');
    Assert(Experiments.Current.State = xsRunning,
      'successful read step advances experiment');

    FillChar(Evidence, SizeOf(Evidence), 0);
    Evidence.Id := 'evidence:scan-1';
    Evidence.SchemaVersion := '1.0';
    Evidence.Scope := esRuntime;
    Evidence.Kind := ekScanSnapshot;
    Evidence.ProvenanceUri := 'cea://runtime/scan/scan-1';
    Evidence.ContentHash := ValidHash;
    Evidence.Target := Experiment.Target;
    Evidence.ProducedByCapabilityId := 'memory_scan';
    Evidence.ObservedAt := Clock.CurrentTime;
    Assert(EvidenceService.Add(Evidence, Experiment.Target).Code = rcOk,
      'target-bound evidence is retained');
    StaleTarget := Experiment.Target;
    Inc(StaleTarget.Epoch);
    Assert(EvidenceService.FindForTarget(Evidence.Id, StaleTarget,
      FoundEvidence).Code = rcStaleProcessIdentity,
      'epoch change invalidates retained runtime evidence');

    FillChar(Candidate, SizeOf(Candidate), 0);
    Candidate.Id := 'candidate:health';
    Candidate.SchemaVersion := '1.0';
    Candidate.Kind := ckAbsoluteAddress;
    Candidate.Target := Experiment.Target;
    Candidate.AddressText := '0x1234ABCD';
    Candidate.AddressWidthBits := 64;
    Candidate.DiscoveryEvidenceId := Evidence.Id;
    FillChar(Hypothesis, SizeOf(Hypothesis), 0);
    Hypothesis.Id := 'hypothesis:health';
    Hypothesis.SchemaVersion := '1.0';
    Hypothesis.ExperimentId := Experiment.Id;
    Hypothesis.StatementText := 'The unique candidate stores health';
    Hypothesis.CandidateId := Candidate.Id;
    Hypothesis.EvidenceIdsJson := '["evidence:scan-1"]';
    Hypothesis.ConfidenceBasis := 'exact scan refined after health decreased';
    Assert(Hypotheses.Add(Hypothesis, Candidate, Evidence).Code = rcOk,
      'hypothesis must bind a valid candidate and evidence');

    ResultValue := Verifier.VerifyAobUniqueness(Experiment.Id,
      Experiment.Target, 1, 1, Evidence.Id, 'proof:aob-unique', Run);
    Assert(ResultValue.Code = rcOk, 'unique AOB verification passes');
    Assert(Run.Outcome = voPass, 'verification outcome is pass');
    Assert(CompletionExperiments.Start(Experiment).Code = rcOk,
      'completion state machine starts independently');
    Assert(CompletionExperiments.ApplyVerification(Run).Code = rcOk,
      'passed verification is accepted');
    Assert(CompletionExperiments.Current.State = xsVerifying,
      'proof moves experiment into verifying state');

    FillChar(Recipe, SizeOf(Recipe), 0);
    Recipe.Id := 'recipe:health';
    Recipe.SchemaVersion := '1.0';
    Recipe.Name := 'Health location recipe';
    Recipe.CompatibilityHash := ValidHash;
    Recipe.SourceEvidenceIdsJson := '["evidence:scan-1"]';
    Recipe.RequiredCapabilityIdsJson := '["memory_read"]';
    Recipe.VerificationPlanJson := '{"checks":["aob_unique"]}';
    Assert(Recipes.Publish(Recipe, Run).Code = rcOk,
      'passed proof publishes authority-free recipe');
    Assert(CompletionExperiments.CompleteWithRecipe(Recipe).Code = rcOk,
      'verified recipe completes experiment');
    Assert(CompletionExperiments.Current.State = xsCompleted,
      'recipe publication reaches completed state');

    Verifier.VerifyAobUniqueness(Experiment.Id, Experiment.Target,
      0, 1, Evidence.Id, '', Run);
    Assert(Run.Outcome = voInconclusive, 'zero AOB matches are inconclusive');
    Verifier.VerifyAobUniqueness(Experiment.Id, Experiment.Target,
      2, 1, Evidence.Id, '', Run);
    Assert(Run.Outcome = voInconclusive,
      'multiple AOB matches are inconclusive');

    ExecutionCountBefore := Capabilities.ExecutionCount;
    Context.Epoch := 5;
    InstallLease(Store, Context, 'memory_read', 1);
    Step.Id := 'step:stale';
    Step.Kind := skObserve;
    Step.RequiredCapabilityId := 'memory_read';
    ResultValue := Experiments.RunReadStep(Context, Step, '{}');
    Assert(ResultValue.Code = rcStaleProcessIdentity,
      'epoch change invalidates experiment candidates');
    Assert(Capabilities.ExecutionCount = ExecutionCountBefore,
      'stale experiment never reaches capability');
    Context.Epoch := Experiment.Target.Epoch;

    InstallLease(Store, Context, 'memory_write', 1);
    ExecutionCountBefore := Capabilities.ExecutionCount;
    ResultValue := Experiments.ProposeEffect(Context, 'memory_write',
      '{"address":"0x1234ABCD","expected":"64","replacement":"63"}',
      'effect:health-once');
    Assert(ResultValue.Code = rcApprovalRequired,
      'mutation proposal creates an approval boundary');
    Assert(Capabilities.ExecutionCount = ExecutionCountBefore,
      'unapproved mutation is not executed');

    ResultValue := Verifier.VerifyReadback(Experiment.Id, Experiment.Target,
      '64', '63', rcOk, Evidence.Id, '', Run);
    Assert(ResultValue.Code = rcVerificationFailed,
      'mismatched readback fails verification');
    Assert(Run.Outcome = voFail, 'mismatched readback outcome is fail');
    ResultValue := Verifier.VerifyReadback(Experiment.Id, Experiment.Target,
      '64', '', rcTimeout, Evidence.Id, '', Run);
    Assert(ResultValue.Code = rcUnknownOutcome,
      'unobservable readback becomes unknown');
    Assert(Run.Outcome = voUnknown, 'timeout outcome is unknown');
    Assert(not Verifier.CanRetryAutomatically(Run),
      'unknown verification cannot retry automatically');

    InstallLease(Store, Context, 'scan_cancel', 1);
    Capabilities.NextResult := TCEAResult.Ok('{"cancelled":true}');
    Assert(Experiments.Cancel(Context, 'scan:1').Code = rcOk,
      'cancel releases the active scan through governance');
    Assert(Experiments.Current.State = xsCancelled,
      'experiment remains cancelled');
    Assert(Audit.EventCount = 1, 'cancel appends an audit event');

    WriteLn('REVERSE_ORCHESTRATOR=PASS');
  finally
    Verifier.Free;
    Recipes.Free;
    Hypotheses.Free;
    EvidenceService.Free;
    CompletionExperiments.Free;
    Experiments.Free;
    Gateway.Free;
    Effects.Free;
    Leases.Free;
    Policy.Free;
    Capabilities.Free;
    Approvals.Free;
    Audit.Free;
    Store.Free;
    Hasher.Free;
    Clock.Free;
  end;
end.

program test_reverse_contracts;

{$mode objfpc}{$H+}

uses
  cea_reverse_types, cea_reverse_ports;

const
  ValidHash = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

var
  Binding: TCEATargetBinding;
  Evidence: TCEAEvidenceReference;
  Candidate: TCEACandidateLocation;
  Recipe: TCEAReverseRecipe;
  Capability: TCEAPlatformCapabilityDescriptor;

begin
  Assert(IsCEAHash(ValidHash), 'valid sha256 reference');
  Assert(not IsCEAHash('sha256:ABC'), 'invalid sha256 reference');

  Binding.ProcessIdentityId := 'process:test';
  Binding.Epoch := 1;
  Assert(Binding.IsValid, 'runtime target binding');
  Binding.Epoch := 0;
  Assert(not Binding.IsValid, 'epoch zero is invalid');
  Binding.Epoch := 1;

  Evidence.Id := 'evidence:runtime';
  Evidence.SchemaVersion := '1.0';
  Evidence.Scope := esRuntime;
  Evidence.Kind := ekMemoryObservation;
  Evidence.ProvenanceUri := 'cea://runtime/read/1';
  Evidence.ContentHash := ValidHash;
  Evidence.Target := Binding;
  Assert(Evidence.IsValid, 'runtime evidence requires a valid target');
  Evidence.Target.Epoch := 0;
  Assert(not Evidence.IsValid, 'unbound runtime evidence is invalid');

  Candidate.Id := 'candidate:1';
  Candidate.SchemaVersion := '1.0';
  Candidate.Kind := ckAbsoluteAddress;
  Candidate.Target := Binding;
  Candidate.AddressText := '0x1234ABCD';
  Candidate.AddressWidthBits := 64;
  Candidate.DiscoveryEvidenceId := 'evidence:runtime';
  Assert(Candidate.IsValid, 'explicit-width hexadecimal candidate');
  Candidate.AddressWidthBits := 48;
  Assert(not Candidate.IsValid, 'unsupported address width');

  Recipe.Id := 'recipe:1';
  Recipe.SchemaVersion := '1.0';
  Recipe.Name := 'Verified health recipe';
  Recipe.CompatibilityHash := ValidHash;
  Recipe.SourceEvidenceIdsJson := '["evidence:runtime"]';
  Recipe.RequiredCapabilityIdsJson := '["memory.read"]';
  Recipe.VerificationPlanJson := '{"checks":[]}';
  Assert(Recipe.IsPortableDefinition, 'recipe is authority-free data');
  Recipe.ApprovalId := 'approval:must-not-travel';
  Assert(not Recipe.IsPortableDefinition,
    'historical approval must never make a recipe replayable');

  Capability.Id := 'memory.write';
  Capability.Platform := pkWindowsCE;
  Capability.MutatesExternalState := True;
  Assert(Capability.RequiresEffect, 'mutating capability requires Effect');
  Capability.MutatesExternalState := False;
  Assert(not Capability.RequiresEffect, 'read capability does not require Effect');

  WriteLn('REVERSE_CONTRACTS=PASS');
end.

program test_mapping_service;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_reverse_types, cea_mapping_service;

var
  Service: TCEAMappingService;
  Candidate: TCEACandidateLocation;
  AiMapping, CandidateMapping, DeclaredMapping, Confirmed, Fetched: TCEAFieldMapping;
  Field: TCEAGameField;
  R: TCEAResult;

begin
  Service := TCEAMappingService.Create;
  try
    // 1. 逆向候选地址提案 → 必须进「待确认」态（AC-014）
    FillChar(Candidate, SizeOf(Candidate), 0);
    Candidate.Id := 'cand-0001';
    Candidate.SchemaVersion := '1.0';
    Candidate.Kind := ckAbsoluteAddress;
    Candidate.Target.ProcessIdentityId := 'process-b50aa21d';
    Candidate.Target.Epoch := 1;
    Candidate.AddressText := '0x14D73CD0000';
    Candidate.AddressWidthBits := 64;
    Candidate.DiscoveryEvidenceId := 'evidence-0001';
    R := Service.ProposeFromCandidate(Candidate, 'player.geo', 'Geo', 'dword',
      '2026-10-20T10:00:00Z', CandidateMapping);
    Assert(R.Code = rcOk, 'candidate proposal: ' + R.StableCode);
    Assert(CandidateMapping.State = msProposed,
      'reverse candidate must be proposed, not auto-confirmed (AC-014)');
    Assert(CandidateMapping.Source = mpReverseCandidate, 'source is candidate');

    // 2. AI 推断提案 → 必须进「待确认」态（AC-014）
    R := Service.ProposeFromAi('player.stamina', 'Stamina', 'single',
      '0x12340000', '["ai-run-1"]', 0.62, '2026-10-20T10:00:01Z', AiMapping);
    Assert(R.Code = rcOk, 'ai proposal: ' + R.StableCode);
    Assert(AiMapping.State = msProposed,
      'ai inferred mapping must be proposed (AC-014)');

    // 3. 未确认映射不得物化为字段
    R := Service.MaterializeField(AiMapping.Id, '2026-10-20T10:00:02Z', Field);
    Assert(R.Code = rcApprovalRequired, 'unconfirmed cannot materialize: ' +
      R.StableCode);

    // 4. 确认映射 → 物化字段，access 保守地从 read_only 起步
    R := Service.Confirm(AiMapping.Id, Confirmed);
    Assert(R.Code = rcOk, 'confirm: ' + R.StableCode);
    R := Service.MaterializeField(AiMapping.Id, '2026-10-20T10:00:03Z', Field);
    Assert(R.Code = rcOk, 'materialize: ' + R.StableCode);
    Assert(Field.FieldId = 'player.stamina', 'field id carried');
    Assert(Field.Access = faReadOnly,
      'materialized field starts read_only (FR-040/AC-006)');
    Assert(Field.ValidationStatus = vsHypothesis,
      'ai-sourced field stays hypothesis until verified');
    Assert(Field.AddressHex = '0x12340000', 'address carried');

    // 5. 用户手工声明 → 直接 confirmed，但字段仍从 read_only 起步
    R := Service.ProposeUserDeclared('player.gold', 'Gold', 'dword',
      '0x20000000', '2026-10-20T10:00:04Z', DeclaredMapping);
    Assert(R.Code = rcOk, 'user declared: ' + R.StableCode);
    Assert(DeclaredMapping.State = msConfirmed,
      'user declared is confirmed immediately');
    R := Service.MaterializeField(DeclaredMapping.Id,
      '2026-10-20T10:00:05Z', Field);
    Assert(R.Code = rcOk, 'materialize declared: ' + R.StableCode);
    Assert(Field.Access = faReadOnly,
      'even user-declared starts read_only until write verification');
    Assert(Field.ValidationStatus = vsUserConfirmed, 'user confirmed status');

    // 6. 同一 field_id 再提案 → 旧提案被 superseded
    R := Service.ProposeFromAi('player.stamina', 'Stamina', 'single',
      '0x12349999', '[]', 0.9, '2026-10-20T10:00:06Z', AiMapping);
    Assert(R.Code = rcOk, 're-propose: ' + R.StableCode);
    Assert(Service.GetMapping(Confirmed.Id, Fetched), 'fetch older mapping');
    Assert(Fetched.State = msSuperseded, 'older proposal superseded');

    // 7. 已 superseded 的映射不得再确认
    R := Service.Confirm(Confirmed.Id, Fetched);
    Assert(R.Code = rcConflict, 'superseded cannot be confirmed: ' +
      R.StableCode);

    // 8. 否决的映射不得物化
    R := Service.Reject(AiMapping.Id, Confirmed);
    Assert(R.Code = rcOk, 'reject: ' + R.StableCode);
    R := Service.MaterializeField(AiMapping.Id, '2026-10-20T10:00:07Z', Field);
    Assert(R.Code = rcApprovalRequired, 'rejected cannot materialize');

    // 9. 不支持的值类型被拒
    R := Service.ProposeFromAi('player.x', 'X', 'vec3', '0x1', '[]', 0.5,
      '2026-10-20T10:00:08Z', AiMapping);
    Assert(R.Code = rcInvalidArgument, 'unsupported value type rejected: ' +
      R.StableCode);

    // 10. 语义值类型映射（内存原语 → PRD 值类型）
    Assert(SemanticValueType('dword') = 'integer', 'dword -> integer');
    Assert(SemanticValueType('qword') = 'integer', 'qword -> integer');
    Assert(SemanticValueType('double') = 'single', 'double -> single');
    Assert(SemanticValueType('bool') = 'bool', 'bool -> bool');

    WriteLn('MAPPING_SERVICE=PASS');
  finally
    Service.Free;
  end;
end.
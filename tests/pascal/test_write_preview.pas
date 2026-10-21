program test_write_preview;
{ Tests for FR-042 command preview and FR-045 conflict detection. }
{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, fpjson, jsonparser, cea_results, cea_write_preview,
  cea_value_scan_types, cea_field_model;

var
  Failures: Integer;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', AMessage);
  end;
end;

function Obj(const AJson: string): TJSONObject;
var
  D: TJSONData;
begin
  D := GetJSON(Utf8JsonText(AJson));
  Check(D is TJSONObject, 'json is an object: ' + AJson);
  if D is TJSONObject then
    Result := TJSONObject(D)
  else
  begin
    D.Free;
    Result := TJSONObject.Create;
  end;
end;

procedure FreeObj(var AObj: TJSONObject);
begin
  FreeAndNil(AObj);
end;

var
  R: TCEAResult;
  P: TCEAWritePreview;
  O: TJSONObject;
  I: Integer;
  Kinds: array[0..6] of string;
begin
  Failures := 0;

  // --- 1. happy path: live value matches what the operator expects ----------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'command_bus/win32_compare_write_readback',
    '500', '100', '100', '64000000', False, P);
  Check(not R.Failed, 'preview builds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('field_id', '') = 'player.gold', 'field id carried');
  Check(O.Get('value_type', '') = 'dword', 'value type carried');
  Check(O.Get('address_hex', '') = '0x00A1B2C3', 'address carried');
  Check(O.Get('adapter_id', '') =
    'command_bus/win32_compare_write_readback', 'adapter carried');
  Check(O.Get('original_value', '') = '100', 'original value is the live one');
  Check(O.Get('original_bytes_hex', '') = '64000000', 'original bytes carried');
  Check(O.Get('target_value', '') = '500', 'target value carried');
  Check(O.Get('target_bytes_hex', '') = 'f4010000', 'target bytes encoded');
  Check(O.Get('conflict', False) = False, 'no conflict');
  Check(O.Get('writable_now', False) = True, 'writable now');
  Check(O.Get('requires_confirmation', False) = True,
    'every write requires confirmation (FR-043)');
  Check(O.Get('can_execute', False) = True, 'can execute');
  Check(O.Get('blocking_reason', '') = '', 'no blocking reason');
  Check(O.Get('has_pointer_chain', False) = False, 'no pointer chain');
  FreeObj(O);

  // --- 2. FR-045: live value differs from the expected one -----------------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'command_bus/win32_compare_write_readback',
    '500', '100', '777', '09030000', False, P);
  Check(not R.Failed, 'conflict preview still succeeds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('conflict', False) = True, 'conflict detected');
  Check(O.Get('original_value', '') = '777',
    'original value is what is actually there');
  Check(O.Get('original_bytes_hex', '') = '09030000',
    'original bytes are the live ones');
  Check(O.Get('can_execute', False) = False, 'conflict blocks execution');
  Check(O.Get('blocking_reason', '') = 'expected_value_changed',
    'blocking reason names the conflict');
  FreeObj(O);

  // --- 3. field is not writable yet ----------------------------------------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'read_only', 'command_bus/win32_compare_write_readback',
    '500', '100', '100', '64000000', False, P);
  Check(not R.Failed, 'read-only preview builds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('writable_now', False) = False, 'read only is not writable');
  Check(O.Get('can_execute', False) = False, 'read only blocks execution');
  Check(O.Get('blocking_reason', '') = 'field_not_verified_writable',
    'blocking reason names writability');
  Check(O.Get('conflict', False) = False,
    'writability and conflict are independent signals');
  FreeObj(O);

  // --- 4. both problems at once: writability wins the reason --------------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'pending_write', 'command_bus/win32_compare_write_readback',
    '500', '100', '777', '09030000', False, P);
  O := Obj(R.DataJson);
  Check(O.Get('conflict', False) = True, 'conflict still reported');
  Check(O.Get('blocking_reason', '') = 'field_not_verified_writable',
    'writability is the first reason');
  FreeObj(O);

  // --- 5. float formatting must not fake a conflict ------------------------
  R := BuildWritePreview('player.speed', 'Speed', 'double', '0x00A1B2C3',
    'verified_writable', 'direct_verify/win32_compare_write_readback',
    '2.5', '1.50', '1.5', '000000000000F83F', False, P);
  Check(not R.Failed, 'float preview builds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('conflict', False) = False,
    '1.50 and 1.5 are the same bytes, not a conflict');
  Check(O.Get('target_bytes_hex', '') = '0000000000000440',
    'double target encoded little endian');
  FreeObj(O);

  // --- 6. an unknown live value cannot be compared, so it is not a conflict
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'command_bus/win32_compare_write_readback',
    '500', '100', '', '', False, P);
  Check(not R.Failed, 'preview without live read builds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('conflict', False) = False,
    'an unread value is unknown, not a conflict');
  Check(O.Get('original_value', '') = '', 'no invented original value');
  Check(O.Get('can_execute', False) = True,
    'unknown live value does not block on its own');
  Check(O.Get('live_read_failed', False) = False,
    'no read was attempted, so nothing failed');
  FreeObj(O);

  // --- 6b. a failed live read blocks execution and names the reason ------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'command_bus/win32_compare_write_readback',
    '500', '100', '', '', False, P,
    'memory_effect_observation_read_failed');
  Check(not R.Failed, 'failed-read preview still succeeds: ' + R.StableCode);
  O := Obj(R.DataJson);
  Check(O.Get('live_read_failed', False) = True, 'live read failure flagged');
  Check(O.Get('live_read_stable_code', '') =
    'memory_effect_observation_read_failed', 'read failure code carried');
  Check(O.Get('can_execute', False) = False,
    'a write whose original value is unknown cannot be previewed for real');
  Check(O.Get('blocking_reason', '') = 'original_value_unavailable',
    'blocking reason names the unreadable original value');
  FreeObj(O);

  // --- 7. required inputs -------------------------------------------------
  Kinds[0] := 'write_preview_field_required';
  Kinds[1] := 'write_preview_value_type_required';
  Kinds[2] := 'write_preview_address_required';
  Kinds[3] := 'write_preview_adapter_required';
  Kinds[4] := 'write_preview_target_required';
  Kinds[5] := 'write_preview_expected_current_required';
  Kinds[6] := 'write_preview_target_invalid';

  for I := 0 to 5 do
  begin
    case I of
      0: R := BuildWritePreview('', 'Gold', 'dword', '0x00A1B2C3',
           'verified_writable', 'adapter', '500', '100', '100', '64000000',
           False, P);
      1: R := BuildWritePreview('player.gold', 'Gold', '', '0x00A1B2C3',
           'verified_writable', 'adapter', '500', '100', '100', '64000000',
           False, P);
      2: R := BuildWritePreview('player.gold', 'Gold', 'dword', '',
           'verified_writable', 'adapter', '500', '100', '100', '64000000',
           False, P);
      3: R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
           'verified_writable', '', '500', '100', '100', '64000000',
           False, P);
      4: R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
           'verified_writable', 'adapter', '', '100', '100', '64000000',
           False, P);
      5: R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
           'verified_writable', 'adapter', '500', '', '100', '64000000',
           False, P);
    end;
    Check(R.Failed, 'missing input is rejected: ' + Kinds[I]);
    Check(R.StableCode = Kinds[I], 'expected ' + Kinds[I] + ' got ' +
      R.StableCode);
    Check(R.Code = rcInvalidArgument, 'invalid argument code: ' + Kinds[I]);
  end;

  // --- 8. invalid value text ---------------------------------------------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', 'not-a-number', '100', '100', '64000000',
    False, P);
  Check(R.Failed, 'invalid target rejected');
  Check(R.StableCode = 'write_preview_target_invalid', 'target invalid code');
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '500', 'not-a-number', '100', '64000000',
    False, P);
  Check(R.Failed, 'invalid expected current rejected');
  Check(R.StableCode = 'write_preview_expected_current_invalid',
    'expected current invalid code');

  // --- 9. preview never mutates its own record on failure -----------------
  R := BuildWritePreview('', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '500', '100', '100', '64000000',
    False, P);
  Check(R.Failed, 'preview failure');
  Check(P.FieldId = '', 'failed preview leaves the record empty');
  Check(P.CanExecute = False, 'failed preview cannot execute');

  // --- 9b. FR-041 constraints are evaluated in the preview ---------------
  // No declared constraints: the field is unconstrained, not invalid.
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '500', '100', '100', '64000000',
    False, P, '', '');
  Check(R.Code = rcOk, 'empty constraints are not an error');
  Check(P.ConstraintsSatisfied, 'unconstrained target is satisfied');
  Check(P.ConstraintStableCode = '', 'no constraint code without constraints');
  Check(P.CanExecute, 'unconstrained preview can execute');

  // A target inside the declared range passes.
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '500', '100', '100', '64000000',
    False, P, '', '{"min":0,"max":999}');
  Check(R.Code = rcOk, 'in-range constraints parse');
  Check(P.ConstraintsSatisfied, 'in-range target satisfies constraints');
  Check(P.CanExecute, 'in-range preview can execute');

  // A target above the maximum blocks execution but still returns a payload:
  // the operator needs to see the preview in order to pick a valid value.
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '5000', '100', '100', '64000000',
    False, P, '', '{"min":0,"max":999}');
  Check(R.Code = rcOk, 'out-of-range preview is still a successful preview');
  Check(not P.ConstraintsSatisfied, 'out-of-range target fails constraints');
  Check(P.ConstraintStableCode = 'field_value_above_max',
    'out-of-range code: ' + P.ConstraintStableCode);
  Check(P.BlockingReason = 'constraints_not_satisfied',
    'out-of-range blocking reason: ' + P.BlockingReason);
  Check(not P.CanExecute, 'out-of-range preview cannot execute');
  O := Obj(R.DataJson);
  Check(O.Get('constraints_satisfied', True) = False,
    'constraints_satisfied is a JSON boolean');
  Check(O.Get('constraint_stable_code', '') = 'field_value_above_max',
    'constraint code reaches the payload');
  FreeObj(O);

  // A malformed constraint block is reported as such, not silently ignored.
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'adapter', '500', '100', '100', '64000000',
    False, P, '', '{"maximun":999}');
  Check(R.Code = rcOk, 'malformed constraints still return a preview');
  Check(not P.ConstraintsSatisfied, 'malformed constraints fail');
  Check(P.ConstraintStableCode = 'field_constraints_unknown_key',
    'malformed constraint code: ' + P.ConstraintStableCode);

  // Writability still wins over constraints: a read-only field is blocked for
  // the reason that matters most.
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'read_only', 'adapter', '5000', '100', '100', '64000000',
    False, P, '', '{"max":999}');
  Check(P.BlockingReason = 'field_not_verified_writable',
    'writability outranks constraints: ' + P.BlockingReason);

  // --- 10. pointer chain flag is carried through -------------------------
  R := BuildWritePreview('player.gold', 'Gold', 'dword', '0x00A1B2C3',
    'verified_writable', 'command_bus/win32_compare_write_readback',
    '500', '100', '100', '64000000', True, P);
  O := Obj(R.DataJson);
  Check(O.Get('has_pointer_chain', False) = True,
    'pointer chain flag carried');
  Check(O.Get('display_name', '') = 'Gold', 'display name carried');
  FreeObj(O);

  // --- 11. the record itself agrees with the JSON ------------------------
  Check(P.FieldId = 'player.gold', 'record field id');
  Check(P.OriginalBytesHex = '64000000', 'record original bytes');
  Check(P.TargetBytesHex = 'f4010000', 'record target bytes');
  Check(P.CanExecute, 'record can execute');

  if Failures = 0 then
    WriteLn('WRITE_PREVIEW=PASS')
  else
  begin
    WriteLn('WRITE_PREVIEW=FAIL failures=', Failures);
    Halt(1);
  end;
end.

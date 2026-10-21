program test_field_constraints;

{ FR-041: a value is checked against the field's declared constraints before it
  reaches the write path. These assertions pin the parts that are easy to get
  silently wrong: an empty constraint set must allow everything, a malformed
  constraint set must block rather than pass, and numeric bounds must be
  compared as numbers. }

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, cea_results, cea_value_scan_types, cea_field_constraints;

var
  Failures: Integer = 0;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage);
  end;
end;

procedure CheckFails(const AResult: TCEAResult; const AStableCode,
  AMessage: string);
begin
  if AResult.Code = rcOk then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage, ' (expected ', AStableCode, ', got rcOk)');
    Exit;
  end;
  if AResult.StableCode <> AStableCode then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage, ' (expected ', AStableCode, ', got ',
      AResult.StableCode, ')');
  end;
end;

var
  Constraints, Broken: TCEAFieldConstraints;
  R: TCEAResult;
  Bytes: TBytes;
  Alignment: Cardinal;

begin
  // 1. No constraints at all: every legal value passes, illegal values still do
  //    not. "No bound declared" must not become "no validation".
  R := ParseFieldConstraints('', Constraints);
  Check(R.Code = rcOk, 'empty constraints parse');
  Check(Constraints.IsEmpty, 'empty constraints are empty');
  Check(ValidateFieldValue('dword', '5000', Constraints).Code = rcOk,
    'no constraints allows a large value');
  CheckFails(ValidateFieldValue('dword', 'abc', Constraints),
    'field_value_not_numeric', 'no constraints still rejects non-numeric text');

  // 2. min/max are compared as numbers, not as text. 9 is below 100 even though
  //    the string '9' sorts after '100'.
  R := ParseFieldConstraints('{"min":100,"max":200}', Constraints);
  Check(R.Code = rcOk, 'min/max constraints parse');
  Check(ValidateFieldValue('dword', '150', Constraints).Code = rcOk,
    'value inside the range passes');
  Check(ValidateFieldValue('dword', '100', Constraints).Code = rcOk,
    'the lower bound is inclusive');
  Check(ValidateFieldValue('dword', '200', Constraints).Code = rcOk,
    'the upper bound is inclusive');
  CheckFails(ValidateFieldValue('dword', '99', Constraints),
    'field_value_below_min', 'value below the minimum is rejected');
  CheckFails(ValidateFieldValue('dword', '201', Constraints),
    'field_value_above_max', 'value above the maximum is rejected');
  CheckFails(ValidateFieldValue('dword', '9', Constraints),
    'field_value_below_min', 'numeric comparison, not text comparison');

  // 3. A negative bound works for signed types.
  R := ParseFieldConstraints('{"min":-50,"max":50}', Constraints);
  Check(R.Code = rcOk, 'negative bounds parse');
  Check(ValidateFieldValue('integer', '-25', Constraints).Code = rcOk,
    'a negative value inside the range passes');
  CheckFails(ValidateFieldValue('integer', '-51', Constraints),
    'field_value_below_min', 'a negative value below the range is rejected');

  // 4. Floats: the bound comparison must not round through an integer.
  R := ParseFieldConstraints('{"min":0.5,"max":1.5}', Constraints);
  Check(R.Code = rcOk, 'float bounds parse');
  Check(ValidateFieldValue('single', '1.25', Constraints).Code = rcOk,
    'a float inside the range passes');
  CheckFails(ValidateFieldValue('single', '1.75', Constraints),
    'field_value_above_max', 'a float above the range is rejected');

  // 5. allowed_values compares encoded bytes, so 1.5 and 1.50 are the same
  //    allowed value.
  R := ParseFieldConstraints('{"allowed_values":[1.5,2.5]}', Constraints);
  Check(R.Code = rcOk, 'allowed values parse');
  Check(ValidateFieldValue('single', '1.5', Constraints).Code = rcOk,
    'an allowed float passes');
  Check(ValidateFieldValue('single', '1.50', Constraints).Code = rcOk,
    'the same float written differently is still allowed');
  CheckFails(ValidateFieldValue('single', '3.5', Constraints),
    'field_value_not_allowed', 'a value outside the allowed set is rejected');
  R := ParseFieldConstraints('{"allowed_values":["1","2","3"]}', Constraints);
  Check(R.Code = rcOk, 'string allowed values parse');
  Check(ValidateFieldValue('byte', '2', Constraints).Code = rcOk,
    'a numeric string in the allowed set matches the encoded byte');
  CheckFails(ValidateFieldValue('byte', '4', Constraints),
    'field_value_not_allowed', 'a byte outside the allowed set is rejected');

  // 6. A malformed constraint set is an error, never a silent skip. Every one of
  //    these would otherwise allow the write while looking "constrained".
  CheckFails(ParseFieldConstraints('{"min":', Broken),
    'field_constraints_invalid', 'broken JSON is rejected');
  CheckFails(ParseFieldConstraints('[1,2]', Broken),
    'field_constraints_invalid', 'a non-object is rejected');
  CheckFails(ParseFieldConstraints('{"maximun":100}', Broken),
    'field_constraints_unknown_key', 'a misspelled key is rejected');
  CheckFails(ParseFieldConstraints('{"allowed_values":"x"}', Broken),
    'field_constraints_allowed_invalid', 'a non-array allowed set is rejected');
  CheckFails(ParseFieldConstraints('{"allowed_values":[true]}', Broken),
    'field_constraints_allowed_invalid', 'a boolean allowed value is rejected');
  CheckFails(ParseFieldConstraints('{"allowed_values":[[1]]}', Broken),
    'field_constraints_allowed_invalid', 'a nested allowed value is rejected');
  CheckFails(ParseFieldConstraints('{"min":null}', Broken),
    'field_constraints_invalid', 'a null bound is rejected');

  // 7. Value types with no encoding on this path are refused up front instead of
  //    being half validated.
  R := ParseFieldConstraints('', Constraints);
  CheckFails(ValidateFieldValue('enum', '1', Constraints),
    'field_value_type_unsupported', 'enum is not writable on this path');
  CheckFails(ValidateFieldValue('string', 'abc', Constraints),
    'field_value_type_unsupported', 'string is not writable on this path');
  Check(IsWritableValueType('integer'), 'integer is writable');
  Check(IsWritableValueType('bool'), 'bool is writable');
  Check(not IsWritableValueType('enum'), 'enum is not writable');

  // 8. bool and integer now encode. Before this change every write to such a
  //    field failed with invalid_scan_value, so the type was declared but not
  //    usable.
  R := EncodeExactValue('bool', 'true', Bytes, Alignment);
  Check(R.Code = rcOk, 'bool encodes');
  Check((Length(Bytes) = 4) and (Bytes[0] = 1), 'bool true is a 32 bit 1');
  R := EncodeExactValue('bool', 'false', Bytes, Alignment);
  Check((R.Code = rcOk) and (Length(Bytes) = 4) and (Bytes[0] = 0),
    'bool false is a 32 bit 0');
  Check(EncodeExactValue('bool', 'yes', Bytes, Alignment).Failed,
    'bool rejects non-boolean text');
  R := EncodeExactValue('integer', '-2', Bytes, Alignment);
  Check((R.Code = rcOk) and (Length(Bytes) = 4) and (Bytes[0] = $FE) and
    (Bytes[3] = $FF), 'integer is a signed 32 bit value');
  Check(ValidateFieldValue('bool', 'true', Constraints).Code = rcOk,
    'bool passes validation with no constraints');

  // 9. The constraint set survives a JSON round trip, so the runtime can report
  //    back exactly what it enforced.
  R := ParseFieldConstraints('{"min":10,"max":20,"allowed_values":["12","14"]}',
    Constraints);
  Check(R.Code = rcOk, 'combined constraints parse');
  Check(Pos('"has_min":true', Constraints.ToJson) > 0, 'to_json reports min');
  Check(Pos('"allowed_values":["12","14"]', Constraints.ToJson) > 0,
    'to_json reports the allowed set: ' + Constraints.ToJson);
  Check(ValidateFieldValue('dword', '14', Constraints).Code = rcOk,
    'a value inside both the range and the allowed set passes');
  CheckFails(ValidateFieldValue('dword', '12.5', Constraints),
    'field_value_not_numeric',
    'a fractional value is rejected for an integer field');

  if Failures = 0 then
    WriteLn('FIELD_CONSTRAINTS=PASS')
  else
  begin
    WriteLn('FIELD_CONSTRAINTS=FAIL failures=', Failures);
    Halt(1);
  end;
end.

program test_write_access;
// FR-054 write isolation + FR-040 write-capability marking.
//
// The interesting assertions here are the negative ones: a fresh session must
// refuse writes, a grant must not survive a target change, and pending_write
// must never be mistaken for permission to write.

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, fpjson, jsonparser, cea_results, cea_field_model, cea_write_access;

var
  Failures: Integer = 0;

procedure Check(const AOk: Boolean; const AMessage: string);
begin
  if not AOk then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage);
  end;
end;

procedure CheckFails(const AResult: TCEAResult; const ACode: TCEAResultCode;
  const AStableCode, AMessage: string);
begin
  Check(AResult.Failed and (AResult.Code = ACode) and
    (AResult.StableCode = AStableCode),
    AMessage + ' (got ' + AResult.StableCode + ' / ' + IntToStr(Ord(AResult.Code)) +
    ')');
end;

function Obj(const AJson: string): TJSONData;
begin
  Result := GetJSON(Utf8JsonText(AJson));
end;

function BoolAt(const AJson, APath: string): Boolean;
var
  Data: TJSONData;
begin
  Result := False;
  Data := Obj(AJson);
  try
    Result := Data.FindPath(APath).AsBoolean;
  finally
    Data.Free;
  end;
end;

function StrAt(const AJson, APath: string): string;
var
  Data: TJSONData;
begin
  Result := '';
  Data := Obj(AJson);
  try
    Result := Data.FindPath(APath).AsString;
  finally
    Data.Free;
  end;
end;

var
  Access: TCEAWriteAccess;
  R: TCEAResult;
  Enabled: TCEAWriteAccess;
  Identity: string;
  Epoch: QWord;
  Request: TCEAFieldWriteRequest;

begin
  Identity := 'pid-4242-abc';
  Epoch := 7;

  // --- 1. a fresh session refuses writes, and says why
  Access := DefaultWriteAccess;
  Check(not Access.Enabled, 'a fresh session starts with writes disabled');
  R := CheckWriteAccess(Access, Identity, Epoch);
  CheckFails(R, rcUnauthorized, CeaWriteAccessDisabledCode,
    'writing is refused before the operator enables it');
  Check(Pos('local_ui_only', R.DataJson) > 0,
    'the refusal names the only place writes can be enabled: ' + R.DataJson);

  // --- 2. enabling requires a stated reason
  CheckFails(ValidateWriteAccessReason(''), rcInvalidArgument,
    CeaWriteAccessReasonRequiredCode, 'enabling without a reason is refused');
  CheckFails(ValidateWriteAccessReason('   '), rcInvalidArgument,
    CeaWriteAccessReasonRequiredCode, 'whitespace is not a reason');
  Check(ValidateWriteAccessReason('测试离线存档').Code = rcOk,
    'a stated reason is accepted');
  CheckFails(ValidateWriteAccessReason(StringOfChar('x', 401)), rcInvalidArgument,
    CeaWriteAccessReasonTooLongCode, 'an unbounded reason is refused');

  // --- 3. an enabled grant covers exactly one target
  Enabled := EnableWriteAccess(Identity, Epoch, '2026-10-21T00:00:00Z', '测试');
  Check(Enabled.Enabled, 'enabling marks the grant active');
  Check(CheckWriteAccess(Enabled, Identity, Epoch).Code = rcOk,
    'the grant covers the target it was made for');
  CheckFails(CheckWriteAccess(Enabled, 'pid-9999-other', Epoch), rcUnauthorized,
    CeaWriteAccessTargetChangedCode, 'a different process is not covered');
  CheckFails(CheckWriteAccess(Enabled, Identity, Epoch + 1), rcUnauthorized,
    CeaWriteAccessTargetChangedCode,
    'a re-attach invalidates the grant instead of inheriting it');

  // --- 4. disabling forgets the grant entirely
  Access := DisableWriteAccess;
  Check(not Access.Enabled, 'disabling clears the flag');
  Check(Access.ProcessIdentityId = '',
    'disabling forgets which target it applied to');
  CheckFails(CheckWriteAccess(Access, Identity, Epoch), rcUnauthorized,
    CeaWriteAccessDisabledCode, 'a disabled grant refuses writes again');

  // --- 5. the four states of FR-040 are each reachable
  Check(FieldAcceptsWrite(faVerifiedWritable), 'verified_writable may be written');
  Check(not FieldAcceptsWrite(faReadOnly), 'read_only may not be written');
  Check(not FieldAcceptsWrite(faPendingWrite),
    'pending_write is intent, not permission');
  Check(not FieldAcceptsWrite(faInvalid),
    'an invalid field has no address worth writing');

  // --- 6. a write request moves read_only and invalid to pending_write
  Request := ClassifyWriteRequest(faReadOnly);
  Check(Request = fwrAccepted, 'a read_only field accepts a write request');
  Check(FieldAccessAfterRequest(faReadOnly) = faPendingWrite,
    'the request parks the field in pending_write');
  Check(ClassifyWriteRequest(faPendingWrite) = fwrAlreadyPending,
    'asking twice is reported, not silently repeated');
  Check(FieldAccessAfterRequest(faPendingWrite) = faPendingWrite,
    'a pending field stays pending');
  Check(ClassifyWriteRequest(faVerifiedWritable) = fwrAlreadyVerified,
    'an already proven field reports that it is proven');
  Check(FieldAccessAfterRequest(faVerifiedWritable) = faVerifiedWritable,
    'a proven field is not demoted by asking again');
  Check(ClassifyWriteRequest(faInvalid) = fwrAccepted,
    'an invalid field may be re-resolved and requested again');
  Check(FieldAccessAfterRequest(faInvalid) = faPendingWrite,
    're-requesting clears the invalid state back to intent');

  // --- 7. request text is stable for the MCP surface
  Check(FieldWriteRequestText(fwrAccepted) = 'accepted', 'accepted text');
  Check(FieldWriteRequestText(fwrAlreadyPending) = 'already_pending',
    'already_pending text');
  Check(FieldWriteRequestText(fwrAlreadyVerified) = 'already_verified',
    'already_verified text');

  // --- 8. the access payload is real JSON
  R := TCEAResult.Ok(WriteAccessJson(Enabled));
  Check(BoolAt(R.DataJson, 'enabled'), 'enabled is a JSON boolean');
  Check(StrAt(R.DataJson, 'process_identity_id') = Identity,
    'the payload names the target: ' + R.DataJson);
  // Byte comparison, not string comparison: a string comparison here would be
  // decided by the code page label on each side rather than by the bytes.
  Check(Pos('"reason":"测试"', R.DataJson) > 0,
    'the payload carries the reason: ' + R.DataJson);
  Check(StrAt(WriteAccessJson(DefaultWriteAccess), 'process_identity_id') = '',
    'a default grant names no target');
  Check(not BoolAt(WriteAccessJson(DefaultWriteAccess), 'enabled'),
    'a default grant is disabled in JSON too');

  if Failures = 0 then
    WriteLn('WRITE_ACCESS=PASS')
  else
  begin
    WriteLn('WRITE_ACCESS=FAIL failures=', Failures);
    Halt(1);
  end;
end.

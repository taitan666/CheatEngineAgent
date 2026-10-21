unit cea_write_access;
// FR-054 write isolation and FR-040 write-capability marking.
//
// Two separate permissions, deliberately:
//   * scanning is granted by the scan lease and needs no write access at all;
//   * writing is disabled for every session until the operator enables it, and
//     even then a field must be moved from read_only to pending_write before the
//     verification write may run.
//
// Why a session gate instead of a per-call confirmation: a per-call confirmation
// answers "do you want this write" but never answers "is writing allowed on this
// target at all". A player who enabled writes once expects the next write to be
// possible; a player who never enabled them should not have to trust that every
// code path remembered to ask.
//
// Why pending_write instead of jumping straight to the verification write: the
// four states of FR-040 are only real if each one can be observed. read_only is
// the default, verified_writable is the proof, invalid is the loss, and
// pending_write is the operator saying "I intend to write this field". Without a
// resting state between intent and proof, a caller can perform a real write to
// the target process without ever having declared that it meant to.
//
// The grant is bound to one process identity and epoch: enabling writes for one
// target must never silently authorise another, and a re-attach invalidates the
// grant rather than inheriting it.

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_field_model;

const
  CeaWriteAccessReasonMaxChars = 400;
  // Stable codes. A caller must be able to tell "you never allowed writing"
  // apart from "you allowed it for a process that is gone".
  CeaWriteAccessDisabledCode = 'writes_not_enabled';
  CeaWriteAccessTargetChangedCode = 'write_access_target_changed';
  CeaWriteAccessNotRequestedCode = 'field_write_not_requested';
  CeaWriteAccessReasonRequiredCode = 'write_access_reason_required';
  CeaWriteAccessReasonTooLongCode = 'write_access_reason_too_long';

type
  TCEAWriteAccess = record
    Enabled: Boolean;
    EnabledAt: string;
    Reason: string;
    ProcessIdentityId: string;
    Epoch: QWord;
  end;

  // What a write request on one field means. There is deliberately no
  // "not requestable" member: every access state either accepts the request or
  // is already past it, so an unhandled state cannot hide here.
  TCEAFieldWriteRequest = (fwrAccepted, fwrAlreadyPending, fwrAlreadyVerified);

function DefaultWriteAccess: TCEAWriteAccess;
function EnableWriteAccess(const AIdentityId: string; const AEpoch: QWord;
  const AEnabledAt, AReason: string): TCEAWriteAccess;
function DisableWriteAccess: TCEAWriteAccess;
function WriteAccessJson(const AAccess: TCEAWriteAccess): string;

// The session gate. Returns rcUnauthorized when writing was never enabled, or
// when the grant belongs to a different target than the one in front of us.
function CheckWriteAccess(const AAccess: TCEAWriteAccess;
  const AIdentityId: string; const AEpoch: QWord): TCEAResult;

// Validates the operator's stated reason. Enabling writes without recording why
// leaves an audit trail that says a capability appeared out of nowhere.
function ValidateWriteAccessReason(const AReason: string): TCEAResult;

function ClassifyWriteRequest(const AAccess: TCEAFieldAccess): TCEAFieldWriteRequest;
function FieldAccessAfterRequest(const AAccess: TCEAFieldAccess): TCEAFieldAccess;
function FieldWriteRequestText(const ARequest: TCEAFieldWriteRequest): string;

// Only verified_writable may be written. pending_write exists precisely so that
// "the operator asked" cannot be mistaken for "the write is proven".
function FieldAcceptsWrite(const AAccess: TCEAFieldAccess): Boolean;

implementation

function JsonEscape(const AValue: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    Ch := AValue[I];
    case Ch of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if Ch < ' ' then
        Result := Result + '\u' + IntToHex(Ord(Ch), 4)
      else
        Result := Result + Ch;
    end;
  end;
end;

function JsonBoolText(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function DefaultWriteAccess: TCEAWriteAccess;
begin
  Result := Default(TCEAWriteAccess);
  Result.Enabled := False;
  Result.Epoch := 0;
end;

function EnableWriteAccess(const AIdentityId: string; const AEpoch: QWord;
  const AEnabledAt, AReason: string): TCEAWriteAccess;
begin
  Result := Default(TCEAWriteAccess);
  Result.Enabled := True;
  Result.EnabledAt := AEnabledAt;
  Result.Reason := AReason;
  Result.ProcessIdentityId := AIdentityId;
  Result.Epoch := AEpoch;
end;

function DisableWriteAccess: TCEAWriteAccess;
begin
  // Disabling forgets the grant entirely: keeping the old identity around would
  // let a later enable for the same process look like a continuation of a grant
  // the operator has already withdrawn.
  Result := DefaultWriteAccess;
end;

function WriteAccessJson(const AAccess: TCEAWriteAccess): string;
begin
  Result := Utf8JsonText('{"enabled":' + JsonBoolText(AAccess.Enabled) +
    ',"enabled_at":"' + JsonEscape(AAccess.EnabledAt) +
    '","reason":"' + JsonEscape(AAccess.Reason) +
    '","process_identity_id":"' + JsonEscape(AAccess.ProcessIdentityId) +
    '","epoch":' + IntToStr(AAccess.Epoch) + '}');
end;

function CheckWriteAccess(const AAccess: TCEAWriteAccess;
  const AIdentityId: string; const AEpoch: QWord): TCEAResult;
begin
  if not AAccess.Enabled then
    Exit(TCEAResult.Error(rcUnauthorized, CeaWriteAccessDisabledCode,
      '{"hint":"enable writes for this session in the local UI",' +
      '"approval_surface":"local_ui_only"}'));
  if (AAccess.ProcessIdentityId <> AIdentityId) or (AAccess.Epoch <> AEpoch) then
    Exit(TCEAResult.Error(rcUnauthorized, CeaWriteAccessTargetChangedCode,
      '{"hint":"the target process changed, writes must be enabled again"}'));
  Result := TCEAResult.Ok('{}');
end;

function ValidateWriteAccessReason(const AReason: string): TCEAResult;
begin
  if Trim(AReason) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, CeaWriteAccessReasonRequiredCode,
      '{"hint":"record why writes were enabled for this session"}'));
  if Length(AReason) > CeaWriteAccessReasonMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, CeaWriteAccessReasonTooLongCode,
      '{"max_chars":' + IntToStr(CeaWriteAccessReasonMaxChars) + '}'));
  Result := TCEAResult.Ok('{}');
end;

function ClassifyWriteRequest(const AAccess: TCEAFieldAccess): TCEAFieldWriteRequest;
begin
  case AAccess of
    faVerifiedWritable: Result := fwrAlreadyVerified;
    faPendingWrite: Result := fwrAlreadyPending;
  else
    // read_only and invalid both accept the request: an invalid field has lost
    // its address, and asking to write it again is exactly how the operator says
    // "re-resolve it and try once more".
    Result := fwrAccepted;
  end;
end;

function FieldAccessAfterRequest(const AAccess: TCEAFieldAccess): TCEAFieldAccess;
begin
  if ClassifyWriteRequest(AAccess) = fwrAccepted then
    Result := faPendingWrite
  else
    Result := AAccess;
end;

function FieldWriteRequestText(const ARequest: TCEAFieldWriteRequest): string;
begin
  case ARequest of
    fwrAccepted: Result := 'accepted';
    fwrAlreadyPending: Result := 'already_pending';
    fwrAlreadyVerified: Result := 'already_verified';
  else
    Result := 'accepted';
  end;
end;

function FieldAcceptsWrite(const AAccess: TCEAFieldAccess): Boolean;
begin
  Result := AAccess = faVerifiedWritable;
end;

end.

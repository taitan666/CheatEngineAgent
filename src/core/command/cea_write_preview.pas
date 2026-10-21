unit cea_write_preview;

{ FR-042 command preview and FR-045 state conflict detection.

  The preview exists so the operator sees exactly what a write command will do
  before it happens: which field, which address, the value that is there right
  now, the value that would replace it, and which adapter would carry it out.

  Design rules (each one is load-bearing):

  1. The "original value" is the LIVE value read from the target process, never
     the value cached in the game state model. The model's value can be minutes
     old, and after a session restart it is deliberately cleared, so reusing it
     would show the operator a number that is no longer there.

  2. A conflict is reported when the operator's expected current value does not
     match the live bytes. Comparing bytes (not text) keeps float values from
     being reported as conflicts because of formatting.

  3. A preview never writes and never mutates the model. That is why it can be
     exposed to an MCP client while the write itself cannot.

  4. A conflict is NOT an error result. The preview succeeded at previewing; the
     payload carries can_execute=false plus a blocking reason. Returning an error
     would leave the UI with nothing to display, which is exactly the situation
     the operator needs to see. }

{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_value_scan_types, cea_field_constraints;

const
  CeaWritePreviewMaxChars = 512;

type
  TCEAWritePreview = record
    FieldId: string;
    DisplayName: string;
    ValueType: string;
    AddressHex: string;
    AccessText: string;
    AdapterId: string;
    OriginalValue: string;
    OriginalBytesHex: string;
    ExpectedCurrentValue: string;
    TargetValue: string;
    TargetBytesHex: string;
    HasPointerChain: Boolean;
    Conflict: Boolean;
    WritableNow: Boolean;
    RequiresConfirmation: Boolean;
    BlockingReason: string;
    LiveReadFailed: Boolean;
    LiveReadStableCode: string;
    // FR-041: the field's declared constraints travel with the preview so the
    // operator sees why a value was refused instead of discovering it at write
    // time. ConstraintsSatisfied stays True when the field declares nothing.
    ConstraintsJson: string;
    ConstraintsSatisfied: Boolean;
    ConstraintStableCode: string;
    function CanExecute: Boolean;
    function ToJson: string;
  end;

{ Builds a preview for a write command. AObservedCurrentValue and
  AObservedCurrentHex must come from a live read of the field address; the
  caller is responsible for performing that read (this unit never touches a
  process). ALiveReadStableCode carries the reason when that read failed, so the
  operator can tell "the value is unknown" from "the value is empty".

  AConstraintsJson is the field's ConstraintsJson verbatim. A constraint problem
  (malformed metadata or an out-of-range target) becomes a blocking reason, not
  an error result, for the same reason a conflict is not an error: the preview
  succeeded at previewing, and the operator needs to see the payload in order to
  understand what to fix. The write paths still refuse hard. }
function BuildWritePreview(const AFieldId, ADisplayName, AValueType,
  AAddressHex, AAccessText, AAdapterId, ATargetValue, AExpectedCurrentValue,
  AObservedCurrentValue, AObservedCurrentHex: string;
  const AHasPointerChain: Boolean;
  out APreview: TCEAWritePreview;
  const ALiveReadStableCode: string = '';
  const AConstraintsJson: string = ''): TCEAResult;

implementation

function JsonEscape(const AValue: string): string;
var
  I: Integer;
  B: Byte;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    B := Byte(AValue[I]);
    if B = Ord('"') then
      Result := Result + '\"'
    else if B = Ord('\') then
      Result := Result + '\\'
    else if B < 32 then
      Result := Result + '\u' + LowerCase(IntToHex(B, 4))
    else
      Result := Result + Char(B);
  end;
end;

function BytesToHexLower(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(ABytes) - 1 do
    Result := Result + LowerCase(IntToHex(ABytes[I], 2));
end;

function PreviewError(const AStableCode: string): TCEAResult;
begin
  Result := TCEAResult.Error(rcInvalidArgument, AStableCode, '{}');
end;

function TCEAWritePreview.CanExecute: Boolean;
begin
  Result := WritableNow and (not Conflict) and (not LiveReadFailed) and
    ConstraintsSatisfied;
end;

function TCEAWritePreview.ToJson: string;
begin
  Result := Utf8JsonText('{"field_id":"' + JsonEscape(FieldId) +
    '","display_name":"' + JsonEscape(DisplayName) +
    '","value_type":"' + JsonEscape(ValueType) +
    '","address_hex":"' + JsonEscape(AddressHex) +
    '","access":"' + JsonEscape(AccessText) +
    '","adapter_id":"' + JsonEscape(AdapterId) +
    '","original_value":"' + JsonEscape(OriginalValue) +
    '","original_bytes_hex":"' + JsonEscape(OriginalBytesHex) +
    '","expected_current_value":"' + JsonEscape(ExpectedCurrentValue) +
    '","target_value":"' + JsonEscape(TargetValue) +
    '","target_bytes_hex":"' + JsonEscape(TargetBytesHex) +
    '","has_pointer_chain":' + BoolToStr(HasPointerChain, 'true', 'false') +
    ',"conflict":' + BoolToStr(Conflict, 'true', 'false') +
    ',"writable_now":' + BoolToStr(WritableNow, 'true', 'false') +
    ',"requires_confirmation":' +
    BoolToStr(RequiresConfirmation, 'true', 'false') +
    ',"can_execute":' + BoolToStr(CanExecute, 'true', 'false') +
    ',"blocking_reason":"' + JsonEscape(BlockingReason) +
    '","live_read_failed":' + BoolToStr(LiveReadFailed, 'true', 'false') +
    ',"live_read_stable_code":"' + JsonEscape(LiveReadStableCode) +
    '","constraints_json":"' + JsonEscape(ConstraintsJson) +
    '","constraints_satisfied":' +
    BoolToStr(ConstraintsSatisfied, 'true', 'false') +
    ',"constraint_stable_code":"' + JsonEscape(ConstraintStableCode) + '"}');
end;

function BuildWritePreview(const AFieldId, ADisplayName, AValueType,
  AAddressHex, AAccessText, AAdapterId, ATargetValue, AExpectedCurrentValue,
  AObservedCurrentValue, AObservedCurrentHex: string;
  const AHasPointerChain: Boolean;
  out APreview: TCEAWritePreview;
  const ALiveReadStableCode: string;
  const AConstraintsJson: string): TCEAResult;
var
  ExpectedBytes, TargetBytes: TBytes;
  Alignment: Cardinal;
  EncodeResult: TCEAResult;
  Constraints: TCEAFieldConstraints;
  ConstraintResult: TCEAResult;
begin
  APreview := Default(TCEAWritePreview);

  if Trim(AFieldId) = '' then
    Exit(PreviewError('write_preview_field_required'));
  if Trim(AValueType) = '' then
    Exit(PreviewError('write_preview_value_type_required'));
  if Trim(AAddressHex) = '' then
    Exit(PreviewError('write_preview_address_required'));
  if Trim(AAdapterId) = '' then
    Exit(PreviewError('write_preview_adapter_required'));
  if Trim(ATargetValue) = '' then
    Exit(PreviewError('write_preview_target_required'));
  if Trim(AExpectedCurrentValue) = '' then
    Exit(PreviewError('write_preview_expected_current_required'));

  EncodeResult := EncodeExactValue(AValueType, AExpectedCurrentValue,
    ExpectedBytes, Alignment);
  if EncodeResult.Failed then
    Exit(PreviewError('write_preview_expected_current_invalid'));
  EncodeResult := EncodeExactValue(AValueType, ATargetValue, TargetBytes,
    Alignment);
  if EncodeResult.Failed then
    Exit(PreviewError('write_preview_target_invalid'));

  APreview.FieldId := AFieldId;
  APreview.DisplayName := ADisplayName;
  APreview.ValueType := AValueType;
  APreview.AddressHex := AAddressHex;
  APreview.AccessText := AAccessText;
  APreview.AdapterId := AAdapterId;
  APreview.OriginalValue := AObservedCurrentValue;
  APreview.OriginalBytesHex := LowerCase(AObservedCurrentHex);
  APreview.ExpectedCurrentValue := AExpectedCurrentValue;
  APreview.TargetValue := ATargetValue;
  APreview.TargetBytesHex := BytesToHexLower(TargetBytes);
  APreview.HasPointerChain := AHasPointerChain;
  APreview.LiveReadFailed := ALiveReadStableCode <> '';
  APreview.LiveReadStableCode := ALiveReadStableCode;
  // FR-045: compare the live bytes against the bytes the operator expects. Text
  // comparison would call '1.5' and '1.50' a conflict when they are the same
  // value, and would miss a difference hidden by formatting.
  APreview.Conflict := (APreview.OriginalBytesHex <> '') and
    (not SameText(APreview.OriginalBytesHex, BytesToHexLower(ExpectedBytes)));
  APreview.WritableNow := SameText(AAccessText, 'verified_writable');
  // FR-041: check the target against the field's declared constraints. A
  // malformed constraint block is reported separately from an out-of-range
  // value, because the operator's fix is different in each case (repair the
  // metadata vs pick another value).
  APreview.ConstraintsJson := AConstraintsJson;
  APreview.ConstraintsSatisfied := True;
  APreview.ConstraintStableCode := '';
  if Trim(AConstraintsJson) <> '' then
  begin
    ConstraintResult := ParseFieldConstraints(AConstraintsJson, Constraints);
    if ConstraintResult.Failed then
    begin
      APreview.ConstraintsSatisfied := False;
      APreview.ConstraintStableCode := ConstraintResult.StableCode;
    end
    else
    begin
      ConstraintResult := ValidateFieldValue(AValueType, ATargetValue,
        Constraints);
      if ConstraintResult.Failed then
      begin
        APreview.ConstraintsSatisfied := False;
        APreview.ConstraintStableCode := ConstraintResult.StableCode;
      end;
    end;
  end;
  // FR-043: every write command is confirmed, even a fully previewed one.
  APreview.RequiresConfirmation := True;
  if not APreview.WritableNow then
    APreview.BlockingReason := 'field_not_verified_writable'
  else if not APreview.ConstraintsSatisfied then
    // A value the field's own constraints reject must not look executable,
    // even though the address and the access state are fine.
    APreview.BlockingReason := 'constraints_not_satisfied'
  else if APreview.LiveReadFailed then
    // A preview whose original value could not be read shows the operator
    // nothing about what would be overwritten. That is worse than a stale
    // value, because a stale value at least looks like a value.
    APreview.BlockingReason := 'original_value_unavailable'
  else if APreview.Conflict then
    APreview.BlockingReason := 'expected_value_changed'
  else
    APreview.BlockingReason := '';

  Result := TCEAResult.Ok(APreview.ToJson);
end;

end.

unit cea_value_scan_ui_model;

{$mode objfpc}{$H+}

interface

uses
  cea_results;

type
  TCEAValueScanUiInput = record
    StartAddress: QWord;
    RangeBytes: Cardinal;
    ValueType: string;
    ValueText: string;
    MaxResults: Cardinal;
  end;

function ValidateValueScanUiInput(const AStartHex, ARangeText,
  AValueType, AValueText, AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
function ValidateValueScanScopeUiInput(const AStartHex, ARangeText,
  AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
function ValidateProcessValueScanUiInput(const ARegionKinds,
  AMaxBytesText, AValueType, AValueText, AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
function ValidateValueRefineUiInput(const AScanId, AOriginalType,
  ACurrentType, AValueText: string): TCEAResult;

implementation

uses
  SysUtils, cea_value_scan_types;

function ValidateValueScanUiInput(const AStartHex, ARangeText,
  AValueType, AValueText, AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
var
  Bytes: TBytes;
  Alignment: Cardinal;
begin
  AInput.StartAddress := 0;
  AInput.RangeBytes := 0;
  AInput.ValueType := '';
  AInput.ValueText := '';
  AInput.MaxResults := 0;
  if (Copy(AStartHex, 1, 2) <> '0x') or
     not TryStrToQWord('$' + Copy(AStartHex, 3, MaxInt),
       AInput.StartAddress) or
     (AInput.StartAddress = 0) or
     not TryStrToDWord(ARangeText, AInput.RangeBytes) or
     not TryStrToDWord(AMaxResultsText, AInput.MaxResults) or
     (AInput.RangeBytes = 0) or (AInput.MaxResults = 0) or
     (AInput.StartAddress > High(QWord) - AInput.RangeBytes) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'value_scan_ui_input_invalid', '{}'));
  if (QWord(AInput.RangeBytes) > QWord(512) * 1024 * 1024) or
     (AInput.MaxResults > 10000) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'value_scan_ui_budget_exceeded', '{}'));
  Result := EncodeExactValue(AValueType, AValueText, Bytes, Alignment);
  if Result.Failed then Exit;
  if Length(Bytes) > AInput.RangeBytes then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'value_scan_ui_range_too_small', '{}'));
  AInput.ValueType := AValueType;
  AInput.ValueText := AValueText;
  Result := TCEAResult.Ok('{}');
end;

function ValidateValueRefineUiInput(const AScanId, AOriginalType,
  ACurrentType, AValueText: string): TCEAResult;
var
  Bytes: TBytes;
  Alignment: Cardinal;
begin
  if (AScanId = '') or (AOriginalType = '') or
     (ACurrentType <> AOriginalType) then
    Exit(TCEAResult.Error(rcConflict,
      'value_refine_session_invalid', '{}'));
  Result := EncodeExactValue(ACurrentType, Trim(AValueText), Bytes,
    Alignment);
end;

function ValidateValueScanScopeUiInput(const AStartHex, ARangeText,
  AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
begin
  Result := ValidateValueScanUiInput(AStartHex, ARangeText,
    'byte', '0', AMaxResultsText, AInput);
  if not Result.Failed then
  begin
    AInput.ValueType := '';
    AInput.ValueText := '';
  end;
end;

function ValidateProcessValueScanUiInput(const ARegionKinds,
  AMaxBytesText, AValueType, AValueText, AMaxResultsText: string;
  out AInput: TCEAValueScanUiInput): TCEAResult;
var
  Kinds: string;
  Bytes: TBytes;
  Alignment: Cardinal;
begin
  FillChar(AInput, SizeOf(AInput), 0);
  Kinds := LowerCase(StringReplace(Trim(ARegionKinds), ' ', '',
    [rfReplaceAll]));
  if (Kinds <> 'private') and (Kinds <> 'private,image') and
     (Kinds <> 'private,mapped') and
     (Kinds <> 'private,image,mapped') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'value_scan_region_kinds_invalid', '{}'));
  if not TryStrToDWord(AMaxBytesText, AInput.RangeBytes) or
     not TryStrToDWord(AMaxResultsText, AInput.MaxResults) or
     (AInput.RangeBytes = 0) or (AInput.MaxResults = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'value_scan_ui_input_invalid', '{}'));
  if (QWord(AInput.RangeBytes) > QWord(512) * 1024 * 1024) or
     (AInput.MaxResults > 10000) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'value_scan_ui_budget_exceeded', '{}'));
  Result := EncodeExactValue(AValueType, Trim(AValueText), Bytes, Alignment);
  if Result.Failed then Exit;
  AInput.ValueType := AValueType;
  AInput.ValueText := Trim(AValueText);
  Result := TCEAResult.Ok('{}');
end;

end.

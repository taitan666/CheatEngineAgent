unit cea_value_scan_types;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results;

type
  TCEAScanCoverage = record
    RequestedBytes: QWord;
    EligibleBytes: QWord;
    InspectedBytes: QWord;
    SkippedBytes: QWord;
    Complete: Boolean;
    PartialReason: string;
  end;

function EncodeExactValue(const AValueType, AText: string;
  out ABytes: TBytes; out AAlignment: Cardinal): TCEAResult;
function IsValueAligned(const AAddress: QWord;
  const AAlignment: Cardinal): Boolean;

implementation

uses
  Math;

function DecimalInteger(const AText: string): Boolean;
var
  Index, FirstDigit: Integer;
begin
  Result := False;
  if AText = '' then Exit;
  FirstDigit := 1;
  if AText[1] in ['-', '+'] then FirstDigit := 2;
  if FirstDigit > Length(AText) then Exit;
  for Index := FirstDigit to Length(AText) do
    if not (AText[Index] in ['0'..'9']) then Exit;
  Result := True;
end;

function InvalidValue: TCEAResult;
begin
  Result := TCEAResult.Error(rcInvalidArgument,
    'invalid_scan_value', '{}');
end;

function IsValueAligned(const AAddress: QWord;
  const AAlignment: Cardinal): Boolean;
begin
  Result := (AAlignment > 0) and ((AAddress mod AAlignment) = 0);
end;

function EncodeExactValue(const AValueType, AText: string;
  out ABytes: TBytes; out AAlignment: Cardinal): TCEAResult;
var
  Width: Cardinal;
  Bits, MaximumUnsigned: QWord;
  SignedValue, MinimumSigned: Int64;
  FloatValue: Double;
  SingleValue: Single;
  Settings: TFormatSettings;
  Index: Cardinal;
begin
  SetLength(ABytes, 0);
  AAlignment := 0;
  if AValueType = 'byte' then Width := 1
  else if AValueType = 'word' then Width := 2
  // integer and bool occupy four bytes like dword: integer is a signed dword
  // and bool is a 32 bit flag. Both are declared value types in the field model
  // and in the write command schema, so refusing them here made every write to
  // such a field fail with invalid_scan_value (FR-041).
  else if (AValueType = 'dword') or (AValueType = 'single') or
          (AValueType = 'integer') or (AValueType = 'bool') then Width := 4
  else if (AValueType = 'qword') or (AValueType = 'double') then Width := 8
  else Exit(InvalidValue);

  if AValueType = 'bool' then
  begin
    if SameText(AText, 'true') or (AText = '1') then
      Bits := 1
    else if SameText(AText, 'false') or (AText = '0') then
      Bits := 0
    else
      Exit(InvalidValue);
  end
  else if (AValueType = 'single') or (AValueType = 'double') then
  begin
    Settings := DefaultFormatSettings;
    Settings.DecimalSeparator := '.';
    if (not TryStrToFloat(AText, FloatValue, Settings)) or
      IsNan(FloatValue) or IsInfinite(FloatValue) then
      Exit(InvalidValue);
    if AValueType = 'single' then
    begin
      SingleValue := FloatValue;
      if IsNan(SingleValue) or IsInfinite(SingleValue) then
        Exit(InvalidValue);
      Bits := 0;
      Move(SingleValue, Bits, SizeOf(SingleValue));
    end
    else
      Move(FloatValue, Bits, SizeOf(FloatValue));
  end
  else
  begin
    if not DecimalInteger(AText) then Exit(InvalidValue);
    if AText[1] = '-' then
    begin
      if not TryStrToInt64(AText, SignedValue) then Exit(InvalidValue);
      if Width = 8 then MinimumSigned := Low(Int64)
      else MinimumSigned := -(Int64(1) shl (Width * 8 - 1));
      if SignedValue < MinimumSigned then Exit(InvalidValue);
      Bits := QWord(SignedValue);
    end
    else
    begin
      if not TryStrToQWord(AText, Bits) then Exit(InvalidValue);
      if Width = 8 then MaximumUnsigned := High(QWord)
      else MaximumUnsigned := (QWord(1) shl (Width * 8)) - 1;
      if Bits > MaximumUnsigned then Exit(InvalidValue);
    end;
  end;

  SetLength(ABytes, Width);
  for Index := 0 to Width - 1 do
    ABytes[Index] := Byte((Bits shr (Index * 8)) and $FF);
  AAlignment := Width;
  Result := TCEAResult.Ok('{}');
end;

end.

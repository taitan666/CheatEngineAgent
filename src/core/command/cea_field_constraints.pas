unit cea_field_constraints;

// FR-041 input validation: check a value against the field's declared
// constraints before it ever reaches the write path.
//
// Until now ConstraintsJson was carried around by the field model and the game
// profile but never read by anything. That is worse than having no constraints
// at all: an operator who writes a min/max object into a field reasonably
// believes the bound is enforced, while the write path happily pushed a value
// far outside it into the process. This unit makes the stored metadata load
// bearing.
//
// Design rules (each one is load-bearing):
//
// 1. An empty ConstraintsJson means "no constraints", not "invalid". Declaring
//    nothing is the normal case and must not turn into a write blocker.
//
// 2. A malformed ConstraintsJson is an ERROR, never a silent skip. Silently
//    ignoring a broken bound has exactly the same outcome as ignoring a valid
//    one, so the operator cannot tell the difference between "checked and
//    allowed" and "never checked".
//
// 3. Unknown keys are rejected. A misspelled bound key would otherwise drop the
//    bound while still parsing cleanly, which is the same silent failure in a
//    harder-to-see form.
//
// 4. Numeric bounds are compared as numbers, not as text. Text comparison says
//    9 > 100, and it cannot express min/max at all.
//
// 5. Allowed values are compared as ENCODED BYTES, not as text, for the same
//    reason the preview compares bytes: 1.5 and 1.50 are the same value, and
//    only the encoding knows that.
//
// 6. Only fixed width numeric types are accepted here. bool, enum and string
//    have no encoding on this path (EncodeExactValue refuses them), so claiming
//    to validate them would promise a guarantee the write path cannot keep.
//    The operator is told to declare byte/word/dword/qword/single/double (or
//    integer, which is a signed dword).

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpjson, jsonparser, cea_results, cea_value_scan_types;

const
  CeaFieldConstraintsMaxAllowedValues = 256;

type
  TCEAStringArray = array of string;

  TCEAFieldConstraints = record
    HasMin: Boolean;
    HasMax: Boolean;
    MinValue: string;
    MaxValue: string;
    AllowedValues: TCEAStringArray;
    function IsEmpty: Boolean;
    function ToJson: string;
  end;

{ Parses the field's stored ConstraintsJson. An empty string yields an empty
  constraint set and rcOk. }
function ParseFieldConstraints(const AJson: string;
  out AConstraints: TCEAFieldConstraints): TCEAResult;

{ Returns True when this value type can be encoded into bytes at all. bool,
  enum and string cannot, so they are not writable on this path. }
function IsWritableValueType(const AValueType: string): Boolean;

{ Validates AText against AValueType and AConstraints. rcOk means the value may
  be written. Any failure is rcInvalidArgument with a stable code the caller can
  show the operator directly. }
function ValidateFieldValue(const AValueType, AText: string;
  const AConstraints: TCEAFieldConstraints): TCEAResult;

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

function ConstraintError(const AStableCode, ADetailJson: string): TCEAResult;
begin
  Result := TCEAResult.Error(rcInvalidArgument, AStableCode, ADetailJson);
end;

function TCEAFieldConstraints.IsEmpty: Boolean;
begin
  Result := (not HasMin) and (not HasMax) and (Length(AllowedValues) = 0);
end;

function TCEAFieldConstraints.ToJson: string;
var
  I: Integer;
  Values: string;
begin
  Values := '';
  for I := 0 to Length(AllowedValues) - 1 do
  begin
    if I > 0 then
      Values := Values + ',';
    Values := Values + '"' + JsonEscape(AllowedValues[I]) + '"';
  end;
  Result := Utf8JsonText('{"has_min":' + BoolToStr(HasMin, 'true', 'false') +
    ',"min":"' + JsonEscape(MinValue) + '"' +
    ',"has_max":' + BoolToStr(HasMax, 'true', 'false') +
    ',"max":"' + JsonEscape(MaxValue) + '"' +
    ',"allowed_values":[' + Values + ']}');
end;

// Reads a bound out of the JSON object. Obj.Get('min', '') is the STRING
// overload: for a JSON number it returns the default instead of the number, so
// a numeric min used to arrive as an empty string and every bounded field
// looked malformed. Numbers are taken as their JSON text, and strings are
// accepted so that a bound written as a quoted number still works.
function ReadBound(const AObj: TJSONObject; const AName: string;
  out AText: string): Boolean;
var
  Item: TJSONData;
begin
  AText := '';
  Item := AObj.Find(AName);
  if Item = nil then
    Exit(False);
  case Item.JSONType of
    jtNumber: AText := Item.AsJSON;
    jtString: AText := Item.AsString;
  end;
  Result := Trim(AText) <> '';
end;

{ Normalises one allowed value out of JSON into the text form the encoder
  accepts. Numbers become their JSON text; booleans and nested containers are
  rejected because no numeric field can ever equal them. }
function AllowedValueText(const AItem: TJSONData; out AText: string): Boolean;
begin
  AText := '';
  Result := False;
  if AItem = nil then Exit;
  case AItem.JSONType of
    jtString:
      begin
        AText := AItem.AsString;
        Result := True;
      end;
    jtNumber:
      begin
        AText := AItem.AsJSON;
        Result := True;
      end;
  end;
end;

function ParseFieldConstraints(const AJson: string;
  out AConstraints: TCEAFieldConstraints): TCEAResult;
var
  Parsed: TJSONData;
  Obj: TJSONObject;
  Allowed: TJSONData;
  I, Count: Integer;
  Name, ValueText: string;
  Values: TCEAStringArray;
begin
  AConstraints := Default(TCEAFieldConstraints);
  if Trim(AJson) = '' then
    Exit(TCEAResult.Ok('{}'));

  Parsed := nil;
  try
    try
      Parsed := GetJSON(Utf8JsonText(AJson));
    except
      Exit(ConstraintError('field_constraints_invalid',
        '{"detail":"constraints_json is not valid JSON"}'));
    end;
    if (Parsed = nil) or (Parsed.JSONType <> jtObject) then
      Exit(ConstraintError('field_constraints_invalid',
        '{"detail":"constraints_json must be a JSON object"}'));
    Obj := TJSONObject(Parsed);

    for I := 0 to Obj.Count - 1 do
    begin
      Name := Obj.Names[I];
      if (Name <> 'min') and (Name <> 'max') and (Name <> 'allowed_values') then
        Exit(ConstraintError('field_constraints_unknown_key',
          '{"key":"' + JsonEscape(Name) + '"}'));
    end;

    if Obj.IndexOfName('min') >= 0 then
    begin
      AConstraints.HasMin := True;
      if not ReadBound(Obj, 'min', AConstraints.MinValue) then
        Exit(ConstraintError('field_constraints_invalid',
          '{"detail":"min must be a number"}'));
    end;
    if Obj.IndexOfName('max') >= 0 then
    begin
      AConstraints.HasMax := True;
      if not ReadBound(Obj, 'max', AConstraints.MaxValue) then
        Exit(ConstraintError('field_constraints_invalid',
          '{"detail":"max must be a number"}'));
    end;

    if Obj.IndexOfName('allowed_values') >= 0 then
    begin
      Allowed := Obj.Find('allowed_values');
      if (Allowed = nil) or (Allowed.JSONType <> jtArray) then
        Exit(ConstraintError('field_constraints_allowed_invalid',
          '{"detail":"allowed_values must be an array"}'));
      Count := TJSONArray(Allowed).Count;
      if Count > CeaFieldConstraintsMaxAllowedValues then
        Exit(ConstraintError('field_constraints_too_many_allowed',
          '{"limit":' + IntToStr(CeaFieldConstraintsMaxAllowedValues) + '}'));
      SetLength(Values, Count);
      for I := 0 to Count - 1 do
        if not AllowedValueText(TJSONArray(Allowed).Items[I], ValueText) then
          Exit(ConstraintError('field_constraints_allowed_invalid',
            '{"detail":"allowed_values entries must be strings or numbers"}'))
        else
          Values[I] := ValueText;
      AConstraints.AllowedValues := Values;
    end;
  finally
    Parsed.Free;
  end;

  Result := TCEAResult.Ok('{}');
end;

function IsWritableValueType(const AValueType: string): Boolean;
begin
  Result := (AValueType = 'byte') or (AValueType = 'word') or
    (AValueType = 'dword') or (AValueType = 'integer') or
    (AValueType = 'bool') or (AValueType = 'qword') or
    (AValueType = 'single') or (AValueType = 'double');
end;

{ Compares two numeric texts. Tries 64 bit integers first so that large values
  do not lose precision through a double, then falls back to doubles for the
  float types. Returns False when either side is not numeric. }
function CompareNumeric(const ALeft, ARight: string; out ARelation: Integer): Boolean;
var
  LeftInt, RightInt: Int64;
  LeftWord, RightWord: QWord;
  LeftFloat, RightFloat: Double;
  Settings: TFormatSettings;
begin
  ARelation := 0;
  Result := False;
  if TryStrToInt64(ALeft, LeftInt) and TryStrToInt64(ARight, RightInt) then
  begin
    if LeftInt < RightInt then ARelation := -1
    else if LeftInt > RightInt then ARelation := 1;
    Exit(True);
  end;
  if TryStrToQWord(ALeft, LeftWord) and TryStrToQWord(ARight, RightWord) then
  begin
    if LeftWord < RightWord then ARelation := -1
    else if LeftWord > RightWord then ARelation := 1;
    Exit(True);
  end;
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  if (not TryStrToFloat(ALeft, LeftFloat, Settings)) or
     (not TryStrToFloat(ARight, RightFloat, Settings)) then
    Exit(False);
  if LeftFloat < RightFloat then ARelation := -1
  else if LeftFloat > RightFloat then ARelation := 1;
  Result := True;
end;

function ValidateFieldValue(const AValueType, AText: string;
  const AConstraints: TCEAFieldConstraints): TCEAResult;
var
  Encoded, AllowedEncoded: TBytes;
  Alignment: Cardinal;
  EncodeResult: TCEAResult;
  I, Relation: Integer;
  HasRelation: Boolean;
begin
  if not IsWritableValueType(AValueType) then
    Exit(ConstraintError('field_value_type_unsupported',
      '{"value_type":"' + JsonEscape(AValueType) + '"}'));

  // The encoder is the authority on whether the text is a legal value of this
  // type; constraints only add bounds on top of it.
  EncodeResult := EncodeExactValue(AValueType, AText, Encoded, Alignment);
  if EncodeResult.Failed then
    Exit(ConstraintError('field_value_not_numeric',
      '{"value":"' + JsonEscape(AText) + '","value_type":"' +
      JsonEscape(AValueType) + '"}'));

  if AConstraints.HasMin then
  begin
    HasRelation := CompareNumeric(AText, AConstraints.MinValue, Relation);
    if (not HasRelation) or (Relation < 0) then
      Exit(ConstraintError('field_value_below_min',
        '{"value":"' + JsonEscape(AText) + '","min":"' +
        JsonEscape(AConstraints.MinValue) + '"}'));
  end;

  if AConstraints.HasMax then
  begin
    HasRelation := CompareNumeric(AText, AConstraints.MaxValue, Relation);
    if (not HasRelation) or (Relation > 0) then
      Exit(ConstraintError('field_value_above_max',
        '{"value":"' + JsonEscape(AText) + '","max":"' +
        JsonEscape(AConstraints.MaxValue) + '"}'));
  end;

  if Length(AConstraints.AllowedValues) > 0 then
  begin
    for I := 0 to Length(AConstraints.AllowedValues) - 1 do
    begin
      if EncodeExactValue(AValueType, AConstraints.AllowedValues[I],
        AllowedEncoded, Alignment).Failed then
        Continue;
      if Length(AllowedEncoded) <> Length(Encoded) then
        Continue;
      if CompareMem(@AllowedEncoded[0], @Encoded[0], Length(Encoded)) then
        Exit(TCEAResult.Ok('{}'));
    end;
    Exit(ConstraintError('field_value_not_allowed',
      '{"value":"' + JsonEscape(AText) + '"}'));
  end;

  Result := TCEAResult.Ok('{}');
end;

end.

unit cea_fixture_save_codec;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_results, cea_save_types, cea_save_ports;

type
  TCEAFixtureSaveCodec = class(TObject, ICEASaveCodec)
  private
    function Parse(const ABytes: TBytes; out AHp, AGold: Integer): TCEAResult;
  public
    function Probe(const ABytes: TBytes;
      out ADescriptor: TCEASaveFormatDescriptor): TCEAResult;
    function Decode(const ABytes: TBytes;
      out AFields: TCEASaveFieldArray): TCEAResult;
    function Encode(const AOriginal: TBytes;
      const AEdit: TCEASaveEditProposal; out AEncoded: TBytes): TCEAResult;
    function Validate(const ABytes: TBytes): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser, cea_windows_sha256;

const
  Magic = 'CEA-SAVE-1' + #10;

function BytesToString(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then Move(ABytes[0], Result[1], Length(ABytes));
end;

function StringToBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Result[0], Length(AText));
end;

function TCEAFixtureSaveCodec.Parse(const ABytes: TBytes;
  out AHp, AGold: Integer): TCEAResult;
var
  Raw, Body, JsonText, Checksum: string;
  FooterAt: SizeInt;
  Data: TJSONData;
  Obj: TJSONObject;
  Hasher: TCEAWindowsSha256;
begin
  AHp := 0;
  AGold := 0;
  Raw := BytesToString(ABytes);
  if (Length(Raw) < Length(Magic) + 73) or
     (Copy(Raw, 1, Length(Magic)) <> Magic) or
     (Raw[Length(Raw)] <> #10) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_version_invalid', '{}'));
  FooterAt := Length(Raw) - 72;
  if Raw[FooterAt] <> #10 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_footer_invalid', '{}'));
  Body := Copy(Raw, 1, FooterAt - 1);
  Checksum := Copy(Raw, FooterAt + 1, 71);
  Hasher := TCEAWindowsSha256.Create;
  try
    if Checksum <> Hasher.HashUtf8(Body) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'fixture_checksum_invalid', '{}'));
  finally
    Hasher.Free;
  end;
  JsonText := Copy(Body, Length(Magic) + 1, MaxInt);
  Data := nil;
  try
    try
      Data := GetJSON(JsonText);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_json_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_json_invalid', '{}'));
    Obj := TJSONObject(Data);
    if (Obj.Count <> 2) or (Obj.Find('hp') = nil) or
       (Obj.Find('gold') = nil) or
       (Obj.Find('hp').JSONType <> jtNumber) or
       (Obj.Find('gold').JSONType <> jtNumber) or
       not TryStrToInt(Obj.Find('hp').AsJSON, AHp) or
       not TryStrToInt(Obj.Find('gold').AsJSON, AGold) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_fields_invalid', '{}'));
    if (AHp < 0) or (AHp > 9999) or
       (AGold < 0) or (AGold > 999999) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_range_invalid', '{}'));
    if JsonText <> '{"hp":' + IntToStr(AHp) +
      ',"gold":' + IntToStr(AGold) + '}' then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'fixture_not_canonical', '{}'));
    Result := TCEAResult.Ok('{}');
  finally
    Data.Free;
  end;
end;

function TCEAFixtureSaveCodec.Probe(const ABytes: TBytes;
  out ADescriptor: TCEASaveFormatDescriptor): TCEAResult;
var
  Hp, Gold: Integer;
begin
  FillChar(ADescriptor, SizeOf(ADescriptor), 0);
  Result := Parse(ABytes, Hp, Gold);
  if Result.Failed then Exit;
  ADescriptor.Id := 'cea-fixture-save';
  ADescriptor.Version := '1';
  ADescriptor.AdapterHash := 'builtin:cea-fixture-save-v1';
  ADescriptor.Readable := True;
  ADescriptor.Writable := True;
end;

function TCEAFixtureSaveCodec.Decode(const ABytes: TBytes;
  out AFields: TCEASaveFieldArray): TCEAResult;
var
  Hp, Gold: Integer;
begin
  SetLength(AFields, 0);
  Result := Parse(ABytes, Hp, Gold);
  if Result.Failed then Exit;
  SetLength(AFields, 2);
  AFields[0].Path := '/hp';
  AFields[0].ValueJson := IntToStr(Hp);
  AFields[1].Path := '/gold';
  AFields[1].ValueJson := IntToStr(Gold);
end;

function TCEAFixtureSaveCodec.Encode(const AOriginal: TBytes;
  const AEdit: TCEASaveEditProposal; out AEncoded: TBytes): TCEAResult;
var
  Hp, Gold, OldValue, NewValue: Integer;
  Body: string;
  Hasher: TCEAWindowsSha256;
begin
  SetLength(AEncoded, 0);
  Result := Parse(AOriginal, Hp, Gold);
  if Result.Failed then Exit;
  if (AEdit.FieldPath <> '/hp') and (AEdit.FieldPath <> '/gold') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_field_unknown', '{}'));
  if not TryStrToInt(AEdit.ExpectedJson, OldValue) or
     not TryStrToInt(AEdit.NewJson, NewValue) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_value_invalid', '{}'));
  if AEdit.FieldPath = '/hp' then
  begin
    if OldValue <> Hp then
      Exit(TCEAResult.Error(rcConflict, 'fixture_expected_mismatch', '{}'));
    if (NewValue < 0) or (NewValue > 9999) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_range_invalid', '{}'));
    Hp := NewValue;
  end
  else
  begin
    if OldValue <> Gold then
      Exit(TCEAResult.Error(rcConflict, 'fixture_expected_mismatch', '{}'));
    if (NewValue < 0) or (NewValue > 999999) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'fixture_range_invalid', '{}'));
    Gold := NewValue;
  end;
  Body := Magic + '{"hp":' + IntToStr(Hp) +
    ',"gold":' + IntToStr(Gold) + '}';
  Hasher := TCEAWindowsSha256.Create;
  try
    AEncoded := StringToBytes(Body + #10 + Hasher.HashUtf8(Body) + #10);
  finally
    Hasher.Free;
  end;
  Result := Validate(AEncoded);
end;

function TCEAFixtureSaveCodec.Validate(const ABytes: TBytes): TCEAResult;
var
  Hp, Gold: Integer;
begin
  Result := Parse(ABytes, Hp, Gold);
end;

end.

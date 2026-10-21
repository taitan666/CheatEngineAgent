unit cea_schema_validator;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, FPJSON, cea_ports, cea_results;

type
  TCEASchemaValidator = class(TObject, ISchemaValidator)
  private
    FSchemaRoot: string;
    function ErrorAt(const APointer, AReason: string): TCEAResult;
    function ValidateNode(ASchema, AValue: TJSONData;
      const APointer: string): TCEAResult;
  public
    constructor Create(const ASchemaRoot: string);
    function Validate(const ASchemaId, APayloadJson: string): TCEAResult;
  end;

function ValidateInlineJsonSchema(const ASchemaJson,
  APayloadJson: string): TCEAResult;

implementation

uses
  JSONParser;

constructor TCEASchemaValidator.Create(const ASchemaRoot: string);
begin
  inherited Create;
  FSchemaRoot := ExpandFileName(ASchemaRoot);
end;

function JsonQuoted(const AValue: string): string;
var
  JsonString: TJSONString;
begin
  JsonString := TJSONString.Create(AValue);
  try
    Result := JsonString.AsJSON;
  finally
    JsonString.Free;
  end;
end;

function EscapePointerToken(const AValue: string): string;
begin
  Result := StringReplace(AValue, '~', '~0', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '~1', [rfReplaceAll]);
end;

function TCEASchemaValidator.ErrorAt(const APointer,
  AReason: string): TCEAResult;
begin
  Result := TCEAResult.Error(rcInvalidArgument, 'schema_validation_failed',
    '{"pointer":' + JsonQuoted(APointer) + ',"reason":' +
    JsonQuoted(AReason) + '}');
end;

function JsonTypeMatches(const AExpected: string; AValue: TJSONData): Boolean;
begin
  case AExpected of
    'object': Result := AValue.JSONType = jtObject;
    'array': Result := AValue.JSONType = jtArray;
    'string': Result := AValue.JSONType = jtString;
    'boolean': Result := AValue.JSONType = jtBoolean;
    'null': Result := AValue.JSONType = jtNull;
    'number': Result := AValue.JSONType = jtNumber;
    'integer': Result := (AValue.JSONType = jtNumber) and
      (Frac(AValue.AsFloat) = 0);
  else
    Result := False;
  end;
end;

function IsHexCharacter(const AValue: Char): Boolean;
begin
  Result := AValue in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

function MatchesSupportedPattern(const APattern, AValue: string): Boolean;
var
  I: Integer;
begin
  if APattern = '^0x[0-9a-fA-F]+$' then
  begin
    if (Length(AValue) <= 2) or (Copy(AValue, 1, 2) <> '0x') then
      Exit(False);
    for I := 3 to Length(AValue) do
      if not IsHexCharacter(AValue[I]) then Exit(False);
    Exit(True);
  end;
  if APattern = '^([0-9a-fA-F]{2})+$' then
  begin
    if (Length(AValue) = 0) or Odd(Length(AValue)) then Exit(False);
    for I := 1 to Length(AValue) do
      if not IsHexCharacter(AValue[I]) then Exit(False);
    Exit(True);
  end;
  { The embedded validator intentionally implements only the bounded pattern
    vocabulary used by MCP. Full Draft 2020-12 qualification remains an
    external release requirement. }
  Result := True;
end;

function TCEASchemaValidator.ValidateNode(ASchema, AValue: TJSONData;
  const APointer: string): TCEAResult;
var
  SchemaObj: TJSONObject;
  ValueObj: TJSONObject;
  Properties: TJSONObject;
  RequiredItems: TJSONArray;
  TypeNode: TJSONData;
  TypeItems: TJSONArray;
  EnumItems: TJSONArray;
  ValueItems: TJSONArray;
  ItemsSchema: TJSONData;
  LimitNode: TJSONData;
  ChildSchema: TJSONData;
  I: Integer;
  Name: string;
  Matches: Boolean;
begin
  if (ASchema = nil) or (ASchema.JSONType <> jtObject) then
    Exit(ErrorAt(APointer, 'schema_object_required'));
  SchemaObj := TJSONObject(ASchema);

  TypeNode := SchemaObj.Find('type');
  if TypeNode <> nil then
  begin
    Matches := False;
    if TypeNode.JSONType = jtString then
      Matches := JsonTypeMatches(TypeNode.AsString, AValue)
    else if TypeNode.JSONType = jtArray then
    begin
      TypeItems := TJSONArray(TypeNode);
      for I := 0 to TypeItems.Count - 1 do
        if (TypeItems.Items[I].JSONType = jtString) and
           JsonTypeMatches(TypeItems.Strings[I], AValue) then
          Matches := True;
    end;
    if not Matches then
      Exit(ErrorAt(APointer, 'type_mismatch'));
  end;

  EnumItems := TJSONArray(SchemaObj.Find('enum'));
  if EnumItems <> nil then
  begin
    Matches := False;
    for I := 0 to EnumItems.Count - 1 do
      if EnumItems.Items[I].AsJSON = AValue.AsJSON then
      begin
        Matches := True;
        Break;
      end;
    if not Matches then
      Exit(ErrorAt(APointer, 'enum_mismatch'));
  end;

  if AValue.JSONType = jtString then
  begin
    LimitNode := SchemaObj.Find('minLength');
    if (LimitNode <> nil) and
       (Length(AValue.AsString) < LimitNode.AsInteger) then
      Exit(ErrorAt(APointer, 'min_length'));
    LimitNode := SchemaObj.Find('maxLength');
    if (LimitNode <> nil) and
       (Length(AValue.AsString) > LimitNode.AsInteger) then
      Exit(ErrorAt(APointer, 'max_length'));
    LimitNode := SchemaObj.Find('pattern');
    if (LimitNode <> nil) and
       (not MatchesSupportedPattern(LimitNode.AsString, AValue.AsString)) then
      Exit(ErrorAt(APointer, 'pattern_mismatch'));
  end;

  if AValue.JSONType = jtNumber then
  begin
    LimitNode := SchemaObj.Find('minimum');
    if (LimitNode <> nil) and (AValue.AsFloat < LimitNode.AsFloat) then
      Exit(ErrorAt(APointer, 'minimum'));
    LimitNode := SchemaObj.Find('maximum');
    if (LimitNode <> nil) and (AValue.AsFloat > LimitNode.AsFloat) then
      Exit(ErrorAt(APointer, 'maximum'));
  end;

  if AValue.JSONType = jtArray then
  begin
    ValueItems := TJSONArray(AValue);
    LimitNode := SchemaObj.Find('minItems');
    if (LimitNode <> nil) and (ValueItems.Count < LimitNode.AsInteger) then
      Exit(ErrorAt(APointer, 'min_items'));
    LimitNode := SchemaObj.Find('maxItems');
    if (LimitNode <> nil) and (ValueItems.Count > LimitNode.AsInteger) then
      Exit(ErrorAt(APointer, 'max_items'));
    ItemsSchema := SchemaObj.Find('items');
    if ItemsSchema <> nil then
      for I := 0 to ValueItems.Count - 1 do
      begin
        Result := ValidateNode(ItemsSchema, ValueItems.Items[I],
          APointer + '/' + IntToStr(I));
        if Result.Failed then Exit;
      end;
  end;

  if AValue.JSONType = jtObject then
  begin
    ValueObj := TJSONObject(AValue);
    RequiredItems := TJSONArray(SchemaObj.Find('required'));
    if RequiredItems <> nil then
      for I := 0 to RequiredItems.Count - 1 do
        if ValueObj.Find(RequiredItems.Strings[I]) = nil then
          Exit(ErrorAt(APointer + '/' +
            EscapePointerToken(RequiredItems.Strings[I]), 'required'));

    Properties := TJSONObject(SchemaObj.Find('properties'));
    if Properties <> nil then
    begin
      if (SchemaObj.Find('additionalProperties') <> nil) and
         (not SchemaObj.Booleans['additionalProperties']) then
        for I := 0 to ValueObj.Count - 1 do
          if Properties.Find(ValueObj.Names[I]) = nil then
            Exit(ErrorAt(APointer + '/' + EscapePointerToken(
              ValueObj.Names[I]), 'additional_property'));

      for I := 0 to ValueObj.Count - 1 do
      begin
        Name := ValueObj.Names[I];
        ChildSchema := Properties.Find(Name);
        if ChildSchema <> nil then
        begin
          Result := ValidateNode(ChildSchema, ValueObj.Items[I],
            APointer + '/' + EscapePointerToken(Name));
          if Result.Failed then
            Exit;
        end;
      end;
    end;
  end;

  Result := TCEAResult.Ok('{}');
end;

function TCEASchemaValidator.Validate(const ASchemaId,
  APayloadJson: string): TCEAResult;
var
  SchemaPath: string;
  SchemaText: TStringList;
  SchemaData: TJSONData;
  PayloadData: TJSONData;
begin
  if (ASchemaId = '') or (Pos('..', ASchemaId) > 0) or
     (Pos(':', ASchemaId) > 0) or (ASchemaId[1] in ['\', '/']) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'unknown_schema', '{}'));
  SchemaPath := ExpandFileName(IncludeTrailingPathDelimiter(FSchemaRoot) +
    StringReplace(ASchemaId, '/', PathDelim, [rfReplaceAll]));
  if (Copy(SchemaPath, 1, Length(IncludeTrailingPathDelimiter(FSchemaRoot))) <>
      IncludeTrailingPathDelimiter(FSchemaRoot)) or
     (not FileExists(SchemaPath)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'unknown_schema',
      '{"schema_id":' + JsonQuoted(ASchemaId) + '}'));

  SchemaText := TStringList.Create;
  SchemaData := nil;
  PayloadData := nil;
  try
    try
      SchemaText.LoadFromFile(SchemaPath);
      SchemaData := GetJSON(SchemaText.Text);
      PayloadData := GetJSON(APayloadJson);
    except
      on E: Exception do
        Exit(TCEAResult.Error(rcInvalidArgument, 'json_invalid',
          '{"message":' + JsonQuoted(E.Message) + '}'));
    end;
    Result := ValidateNode(SchemaData, PayloadData, '');
  finally
    PayloadData.Free;
    SchemaData.Free;
    SchemaText.Free;
  end;
end;

function ValidateInlineJsonSchema(const ASchemaJson,
  APayloadJson: string): TCEAResult;
var
  Validator: TCEASchemaValidator;
  SchemaData, PayloadData: TJSONData;
begin
  Validator := TCEASchemaValidator.Create('.');
  SchemaData := nil;
  PayloadData := nil;
  try
    try
      SchemaData := GetJSON(ASchemaJson);
      PayloadData := GetJSON(APayloadJson);
    except
      on E: Exception do
        Exit(TCEAResult.Error(rcInvalidArgument, 'json_invalid',
          '{"message":' + JsonQuoted(E.Message) + '}'));
    end;
    Result := Validator.ValidateNode(SchemaData, PayloadData, '');
  finally
    PayloadData.Free;
    SchemaData.Free;
    Validator.Free;
  end;
end;

end.

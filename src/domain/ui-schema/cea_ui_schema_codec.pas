unit cea_ui_schema_codec;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_ui_schema_types;

type
  // UI Schema 编解码：TCEAUiSchema ↔ 受控 JSON（白名单组件），
  // 只序列化/校验已知组件类型，拒绝未知 kind / 未知字段。
  TCEAUiSchemaCodec = class
  public
    // 序列化 UI Schema 为 JSON 字符串
    function Encode(const ASchema: TCEAUiSchema;
      out AJson: string): TCEAResult;
    // 解析 JSON 为 UI Schema（白名单校验 + 舍去未知字段）
    function Decode(const AJson: string;
      out ASchema: TCEAUiSchema): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]);
end;

function TCEAUiSchemaCodec.Encode(const ASchema: TCEAUiSchema;
  out AJson: string): TCEAResult;
var
  I, J: Integer;
  Comps, Sections: string;
begin
  AJson := '';
  if not ASchema.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_invalid', '{}'));
  Sections := '';
  for I := 0 to High(ASchema.Sections) do
  begin
    if not ASchema.Sections[I].IsValid then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_section_invalid', '{}'));
    Comps := '';
    for J := 0 to High(ASchema.Sections[I].Components) do
    begin
      if not ASchema.Sections[I].Components[J].IsValid then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'ui_component_invalid', '{}'));
      if J > 0 then Comps := Comps + ',';
      Comps := Comps +
        '{"id":"' + JsonEscape(ASchema.Sections[I].Components[J].Id) +
        '","kind":"' + UiComponentKindText(ASchema.Sections[I].Components[J].Kind) +
        '","title":"' + JsonEscape(ASchema.Sections[I].Components[J].Title) +
        '","field_id":"' + JsonEscape(ASchema.Sections[I].Components[J].FieldId) +
        '","access":"' + UiComponentAccessText(ASchema.Sections[I].Components[J].Access) +
        '","options_json":"' + JsonEscape(ASchema.Sections[I].Components[J].OptionsJson) +
        '"}';
    end;
    if I > 0 then Sections := Sections + ',';
    Sections := Sections +
      '{"id":"' + JsonEscape(ASchema.Sections[I].Id) +
      '","title":"' + JsonEscape(ASchema.Sections[I].Title) +
      '","components":[' + Comps + ']}';
  end;
  AJson := '{"id":"' + JsonEscape(ASchema.Id) +
    '","page_title":"' + JsonEscape(ASchema.PageTitle) +
    '","sections":[' + Sections + ']}';
  Result := TCEAResult.Ok('{}');
end;

function TCEAUiSchemaCodec.Decode(const AJson: string;
  out ASchema: TCEAUiSchema): TCEAResult;
var
  Data, Item: TJSONData;
  Obj, CompObj: TJSONObject;
  SecArr, CompArr: TJSONArray;
  I, J: Integer;
  KindText, AccessText: string;
begin
  FillChar(ASchema, SizeOf(ASchema), 0);
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_json_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_object_required', '{}'));
    Obj := TJSONObject(Data);
    ASchema.Id := Obj.Get('id', '');
    ASchema.PageTitle := Obj.Get('page_title', '');
    Item := Obj.Find('sections');
    if (Item = nil) or (Item.JSONType <> jtArray) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_sections_required', '{}'));
    SecArr := TJSONArray(Item);
    SetLength(ASchema.Sections, SecArr.Count);
    for I := 0 to SecArr.Count - 1 do
    begin
      if SecArr.Items[I].JSONType <> jtObject then
        Exit(TCEAResult.Error(rcInvalidArgument, 'ui_section_object_required', '{}'));
      ASchema.Sections[I].Id := TJSONObject(SecArr.Items[I]).Get('id', '');
      ASchema.Sections[I].Title := TJSONObject(SecArr.Items[I]).Get('title', '');
      Item := TJSONObject(SecArr.Items[I]).Find('components');
      if (Item = nil) or (Item.JSONType <> jtArray) then
        Exit(TCEAResult.Error(rcInvalidArgument, 'ui_section_components_required', '{}'));
      CompArr := TJSONArray(Item);
      SetLength(ASchema.Sections[I].Components, CompArr.Count);
      for J := 0 to CompArr.Count - 1 do
      begin
        if CompArr.Items[J].JSONType <> jtObject then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'ui_component_object_required', '{}'));
        CompObj := TJSONObject(CompArr.Items[J]);
        KindText := CompObj.Get('kind', '');
        AccessText := CompObj.Get('access', '');
        // 白名单校验：未识别的组件类型直接拒绝
        if not TryParseUiComponentKind(KindText,
          ASchema.Sections[I].Components[J].Kind) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'ui_component_kind_not_whitelisted',
            '{"kind":"' + JsonEscape(KindText) + '"}'));
        if not TryParseUiComponentAccess(AccessText,
          ASchema.Sections[I].Components[J].Access) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'ui_component_access_invalid', '{}'));
        ASchema.Sections[I].Components[J].Id := CompObj.Get('id', '');
        ASchema.Sections[I].Components[J].Title := CompObj.Get('title', '');
        ASchema.Sections[I].Components[J].FieldId := CompObj.Get('field_id', '');
        ASchema.Sections[I].Components[J].OptionsJson := CompObj.Get('options_json', '');
      end;
    end;
    if not ASchema.IsValid then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_invalid', '{}'));
    Result := TCEAResult.Ok('{}');
  finally
    Data.Free;
  end;
end;

end.
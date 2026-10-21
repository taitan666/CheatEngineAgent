program test_ui_schema_codec;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_ui_schema_types, cea_ui_schema_codec;

var
  Codec: TCEAUiSchemaCodec;
  Schema, Decoded: TCEAUiSchema;
  Json: string;
  R: TCEAResult;

begin
  Codec := TCEAUiSchemaCodec.Create;
  try
    // 构造一个合法 schema
    FillChar(Schema, SizeOf(Schema), 0);
    Schema.Id := 'page-overview';
    Schema.PageTitle := '角色概览';
    SetLength(Schema.Sections, 1);
    Schema.Sections[0].Id := 'sec-stats';
    Schema.Sections[0].Title := '属性';
    SetLength(Schema.Sections[0].Components, 2);
    Schema.Sections[0].Components[0].Id := 'comp-geo';
    Schema.Sections[0].Components[0].Kind := ucValueCard;
    Schema.Sections[0].Components[0].Title := 'Geo';
    Schema.Sections[0].Components[0].FieldId := 'player.geo';
    Schema.Sections[0].Components[0].Access := uaEditable;
    Schema.Sections[0].Components[1].Id := 'comp-title';
    Schema.Sections[0].Components[1].Kind := ucText;
    Schema.Sections[0].Components[1].Title := '状态正常';
    Schema.Sections[0].Components[1].Access := uaReadOnly;

    // 序列化
    R := Codec.Encode(Schema, Json);
    Assert(R.Code = rcOk, 'encode ok: ' + R.StableCode);
    Assert(Pos('value_card', Json) > 0, 'encode contains kind');
    Assert(Pos('player.geo', Json) > 0, 'encode contains field_id');

    // 反序列化（往返）
    R := Codec.Decode(Json, Decoded);
    Assert(R.Code = rcOk, 'decode ok: ' + R.StableCode);
    Assert(Decoded.Id = 'page-overview', 'id roundtrip');
    Assert(Decoded.Sections[0].Components[0].Kind = ucValueCard, 'kind roundtrip');
    Assert(Decoded.Sections[0].Components[0].FieldId = 'player.geo', 'field roundtrip');
    Assert(Decoded.Sections[0].Components[0].Access = uaEditable, 'access roundtrip');

    // 白名单校验：未知 kind 拒绝
    R := Codec.Decode(
      '{"id":"p","page_title":"t","sections":[{"id":"s","title":"x",' +
      '"components":[{"id":"c","kind":"custom_widget","title":"y","access":"read_only"}]}]}',
      Decoded);
    Assert(R.Code = rcInvalidArgument, 'unknown kind rejected');
    Assert(R.StableCode = 'ui_component_kind_not_whitelisted',
      'whitelist stable code');

    // 非法 access 拒绝
    R := Codec.Decode(
      '{"id":"p","page_title":"t","sections":[{"id":"s","title":"x",' +
      '"components":[{"id":"c","kind":"text","title":"y","access":"admin"}]}]}',
      Decoded);
    Assert(R.Code = rcInvalidArgument, 'unknown access rejected');

    WriteLn('UI_SCHEMA_CODEC=PASS');
  finally
    Codec.Free;
  end;
end.
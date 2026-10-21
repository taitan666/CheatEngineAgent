program test_phase1_e2e;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_ui_schema_types, cea_ui_schema_codec, cea_ui_schema_builder,
  cea_profile_types, cea_profile_ports, cea_profile_store,
  cea_profile_service;

var
  DirPath, DbPath: string;
  Store: TCEAProfileStore;
  ProfileService: TCEAProfileService;
  Builder: TCEAUiSchemaBuilder;
  Codec: TCEAUiSchemaCodec;
  Model: TCEAGameStateModel;
  Field: TCEAGameField;
  Schema, DecodedSchema: TCEAUiSchema;
  SchemaJson: string;
  Profile: TCEAGameProfile;
  Loaded: TCEAGameProfile;
  Match: TCEAProfileMatchResult;
  R: TCEAResult;
  ExeA, ModA: string;

begin
  ExeA := 'sha256:' + StringOfChar('a', 64);
  ModA := 'sha256:' + StringOfChar('b', 64);

  DirPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-e2e-test-' + IntToStr(GetProcessID);
  ForceDirectories(DirPath);
  DbPath := IncludeTrailingPathDelimiter(DirPath) + 'e2e.sqlite3';

  Store := TCEAProfileStore.Create(DbPath);
  ProfileService := TCEAProfileService.Create(Store);
  Builder := TCEAUiSchemaBuilder.Create;
  Codec := TCEAUiSchemaCodec.Create;
  try
    R := Store.Initialize;
    Assert(R.Code = rcOk, 'store init');

    // 1. 字段模型（模拟已识别的字段）
    Model := TCEAGameStateModel.Create('Hollow Knight', '1.5', ExeA, ModA);
    try
      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := 'player.geo';
      Field.DisplayName := 'Geo';
      Field.ValueType := 'dword';
      Field.Source := 'win32_memory';
      Field.Confidence := 1.0;
      Field.Access := faVerifiedWritable;
      Field.ValidationStatus := vsVerified;
      Field.LastUpdated := '2026-10-19T20:00:00Z';
      Field.AddressHex := '0x12345678';
      Assert(Model.AddField(Field), 'add geo');

      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := 'player.stamina';
      Field.DisplayName := 'Stamina';
      Field.ValueType := 'single';
      Field.Source := 'win32_memory';
      Field.Confidence := 0.9;
      Field.Access := faReadOnly;
      Field.ValidationStatus := vsObserved;
      Field.LastUpdated := '2026-10-19T20:00:00Z';
      Field.AddressHex := '0x12340000';
      Assert(Model.AddField(Field), 'add stamina');

      // 2. Builder 生成 UI Schema
      R := Builder.BuildFromModel(Model, '角色概览', Schema);
      Assert(R.Code = rcOk, 'build schema: ' + R.StableCode);

      // 3. Codec 序列化
      R := Codec.Encode(Schema, SchemaJson);
      Assert(R.Code = rcOk, 'encode schema: ' + R.StableCode);

      // 4. Profile 保存（带 UI Schema JSON）
      R := ProfileService.SaveFromModel(Model, 'win32_memory', SchemaJson,
        '{"evidence":"scan"}' , Profile);
      Assert(R.Code = rcOk, 'save profile: ' + R.StableCode);

      // 5. Profile 加载 + 兼容性检测
      R := ProfileService.LoadForGame('Hollow Knight', ExeA, ModA,
        Loaded, Match);
      Assert(R.Code = rcOk, 'load profile');
      Assert(Match.Compatible, 'profile compatible');
      Assert(Loaded.UiSchemaJson = SchemaJson, 'ui schema persisted');

      // 6. 从 Profile 的 UiSchemaJson 反序列化回 UI Schema
      R := Codec.Decode(Loaded.UiSchemaJson, DecodedSchema);
      Assert(R.Code = rcOk, 'decode persisted schema');
      Assert(DecodedSchema.PageTitle = '角色概览', 'page title roundtrip');
      Assert(Length(DecodedSchema.Sections[0].Components) = 2, '2 components');

      WriteLn('PHASE1_E2E=PASS');
    finally
      Model.Free;
    end;
  finally
    Codec.Free;
    Builder.Free;
    ProfileService.Free;
    Store.Free;
    DeleteFile(DbPath);
    RemoveDir(DirPath);
  end;
end.
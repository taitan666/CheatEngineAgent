program test_ui_schema_runtime;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  SysUtils, FPJSON, JSONParser, cea_results, cea_field_model,
  cea_game_state_model, cea_ui_schema_types, cea_ui_layout_types,
  cea_ui_schema_runtime, cea_ui_layout_store, cea_win32_display_enumerator;

var
  Model: TCEAGameStateModel;
  Schema: TCEAUiSchema;
  Field: TCEAGameField;
  Runtime: TCEAUiSchemaRuntime;
  Render, Reordered: TCEAUiRenderModel;
  Layout: TCEAUiLayoutState;
  R: TCEAResult;
  Json: string;
  ExeA, ModA: string;
  Store: TCEAUiLayoutStore;
  DirPath, DbPath: string;
  Placement, LoadedPlacement: TCEASecondaryWindowPlacement;
  LoadedLayout: TCEAUiLayoutState;
  Displays: TCEADisplayInfoArray;
  Enumerator: TCEAWin32DisplayEnumerator;
  Info: TCEADisplayInfo;
  Primary: TCEADisplayInfo;
  RenderData: TJSONData;
  RenderObj, SectionObj, GeoObj, StaminaObj, MissObj: TJSONObject;
  SectionsData, CompsData: TJSONData;
  I: Integer;
  EditableGeo, ReadOnlyGeo, MissingComp: Integer;

  procedure AddField(const AId, AName, ATypeName: string;
    const AAccess: TCEAFieldAccess; const AConfidence: Double;
    const AValue: string);
  var
    F: TCEAGameField;
  begin
    FillChar(F, SizeOf(F), 0);
    F.FieldId := AId;
    F.DisplayName := AName;
    F.ValueType := ATypeName;
    F.ValueJson := AValue;
    F.Source := 'win32_memory';
    F.Confidence := AConfidence;
    F.Access := AAccess;
    F.ValidationStatus := vsObserved;
    F.LastUpdated := '2026-10-20T12:00:00Z';
    Assert(Model.AddField(F), 'add field ' + AId);
  end;

  procedure MakeComponent(out AComponent: TCEAUiComponent;
    const AId: string; const AKind: TCEAUiComponentKind;
    const ATitle, AFieldId: string;
    const AAccess: TCEAUiComponentAccess);
  begin
    AComponent.Id := AId;
    AComponent.Kind := AKind;
    AComponent.Title := ATitle;
    AComponent.FieldId := AFieldId;
    AComponent.Access := AAccess;
    AComponent.OptionsJson := '';
  end;

begin
  ExeA := 'sha256:' + StringOfChar('a', 64);
  ModA := 'sha256:' + StringOfChar('b', 64);

  Model := TCEAGameStateModel.Create('HollowKnight', '1.5', ExeA, ModA);
  Runtime := TCEAUiSchemaRuntime.Create;
  try
    // player.geo 已验证可写；stamina 只读；invincible 待验证。
    AddField('player.geo', 'Geo', 'dword', faVerifiedWritable, 1.0, '123');
    AddField('player.stamina', 'Stamina', 'single', faReadOnly, 1.0, '95.5');
    AddField('player.invincible', 'Invincible', 'bool', faPendingWrite, 0.5,
      'false');

    // 状态模型自身拒绝非法字段记录（Confidence 越界），
    // 因此模型内的字段永远合法；此处确认该保证成立。
    FillChar(Field, SizeOf(Field), 0);
    Field.FieldId := 'player.broken';
    Field.DisplayName := 'Broken';
    Field.ValueType := 'dword';
    Field.Source := 'win32_memory';
    Field.Confidence := 2.0;
    Field.LastUpdated := '2026-10-20T12:00:00Z';
    Assert(not Model.AddField(Field), 'invalid field rejected by model');
    Assert(Model.FieldCount = 3, 'model holds three valid fields');

    Schema.Id := 'ui-HollowKnight';
    Schema.PageTitle := 'Hollow Knight Console';
    SetLength(Schema.Sections, 1);
    Schema.Sections[0].Id := 'sec-overview';
    Schema.Sections[0].Title := 'Overview';
    SetLength(Schema.Sections[0].Components, 6);
    MakeComponent(Schema.Sections[0].Components[0], 'comp-geo', ucValueCard,
      'Geo', 'player.geo', uaEditable);
    MakeComponent(Schema.Sections[0].Components[1], 'comp-stamina', ucValueCard,
      'Stamina', 'player.stamina', uaEditable);
    MakeComponent(Schema.Sections[0].Components[2], 'comp-invincible', ucToggle,
      'Invincible', 'player.invincible', uaEditable);
    MakeComponent(Schema.Sections[0].Components[3], 'comp-geo-ro', ucValueCard,
      'Geo (read only)', 'player.geo', uaReadOnly);
    MakeComponent(Schema.Sections[0].Components[4], 'comp-missing',
      ucValueCard, 'Missing', 'player.missing', uaReadOnly);
    MakeComponent(Schema.Sections[0].Components[5], 'comp-note', ucText,
      'Notes', '', uaReadOnly);

    Assert(Schema.IsValid, 'schema valid');

    // 绑定：只有 verified_writable 且组件声明 editable 才可编辑
    R := Runtime.Bind(Schema, Model, 1700000000000, Render);
    Assert(R.Code = rcOk, 'bind: ' + R.StableCode);
    Assert(Render.IsValid, 'render model valid');
    Assert(Render.SchemaId = 'ui-HollowKnight', 'schema id');
    Assert(Render.ComponentCount = 6, 'component count 6');
    Assert(Render.EditableCount = 1, 'exactly one editable');
    Assert(Render.MissingCount = 1, 'one missing field');

    EditableGeo := -1;
    ReadOnlyGeo := -1;
    MissingComp := -1;
    for I := 0 to High(Render.Sections[0].Components) do
    begin
      if Render.Sections[0].Components[I].ComponentId = 'comp-geo' then
        EditableGeo := I;
      if Render.Sections[0].Components[I].ComponentId = 'comp-geo-ro' then
        ReadOnlyGeo := I;
      if Render.Sections[0].Components[I].ComponentId = 'comp-missing' then
        MissingComp := I;
    end;
    Assert(EditableGeo >= 0, 'geo component present');
    Assert(ReadOnlyGeo >= 0, 'geo read only component present');
    Assert(MissingComp >= 0, 'missing component present');

    // 已验证可写 + 声明可编辑 -> 可编辑
    Assert(Render.Sections[0].Components[EditableGeo].Editable,
      'verified writable is editable');
    Assert(Render.Sections[0].Components[EditableGeo].Semantic =
      ufsVerifiedWritable, 'geo semantic verified_writable');
    Assert(Render.Sections[0].Components[EditableGeo].FieldValueJson = '123',
      'geo value bound');

    // 只读字段即使组件声明 editable 也不得渲染编辑控件（FR-022 / AC-005）
    Assert(not Render.Sections[0].Components[1].Editable,
      'read only field not editable');
    Assert(Render.Sections[0].Components[1].DisabledReason =
      'field_not_verified_writable', 'read only reason');
    Assert(Render.Sections[0].Components[1].Semantic = ufsReadOnly,
      'stamina semantic read_only');

    // 待验证字段同样不可写
    Assert(not Render.Sections[0].Components[2].Editable,
      'pending write field not editable');
    Assert(Render.Sections[0].Components[2].Semantic = ufsPendingWrite,
      'invincible semantic pending_write');

    // 组件自身声明只读 -> 不可编辑，原因是组件级
    Assert(not Render.Sections[0].Components[ReadOnlyGeo].Editable,
      'read only component not editable');
    Assert(Render.Sections[0].Components[ReadOnlyGeo].DisabledReason =
      'component_read_only', 'component read only reason');

    // 字段缺失
    Assert(Render.Sections[0].Components[MissingComp].Binding =
      ubsFieldMissing, 'missing binding field_missing');
    Assert(Render.Sections[0].Components[MissingComp].DisabledReason =
      'field_not_in_state_model', 'missing disabled reason');
    Assert(Render.Sections[0].Components[MissingComp].FieldValueJson = '',
      'missing field has no value');

    // 静态文本不绑定字段
    Assert(Render.Sections[0].Components[5].Binding = ubsNotBound,
      'text not bound');
    Assert(Render.Sections[0].Components[5].Semantic = ufsUnknown,
      'text semantic unknown');

    // JSON 渲染输出（用解析器断言，不依赖序列化空白格式）
    Json := Runtime.RenderToJson(Render);
    RenderData := GetJSON(Json);
    try
      Assert(RenderData.JSONType = jtObject, 'render json is object');
      RenderObj := TJSONObject(RenderData);
      Assert(RenderObj.Get('schema_id', '') = 'ui-HollowKnight',
        'json schema id');
      Assert(RenderObj.Get('page_title', '') = 'Hollow Knight Console',
        'json page title');
      Assert(RenderObj.Get('component_count', 0) = 6, 'json component_count');
      Assert(RenderObj.Get('editable_count', 0) = 1, 'json editable_count');
      Assert(RenderObj.Get('missing_count', 0) = 1, 'json missing_count');
      Assert(RenderObj.Get('generated_at_ms', Int64(0)) = Int64(1700000000000),
        'json generated_at_ms');
      SectionsData := RenderObj.Find('sections');
      Assert((SectionsData <> nil) and (SectionsData.JSONType = jtArray),
        'json sections array');
      Assert(TJSONArray(SectionsData).Count = 1, 'json one section');
      SectionObj := TJSONObject(TJSONArray(SectionsData).Items[0]);
      Assert(SectionObj.Get('section_id', '') = 'sec-overview',
        'json section id');
      CompsData := SectionObj.Find('components');
      Assert((CompsData <> nil) and (CompsData.JSONType = jtArray),
        'json components array');
      Assert(TJSONArray(CompsData).Count = 6, 'json six components');
      GeoObj := TJSONObject(TJSONArray(CompsData).Items[0]);
      Assert(GeoObj.Get('component_id', '') = 'comp-geo', 'json first comp id');
      Assert(GeoObj.Get('semantic', '') = 'verified_writable',
        'json semantic token');
      Assert(GeoObj.Get('editable', False), 'json geo editable');
      Assert(GeoObj.Get('disabled_reason', '') = '', 'json geo no disabled');
      Assert(GeoObj.Get('binding', '') = 'bound', 'json geo bound');
      Assert(GeoObj.Get('field_value_json', '') = '123', 'json geo value');
      StaminaObj := TJSONObject(TJSONArray(CompsData).Items[1]);
      Assert(StaminaObj.Get('semantic', '') = 'read_only',
        'json stamina read_only');
      Assert(not StaminaObj.Get('editable', True), 'json stamina not editable');
      Assert(StaminaObj.Get('disabled_reason', '') = 'field_not_verified_writable',
        'json stamina reason');
      MissObj := TJSONObject(TJSONArray(CompsData).Items[4]);
      Assert(MissObj.Get('binding', '') = 'field_missing',
        'json missing binding');
    finally
      RenderData.Free;
    end;

    // 布局记忆：把 comp-note 提到最前并隐藏 comp-stamina
    Layout.SchemaId := 'ui-HollowKnight';
    Layout.UpdatedAt := '2026-10-20T12:00:00Z';
    SetLength(Layout.Components, 2);
    Layout.Components[0].ComponentId := 'comp-note';
    Layout.Components[0].Order := 0;
    Layout.Components[0].Hidden := False;
    Layout.Components[0].Width := 320;
    Layout.Components[0].Height := 48;
    Layout.Components[1].ComponentId := 'comp-stamina';
    Layout.Components[1].Order := 1;
    Layout.Components[1].Hidden := True;
    Layout.Components[1].Width := 0;
    Layout.Components[1].Height := 0;
    Assert(Layout.IsValid, 'layout valid');

    R := Runtime.ApplyLayout(Render, Layout, Reordered);
    Assert(R.Code = rcOk, 'apply layout: ' + R.StableCode);
    Assert(Reordered.ComponentCount = 5, 'hidden component removed');
    Assert(Reordered.EditableCount = 1, 'editable count preserved');
    Assert(Reordered.MissingCount = 1, 'missing count preserved');
    Assert(Reordered.Sections[0].Components[0].ComponentId = 'comp-note',
      'note moved first');
    Assert(Reordered.Sections[0].Components[1].ComponentId = 'comp-geo',
      'geo follows');
    Assert(Render.ComponentCount = 6, 'original render untouched');

    // 布局属于别的 schema -> 拒绝
    Layout.SchemaId := 'ui-Other';
    R := Runtime.ApplyLayout(Render, Layout, Reordered);
    Assert(R.Code = rcInvalidArgument, 'layout schema mismatch rejected');
    Assert(R.StableCode = 'ui_layout_schema_mismatch', 'mismatch code');
    Layout.SchemaId := 'ui-HollowKnight';

    // 静态文本不得声明可编辑
    Schema.Sections[0].Components[5].Access := uaEditable;
    R := Runtime.Bind(Schema, Model, 0, Render);
    Assert(R.Code = rcInvalidArgument, 'editable text rejected');
    Assert(R.StableCode = 'text_component_not_editable', 'editable text code');
    Schema.Sections[0].Components[5].Access := uaReadOnly;

    // 可编辑的非文本组件若没有绑定字段，会在组件校验层被拒绝
    // （组件 IsValid 要求非 ucText 组件必须有 FieldId），
    // 因此不可能走到 BindComponent 的字段缺失分支。
    Assert(Schema.IsValid, 'schema record itself only checks id and sections');
    Schema.Sections[0].Components[0].FieldId := '';
    Assert(not Schema.Sections[0].Components[0].IsValid,
      'non text component requires field id');
    R := Runtime.Bind(Schema, Model, 0, Render);
    Assert(R.Code = rcInvalidArgument, 'schema without field id rejected');
    Assert(R.StableCode = 'ui_component_invalid', 'component invalid code');
    Schema.Sections[0].Components[0].FieldId := 'player.geo';

    WriteLn('UI_SCHEMA_RUNTIME=PASS');
  finally
    Runtime.Free;
    Model.Free;
  end;

  // 布局与窗口位置的持久化
  DirPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-uilayout-test-' + IntToStr(GetProcessID);
  ForceDirectories(DirPath);
  DbPath := IncludeTrailingPathDelimiter(DirPath) + 'ui-layout.sqlite3';
  Store := TCEAUiLayoutStore.Create(DbPath);
  try
    R := Store.Initialize;
    Assert(R.Code = rcOk, 'layout store initializes');

    Layout.SchemaId := 'ui-HollowKnight';
    Layout.UpdatedAt := '2026-10-20T12:00:00Z';
    SetLength(Layout.Components, 1);
    Layout.Components[0].ComponentId := 'comp-geo';
    Layout.Components[0].Order := 0;
    Layout.Components[0].Hidden := False;
    Layout.Components[0].Width := 240;
    Layout.Components[0].Height := 64;

    R := Store.SaveLayout(Layout);
    Assert(R.Code = rcOk, 'save layout: ' + R.StableCode);

    R := Store.LoadLayout('ui-HollowKnight', LoadedLayout);
    Assert(R.Code = rcOk, 'load layout: ' + R.StableCode);
    Assert(LoadedLayout.SchemaId = 'ui-HollowKnight', 'layout schema roundtrip');
    Assert(Length(LoadedLayout.Components) = 1, 'layout component roundtrip');
    Assert(LoadedLayout.Components[0].ComponentId = 'comp-geo',
      'layout component id roundtrip');
    Assert(LoadedLayout.Components[0].Width = 240, 'layout width roundtrip');
    Assert(not LoadedLayout.Components[0].Hidden, 'layout hidden roundtrip');

    R := Store.LoadLayout('ui-Missing', LoadedLayout);
    Assert(R.Code = rcUnknown, 'missing layout reported');
    Assert(R.StableCode = 'ui_layout_not_found', 'missing layout code');

    Placement.SchemaId := 'ui-HollowKnight';
    Placement.DisplayId := '\\.\DISPLAY2';
    Placement.Left := 1920;
    Placement.Top := 0;
    Placement.Width := 1280;
    Placement.Height := 720;
    Placement.Maximized := False;
    Placement.ScalePercent := 100;
    Assert(Placement.IsValid, 'placement valid');

    R := Store.SavePlacement(Placement);
    Assert(R.Code = rcOk, 'save placement: ' + R.StableCode);

    R := Store.LoadPlacement('ui-HollowKnight', LoadedPlacement);
    Assert(R.Code = rcOk, 'load placement: ' + R.StableCode);
    Assert(LoadedPlacement.DisplayId = '\\.\DISPLAY2', 'display id roundtrip');
    Assert(LoadedPlacement.Left = 1920, 'placement left roundtrip');
    Assert(LoadedPlacement.Width = 1280, 'placement width roundtrip');
    Assert(not LoadedPlacement.Maximized, 'placement maximized roundtrip');
    Assert(LoadedPlacement.ScalePercent = 100, 'placement scale roundtrip');

    // 位置合法性：缩放越界必须被拒绝
    Placement.ScalePercent := 10;
    Assert(not Placement.IsValid, 'scale out of range invalid');
    Placement.ScalePercent := 100;

    R := Store.DeleteLayout('ui-HollowKnight');
    Assert(R.Code = rcOk, 'delete layout');
    R := Store.LoadLayout('ui-HollowKnight', LoadedLayout);
    Assert(R.StableCode = 'ui_layout_not_found', 'layout deleted');

    WriteLn('UI_LAYOUT_STORE=PASS');
  finally
    Store.Free;
    DeleteFile(DbPath);
    RemoveDir(DirPath);
  end;

  // 显示器枚举（真实 Windows API）
  Enumerator := TCEAWin32DisplayEnumerator.Create;
  try
    R := Enumerator.EnumerateDisplays(Displays);
    Assert(R.Code = rcOk, 'enumerate displays: ' + R.StableCode);
    Assert(Length(Displays) >= 1, 'at least one display');
    Assert(FindPrimaryDisplay(Displays, Primary), 'primary display found');
    Assert(Primary.IsValid, 'primary display valid');
    Assert(Primary.Width > 0, 'primary width positive');
    Assert(DisplayContainsPoint(Primary, Primary.Left + 1, Primary.Top + 1),
      'point inside primary');
    Assert(FindDisplay(Displays, Primary.DisplayId, Info), 'find by display id');
    Assert(Info.DisplayId = Primary.DisplayId, 'found display matches');

    // 窗口位置跨屏判定
    Placement.DisplayId := Primary.DisplayId;
    Placement.Left := Primary.Left + 10;
    Placement.Top := Primary.Top + 10;
    Placement.Width := 640;
    Placement.Height := 480;
    Placement.Maximized := False;
    Placement.ScalePercent := 100;
    Assert(PlacementIntersectsAnyDisplay(Placement, Displays),
      'placement intersects a display');

    Placement.Left := Primary.Left - 100000;
    Placement.Top := Primary.Top - 100000;
    Assert(not PlacementIntersectsAnyDisplay(Placement, Displays),
      'far away placement does not intersect');

    WriteLn('DISPLAY_ENUMERATOR=PASS displays=' + IntToStr(Length(Displays)));
  finally
    Enumerator.Free;
  end;
end.

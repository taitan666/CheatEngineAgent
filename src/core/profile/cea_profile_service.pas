unit cea_profile_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_profile_types, cea_profile_ports,
  cea_field_model, cea_game_state_model;

type
  // Game Profile 服务：保存/加载字段模型 + UI Schema，加载前兼容性检测 + 失效降级
  TCEAProfileService = class
  private
    FStore: ICEAProfileStore;
    function BuildProfileId(const AGameName, AExecutableSha256: string): string;
  public
    constructor Create(const AStore: ICEAProfileStore);
    // 从 Game State Model 保存 Profile
    function SaveFromModel(const AModel: TCEAGameStateModel;
      const AConnectorType, AUiSchemaJson, AEvidenceJson: string;
      out AProfile: TCEAGameProfile): TCEAResult;
    // 加载 Profile 并做兼容性检测（版本指纹匹配）
    function LoadForGame(const AGameName, AExecutableSha256,
      AModuleSetHash: string; out AProfile: TCEAGameProfile;
      out AMatch: TCEAProfileMatchResult): TCEAResult;
    // 版本不匹配时降级：返回 profile 但标记失效
    function Invalidate(const AProfileId, AReason: string): TCEAResult;
    // 把 Profile 里的字段集合还原进一个状态模型（FR-055 配置复用）。
    // 还原出来的字段一律是 faReadOnly：Profile 只能证明「这个字段存在过」，
    // 不能证明「这个地址现在还能写」——可写必须重新走一遍写-重读验证。
    function RestoreInto(const AProfile: TCEAGameProfile;
      const AModel: TCEAGameStateModel; out ARestored: Integer): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

// JSON 布尔只有小写 true/false；BoolToStr 会给出 Pascal 风格的 True/False，
// 那是非法 JSON，上游解析器会静默把整个对象吞掉。
function BoolToJson(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

constructor TCEAProfileService.Create(const AStore: ICEAProfileStore);
begin
  inherited Create;
  FStore := AStore;
end;

function TCEAProfileService.BuildProfileId(const AGameName,
  AExecutableSha256: string): string;
begin
  // 简单稳定 ID：游戏名 + exe 哈希（Phase 1 简化，后续可换内容哈希）
  Result := 'profile:' + AGameName + ':' + Copy(AExecutableSha256, 1, 16);
end;

function TCEAProfileService.SaveFromModel(const AModel: TCEAGameStateModel;
  const AConnectorType, AUiSchemaJson, AEvidenceJson: string;
  out AProfile: TCEAGameProfile): TCEAResult;
var
  Fp: TCEAGameVersionFingerprint;
  Fields: TCEAGameFieldArray;
  FieldsJson: string;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
  NowIso: string;
begin
  FillChar(AProfile, SizeOf(AProfile), 0);
  if AModel = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_required', '{}'));
  Fp := AModel.Fingerprint;
  if not Fp.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_fingerprint_invalid', '{}'));

  // 序列化字段集合
  Fields := AModel.GetFields;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Fields) do
    begin
      O := TJSONObject.Create;
      O.Add('field_id', Fields[I].FieldId);
      O.Add('display_name', Fields[I].DisplayName);
      O.Add('value_type', Fields[I].ValueType);
      O.Add('source', Fields[I].Source);
      O.Add('access', FieldAccessText(Fields[I].Access));
      O.Add('validation_status', ValidationStatusText(Fields[I].ValidationStatus));
      O.Add('address_hex', Fields[I].AddressHex);
      // 指针链配方必须一起存：只存 address_hex 的话，游戏重启后地址作废，
      // Profile 就变成一堆读不出来的数字（FR-056 重验证也无从谈起）。
      O.Add('module_name', Fields[I].ModuleName);
      O.Add('pointer_offsets_json', Fields[I].PointerOffsetsJson);
      O.Add('address_width_bits', IntToStr(Fields[I].AddressWidthBits));
      O.Add('confidence', FloatToStr(Fields[I].Confidence));
      O.Add('constraints_json', Fields[I].ConstraintsJson);
      O.Add('evidence_refs_json', Fields[I].EvidenceRefsJson);
      Arr.Add(O);
    end;
    FieldsJson := Arr.AsJSON;
  finally
    Arr.Free;
  end;

  NowIso := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  AProfile.Id := BuildProfileId(Fp.GameName, Fp.ExecutableSha256);
  AProfile.GameName := Fp.GameName;
  AProfile.GameVersion := Fp.GameVersion;
  AProfile.ExecutableSha256 := Fp.ExecutableSha256;
  AProfile.ModuleSetHash := Fp.ModuleSetHash;
  AProfile.ConnectorType := AConnectorType;
  AProfile.FieldsJson := FieldsJson;
  AProfile.UiSchemaJson := AUiSchemaJson;
  AProfile.EvidenceJson := AEvidenceJson;
  AProfile.CreatedAt := NowIso;
  AProfile.UpdatedAt := NowIso;
  AProfile.LastVerifiedAt := NowIso;
  AProfile.InvalidationReason := '';
  Result := FStore.SaveProfile(AProfile);
end;

function TCEAProfileService.LoadForGame(const AGameName, AExecutableSha256,
  AModuleSetHash: string; out AProfile: TCEAGameProfile;
  out AMatch: TCEAProfileMatchResult): TCEAResult;
var
  Profiles: TCEAGameProfileArray;
  I: Integer;
begin
  FillChar(AProfile, SizeOf(AProfile), 0);
  FillChar(AMatch, SizeOf(AMatch), 0);
  AMatch.Compatible := False;
  if AGameName = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'game_name_required', '{}'));
  Result := FStore.ListProfiles(AGameName, Profiles);
  if Result.Failed then Exit;
  // 找版本匹配的 profile
  for I := 0 to High(Profiles) do
    if (AExecutableSha256 <> '') and
       (Profiles[I].ExecutableSha256 = AExecutableSha256) then
    begin
      AProfile := Profiles[I];
      if (Profiles[I].ModuleSetHash <> '') and (AModuleSetHash <> '') and
         (Profiles[I].ModuleSetHash <> AModuleSetHash) then
      begin
        AMatch.Compatible := False;
        AMatch.Reason := 'module_set_changed';
      end
      else
      begin
        AMatch.Compatible := True;
        AMatch.Reason := '';
      end;
      Exit(TCEAResult.Ok('{"compatible":' +
        BoolToJson(AMatch.Compatible) + '}'));
    end;
  // 有 profile 但版本不匹配
  if Length(Profiles) > 0 then
  begin
    AProfile := Profiles[0];
    AMatch.Compatible := False;
    AMatch.Reason := 'version_mismatch';
    Exit(TCEAResult.Ok('{"compatible":false,"reason":"version_mismatch"}'));
  end;
  Result := TCEAResult.Error(rcInvalidArgument, 'profile_not_found',
    '{"game":"' + AGameName + '"}');
end;

function TCEAProfileService.Invalidate(const AProfileId,
  AReason: string): TCEAResult;
var
  P: TCEAGameProfile;
begin
  Result := FStore.LoadProfile(AProfileId, P);
  if Result.Failed then Exit;
  P.InvalidationReason := AReason;
  P.UpdatedAt := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  Result := FStore.SaveProfile(P);
end;

function TCEAProfileService.RestoreInto(const AProfile: TCEAGameProfile;
  const AModel: TCEAGameStateModel; out ARestored: Integer): TCEAResult;
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I, Skipped: Integer;
  Field: TCEAGameField;
  NowIso: string;
begin
  ARestored := 0;
  Skipped := 0;
  if AModel = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_required', '{}'));
  if AProfile.Id = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_required', '{}'));
  if Trim(AProfile.FieldsJson) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_has_no_fields',
      '{"profile_id":"' + AProfile.Id + '"}'));

  Data := nil;
  try
    try
      Data := GetJSON(AProfile.FieldsJson);
    except
      Data := nil;
    end;
    if not (Data is TJSONArray) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'profile_fields_invalid',
        '{"profile_id":"' + AProfile.Id + '"}'));
    Arr := TJSONArray(Data);
    NowIso := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I] is TJSONObject) then
      begin
        Inc(Skipped);
        Continue;
      end;
      Obj := TJSONObject(Arr.Items[I]);
      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := Obj.Get('field_id', '');
      Field.DisplayName := Obj.Get('display_name', '');
      Field.ValueType := Obj.Get('value_type', '');
      Field.Source := Obj.Get('source', '');
      Field.AddressHex := Obj.Get('address_hex', '');
      Field.ModuleName := Obj.Get('module_name', '');
      Field.PointerOffsetsJson := Obj.Get('pointer_offsets_json', '');
      Field.AddressWidthBits := Cardinal(StrToIntDef(
        Obj.Get('address_width_bits', '0'), 0));
      Field.Confidence := StrToFloatDef(Obj.Get('confidence', '0'), 0);
      if Field.Confidence < 0 then Field.Confidence := 0;
      if Field.Confidence > 1 then Field.Confidence := 1;
      Field.ConstraintsJson := Obj.Get('constraints_json', '');
      Field.EvidenceRefsJson := Obj.Get('evidence_refs_json', '');
      Field.LastUpdated := NowIso;
      // Profile 里存的 access / validation_status 只作历史证据，不能直接采信：
      // 上一轮会话的可写证明对新进程无效（地址与指针链都可能已变）。
      // 因此还原出来的字段一律 read_only + observed，重验证必须由用户重新触发。
      Field.Access := faReadOnly;
      Field.ValidationStatus := vsObserved;
      // 同理不还原 value_json：那是上一轮进程里的瞬时值，当成当前值展示会误导。
      Field.ValueJson := '';
      if not Field.IsValid then
      begin
        Inc(Skipped);
        Continue;
      end;
      if not AModel.UpdateField(Field) then
        AModel.AddField(Field);
      Inc(ARestored);
    end;
  finally
    Data.Free;
  end;
  Result := TCEAResult.Ok('{"profile_id":"' + AProfile.Id +
    '","restored":' + IntToStr(ARestored) +
    ',"skipped":' + IntToStr(Skipped) + '}');
end;

end.

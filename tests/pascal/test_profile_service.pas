program test_profile_service;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_profile_types, cea_profile_ports, cea_profile_store,
  cea_profile_service;

var
  DirPath, DbPath: string;
  Store: TCEAProfileStore;
  Service: TCEAProfileService;
  Model: TCEAGameStateModel;
  Field: TCEAGameField;
  Profile: TCEAGameProfile;
  Loaded: TCEAGameProfile;
  Match: TCEAProfileMatchResult;
  Profiles: TCEAGameProfileArray;
  R: TCEAResult;
  ExeA, ExeB, ModA: string;
  Restored: TCEAGameStateModel;
  RestoredCount: Integer;
  Back: TCEAGameField;

begin
  ExeA := 'sha256:' + StringOfChar('a', 64);
  ExeB := 'sha256:' + StringOfChar('b', 64);
  ModA := 'sha256:' + StringOfChar('c', 64);

  DirPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-profile-test-' + IntToStr(GetProcessID);
  ForceDirectories(DirPath);
  DbPath := IncludeTrailingPathDelimiter(DirPath) + 'profiles.sqlite3';

  Store := TCEAProfileStore.Create(DbPath);
  Service := TCEAProfileService.Create(Store);
  try
    R := Store.Initialize;
    Assert(R.Code = rcOk, 'profile store initializes');

    // 构造 Game State Model（模拟「已验证的金币字段」）
    Model := TCEAGameStateModel.Create('Hollow Knight', '1.5', ExeA, ModA);
    try
      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := 'player.geo';
      Field.DisplayName := 'Geo 金币';
      Field.ValueType := 'dword';
      Field.Source := 'win32_memory';
      Field.Confidence := 1.0;
      Field.Access := faVerifiedWritable;
      Field.ValidationStatus := vsVerified;
      Field.LastUpdated := '2026-10-19T20:00:00Z';
      Field.AddressHex := '0x12345678';
      Assert(Model.AddField(Field), 'add field');

      // 保存 Profile
      R := Service.SaveFromModel(Model, 'win32_memory', '{"page":"overview"}',
        '{"evidence":"scan"}' , Profile);
      Assert(R.Code = rcOk, 'save profile: ' + R.StableCode);
      Assert(Profile.Id <> '', 'profile has id');

      // 加载 + 版本匹配
      R := Service.LoadForGame('Hollow Knight', ExeA, ModA, Loaded, Match);
      Assert(R.Code = rcOk, 'load profile');
      Assert(Match.Compatible, 'version matches');
      Assert(Loaded.FieldsJson <> '', 'fields persisted');
      Assert(Pos('player.geo', Loaded.FieldsJson) > 0, 'field serialized');

      // 版本不匹配（exe 哈希变了）→ 降级
      R := Service.LoadForGame('Hollow Knight', ExeB, ModA, Loaded, Match);
      Assert(R.Code = rcOk, 'load with mismatched version');
      Assert(not Match.Compatible, 'version mismatch detected');
      Assert(Match.Reason = 'version_mismatch', 'mismatch reason');

      // module 集变化 → 降级
      R := Service.LoadForGame('Hollow Knight', ExeA,
        'sha256:' + StringOfChar('d', 64), Loaded, Match);
      Assert(R.Code = rcOk, 'load with changed module set');
      Assert(not Match.Compatible, 'module set change detected');
      Assert(Match.Reason = 'module_set_changed', 'module reason');

      // 列表
      R := Store.ListProfiles('Hollow Knight', Profiles);
      Assert(R.Code = rcOk, 'list profiles');
      Assert(Length(Profiles) = 1, 'one profile listed');

      // 失效标记
      R := Service.Invalidate(Profile.Id, 'game_updated');
      Assert(R.Code = rcOk, 'invalidate profile');
      R := Store.LoadProfile(Profile.Id, Loaded);
      Assert(Loaded.InvalidationReason = 'game_updated', 'invalidation persisted');

      // 指针链配方必须随 Profile 落盘：只存 address_hex 的话，
      // 游戏重启后 Profile 就只是一堆读不出来的旧地址。
      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := 'player.soul';
      Field.DisplayName := 'Soul';
      Field.ValueType := 'dword';
      Field.Source := 'win32_memory';
      Field.Confidence := 1.0;
      Field.LastUpdated := '2026-10-19T20:00:00Z';
      Field.ModuleName := 'hollow_knight.exe';
      Field.PointerOffsetsJson := '{"base":"0x1A8","offsets":["10","8"]}';
      Field.AddressWidthBits := 64;
      Assert(Model.UpdateField(Field) or Model.AddField(Field), 'add chain field');
      R := Service.SaveFromModel(Model, 'win32_memory', '', '', Profile);
      Assert(R.Code = rcOk, 'save profile with chain: ' + R.StableCode);
      R := Store.LoadProfile(Profile.Id, Loaded);
      Assert(Pos('hollow_knight.exe', Loaded.FieldsJson) > 0,
        'module name persisted: ' + Loaded.FieldsJson);
      Assert(Pos('pointer_offsets_json', Loaded.FieldsJson) > 0,
        'pointer offsets persisted');

      // 还原：可写性与当前值都不能从 Profile 继承
      Restored := TCEAGameStateModel.Create('Hollow Knight', '1.5', ExeA, ModA);
      try
        R := Service.RestoreInto(Loaded, Restored, RestoredCount);
        Assert(R.Code = rcOk, 'restore into model: ' + R.StableCode);
        Assert(RestoredCount = 2, 'two fields restored: ' + IntToStr(RestoredCount));
        Assert(Restored.GetField('player.soul', Back), 'chain field restored');
        Assert(Back.ModuleName = 'hollow_knight.exe', 'chain module restored');
        Assert(Back.AddressWidthBits = 64, 'address width restored');
        Assert(Back.Access = faReadOnly, 'restored field is read only');
        Assert(Back.ValidationStatus = vsObserved, 'restored status is observed');
        Assert(Back.ValueJson = '', 'stale value not inherited');
      finally
        Restored.Free;
      end;

      WriteLn('PROFILE_SERVICE=PASS');
    finally
      Model.Free;
    end;
  finally
    Service.Free;
    Store.Free;
    DeleteFile(DbPath);
    RemoveDir(DirPath);
  end;
end.

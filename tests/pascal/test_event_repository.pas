program test_event_repository;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_event_types, cea_event_service,
  cea_event_repository;

var
  DbPath: string;
  Repo: TCEAEventRepository;
  Service: TCEAEventService;
  Config: TCEAEventServiceConfig;
  Rule: TCEAFieldChangeRule;
  R: TCEAResult;
  Event: TCEAEventPackage;
  Events: TCEAEventPackageArray;
  EventId: string;

begin
  DbPath := IncludeTrailingPathDelimiter(GetTempDir) +
    'cea-event-repo-' + IntToStr(GetProcessID) + '.sqlite3';
  if FileExists(DbPath) then DeleteFile(DbPath);

  Repo := TCEAEventRepository.Create(DbPath);
  try
    R := Repo.Initialize;
    Assert(R.Code = rcOk, 'initialize: ' + R.StableCode);

    // ---- 1. 事件包落盘与读回 ----
    FillChar(Event, SizeOf(Event), 0);
    Event.EventId := 'event-00000001';
    Event.TriggerKind := etUserMark;
    Event.TriggerSource := 'user_mark';
    Event.StartAtMs := 1000;
    Event.EndAtMs := 3000;
    Event.ProcessIdentityId := 'process-test';
    Event.Epoch := 1;
    Event.FieldSnapshotsJson := '[]';
    Event.RecordingRefsJson := '[]';
    Event.AnalysisState := eaUnanalyzed;
    Event.UserTagsJson := '["tag1"]';
    Event.CreatedAtMs := 2000;
    R := Repo.SaveEvent(Event);
    Assert(R.Code = rcOk, 'save event: ' + R.StableCode);

    FillChar(Event, SizeOf(Event), 0);
    R := Repo.LoadEvent('event-00000001', Event);
    Assert(R.Code = rcOk, 'load event: ' + R.StableCode);
    Assert(Event.EventId = 'event-00000001', 'event id roundtrip');
    Assert(Event.TriggerKind = etUserMark, 'trigger kind roundtrip');
    Assert(Event.TriggerSource = 'user_mark', 'trigger source roundtrip');
    Assert(Event.StartAtMs = 1000, 'start ms roundtrip');
    Assert(Event.EndAtMs = 3000, 'end ms roundtrip');
    Assert(Event.DurationMs = 2000, 'duration');
    Assert(Event.ProcessIdentityId = 'process-test', 'process identity roundtrip');
    Assert(Event.Epoch = 1, 'epoch roundtrip');
    Assert(Event.AnalysisState = eaUnanalyzed, 'analysis state roundtrip');
    Assert(Event.UserTagsJson = '["tag1"]', 'user tags roundtrip');
    Assert(Event.CreatedAtMs = 2000, 'created at roundtrip');

    // ---- 2. 不存在的事件 ----
    FillChar(Event, SizeOf(Event), 0);
    R := Repo.LoadEvent('event-ffffffff', Event);
    Assert(R.Code = rcUnknown, 'missing event code');
    Assert(R.StableCode = 'event_not_found', 'missing event stable code');

    // ---- 3. 列表与按进程过滤 ----
    Events := Repo.ListEvents;
    Assert(Length(Events) = 1, 'list count');

    R := Repo.ListEventsForProcess('process-test', Events);
    Assert(R.Code = rcOk, 'list by process: ' + R.StableCode);
    Assert(Length(Events) = 1, 'list by process count');

    R := Repo.ListEventsForProcess('process-other', Events);
    Assert(R.Code = rcOk, 'list other process');
    Assert(Length(Events) = 0, 'list other process empty');

    // ---- 4. 服务装配存储后自动落盘 ----
    Config.PreRollMs := 1000;
    Config.PostRollMs := 1000;
    Config.SnapshotCapacity := 16;
    Config.DefaultCooldownMs := 0;
    Service := TCEAEventService.Create(Config);
    try
      Service.SetEventStore(Repo);
      R := Service.MarkEvent('process-test', 1, 10000, 'boss-fight');
      Assert(R.Code = rcOk, 'mark event: ' + R.StableCode);
      EventId := Service.GetEvents[0].EventId;
      Assert(EventId <> '', 'event id assigned');

      FillChar(Event, SizeOf(Event), 0);
      R := Repo.LoadEvent(EventId, Event);
      Assert(R.Code = rcOk, 'service persisted event: ' + R.StableCode);
      Assert(Event.TriggerKind = etUserMark, 'persisted trigger kind');
      Assert(Pos('boss-fight', Event.UserTagsJson) > 0, 'persisted tag');

      // 字段变化规则也应落盘
      Rule.FieldId := 'player.geo';
      Rule.Condition := ccAnyChange;
      Rule.Threshold := 0;
      Rule.CooldownMs := 0;
      Rule.Enabled := True;
      R := Service.ConfigureRule(Rule);
      Assert(R.Code = rcOk, 'configure rule: ' + R.StableCode);
      R := Service.ObserveField('player.geo', '10', 20000, 'process-test', 1);
      Assert(R.Code = rcOk, 'observe 1: ' + R.StableCode);
      R := Service.ObserveField('player.geo', '25', 21000, 'process-test', 1);
      Assert(R.Code = rcOk, 'observe 2: ' + R.StableCode);
      Assert(Service.EventCount = 2, 'two events after change');

      // ---- 5. 删除同步落盘 ----
      R := Service.DeleteEvent(EventId);
      Assert(R.Code = rcOk, 'service delete: ' + R.StableCode);
      FillChar(Event, SizeOf(Event), 0);
      R := Repo.LoadEvent(EventId, Event);
      Assert(R.Code = rcUnknown, 'deleted event gone from store');
    finally
      Service.Free;
    end;

    // ---- 6. 重启后重新载入并续号 ----
    Service := TCEAEventService.Create(Config);
    try
      Service.SetEventStore(Repo);
      R := Service.ReloadFromStore;
      Assert(R.Code = rcOk, 'reload: ' + R.StableCode);
      Assert(Service.EventCount = 1, 'reloaded count');
      Assert(Service.GetEvents[0].EventId = 'event-00000002', 'reloaded event id');

      // 新事件必须使用比历史更大的序号，不能覆盖旧记录
      R := Service.MarkEvent('process-test', 1, 30000, 'after-restart');
      Assert(R.Code = rcOk, 'mark after restart: ' + R.StableCode);
      Assert(Service.GetEvents[1].EventId = 'event-00000003',
        'sequence continues, got ' + Service.GetEvents[1].EventId);
      Events := Repo.ListEvents;
      Assert(Length(Events) = 2, 'store has both events');
    finally
      Service.Free;
    end;

    // ---- 7. 删除全部后库为空 ----
    Events := Repo.ListEvents;
    while Length(Events) > 0 do
    begin
      R := Repo.DeleteEvent(Events[0].EventId);
      Assert(R.Code = rcOk, 'delete all: ' + R.StableCode);
      Events := Repo.ListEvents;
    end;
    Assert(Length(Repo.ListEvents) = 0, 'store empty');

    R := Repo.DeleteEvent('event-00000001');
    Assert(R.Code = rcUnknown, 'delete missing event');
  finally
    Repo.Free;
    if FileExists(DbPath) then DeleteFile(DbPath);
  end;

  WriteLn('EVENT_REPOSITORY=PASS');
end.

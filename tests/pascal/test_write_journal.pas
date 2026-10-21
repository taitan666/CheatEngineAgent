program test_write_journal;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_write_journal_types, cea_write_journal;

var
  DbPath: string;
  Journal: TCEAWriteJournal;
  R: TCEAResult;
  Rec: TCEAFieldWriteRecord;
  Recs: TCEAFieldWriteRecordArray;
  NewId: string;
  Count: Integer;

  procedure ResetRec;
  begin
    FillChar(Rec, SizeOf(Rec), 0);
    Rec.FieldId := 'player.geo';
    Rec.DisplayName := 'Geo';
    Rec.ValueType := 'dword';
    Rec.OriginalValue := '100';
    Rec.TargetValue := '500';
    Rec.AdapterId := CeaWriteAdapterCommandBus;
    Rec.AddressHex := '0x0000000012345678';
    Rec.ProcessIdentityId := 'process-test';
    Rec.Pid := 4242;
    Rec.Epoch := 3;
    Rec.Outcome := 'verified';
    Rec.StableCode := 'verified';
    Rec.ErrorText := '';
    Rec.DetailJson := '{"before":"64","after":"f4010000"}';
    Rec.CommandSent := True;
    Rec.Verified := True;
    Rec.RecordedAt := '2026-10-21T00:00:00Z';
  end;

begin
  DbPath := IncludeTrailingPathDelimiter(GetTempDir) +
    'cea-write-journal-' + IntToStr(GetProcessID) + '.sqlite3';
  if FileExists(DbPath) then DeleteFile(DbPath);

  Journal := TCEAWriteJournal.Create(DbPath);
  try
    R := Journal.Initialize;
    Assert(R.Code = rcOk, 'initialize: ' + R.StableCode);

    // ---- 1. 成功写入落账 ----
    ResetRec;
    Rec.RecordId := 'write-00000001';
    R := Journal.AppendWrite(Rec, NewId);
    Assert(R.Code = rcOk, 'append verified: ' + R.StableCode);
    Assert(NewId = 'write-00000001', 'record id echoed, got ' + NewId);

    // ---- 2. 被拒绝的写入同样必须落账（失败也要留痕） ----
    ResetRec;
    Rec.RecordId := 'write-00000002';
    Rec.FieldId := 'player.soul';
    Rec.DisplayName := 'Soul';
    Rec.OriginalValue := '50';
    Rec.TargetValue := '999';
    Rec.Outcome := 'rejected';
    Rec.StableCode := 'field_not_writable';
    Rec.ErrorText := 'field is not verified writable';
    Rec.DetailJson := '{}';
    Rec.CommandSent := False;
    Rec.Verified := False;
    Rec.RecordedAt := '2026-10-21T00:01:00Z';
    R := Journal.AppendWrite(Rec, NewId);
    Assert(R.Code = rcOk, 'append rejected: ' + R.StableCode);

    // ---- 3. 计数 ----
    R := Journal.CountWrites(Count);
    Assert(R.Code = rcOk, 'count: ' + R.StableCode);
    Assert(Count = 2, 'count should be 2, got ' + IntToStr(Count));

    // ---- 4. 全量列表按时间倒序（最新在前） ----
    R := Journal.ListWrites('', 0, Recs);
    Assert(R.Code = rcOk, 'list all: ' + R.StableCode);
    Assert(Length(Recs) = 2, 'list all count');
    Assert(Recs[0].RecordId = 'write-00000002', 'newest first');
    Assert(Recs[1].RecordId = 'write-00000001', 'oldest last');
    Assert(Recs[0].CommandSent = False, 'rejected write did not send a command');
    Assert(Recs[1].CommandSent = True, 'verified write sent a command');
    Assert(Recs[1].Verified = True, 'verified flag roundtrip');
    Assert(Recs[1].Pid = 4242, 'pid roundtrip');
    Assert(Recs[1].Epoch = 3, 'epoch roundtrip');
    Assert(Recs[1].AddressHex = '0x0000000012345678', 'address roundtrip');
    Assert(Recs[1].AdapterId = CeaWriteAdapterCommandBus, 'adapter roundtrip');
    Assert(Recs[1].OriginalValue = '100', 'original value roundtrip');
    Assert(Recs[1].TargetValue = '500', 'target value roundtrip');
    Assert(Recs[1].RecordedAt = '2026-10-21T00:00:00Z', 'timestamp roundtrip');

    // ---- 5. 按字段过滤 ----
    R := Journal.ListWrites('player.soul', 0, Recs);
    Assert(R.Code = rcOk, 'list by field: ' + R.StableCode);
    Assert(Length(Recs) = 1, 'filtered count');
    Assert(Recs[0].StableCode = 'field_not_writable', 'error code kept');
    Assert(Recs[0].ErrorText = 'field is not verified writable',
      'error text kept');

    R := Journal.ListWrites('player.nonexistent', 0, Recs);
    Assert(R.Code = rcOk, 'list unknown field ok');
    Assert(Length(Recs) = 0, 'unknown field empty');

    // ---- 6. 上限钳制 ----
    R := Journal.ListWrites('', 1, Recs);
    Assert(R.Code = rcOk, 'list with limit: ' + R.StableCode);
    Assert(Length(Recs) = 1, 'limit respected');

    // ---- 7. 记录无效时拒绝落账 ----
    ResetRec;
    Rec.RecordId := 'write-00000003';
    Rec.FieldId := '';
    R := Journal.AppendWrite(Rec, NewId);
    Assert(R.Code = rcInvalidArgument, 'invalid record code');
    Assert(R.StableCode = 'write_record_invalid', 'invalid record stable code');
    R := Journal.CountWrites(Count);
    Assert(Count = 2, 'invalid record not stored');
  finally
    Journal.Free;
  end;

  // ---- 8. 重开后记录仍在（审计必须跨会话） ----
  Journal := TCEAWriteJournal.Create(DbPath);
  try
    R := Journal.Initialize;
    Assert(R.Code = rcOk, 'reopen initialize: ' + R.StableCode);
    R := Journal.CountWrites(Count);
    Assert(Count = 2, 'records survive restart, got ' + IntToStr(Count));
    R := Journal.ListWrites('player.geo', 0, Recs);
    Assert(Length(Recs) = 1, 'filtered after restart');
    Assert(Recs[0].Verified = True, 'verified flag survives restart');
  finally
    Journal.Free;
    if FileExists(DbPath) then DeleteFile(DbPath);
  end;

  WriteLn('WRITE_JOURNAL=PASS');
end.

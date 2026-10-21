program test_event_wake_queue;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_results, cea_event_types, cea_event_wake_queue;

var
  Queue: TCEAEventWakeQueue;
  R: TCEAResult;
  EventId: string;
  ContextJson: string;
  I: Integer;
begin
  Queue := TCEAEventWakeQueue.Create(3);
  try
    // 1. 基本入队与长度
    Assert(Queue.QueueLength = 0, 'starts empty');
    R := Queue.Enqueue('event-00000001', '{"a":1}');
    Assert(R.Code = rcOk, 'enqueue ok: ' + R.StableCode);
    Assert(Queue.QueueLength = 1, 'length 1');
    Assert(Pos('"duplicate":false', R.DataJson) > 0, 'first enqueue not duplicate');

    // 2. 同一事件重复入队不重复排队（防重入）
    R := Queue.Enqueue('event-00000001', '{"a":1}');
    Assert(R.Code = rcOk, 'duplicate enqueue is not an error');
    Assert(Pos('"duplicate":true', R.DataJson) > 0, 'duplicate flagged');
    Assert(Queue.QueueLength = 1, 'duplicate did not grow queue');

    // 3. 出队顺序为先进先出
    R := Queue.Enqueue('event-00000002', '{"a":2}');
    Assert(R.Code = rcOk, 'enqueue 2: ' + R.StableCode);
    Assert(Queue.Dequeue(EventId, ContextJson), 'dequeue first');
    Assert(EventId = 'event-00000001', 'fifo order: ' + EventId);
    Assert(ContextJson = '{"a":1}', 'context preserved: ' + ContextJson);
    Assert(Queue.QueueLength = 1, 'one left');
    Assert(Queue.Dequeue(EventId, ContextJson), 'dequeue second');
    Assert(EventId = 'event-00000002', 'second id: ' + EventId);
    Assert(not Queue.Dequeue(EventId, ContextJson), 'empty dequeue returns false');
    Assert(EventId = '', 'empty dequeue clears id');

    // 4. 容量满时丢弃最旧待办而不是阻塞（新事件更接近当前状态）
    for I := 1 to 3 do
    begin
      R := Queue.Enqueue('event-1000000' + IntToStr(I), '{"i":' + IntToStr(I) + '}');
      Assert(R.Code = rcOk, 'fill ' + IntToStr(I) + ': ' + R.StableCode);
    end;
    Assert(Queue.QueueLength = 3, 'capacity reached');
    Assert(Queue.DroppedCount = 0, 'nothing dropped yet');
    R := Queue.Enqueue('event-10000004', '{"i":4}');
    Assert(R.Code = rcOk, 'overflow enqueue: ' + R.StableCode);
    Assert(Queue.QueueLength = 3, 'capacity stays bounded');
    Assert(Queue.DroppedCount = 1, 'oldest dropped once');
    Assert(Queue.Dequeue(EventId, ContextJson), 'dequeue after overflow');
    Assert(EventId = 'event-10000002', 'oldest was dropped: ' + EventId);
    Assert(ContextJson = '{"i":2}', 'dropped context follows: ' + ContextJson);

    // 5. 空事件 ID 被拒，不占容量
    R := Queue.Enqueue('', '{}');
    Assert(R.Code = rcInvalidArgument, 'empty id rejected');
    Assert(R.StableCode = 'wake_event_id_required',
      'empty id code: ' + R.StableCode);
    Assert(Queue.QueueLength = 2, 'rejected enqueue does not grow queue');

    // 6. Clear 放弃全部待办，已丢弃计数保留（用于观察采集侧压力）
    Queue.Clear;
    Assert(Queue.QueueLength = 0, 'clear empties queue');
    Assert(Queue.DroppedCount = 1, 'dropped count survives clear');
    Assert(not Queue.Dequeue(EventId, ContextJson), 'cleared queue dequeue false');

    // 7. 非法容量回落到默认值而不是建出零容量队列
    Queue.Free;
    Queue := TCEAEventWakeQueue.Create(0);
    Assert(Queue.QueueLength = 0, 'default capacity queue empty');
    for I := 1 to 40 do
      Queue.Enqueue('event-2000000' + IntToStr(I), '{}');
    Assert(Queue.QueueLength > 0, 'default capacity accepts events');

    WriteLn('EVENT_WAKE_QUEUE=PASS');
  finally
    Queue.Free;
  end;
end.

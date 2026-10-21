unit cea_event_wake_queue;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, Classes, cea_results, cea_event_types;

type
  // 按需唤醒 AI 的任务队列（FR-077）。
  //
  // 边界设计：队列只负责「哪些事件值得让模型看」，它自己绝不调用模型。
  // 真正的调用必须由本地操作者触发（FR-080 明确授权），因此队列满了
  // 之后是丢弃最旧待办而不是阻塞事件采集——采集不能因为模型慢而丢证据。
  TCEAEventWakeQueue = class(TObject, ICEAEventWakePort)
  private
    FEventIds: TStringList;
    FContexts: TStringList;
    FCapacity: Integer;
    FDroppedCount: Cardinal;
    FLastError: string;
  public
    constructor Create(const ACapacity: Integer = 32);
    destructor Destroy; override;
    function Enqueue(const AEventId, AContextJson: string): TCEAResult;
    function QueueLength: Integer;
    // 只读查看最早的一条待办（不出队）；空队列返回 False
    function Peek(out AEventId, AContextJson: string): Boolean;
    // 取出最早的一条待办（出队）；空队列返回 False
    function Dequeue(out AEventId, AContextJson: string): Boolean;
    // 放弃全部待办（结束会话/切换目标时调用）
    procedure Clear;
    property DroppedCount: Cardinal read FDroppedCount;
    property LastError: string read FLastError;
  end;

implementation

constructor TCEAEventWakeQueue.Create(const ACapacity: Integer);
begin
  inherited Create;
  if ACapacity > 0 then
    FCapacity := ACapacity
  else
    FCapacity := 32;
  FEventIds := TStringList.Create;
  FContexts := TStringList.Create;
  FDroppedCount := 0;
  FLastError := '';
end;

destructor TCEAEventWakeQueue.Destroy;
begin
  FreeAndNil(FContexts);
  FreeAndNil(FEventIds);
  inherited Destroy;
end;

function TCEAEventWakeQueue.Enqueue(const AEventId,
  AContextJson: string): TCEAResult;
begin
  FLastError := '';
  if Trim(AEventId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'wake_event_id_required', '{}'));
  // 同一事件重复排队没有意义：冷却与合并已在上游做过，这里只防重入。
  if FEventIds.IndexOf(AEventId) >= 0 then
    Exit(TCEAResult.Ok('{"event_id":"' + AEventId +
      '","duplicate":true,"queued":' + IntToStr(FEventIds.Count) + '}'));
  if FEventIds.Count >= FCapacity then
  begin
    // 丢弃最旧待办：新事件比旧事件更接近当前游戏状态
    FEventIds.Delete(0);
    FContexts.Delete(0);
    Inc(FDroppedCount);
  end;
  FEventIds.Add(AEventId);
  FContexts.Add(AContextJson);
  Result := TCEAResult.Ok('{"event_id":"' + AEventId +
    '","duplicate":false,"queued":' + IntToStr(FEventIds.Count) + '}');
end;

function TCEAEventWakeQueue.QueueLength: Integer;
begin
  Result := FEventIds.Count;
end;

function TCEAEventWakeQueue.Peek(out AEventId, AContextJson: string): Boolean;
begin
  AEventId := '';
  AContextJson := '';
  if FEventIds.Count = 0 then
    Exit(False);
  AEventId := FEventIds[0];
  AContextJson := FContexts[0];
  Result := True;
end;

function TCEAEventWakeQueue.Dequeue(out AEventId, AContextJson: string): Boolean;
begin
  AEventId := '';
  AContextJson := '';
  if FEventIds.Count = 0 then
    Exit(False);
  AEventId := FEventIds[0];
  AContextJson := FContexts[0];
  FEventIds.Delete(0);
  FContexts.Delete(0);
  Result := True;
end;

procedure TCEAEventWakeQueue.Clear;
begin
  FEventIds.Clear;
  FContexts.Clear;
end;

end.

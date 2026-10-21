unit cea_owner_thread_queue;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, Windows, SyncObjs, cea_results;

type
  TCEACommandState = (qsPending, qsExecuting, qsCompleted, qsCancelled,
    qsTimedOut);

  ICEACommandExecutor = interface
    function Execute(const ACapabilityId,
      ARequestJson: string): TCEAResult;
  end;

  TCEACommandTicket = class
  private
    FCapabilityId: string;
    FRequestJson: string;
    FState: TCEACommandState;
    FResult: TCEAResult;
    FEvent: TEvent;
  public
    constructor Create(const ACapabilityId, ARequestJson: string);
    destructor Destroy; override;
    property State: TCEACommandState read FState;
  end;

  TCEACommandQueue = class
  private
    FOwnerThreadId: DWORD;
    FLock: TCriticalSection;
    FPending: TList;
    FAll: TList;
    function IsTerminal(const AState: TCEACommandState): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Submit(const ACapabilityId,
      ARequestJson: string): TCEACommandTicket;
    function DrainOne(const AExecutor: ICEACommandExecutor): TCEAResult;
    function WaitFor(const ATicket: TCEACommandTicket;
      const ATimeoutMs: Cardinal): TCEAResult;
    function Cancel(const ATicket: TCEACommandTicket): TCEAResult;
    function Release(var ATicket: TCEACommandTicket): TCEAResult;
    property OwnerThreadId: DWORD read FOwnerThreadId;
  end;

implementation

constructor TCEACommandTicket.Create(const ACapabilityId,
  ARequestJson: string);
begin
  inherited Create;
  FCapabilityId := ACapabilityId;
  FRequestJson := ARequestJson;
  FState := qsPending;
  FResult := TCEAResult.Error(rcConflict, 'command_pending', '{}');
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TCEACommandTicket.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

constructor TCEACommandQueue.Create;
begin
  inherited Create;
  FOwnerThreadId := GetCurrentThreadId;
  FLock := TCriticalSection.Create;
  FPending := TList.Create;
  FAll := TList.Create;
end;

destructor TCEACommandQueue.Destroy;
var
  Index: Integer;
  Ticket: TCEACommandTicket;
begin
  FLock.Acquire;
  try
    for Index := 0 to FAll.Count - 1 do
    begin
      Ticket := TCEACommandTicket(FAll[Index]);
      if not IsTerminal(Ticket.FState) then
      begin
        Ticket.FState := qsCancelled;
        Ticket.FResult := TCEAResult.Error(rcCancelled, 'queue_destroyed', '{}');
        Ticket.FEvent.SetEvent;
      end;
    end;
    for Index := FAll.Count - 1 downto 0 do
      TObject(FAll[Index]).Free;
    FAll.Clear;
    FPending.Clear;
  finally
    FLock.Release;
  end;
  FAll.Free;
  FPending.Free;
  FLock.Free;
  inherited Destroy;
end;

function TCEACommandQueue.IsTerminal(
  const AState: TCEACommandState): Boolean;
begin
  Result := AState in [qsCompleted, qsCancelled, qsTimedOut];
end;

function TCEACommandQueue.Submit(const ACapabilityId,
  ARequestJson: string): TCEACommandTicket;
begin
  if ACapabilityId = '' then
    Exit(nil);
  Result := TCEACommandTicket.Create(ACapabilityId, ARequestJson);
  FLock.Acquire;
  try
    FPending.Add(Result);
    FAll.Add(Result);
  finally
    FLock.Release;
  end;
end;

function TCEACommandQueue.DrainOne(
  const AExecutor: ICEACommandExecutor): TCEAResult;
var
  Ticket: TCEACommandTicket;
begin
  if GetCurrentThreadId <> FOwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'ce_owner_thread_required', '{}'));
  FLock.Acquire;
  try
    if FPending.Count = 0 then
      Exit(TCEAResult.Error(rcConflict, 'command_queue_empty', '{}'));
    Ticket := TCEACommandTicket(FPending[0]);
    FPending.Delete(0);
    Ticket.FState := qsExecuting;
  finally
    FLock.Release;
  end;

  if AExecutor = nil then
    Result := TCEAResult.Error(rcInternalError,
      'command_executor_missing', '{}')
  else
    Result := AExecutor.Execute(Ticket.FCapabilityId, Ticket.FRequestJson);

  FLock.Acquire;
  try
    Ticket.FResult := Result;
    Ticket.FState := qsCompleted;
    Ticket.FEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TCEACommandQueue.WaitFor(const ATicket: TCEACommandTicket;
  const ATimeoutMs: Cardinal): TCEAResult;
var
  WaitResult: TWaitResult;
begin
  if ATicket = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'command_ticket_required', '{}'));
  WaitResult := ATicket.FEvent.WaitFor(ATimeoutMs);
  if WaitResult = wrTimeout then
  begin
    FLock.Acquire;
    try
      if ATicket.FState = qsPending then
      begin
        FPending.Remove(ATicket);
        ATicket.FState := qsTimedOut;
        ATicket.FResult := TCEAResult.Error(rcTimeout,
          'command_timeout', '{}');
        ATicket.FEvent.SetEvent;
      end;
      Result := TCEAResult.Error(rcTimeout, 'command_timeout', '{}');
    finally
      FLock.Release;
    end;
    Exit;
  end;
  FLock.Acquire;
  try
    Result := ATicket.FResult;
  finally
    FLock.Release;
  end;
end;

function TCEACommandQueue.Cancel(
  const ATicket: TCEACommandTicket): TCEAResult;
begin
  if ATicket = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'command_ticket_required', '{}'));
  FLock.Acquire;
  try
    if ATicket.FState <> qsPending then
      Exit(TCEAResult.Error(rcConflict,
        'command_not_cancellable', '{}'));
    FPending.Remove(ATicket);
    ATicket.FState := qsCancelled;
    ATicket.FResult := TCEAResult.Error(rcCancelled,
      'command_cancelled', '{}');
    ATicket.FEvent.SetEvent;
    Result := ATicket.FResult;
  finally
    FLock.Release;
  end;
end;

function TCEACommandQueue.Release(
  var ATicket: TCEACommandTicket): TCEAResult;
begin
  if ATicket = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'command_ticket_required', '{}'));
  FLock.Acquire;
  try
    if not IsTerminal(ATicket.FState) then
      Exit(TCEAResult.Error(rcConflict, 'command_not_terminal', '{}'));
    FPending.Remove(ATicket);
    FAll.Remove(ATicket);
    ATicket.Free;
    ATicket := nil;
    Result := TCEAResult.Ok('{}');
  finally
    FLock.Release;
  end;
end;

end.

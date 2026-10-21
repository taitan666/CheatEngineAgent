program test_ce_command_queue;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  Classes, SysUtils, cea_results, cea_owner_thread_queue;

type
  TTestExecutor = class(TObject, ICEACommandExecutor)
  public
    ExecutionCount: Cardinal;
    function Execute(const ACapabilityId, ARequestJson: string): TCEAResult;
  end;

  TWrongThreadDrain = class(TThread)
  private
    FQueue: TCEACommandQueue;
    FExecutor: ICEACommandExecutor;
  protected
    procedure Execute; override;
  public
    DrainResult: TCEAResult;
    constructor Create(const AQueue: TCEACommandQueue;
      const AExecutor: ICEACommandExecutor);
  end;

function TTestExecutor.Execute(const ACapabilityId,
  ARequestJson: string): TCEAResult;
begin
  Inc(ExecutionCount);
  Result := TCEAResult.Ok('{"capability":"' + ACapabilityId + '"}');
end;

constructor TWrongThreadDrain.Create(const AQueue: TCEACommandQueue;
  const AExecutor: ICEACommandExecutor);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FExecutor := AExecutor;
end;

procedure TWrongThreadDrain.Execute;
begin
  DrainResult := FQueue.DrainOne(FExecutor);
end;

var
  Queue: TCEACommandQueue;
  Executor: TTestExecutor;
  Ticket: TCEACommandTicket;
  Worker: TWrongThreadDrain;
  R: TCEAResult;
  BeforeCount: Cardinal;

begin
  Queue := TCEACommandQueue.Create;
  Executor := TTestExecutor.Create;
  try
    Ticket := Queue.Submit('memory_read', '{"address":"0x1000"}');
    Assert(Assigned(Ticket), 'submit returns a ticket');
    Assert(Queue.DrainOne(Executor).Code = rcOk,
      'owner thread drains command');
    R := Queue.WaitFor(Ticket, 100);
    Assert(R.Code = rcOk, 'completed ticket returns result');
    Assert(R.DataJson = '{"capability":"memory_read"}',
      'result belongs to submitted command');
    Assert(Executor.ExecutionCount = 1, 'command executes once');
    Assert(Queue.Release(Ticket).Code = rcOk,
      'terminal ticket can be released');

    Ticket := Queue.Submit('memory_read', '{}');
    Worker := TWrongThreadDrain.Create(Queue, Executor);
    try
      Worker.Start;
      Worker.WaitFor;
      Assert(Worker.DrainResult.Code = rcUnauthorized,
        'non-owner thread cannot touch CE-bound executor');
      Assert(Executor.ExecutionCount = 1,
        'wrong-thread drain never executes command');
    finally
      Worker.Free;
    end;
    Assert(Queue.Cancel(Ticket).Code = rcCancelled,
      'pending command can be cancelled');
    Assert(Queue.WaitFor(Ticket, 100).Code = rcCancelled,
      'cancel wakes waiter with cancelled result');
    Assert(Queue.Release(Ticket).Code = rcOk,
      'cancelled ticket can be released');

    BeforeCount := Executor.ExecutionCount;
    Ticket := Queue.Submit('memory_scan', '{}');
    R := Queue.WaitFor(Ticket, 1);
    Assert(R.Code = rcTimeout, 'undrained command times out');
    Assert(Queue.DrainOne(Executor).Code = rcConflict,
      'timed-out command is removed from pending queue');
    Assert(Executor.ExecutionCount = BeforeCount,
      'timed-out command is never executed later');
    Assert(Queue.Release(Ticket).Code = rcOk,
      'timed-out ticket can be released');

    WriteLn('CE_COMMAND_QUEUE=PASS');
  finally
    Queue.Free;
    Executor.Free;
  end;
end.

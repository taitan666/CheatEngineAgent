program test_winhttp_transport;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  cea_results, cea_llm_provider, cea_winhttp_transport;

var
  Transport: TCEAWinHttpTransport;
  Cancellation: TCEACancellationToken;
  R: TCEAResult;

begin
  Transport := TCEAWinHttpTransport.Create(4096);
  Cancellation := TCEACancellationToken.Create;
  try
    Cancellation.Cancel;
    R := Transport.PostJson(
      'https://network-must-not-be-reached.invalid/v1/chat/completions',
      'fixture-secret', '{"model":"fixture"}', 1000, Cancellation);
    Assert(R.Code = rcCancelled,
      'pre-cancelled WinHTTP request exits before opening the network');
    Assert(R.StableCode = 'model_request_cancelled',
      'WinHTTP cancellation has a stable result code');
    WriteLn('WINHTTP_TRANSPORT=PASS');
  finally
    Cancellation.Free;
    Transport.Free;
  end;
end.

program test_contracts;

{$mode objfpc}{$H+}

{ This file deliberately omits {$codepage utf8}. Its literals therefore carry
  the system code page (936 here) while holding UTF-8 bytes - exactly the state
  the application's own payloads are in, and the state that used to break
  GetJSON. Assertions on non-ASCII text compare hex bytes rather than strings so
  the check itself cannot be rescued (or broken) by a code page conversion. }

uses
  SysUtils, fpjson, jsonparser, cea_results;

var
  SuccessResult: TCEAResult;
  ErrorResult: TCEAResult;
  Payload: string;
  Parsed: TJSONData;
  PurposeText: UTF8String;

function BytesHex(const AValue: UTF8String): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    Result := Result + IntToHex(Ord(AValue[I]), 2);
end;

begin
  SuccessResult := TCEAResult.Ok('{"status":"ready"}');
  Assert(SuccessResult.Code = rcOk, 'success code');
  Assert(SuccessResult.StableCode = 'ok', 'stable success code');
  Assert(SuccessResult.DataJson = '{"status":"ready"}', 'success data');
  Assert(not SuccessResult.Failed, 'success must not fail');

  ErrorResult := TCEAResult.Error(rcPolicyDenied, 'policy_denied',
    '{"capability":"kernel_driver"}');
  Assert(ErrorResult.Code = rcPolicyDenied, 'policy result code');
  Assert(ErrorResult.StableCode = 'policy_denied', 'stable policy code');
  Assert(ErrorResult.DataJson = '{"capability":"kernel_driver"}',
    'policy data');
  Assert(ErrorResult.Failed, 'policy denial must fail');

  { Regression: a payload carrying non-ASCII text used to arrive tagged with the
    system code page, and GetJSON would transcode the already-UTF-8 bytes a
    second time. A trailing byte such as 0x8F is a valid GBK lead byte, so it
    swallowed the closing quote and the caller saw a parse error instead of the
    data it had just produced. TCEAResult must hand out a payload that every
    consumer can parse. }
  Payload := TCEAResult.Ok(
    '{"purpose":"找血量","operation":"dword 扫描 100"}').DataJson;
  Parsed := GetJSON(Payload);
  try
    PurposeText := Parsed.FindPath('purpose').AsString;
    Assert(BytesHex(PurposeText) = 'E689BEE8A180E9878F',
      'non-ASCII payload survives a JSON round trip, got ' +
      BytesHex(PurposeText));
    Assert(BytesHex(Parsed.FindPath('operation').AsString) =
      '64776F726420E689ABE68F8F20313030',
      'the field after the non-ASCII value is still reachable');
  finally
    Parsed.Free;
  end;

  WriteLn('CONTRACT_RESULTS=PASS');
end.

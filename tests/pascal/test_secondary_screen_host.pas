program test_secondary_screen_host;

{$mode objfpc}{$H+}

// 副屏宿主验收：
//   1. 无令牌一律 401（含首页），令牌可经 Bearer 头或 token 查询参数提供；
//   2. /api/render 返回运行时渲染 JSON；
//   3. 未装配写入回调时 /api/write 一律 403（fail-closed）；
//   4. 装配后写入结果原样回传（含两级反馈字段）；
//   5. 首页是只读页面骨架，含字段状态三重信号（颜色 + 标记 + 文字）。

uses
  Classes, SysUtils, fphttpclient, cea_results, cea_secondary_screen_host;

type
  TFakeScreenCallbacks = class
  public
    RenderCalls: Integer;
    WriteCalls: Integer;
    ListPagesCalls: Integer;
    SelectPageCalls: Integer;
    LastSelectedPageId: string;
    LastFieldId: string;
    LastTargetValue: string;
    LastExpectedValue: string;
    RenderShouldFail: Boolean;
    function Render(const ALayoutSchemaId: string): TCEAResult;
    function Write(const AFieldId, ATargetValue,
      AExpectedCurrentValue: string): TCEAResult;
    function ListPages: TCEAResult;
    function SelectPage(const APageId: string): TCEAResult;
  end;

function TFakeScreenCallbacks.ListPages: TCEAResult;
begin
  Inc(ListPagesCalls);
  Result := TCEAResult.Ok('{"pages":[{"page_id":"attributes",' +
    '"title":"Attributes","schema_id":"ui-demo","version":2,' +
    '"active":true,"updated_at":"2026-10-20T00:00:00Z"}],"count":1}');
end;

function TFakeScreenCallbacks.SelectPage(const APageId: string): TCEAResult;
begin
  Inc(SelectPageCalls);
  LastSelectedPageId := APageId;
  if APageId = 'missing' then
    Exit(TCEAResult.Error(rcUnknown, 'ui_page_not_found', '{}'));
  Result := TCEAResult.Ok('{"page_id":"' + APageId + '","schema_id":"ui-demo",' +
    '"version":2}');
end;

function TFakeScreenCallbacks.Render(const ALayoutSchemaId: string): TCEAResult;
begin
  Inc(RenderCalls);
  if RenderShouldFail then
    Exit(TCEAResult.Error(rcUnknown, 'model_empty', '{}'));
  Result := TCEAResult.Ok('{"schema_id":"ui-test","page_title":"' +
    ALayoutSchemaId + '","component_count":1,"editable_count":1,' +
    '"missing_count":0,"generated_at_ms":1,"sections":[{"section_id":"s1",' +
    '"title":"Main","components":[{"component_id":"comp-a","kind":"value_card",' +
    '"title":"Gold","field_id":"player.gold","options_json":"",' +
    '"binding":"bound","field_value_json":"500","field_value_type":"dword",' +
    '"validation_status":"verified","semantic":"verified_writable",' +
    '"editable":true,"disabled_reason":""}]}]}');
end;

function TFakeScreenCallbacks.Write(const AFieldId, ATargetValue,
  AExpectedCurrentValue: string): TCEAResult;
begin
  Inc(WriteCalls);
  LastFieldId := AFieldId;
  LastTargetValue := ATargetValue;
  LastExpectedValue := AExpectedCurrentValue;
  if AFieldId = 'reject.me' then
    Exit(TCEAResult.Error(rcUnauthorized, 'field_not_writable', '{}'));
  Result := TCEAResult.Ok('{"field_id":"' + AFieldId +
    '","outcome":"verified","stable_code":"verified",' +
    '"command_sent":true,"verified":true}');
end;

function HttpGet(const AUrl: string; const ABearer: string;
  out AStatus: Integer): string;
var
  Client: TFPHTTPClient;
begin
  Client := TFPHTTPClient.Create(nil);
  try
    Client.AllowRedirect := True;
    if ABearer <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + ABearer);
    try
      Result := Client.Get(AUrl);
      AStatus := Client.ResponseStatusCode;
    except
      on E: EHTTPClient do
      begin
        AStatus := Client.ResponseStatusCode;
        Result := '';
      end;
    end;
  finally
    Client.Free;
  end;
end;

function HttpPost(const AUrl, ABearer, ABody: string;
  out AStatus: Integer): string;
var
  Client: TFPHTTPClient;
  Input, Output: TStringStream;
begin
  Client := TFPHTTPClient.Create(nil);
  Input := TStringStream.Create(ABody);
  Output := TStringStream.Create('');
  try
    Client.AddHeader('Content-Type', 'application/json');
    if ABearer <> '' then
      Client.AddHeader('Authorization', 'Bearer ' + ABearer);
    Client.RequestBody := Input;
    try
      Client.Post(AUrl, Output);
      AStatus := Client.ResponseStatusCode;
    except
      on E: EHTTPClient do AStatus := Client.ResponseStatusCode;
    end;
    Result := Output.DataString;
  finally
    Output.Free;
    Input.Free;
    Client.Free;
  end;
end;

var
  Host: TCEASecondaryScreenHost;
  Callbacks: TFakeScreenCallbacks;
  R: TCEAResult;
  Port: Word;
  Status: Integer;
  WriteCallsBefore: Integer;
  Base, Body: string;

begin
  Callbacks := TFakeScreenCallbacks.Create;
  Host := TCEASecondaryScreenHost.Create(
    'secondary-screen-test-token-0123456789');
  try
    R := Host.Start(32511, 5, Port);
    Assert(R.Code = rcOk, 'secondary screen host starts on loopback');
    Assert(Port >= 32511, 'host reports selected loopback port');
    Assert(Host.Endpoint = 'http://127.0.0.1:' + IntToStr(Port) + '/',
      'endpoint is loopback only');
    Base := 'http://127.0.0.1:' + IntToStr(Port);

    // 1. 无令牌：首页与 API 都必须拒绝
    HttpGet(Base + '/', '', Status);
    Assert(Status = 401, 'index requires a token');
    HttpGet(Base + '/api/render', '', Status);
    Assert(Status = 401, 'render requires a token');
    HttpGet(Base + '/api/render?token=wrong-token', '', Status);
    Assert(Status = 401, 'wrong token is rejected');

    // 2. 未装配渲染回调：明确 503，不假装成功
    HttpGet(Base + '/api/render?token=secondary-screen-test-token-0123456789',
      '', Status);
    Assert(Status = 503, 'render without callback fails closed');

    // 3. 装配后经查询参数取渲染 JSON
    Host.OnRender := @Callbacks.Render;
    Body := HttpGet(
      Base + '/api/render?token=secondary-screen-test-token-0123456789&schema_id=ui-demo',
      '', Status);
    Assert(Status = 200, 'render with token succeeds');
    Assert(Pos('"page_title":"ui-demo"', Body) > 0,
      'render callback receives the layout schema id');
    Assert(Pos('"semantic":"verified_writable"', Body) > 0,
      'render payload keeps the field semantic state');
    Assert(Callbacks.RenderCalls = 1, 'render callback invoked once');

    // 4. 渲染失败时如实回传错误码
    Callbacks.RenderShouldFail := True;
    Body := HttpGet(Base + '/api/render?token=secondary-screen-test-token-0123456789',
      '', Status);
    Assert((Status = 200) and (Pos('model_empty', Body) > 0),
      'render failure surfaces its stable code');
    Callbacks.RenderShouldFail := False;

    // 5. 未装配写入回调：写入必须 fail-closed
    Body := HttpPost(Base + '/api/write?token=secondary-screen-test-token-0123456789',
      '', '{"field_id":"player.gold","target_value":"999"}', Status);
    Assert(Status = 403, 'write without callback is refused');
    Assert(Pos('write_not_enabled', Body) > 0, 'refusal names the reason');

    // 6. 装配写入回调：参数被正确转交，结果原样回传
    Host.OnWrite := @Callbacks.Write;
    Body := HttpPost(Base + '/api/write?token=secondary-screen-test-token-0123456789',
      '', '{"field_id":"player.gold","target_value":"999",' +
      '"expected_current_value":"500"}', Status);
    Assert(Status = 200, 'write with token succeeds');
    Assert(Callbacks.WriteCalls = 1, 'write callback invoked once');
    Assert(Callbacks.LastFieldId = 'player.gold', 'field id forwarded');
    Assert(Callbacks.LastTargetValue = '999', 'target value forwarded');
    Assert(Callbacks.LastExpectedValue = '500', 'expected value forwarded');
    Assert(Pos('"verified":true', Body) > 0, 'write result forwarded verbatim');

    // 7. 写入被拒时不得伪装成成功
    Body := HttpPost(Base + '/api/write?token=secondary-screen-test-token-0123456789',
      '', '{"field_id":"reject.me","target_value":"1",' +
      '"expected_current_value":"0"}', Status);
    Assert(Status = 200, 'refused write returns a response');
    Assert(Pos('field_not_writable', Body) > 0, 'refusal reason is forwarded');
    Assert(Pos('"verified":true', Body) = 0, 'refusal never reports verified');

    // 8. 请求体不完整或非法 JSON：400
    Body := HttpPost(Base + '/api/write?token=secondary-screen-test-token-0123456789',
      '', '{"field_id":"player.gold"}', Status);
    Assert(Status = 400, 'incomplete write request is rejected');
    Body := HttpPost(Base + '/api/write?token=secondary-screen-test-token-0123456789',
      '', 'not-json', Status);
    Assert(Status = 400, 'invalid JSON body is rejected');

    // 9. 未知路由：404
    HttpGet(Base + '/nope?token=secondary-screen-test-token-0123456789', '',
      Status);
    Assert(Status = 404, 'unknown route is 404');

    // 9b. 多页面（FR-033）：未装配时返回空列表而不是错误
    Body := HttpGet(Base + '/api/pages?token=secondary-screen-test-token-0123456789',
      '', Status);
    Assert((Status = 200) and (Pos('"count":0', Body) > 0),
      'page list degrades to empty, status=' + IntToStr(Status));
    Body := HttpPost(Base + '/api/page?token=secondary-screen-test-token-0123456789',
      '', '{"page_id":"attributes"}', Status);
    Assert(Status = 403, 'page switch without callback is refused');
    Assert(Pos('page_selection_not_enabled', Body) > 0,
      'page refusal names the reason');

    // 9c. 装配后：列页与切页都转交，且切页不触碰写入回调
    Host.OnListPages := @Callbacks.ListPages;
    Host.OnSelectPage := @Callbacks.SelectPage;
    Body := HttpGet(Base + '/api/pages?token=secondary-screen-test-token-0123456789',
      '', Status);
    Assert((Status = 200) and (Callbacks.ListPagesCalls = 1),
      'page list callback invoked');
    Assert(Pos('"page_id":"attributes"', Body) > 0, 'page list forwarded');
    WriteCallsBefore := Callbacks.WriteCalls;
    Body := HttpPost(Base + '/api/page?token=secondary-screen-test-token-0123456789',
      '', '{"page_id":"attributes"}', Status);
    Assert((Status = 200) and (Callbacks.SelectPageCalls = 1),
      'page switch callback invoked');
    Assert(Callbacks.LastSelectedPageId = 'attributes', 'page id forwarded');
    Assert(Callbacks.WriteCalls = WriteCallsBefore,
      'switching a page never routes through the write path');
    Body := HttpPost(Base + '/api/page?token=secondary-screen-test-token-0123456789',
      '', '{"page_id":"missing"}', Status);
    Assert((Status = 200) and (Pos('ui_page_not_found', Body) > 0),
      'unknown page surfaces its stable code');
    Body := HttpPost(Base + '/api/page?token=secondary-screen-test-token-0123456789',
      '', '{}', Status);
    Assert(Status = 400, 'page switch without page_id is rejected');
    Body := HttpGet(Base + '/api/pages', '', Status);
    Assert(Status = 401, 'page list requires the token too');

    // 10. 首页：只读页面骨架 + 状态三重信号 + 两级反馈文案
    Body := HttpGet(Base + '/?token=secondary-screen-test-token-0123456789', '',
      Status);
    Assert(Status = 200, 'index page served with token, status=' +
      IntToStr(Status) + ' body=' + Copy(Body, 1, 120));
    Assert(Pos('Game Companion Console', Body) > 0, 'page title present');
    Assert(Pos('/api/render', Body) > 0, 'page polls the render endpoint');
    Assert(Pos('/api/pages', Body) > 0, 'page polls the page list endpoint');
    Assert(Pos('id="pageSel"', Body) > 0, 'page carries a page switcher');
    Assert(Pos('read_only', Body) > 0, 'page knows the read-only state');
    Assert(Pos('pending_write', Body) > 0, 'page knows the pending state');
    Assert(Pos('verified_writable', Body) > 0, 'page knows the writable state');
    Assert(Pos('invalid', Body) > 0, 'page knows the invalid state');
    Assert(Pos('[LOCK]', Body) > 0, 'state carries a non-color marker');
    Assert(Pos('Not verified via write -> read-back -> match', Body) > 0,
      'page explains why an unverified field has no write control');
    Assert(Pos('read-back verification', Body) > 0,
      'page states the two-stage write feedback');

    // 11. 令牌撤销后立即失效
    Host.RevokeToken;
    HttpGet(Base + '/?token=secondary-screen-test-token-0123456789', '', Status);
    Assert(Status = 401, 'revoked token no longer authorizes');

    WriteLn('SECONDARY_SCREEN_HOST=PASS');
  finally
    Host.Free;
    Callbacks.Free;
  end;
end.

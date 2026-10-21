unit cea_secondary_screen_host;

{$mode objfpc}{$H+}

// 副屏宿主（Phase 1 1D 的落地形态）
//
// PRD FR-023「本地运行」允许两种形态：本地 WebView，或本地服务。
// 本项目选**本地回环 HTTP 服务**，理由：
//   1. Lazarus/LCL 没有内建 WebView2 组件，自建 COM 宿主会引入大量
//      非治理代码，且与本项目的「受治理写入」边界无关；
//   2. 本地服务同样满足「不把实时游戏数据上传云端」，且天然可被
//      WebView2 / Edge / Chrome 任意宿主打开，选型不被锁死；
//   3. 副屏页面本身是纯渲染产物（TCEAUiRenderModel 的 JSON），
//      不需要与宿主进程共享内存。
//
// 安全边界：
//   - 只绑定 127.0.0.1，永不监听外网；
//   - 所有路由（含首页）都要求 Bearer 令牌或 token 查询参数；
//   - 页面不含任何写控件，除非渲染模型里该字段 Editable=True，
//     且提交仍走运行时 WriteFieldValue（faVerifiedWritable +
//     compare-write-readback + 写后独立重读）；
//   - 回调加锁串行化，避免并发触碰非线程安全的运行时状态。

interface

uses
  Classes, SysUtils, SyncObjs, fphttpserver, httpdefs, cea_results;

type
  // TFPHttpServer 的 Address 是 protected，这里重新公开以便绑定回环地址
  TCEASecondaryHttpServer = class(TFPHttpServer)
  public
    property Address;
  end;

  // 渲染提供者：返回副屏页面的渲染 JSON（TCEAUiRenderModel 的序列化）
  TCEARenderCallback = function(const ALayoutSchemaId: string): TCEAResult of object;
  // 写入提交者：必须复用受治理的写入路径，不得直写内存
  TCEAWriteCallback = function(const AFieldId, ATargetValue,
    AExpectedCurrentValue: string): TCEAResult of object;
  // 页面列表（多页面 FR-033）：只读，返回已保存页面
  TCEAPagesCallback = function: TCEAResult of object;
  // 切换副屏渲染页：只改变呈现，不触碰目标内存
  TCEASelectPageCallback = function(const APageId: string): TCEAResult of object;

  TCEASecondaryScreenHost = class
  private
    FServer: TCEASecondaryHttpServer;
    FToken: string;
    FPort: Word;
    FThread: TThread;
    FLock: TCriticalSection;
    FOnRender: TCEARenderCallback;
    FOnWrite: TCEAWriteCallback;
    FOnListPages: TCEAPagesCallback;
    FOnSelectPage: TCEASelectPageCallback;
    FLastError: string;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
    function Authorized(const AToken: string): Boolean;
    function BuildPage(const AToken: string): string;
  public
    constructor Create(const AToken: string);
    destructor Destroy; override;
    function Start(const APreferredPort, AAttempts: Word;
      out ASelectedPort: Word): TCEAResult;
    procedure Stop;
    procedure RevokeToken;
    function Endpoint: string;
    property OnRender: TCEARenderCallback read FOnRender write FOnRender;
    property OnWrite: TCEAWriteCallback read FOnWrite write FOnWrite;
    property OnListPages: TCEAPagesCallback read FOnListPages write FOnListPages;
    property OnSelectPage: TCEASelectPageCallback
      read FOnSelectPage write FOnSelectPage;
    property LastError: string read FLastError;
  end;

implementation

uses
  fphttpclient, fpjson, jsonparser;

type
  TCEASecondaryServerThread = class(TThread)
  private
    FServer: TCEASecondaryHttpServer;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AServer: TCEASecondaryHttpServer);
    property ErrorText: string read FErrorText;
  end;

function JsonEscapeText(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < ' ' then
        Result := Result + '\u' + IntToHex(Ord(C), 4)
      else
        Result := Result + C;
    end;
  end;
end;

constructor TCEASecondaryServerThread.Create(const AServer: TCEASecondaryHttpServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
end;

procedure TCEASecondaryServerThread.Execute;
begin
  try
    FServer.Active := True;
  except
    on E: Exception do FErrorText := E.Message;
  end;
end;

constructor TCEASecondaryScreenHost.Create(const AToken: string);
begin
  inherited Create;
  if Length(AToken) < 16 then
    raise EArgumentException.Create('secondary screen token too short');
  FToken := AToken;
  FLock := TCriticalSection.Create;
  FServer := TCEASecondaryHttpServer.Create(nil);
  FServer.Address := '127.0.0.1';
  FServer.Threaded := True;
  FServer.QueueSize := 8;
  FServer.OnRequest := @HandleRequest;
end;

destructor TCEASecondaryScreenHost.Destroy;
begin
  Stop;
  FServer.Free;
  FServer := nil;
  FToken := StringOfChar(#0, Length(FToken));
  FLock.Free;
  inherited Destroy;
end;

function TCEASecondaryScreenHost.Start(const APreferredPort, AAttempts: Word;
  out ASelectedPort: Word): TCEAResult;
var
  Attempt: Word;
begin
  ASelectedPort := 0;
  FLastError := '';
  if (APreferredPort = 0) or (AAttempts = 0) or FServer.Active then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'secondary_screen_start_invalid', '{}'));
  for Attempt := 0 to AAttempts - 1 do
  begin
    try
      FServer.Port := APreferredPort + Attempt;
      FThread := TCEASecondaryServerThread.Create(FServer);
      FThread.Start;
      Sleep(100);
      if FThread.Finished then
      begin
        FLastError := TCEASecondaryServerThread(FThread).ErrorText;
        if FServer.Active then FServer.Active := False;
        FreeAndNil(FThread);
        Continue;
      end;
      FPort := FServer.Port;
      ASelectedPort := FPort;
      Exit(TCEAResult.Ok('{"endpoint":"' + Endpoint + '"}'));
    except
      on E: Exception do
      begin
        FLastError := E.Message;
        if FServer.Active then FServer.Active := False;
      end;
    end;
  end;
  Result := TCEAResult.Error(rcConflict,
    'secondary_screen_port_unavailable', '{}');
end;

procedure TCEASecondaryScreenHost.Stop;
begin
  if Assigned(FServer) and FServer.Active then
  begin
    FServer.Active := False;
    try
      // 打一次空请求唤醒监听线程，确保 Active := False 能被观察到
      TFPHTTPClient.SimpleGet(
        'http://127.0.0.1:' + IntToStr(FPort) + '/__stop__');
    except
      // 唤醒请求失败不影响关闭流程
    end;
  end;
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FPort := 0;
end;

procedure TCEASecondaryScreenHost.RevokeToken;
begin
  FToken := StringOfChar(#0, Length(FToken));
  FToken := 'revoked';
end;

function TCEASecondaryScreenHost.Endpoint: string;
begin
  if FPort = 0 then Result := ''
  else Result := 'http://127.0.0.1:' + IntToStr(FPort) + '/';
end;

function TCEASecondaryScreenHost.Authorized(const AToken: string): Boolean;
begin
  Result := (FToken <> '') and (AToken = FToken);
end;

procedure TCEASecondaryScreenHost.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Token, Path, Body: string;
  Render: TCEAResult;
  WriteResult: TCEAResult;
  Obj: TJSONObject;
  FieldId, TargetValue, ExpectedValue: string;
begin
  AResponse.ContentType := 'application/json; charset=utf-8';
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.SetCustomHeader('X-Content-Type-Options', 'nosniff');
  AResponse.SetCustomHeader('X-Frame-Options', 'DENY');

  Path := ARequest.PathInfo;

  if Path = '/__stop__' then
  begin
    AResponse.Code := 200;
    AResponse.Content := '{"stopped":true}';
    Exit;
  end;

  Token := ARequest.QueryFields.Values['token'];
  if Token = '' then
  begin
    if Pos('Bearer ', ARequest.Authorization) = 1 then
      Token := Copy(ARequest.Authorization, 8, MaxInt);
  end;

  if not Authorized(Token) then
  begin
    AResponse.Code := 401;
    AResponse.Content := '{"error":"unauthenticated"}';
    Exit;
  end;

  // 首页：只读副屏页面。令牌由客户端提供，故可安全内联给页面自身使用。
  // 注意：不同 FPC 版本对根路径的 PathInfo 可能给 '' 或 '/'，两者都要接受。
  if (ARequest.Method = 'GET') and
    ((Path = '') or (Path = '/') or (Path = '/index.html')) then
  begin
    AResponse.ContentType := 'text/html; charset=utf-8';
    AResponse.Code := 200;
    AResponse.Content := BuildPage(Token);
    Exit;
  end;

  if (ARequest.Method = 'GET') and (Path = '/api/render') then
  begin
    if FOnRender = nil then
    begin
      AResponse.Code := 503;
      AResponse.Content := '{"error":"render_unavailable"}';
      Exit;
    end;
    FLock.Enter;
    try
      Render := FOnRender(ARequest.QueryFields.Values['schema_id']);
    finally
      FLock.Leave;
    end;
    if Render.Failed then
      AResponse.Content := '{"error":"' + JsonEscapeText(Render.StableCode) + '"}'
    else
      AResponse.Content := Render.DataJson;
    AResponse.Code := 200;
    Exit;
  end;

  if (ARequest.Method = 'GET') and (Path = '/api/pages') then
  begin
    // 多页面（FR-033）：未装配时返回空列表而不是错误，页面切换控件
    // 因此可以安全地总是存在。
    if FOnListPages = nil then
    begin
      AResponse.Code := 200;
      AResponse.Content := '{"pages":[],"count":0}';
      Exit;
    end;
    FLock.Enter;
    try
      Render := FOnListPages();
    finally
      FLock.Leave;
    end;
    if Render.Failed then
      AResponse.Content := '{"error":"' + JsonEscapeText(Render.StableCode) + '"}'
    else
      AResponse.Content := Render.DataJson;
    AResponse.Code := 200;
    Exit;
  end;

  if (ARequest.Method = 'POST') and (Path = '/api/page') then
  begin
    // 切页只改呈现，不写目标内存，因此不需要写开关；但仍要求令牌。
    if FOnSelectPage = nil then
    begin
      AResponse.Code := 403;
      AResponse.Content := '{"error":"page_selection_not_enabled"}';
      Exit;
    end;
    if ARequest.ContentLength > 8 * 1024 then
    begin
      AResponse.Code := 413;
      AResponse.Content := '{"error":"request_too_large"}';
      Exit;
    end;
    Obj := nil;
    try
      try
        Obj := TJSONObject(GetJSON(ARequest.Content));
      except
        AResponse.Code := 400;
        AResponse.Content := '{"error":"page_body_invalid"}';
        Exit;
      end;
      FieldId := Obj.Get('page_id', '');
    finally
      Obj.Free;
    end;
    if Trim(FieldId) = '' then
    begin
      AResponse.Code := 400;
      AResponse.Content := '{"error":"page_request_incomplete"}';
      Exit;
    end;
    FLock.Enter;
    try
      Render := FOnSelectPage(FieldId);
    finally
      FLock.Leave;
    end;
    if Render.Failed then
      AResponse.Content := '{"error":"' + JsonEscapeText(Render.StableCode) + '"}'
    else
      AResponse.Content := Render.DataJson;
    AResponse.Code := 200;
    Exit;
  end;

  if (ARequest.Method = 'POST') and (Path = '/api/write') then
  begin
    // 写入必须走运行时受治理路径；未装配时一律拒绝（fail-closed）
    if FOnWrite = nil then
    begin
      AResponse.Code := 403;
      AResponse.Content := '{"error":"write_not_enabled"}';
      Exit;
    end;
    if ARequest.ContentLength > 64 * 1024 then
    begin
      AResponse.Code := 413;
      AResponse.Content := '{"error":"request_too_large"}';
      Exit;
    end;
    Body := ARequest.Content;
    Obj := nil;
    FieldId := '';
    TargetValue := '';
    ExpectedValue := '';
    try
      try
        Obj := TJSONObject(GetJSON(Body));
      except
        Obj := nil;
      end;
      if Obj = nil then
      begin
        AResponse.Code := 400;
        AResponse.Content := '{"error":"write_body_invalid"}';
        Exit;
      end;
      FieldId := Obj.Get('field_id', '');
      TargetValue := Obj.Get('target_value', '');
      ExpectedValue := Obj.Get('expected_current_value', '');
    finally
      Obj.Free;
    end;
    if (FieldId = '') or (TargetValue = '') then
    begin
      AResponse.Code := 400;
      AResponse.Content := '{"error":"write_request_incomplete"}';
      Exit;
    end;
    FLock.Enter;
    try
      WriteResult := FOnWrite(FieldId, TargetValue, ExpectedValue);
    finally
      FLock.Leave;
    end;
    AResponse.Code := 200;
    if WriteResult.Failed then
      AResponse.Content := '{"error":"' + JsonEscapeText(WriteResult.StableCode) + '"}'
    else
      AResponse.Content := WriteResult.DataJson;
    Exit;
  end;

  AResponse.Code := 404;
  AResponse.Content := '{"error":"not_found"}';
end;

function TCEASecondaryScreenHost.BuildPage(const AToken: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('<!DOCTYPE html>');
    L.Add('<html lang="zh-CN"><head><meta charset="utf-8">');
    L.Add('<meta name="viewport" content="width=device-width,initial-scale=1">');
    L.Add('<title>Game Companion Console - Secondary Screen</title>');
    L.Add('<style>');
    L.Add(':root{--bg:#0F0F23;--card:#1E1C35;--muted:#27273B;--fg:#E2E8F0;');
    L.Add('--dim:#9CA3AF;--border:#4C1D95;--primary:#7C3AED;--secondary:#A78BFA;');
    L.Add('--cta:#F43F5E;--danger:#EF4444;--ok:#34D399;--warn:#FBBF24;');
    L.Add('--space1:4px;--space2:8px;--space3:16px;--space4:24px;--space5:32px;}');
    L.Add('*{box-sizing:border-box;}');
    L.Add('html,body{margin:0;padding:0;background:var(--bg);color:var(--fg);');
    L.Add('font-family:"Fira Sans","Segoe UI","Microsoft YaHei",system-ui,sans-serif;');
    L.Add('font-size:14px;line-height:1.5;}');
    L.Add('code,.num,.mono{font-family:"Fira Code",Consolas,"Courier New",monospace;');
    L.Add('font-variant-numeric:tabular-nums;}');
    L.Add('header{position:sticky;top:0;z-index:2;display:flex;align-items:center;');
    L.Add('gap:var(--space3);flex-wrap:wrap;padding:var(--space3) var(--space4);');
    L.Add('background:var(--card);border-bottom:1px solid var(--border);}');
    L.Add('header h1{font-size:16px;margin:0;font-weight:600;letter-spacing:.2px;}');
    L.Add('.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;');
    L.Add('border-radius:999px;font-size:12px;border:1px solid var(--border);');
    L.Add('background:var(--muted);color:var(--dim);}');
    L.Add('.pill .dot{width:8px;height:8px;border-radius:50%;background:var(--dim);}');
    L.Add('.pill.ok .dot{background:var(--ok);}');
    L.Add('.pill.bad .dot{background:var(--danger);}');
    L.Add('main{padding:var(--space4);display:grid;gap:var(--space4);}');
    L.Add('section{background:var(--card);border:1px solid var(--border);');
    L.Add('border-radius:12px;padding:var(--space4);}');
    L.Add('section h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;');
    L.Add('color:var(--dim);margin:0 0 var(--space3) 0;font-weight:600;}');
    L.Add('.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));');
    L.Add('gap:var(--space3);}');
    L.Add('.card{background:var(--muted);border:1px solid var(--border);');
    L.Add('border-radius:10px;padding:var(--space3);display:flex;');
    L.Add('flex-direction:column;gap:var(--space2);}');
    L.Add('.card .title{font-size:13px;color:var(--dim);}');
    L.Add('.card .value{font-size:22px;font-weight:600;}');
    L.Add('.badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;');
    L.Add('padding:2px 8px;border-radius:6px;border:1px solid transparent;');
    L.Add('align-self:flex-start;}');
    L.Add('.badge .mark{font-weight:700;}');
    L.Add('.state-read_only{color:var(--secondary);border-color:var(--secondary);}');
    L.Add('.state-pending_write{color:var(--warn);border-color:var(--warn);}');
    L.Add('.state-verified_writable{color:var(--ok);border-color:var(--ok);}');
    L.Add('.state-invalid,.state-unknown{color:var(--danger);');
    L.Add('border-color:var(--danger);}');
    L.Add('button{min-height:44px;min-width:44px;padding:0 var(--space4);');
    L.Add('border-radius:8px;border:1px solid var(--border);background:var(--muted);');
    L.Add('color:var(--fg);font-size:14px;cursor:pointer;}');
    L.Add('button:hover{background:#2f2f47;}');
    L.Add('button:focus-visible{outline:2px solid var(--primary);outline-offset:2px;}');
    L.Add('button.cta{background:var(--cta);border-color:var(--cta);color:#fff;}');
    L.Add('button:disabled{opacity:.45;cursor:not-allowed;}');
    L.Add('input{min-height:44px;width:100%;padding:0 var(--space3);');
    L.Add('border-radius:8px;border:1px solid var(--border);background:var(--bg);');
    L.Add('color:var(--fg);font-family:"Fira Code",Consolas,monospace;}');
    L.Add('input:focus-visible{outline:2px solid var(--primary);outline-offset:1px;}');
    L.Add('select{min-height:44px;padding:0 var(--space3);border-radius:8px;');
    L.Add('border:1px solid var(--border);background:var(--muted);color:var(--fg);}');
    L.Add('select:focus-visible{outline:2px solid var(--primary);outline-offset:1px;}');
    L.Add('.row{display:flex;gap:var(--space2);align-items:center;}');
    L.Add('.hint{font-size:12px;color:var(--dim);}');
    L.Add('footer{position:sticky;bottom:0;background:var(--card);');
    L.Add('border-top:1px solid var(--border);padding:var(--space3) var(--space4);');
    L.Add('font-size:12px;color:var(--dim);min-height:44px;}');
    L.Add('.err{color:var(--danger);}');
    L.Add('@media (max-width:720px){main{padding:var(--space3);}');
    L.Add('header{padding:var(--space2) var(--space3);}}');
    L.Add('@media (prefers-reduced-motion:reduce){*{transition:none!important;}}');
    L.Add('</style></head><body>');
    L.Add('<header>');
    L.Add('<h1>Game Companion Console - Secondary Screen</h1>');
    L.Add('<span class="pill" id="conn"><span class="dot"></span>');
    L.Add('<span id="connText">Connecting</span></span>');
    L.Add('<span class="pill">Read-only first</span>');
    L.Add('<span class="hint" id="updated">not refreshed yet</span>');
    L.Add('<label class="hint" for="pageSel">Page</label>');
    L.Add('<select id="pageSel" aria-label="Secondary screen page">');
    L.Add('<option value="">Auto (current state)</option></select>');
    L.Add('</header>');
    L.Add('<main><section><h2>Page</h2><div id="sections"></div></section></main>');
    L.Add('<footer id="feedback">Ready. Writes require two-stage confirmation:');
    L.Add(' command sent, then read-back verified.</footer>');
    L.Add('<script>');
    L.Add('const TOKEN=' + '"' + JsonEscapeText(AToken) + '"' + ';');
    L.Add('const STATE_TEXT={read_only:"Read-only",pending_write:"Pending",');
    L.Add('verified_writable:"Writable",invalid:"Invalid",unknown:"Unknown"};');
    L.Add('const STATE_MARK={read_only:"[LOCK]",pending_write:"[WAIT]",');
    L.Add('verified_writable:"[EDIT]",invalid:"[!]",unknown:"[?]"};');
    L.Add('function el(tag,cls,text){const n=document.createElement(tag);');
    L.Add('if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n;}');
    L.Add('function feedback(msg,isErr){const f=document.getElementById("feedback");');
    L.Add('f.textContent=msg;f.className=isErr?"err":"";}');
    L.Add('function badge(state){const b=el("span","badge state-"+state);');
    L.Add('b.appendChild(el("span","mark",STATE_MARK[state]||STATE_MARK.unknown));');
    L.Add('b.appendChild(el("span",null,STATE_TEXT[state]||STATE_TEXT.unknown));');
    L.Add('b.setAttribute("aria-label","field state: "+(STATE_TEXT[state]||"unknown"));');
    L.Add('return b;}');
    L.Add('function renderCard(c){');
    L.Add('const card=el("div","card");');
    L.Add('card.appendChild(el("div","title",c.title||c.component_id));');
    L.Add('const v=el("div","value mono",c.binding==="bound"?(c.field_value_json||"-"):"n/a");');
    L.Add('card.appendChild(v);');
    L.Add('card.appendChild(badge(c.semantic));');
    L.Add('if(c.disabled_reason){card.appendChild(el("div","hint","reason: "+c.disabled_reason));}');
    L.Add('if(c.editable){');
    L.Add('const row=el("div","row");');
    L.Add('const inp=el("input");inp.type="text";inp.placeholder="target value";');
    L.Add('inp.setAttribute("aria-label",(c.title||c.component_id)+" target value");');
    L.Add('const btn=el("button","cta","Apply");');
    L.Add('btn.onclick=function(){');
    L.Add('const target=inp.value.trim();');
    L.Add('if(!target){feedback("Enter a target value.",true);return;}');
    L.Add('const expected=(c.field_value_json||"").trim();');
    L.Add('const ok=window.confirm("Change "+c.title+" from "+expected+" to "+target+');
    L.Add('"?\\n\\nThe value will be re-read and verified after writing.\\n"');
    L.Add('+"The game may overwrite it at any time. Continue?");');
    L.Add('if(!ok)return;');
    L.Add('btn.disabled=true;');
    L.Add('feedback("Command sent, waiting for read-back verification...",false);');
    L.Add('fetch("/api/write?token="+encodeURIComponent(TOKEN),{method:"POST",');
    L.Add('headers:{"Content-Type":"application/json"},');
    L.Add('body:JSON.stringify({field_id:c.field_id,target_value:target,');
    L.Add('expected_current_value:expected})})');
    L.Add('.then(function(r){return r.json();})');
    L.Add('.then(function(d){btn.disabled=false;');
    L.Add('if(d.error){feedback("Write rejected: "+d.error,true);return;}');
    L.Add('if(d.verified===true){feedback("Verified: the field changed and read-back matched.",false);}');
    L.Add('else{feedback("Command sent but NOT verified as applied ("+');
    L.Add('(d.outcome||"unknown")+" / "+(d.stable_code||"")+"). "');
    L.Add('+"Trust the refreshed value.",true);}');
    L.Add('refresh();});');
    L.Add('.catch(function(e){btn.disabled=false;feedback("Write request failed: "+e,true);});');
    L.Add('};');
    L.Add('row.appendChild(inp);row.appendChild(btn);card.appendChild(row);}');
    L.Add('else if(c.semantic!=="verified_writable"){');
    L.Add('card.appendChild(el("div","hint",');
    L.Add('"Not verified via write -> read-back -> match, so no write control."));}');
    L.Add('return card;}');
    L.Add('function refresh(){');
    L.Add('fetch("/api/render?token="+encodeURIComponent(TOKEN))');
    L.Add('.then(function(r){return r.json();})');
    L.Add('.then(function(d){');
    L.Add('const conn=document.getElementById("conn");');
    L.Add('if(d.error){conn.className="pill bad";');
    L.Add('document.getElementById("connText").textContent="render failed: "+d.error;return;}');
    L.Add('conn.className="pill ok";');
    L.Add('document.getElementById("connText").textContent="connected";');
    L.Add('document.getElementById("updated").textContent=');
    L.Add('"updated "+new Date().toLocaleTimeString();');
    L.Add('const host=document.getElementById("sections");host.textContent="";');
    L.Add('(d.sections||[]).forEach(function(s){');
    L.Add('const sec=el("section");sec.appendChild(el("h2",null,s.title||s.section_id));');
    L.Add('const g=el("div","grid");');
    L.Add('(s.components||[]).forEach(function(c){g.appendChild(renderCard(c));});');
    L.Add('sec.appendChild(g);host.appendChild(sec);});');
    L.Add('}).catch(function(e){const conn=document.getElementById("conn");');
    L.Add('conn.className="pill bad";');
    L.Add('document.getElementById("connText").textContent="disconnected";});}');
    L.Add('function refreshPages(){');
    L.Add('fetch("/api/pages?token="+encodeURIComponent(TOKEN))');
    L.Add('.then(function(r){return r.json();})');
    L.Add('.then(function(d){const sel=document.getElementById("pageSel");');
    L.Add('if(!sel||!d.pages)return;const keep=sel.value;');
    L.Add('while(sel.options.length>1)sel.remove(1);');
    L.Add('d.pages.forEach(function(p){const o=document.createElement("option");');
    L.Add('o.value=p.page_id;o.textContent=(p.title||p.page_id)+');
    L.Add('" (v"+p.version+")";sel.appendChild(o);});');
    L.Add('if(keep){for(let i=0;i<sel.options.length;i++){');
    L.Add('if(sel.options[i].value===keep){sel.selectedIndex=i;break;}}}})');
    L.Add('.catch(function(){});}');
    L.Add('document.getElementById("pageSel").onchange=function(){');
    L.Add('const id=this.value;');
    L.Add('if(!id){feedback("Auto page: rendering current state.",false);refresh();return;}');
    L.Add('fetch("/api/page?token="+encodeURIComponent(TOKEN),{method:"POST",');
    L.Add('headers:{"Content-Type":"application/json"},');
    L.Add('body:JSON.stringify({page_id:id})})');
    L.Add('.then(function(r){return r.json();})');
    L.Add('.then(function(d){if(d.error){feedback("Page switch rejected: "+d.error,true);}');
    L.Add('else{feedback("Page switched: "+(d.page_id||id)+".",false);}refresh();})');
    L.Add('.catch(function(e){feedback("Page switch failed: "+e,true);});};');
    L.Add('refreshPages();setInterval(refreshPages,10000);');
    L.Add('refresh();setInterval(refresh,1000);');
    L.Add('</script></body></html>');
    Result := L.Text;
  finally
    L.Free;
  end;
end;

end.

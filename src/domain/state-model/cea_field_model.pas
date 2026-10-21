unit cea_field_model;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  // 字段读写能力（PRD 6.5 FR-040 / 8.4 access）
  TCEAFieldAccess = (
    faReadOnly,        // read_only：默认，仅展示
    faPendingWrite,    // pending_write：可写待验证
    faVerifiedWritable,// verified_writable：已验证可写
    faInvalid          // invalid：版本失效/结构不匹配
  );

  // 字段验证状态（PRD 6.9 FR-091 证据分级 / 8.4 validation_status）
  TCEAValidationStatus = (
    vsObserved,        // observed：直接采集的事实
    vsHypothesis,      // hypothesis：AI 推断假设
    vsUserConfirmed,   // user_confirmed：用户确认
    vsVerified         // verified：重复验证通过
  );

  TCEAGameField = record
    FieldId: string;        // 稳定标识，如 "player.gold"
    DisplayName: string;    // 显示名，如 "金币"
    ValueType: string;      // integer / single / bool / enum / string
    ValueJson: string;      // 当前值（JSON 编码）
    Source: string;         // 数据来源：win32_memory / save_file / ...
    Confidence: Double;     // 0..1
    Access: TCEAFieldAccess;
    ValidationStatus: TCEAValidationStatus;
    LastUpdated: string;    // UTC ISO8601
    ConstraintsJson: string;// 范围/枚举约束（JSON）
    EvidenceRefsJson: string; // 证据引用（JSON 数组）
    AddressHex: string;     // 定位地址（win32_memory 来源；PRD 6.7 定位信息）
    // 指针链定位配方（可选）：模块名 + 偏移数组 + 地址宽度。填了就表示
    // AddressHex 是这条链在某次解析下的结果，而不是一个绝对地址。
    // 重解析会重新求值，因此字段可以跨进程重启继续用。
    ModuleName: string;
    PointerOffsetsJson: string;
    AddressWidthBits: Cardinal;
    function IsValid: Boolean;
    function HasPointerChain: Boolean;
  end;

  TCEAGameFieldArray = array of TCEAGameField;

  function FieldAccessText(const AAccess: TCEAFieldAccess): string;
  function TryParseFieldAccess(const AText: string;
    out AAccess: TCEAFieldAccess): Boolean;
  function ValidationStatusText(
    const AStatus: TCEAValidationStatus): string;
  function TryParseValidationStatus(const AText: string;
    out AStatus: TCEAValidationStatus): Boolean;

implementation

function FieldAccessText(const AAccess: TCEAFieldAccess): string;
begin
  case AAccess of
    faReadOnly: Result := 'read_only';
    faPendingWrite: Result := 'pending_write';
    faVerifiedWritable: Result := 'verified_writable';
    faInvalid: Result := 'invalid';
  end;
end;

function TryParseFieldAccess(const AText: string;
  out AAccess: TCEAFieldAccess): Boolean;
var
  A: TCEAFieldAccess;
begin
  for A := Low(TCEAFieldAccess) to High(TCEAFieldAccess) do
    if FieldAccessText(A) = AText then
    begin
      AAccess := A;
      Exit(True);
    end;
  Result := False;
end;

function ValidationStatusText(
  const AStatus: TCEAValidationStatus): string;
begin
  case AStatus of
    vsObserved: Result := 'observed';
    vsHypothesis: Result := 'hypothesis';
    vsUserConfirmed: Result := 'user_confirmed';
    vsVerified: Result := 'verified';
  end;
end;

function TryParseValidationStatus(const AText: string;
  out AStatus: TCEAValidationStatus): Boolean;
var
  S: TCEAValidationStatus;
begin
  for S := Low(TCEAValidationStatus) to High(TCEAValidationStatus) do
    if ValidationStatusText(S) = AText then
    begin
      AStatus := S;
      Exit(True);
    end;
  Result := False;
end;

function TCEAGameField.IsValid: Boolean;
begin
  Result := (FieldId <> '') and (DisplayName <> '') and (ValueType <> '') and
    (Source <> '') and (LastUpdated <> '') and
    (Confidence >= 0.0) and (Confidence <= 1.0);
end;

function TCEAGameField.HasPointerChain: Boolean;
begin
  Result := (ModuleName <> '') and (PointerOffsetsJson <> '') and
    (AddressWidthBits in [32, 64]);
end;

end.

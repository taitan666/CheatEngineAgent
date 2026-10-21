unit cea_command_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  // 字段级写入命令（PRD 8.5.5）：不接受裸地址/裸命令
  TCEAFieldWriteCommand = record
    FieldId: string;              // 稳定字段标识，如 "player.gold"
    ValueType: string;            // integer / single / bool / enum / string
    TargetValue: string;          // 目标值（文本，经 EncodeExactValue 编码）
    ExpectedCurrentValue: string; // 预期原值（写入前校验，防状态冲突）
    ProfileId: string;            // Game Profile 标识（版本绑定）
    AddressHex: string;           // 字段定位地址（来自已验证字段定义）
    function IsValid: Boolean;
  end;

  // 命令执行结果（两级反馈，PRD 7.4 / FR-044 / AC-015）
  TCEACommandOutcome = (
    coSubmitted,    // 命令已发送，等待验证
    coVerified,     // 重读验证成功
    coRejected,     // 校验拒绝（权限/类型/范围/版本）
    coSentNotApplied,// 命令已发送但状态未改变
    coOverwritten,  // 状态已改变但与目标值不一致（被游戏覆盖）
    coVersionMismatch // 版本失效
  );

  TCEAFieldWriteResult = record
    Outcome: TCEACommandOutcome;
    StableCode: string;
    DetailJson: string;   // 前后值、读回结果等
    ReceiptId: string;
    ProofId: string;
  end;

  function CommandOutcomeText(const AOutcome: TCEACommandOutcome): string;

implementation

function TCEAFieldWriteCommand.IsValid: Boolean;
begin
  Result := (FieldId <> '') and (ValueType <> '') and
    (TargetValue <> '') and (ExpectedCurrentValue <> '') and
    (AddressHex <> '');
end;

function CommandOutcomeText(const AOutcome: TCEACommandOutcome): string;
begin
  case AOutcome of
    coSubmitted: Result := 'submitted';
    coVerified: Result := 'verified';
    coRejected: Result := 'rejected';
    coSentNotApplied: Result := 'sent_not_applied';
    coOverwritten: Result := 'overwritten';
    coVersionMismatch: Result := 'version_mismatch';
  end;
end;

end.

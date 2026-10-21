unit cea_write_journal_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, cea_results;

type
  // FR-046 (PRD 6.5) 操作历史：每次字段写入都要留下时间、字段、原值、
  // 目标值、适配器、结果与错误信息。
  //
  // 为什么单独建一条日志：玩家日常写入走的是 TCEAFieldCommandBus
  // （命令总线 -> 裸 Win32 CompareWriteReadback），它不经过
  // Effect -> Approval -> Receipt -> Proof 那条治理链路，
  // 所以治理账本里根本没有这些写入的记录。这条日志是玩家写入
  // 唯一的持久审计面。
  TCEAFieldWriteRecord = record
    RecordId: string;        // 稳定标识 "write-XXXXXXXX"
    Sequence: Int64;         // 单调递增序号（库内自增）
    FieldId: string;
    DisplayName: string;
    ValueType: string;
    // 原值：操作者断言写入前应有的值（expected_current_value）。
    // 真实前值在 DetailJson 的 before 字段里，这里存断言值，
    // 因为冲突检测（FR-045）比较的正是断言值与实际值。
    OriginalValue: string;
    TargetValue: string;
    // 适配器：真正执行写入的组件标识，便于区分两条写入路径
    AdapterId: string;
    AddressHex: string;
    ProcessIdentityId: string;
    Pid: Cardinal;
    Epoch: QWord;
    // 结果：submitted / verified / rejected / sent_not_applied /
    // overwritten / version_mismatch（与 TCEACommandOutcome 文本一致）
    Outcome: string;
    StableCode: string;
    ErrorText: string;
    DetailJson: string;
    CommandSent: Boolean;    // 命令是否已发到目标进程
    Verified: Boolean;       // 写入后重读是否与目标值一致
    RecordedAt: string;      // UTC ISO8601
    function IsValid: Boolean;
  end;

  TCEAFieldWriteRecordArray = array of TCEAFieldWriteRecord;

  // 写入日志仓储。实现失败不得阻断写入本身（写入已经发生），
  // 但调用方必须把 journal_recorded 一并回报给操作者。
  ICEAWriteJournalStore = interface
    ['{6F1B7A2C-9D34-4E58-8C71-2A5F0D9B3E44}']
    function Initialize: TCEAResult;
    function AppendWrite(const ARecord: TCEAFieldWriteRecord;
      out ARecordId: string): TCEAResult;
    function ListWrites(const AFieldId: string; const ALimit: Integer;
      out ARecords: TCEAFieldWriteRecordArray): TCEAResult;
    function CountWrites(out ACount: Integer): TCEAResult;
  end;

const
  // 适配器标识：两条写入路径必须能区分，否则审计里看不出是谁动的手
  CeaWriteAdapterCommandBus = 'command_bus/win32_compare_write_readback';
  CeaWriteAdapterDirectVerify = 'direct_verify/win32_compare_write_readback';

  CeaWriteJournalDefaultLimit = 50;
  CeaWriteJournalMaxLimit = 500;

implementation

function TCEAFieldWriteRecord.IsValid: Boolean;
begin
  // 只校验「这条记录说的是哪次写入」的最小集合。Outcome 允许为空
  // （写入在到达命令总线之前就失败时，没有 outcome 可记）。
  Result := (RecordId <> '') and (FieldId <> '') and (AdapterId <> '') and
    (RecordedAt <> '');
end;

end.

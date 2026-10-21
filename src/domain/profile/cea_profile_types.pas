unit cea_profile_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_field_model;

type
  // Game Profile：某款游戏 + 特定版本对应的字段映射、UI Schema、验证证据
  // （对齐 PRD 6.7 FR-060）
  TCEAGameProfile = record
    Id: string;               // 稳定标识（内容哈希派生）
    GameName: string;
    GameVersion: string;
    ExecutableSha256: string; // 版本指纹（加载前兼容性检测）
    ModuleSetHash: string;
    ConnectorType: string;    // 连接器类型（win32_memory / save_file / ...）
    FieldsJson: string;       // 字段集合（JSON 数组）
    UiSchemaJson: string;     // UI Schema（JSON，可空）
    EvidenceJson: string;     // 验证证据（JSON，可空）
    CreatedAt: string;        // UTC ISO8601
    UpdatedAt: string;
    LastVerifiedAt: string;   // 最近验证时间
    InvalidationReason: string; // 失效原因（空 = 有效）
    function IsValid: Boolean;
  end;

  TCEAGameProfileArray = array of TCEAGameProfile;

  // Profile 兼容性检测结果（PRD 6.7 FR-061/062）
  TCEAProfileMatchResult = record
    Compatible: Boolean;
    Reason: string;           // 不兼容原因（空 = 兼容）
  end;

implementation

function TCEAGameProfile.IsValid: Boolean;
begin
  Result := (Id <> '') and (GameName <> '') and
    (ExecutableSha256 <> '') and (ConnectorType <> '') and
    (FieldsJson <> '') and (CreatedAt <> '');
end;

end.

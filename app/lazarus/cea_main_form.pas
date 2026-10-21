unit cea_main_form;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, FPJSON, JSONParser, Forms, Controls, StdCtrls,
  ExtCtrls, ComCtrls, Dialogs, LCLIntf,
  cea_types, cea_results, cea_llm_provider, cea_application_runtime,
  cea_save_types, cea_save_discovery_types, cea_value_scan_ui_model,
  cea_release_identity, cea_pointer_chain;
type
  TCEALLMWorker = class(TThread, ICEALLMTextStreamSink)
  private
    FRuntime: TCEAStandaloneRuntime;
    FPrompt: string;
    FRagContextJson: string;
    FCancellation: ICEACancellationToken;
    FResult: TCEAResult;
    FCompleted: LongInt;
    FStreamLock: TRTLCriticalSection;
    FStreamText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARuntime: TCEAStandaloneRuntime;
      const APrompt, ARagContextJson: string;
      const ACancellation: ICEACancellationToken);
    destructor Destroy; override;
    function Completed: Boolean;
    procedure OnTextDelta(const AText: string);
    function StreamText: string;
    property InvokeResult: TCEAResult read FResult;
  end;

  TCEASaveDiscoveryWorker = class(TThread)
  private
    FRuntime: TCEAStandaloneRuntime;
    FScopeId: string;
    FResult: TCEAResult;
    FCandidates: TCEASaveCandidateArray;
    FCompleted: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARuntime: TCEAStandaloneRuntime;
      const AScopeId: string);
    function Completed: Boolean;
    property ScanResult: TCEAResult read FResult;
    property Candidates: TCEASaveCandidateArray read FCandidates;
  end;

  TCEAMainForm = class(TForm)
  private
    FRuntime: TCEAStandaloneRuntime;
    FPumpTimer: TTimer;
    FStatusLabel: TLabel;
    FOutputMemo: TMemo;
    FPidEdit: TEdit;
    FAddressEdit: TEdit;
    FExpectedEdit: TEdit;
    FReplacementEdit: TEdit;
    FFreezeIntervalEdit: TEdit;
    FFreezeMaxWritesEdit: TEdit;
    FFreezeDurationEdit: TEdit;
    FEffectIdEdit: TEdit;
    FCTPathEdit: TEdit;
    FCTQueryEdit: TEdit;
    FCTMemo: TMemo;
    FSavePathEdit: TEdit;
    FSaveMemo: TMemo;
    FSaveDiscoveryRootEdit: TEdit;
    FSaveDiscoveryList: TListBox;
    FSaveDiscoveryScanButton: TButton;
    FSaveDiscoveryCancelButton: TButton;
    FSaveDiscoveryRevokeButton: TButton;
    FSaveDiscoveryInspectButton: TButton;
    FSaveDiscoveryScope: TCEADiscoveryScope;
    FSaveDiscoveryCandidates: TCEASaveCandidateArray;
    FSaveDiscoveryWorker: TCEASaveDiscoveryWorker;
    FSaveBackupButton: TButton;
    FSaveEditButton: TButton;
    FSaveRestoreButton: TButton;
    FSaveProposeButton: TButton;
    FSaveFieldEdit: TEdit;
    FSaveExpectedEdit: TEdit;
    FSaveNewEdit: TEdit;
    FSaveMCPIdEdit: TEdit;
    FSaveSnapshot: TCEASaveSnapshot;
    FSaveProposal: TCEASaveEditProposal;
    FSaveBackupEffectId: string;
    FLLMEndpointEdit: TEdit;
    FLLMProviderBox: TComboBox;
    FLLMModelEdit: TEdit;
    FLLMSecretRefEdit: TEdit;
    FLLMApiKeyEdit: TEdit;
    FLLMQueryEdit: TEdit;
    FLLMPromptMemo: TMemo;
    FLLMOutputMemo: TMemo;
    FLLMRunButton: TButton;
    FLLMCancelButton: TButton;
    FLLMWorker: TCEALLMWorker;
    FLLMCancellation: TCEACancellationToken;
    FMCPMemo: TMemo;
    FAttachedIdentity: TCEProcessIdentity;
    FScanStartEdit: TEdit;
    FScanSizeEdit: TEdit;
    FScanValueEdit: TEdit;
    FScanMaxResultsEdit: TEdit;
    FScanValueTypeBox: TComboBox;
    FScanRegionKindsBox: TComboBox;
    FScanCoverageLabel: TLabel;
    FScanScopeLabel: TLabel;
    FScanScopeRevokeButton: TButton;
    FScanScopeId: string;
    FScanRefineButton: TButton;
    FScanCancelButton: TButton;
    { AOB 签名扫描：唯一性通过后，签名才能作为写入锚点（真实写入验证前置）。 }
    FScanModuleEdit: TEdit;
    FScanAobEdit: TEdit;
    FScanAobJudgeButton: TButton;
    FScanAobLabel: TLabel;
    FScanIsAob: Boolean;
    FScanId: string;
    FScanTypeAtStart: string;
    { 1H 玩家工作台（PRD 7.5 三栏）：左栏导航 / 中栏内容 / 右栏详情。 }
    FGameNameEdit: TEdit;
    FGameVersionEdit: TEdit;
    FPlayerStatusLabel: TLabel;
    FPlayerNav: TListBox;
    FPlayerOutputMemo: TMemo;
    FPlayerDetailMemo: TMemo;
    FSecOverview: TPanel;
    FSecFields: TPanel;
    FSecWrite: TPanel;
    FSecDiscovery: TPanel;
    FSecEvents: TPanel;
    FSecSecondary: TPanel;
    { CE 下载：GCM 目录匹配 + 本地文件库复用 + 手动导入发布（Phase A–D）。 }
    FSecGcm: TPanel;
    FGcmQueryEdit: TEdit;
    FGcmProcessEdit: TEdit;
    FGcmMemo: TMemo;
    FSecSettings: TPanel;
    FFieldIdEdit: TEdit;
    FFieldNameEdit: TEdit;
    FFieldTypeBox: TComboBox;
    FFieldAddressEdit: TEdit;
    { 指针链字段：从 CT 条目取现成链，或手填 模块 + 偏移。 }
    FFieldChainEntryEdit: TEdit;
    FFieldChainModuleEdit: TEdit;
    FFieldChainOffsetsEdit: TEdit;
    FFieldChainButton: TButton;
    { Game Profile：存档当前字段集合，按游戏名还原。 }
    FProfileNameEdit: TEdit;
    FProfileRestoreButton: TButton;
    FFieldList: TListBox;
    FFieldIds: TStringList;
    FSelectedFieldLabel: TLabel;
    FFieldTargetEdit: TEdit;
    FFieldExpectedEdit: TEdit;
    FEventTagEdit: TEdit;
    { PRD 6.9 事件分析（FR-090~094）：本地分级与关联免费，外发模型要当场同意。 }
    FEventIdEdit: TEdit;
    FEventFieldEdit: TEdit;
    FEventAnalysisButton: TButton;
    FEventTrendButton: TButton;
    FEventCloudButton: TButton;
    FEventList: TListBox;
    FEventIds: TStringList;
  FRecordingStartButton: TButton;
  FRecordingStopButton: TButton;
  FRecordingRefreshButton: TButton;
  FRecordingLockButton: TButton;
  FRecordingList: TListBox;
  FRecordingSegmentIds: TStringList;
  FRecordingStatusLabel: TLabel;
    { FR-046 操作历史：每一次真实写入都留一条可审计记录。 }
    FWriteHistoryList: TListBox;
    FWriteHistoryJson: TStringList;
    { FR-052 证据记录：采集/验证/操作者陈述各自留痕，并标明是否支撑可写结论。 }
    FFieldEvidenceList: TListBox;
    FFieldEvidenceJson: TStringList;
    { FR-041 输入校验：字段可接受的范围/枚举，写前在本地校验。 }
    FFieldConstraintsEdit: TEdit;
    FFieldConstraintsStatusLabel: TLabel;
    { FR-051 分轮验证：先声明这一轮要做什么、预期看到什么，再动手。 }
    FDiscoveryKindBox: TComboBox;
    FDiscoveryPurposeEdit: TEdit;
    FDiscoveryOperationEdit: TEdit;
    FDiscoveryExpectedEdit: TEdit;
    FDiscoveryFieldEdit: TEdit;
    FDiscoveryRoundIdEdit: TEdit;
    FDiscoveryOutcomeEdit: TEdit;
    FDiscoveryMatchedCheck: TCheckBox;
    FDiscoveryRoundList: TListBox;
    FDiscoveryRoundJson: TStringList;
    FDiscoveryRoundIds: TStringList;
    { FR-050 目标描述：操作者用自己的话描述想找什么。目标只是意图，
      接受目标不授权扫描也不授权写入。 }
    FGoalDescriptionEdit: TEdit;
    FGoalValueTypeBox: TComboBox;
    FGoalBehaviorBox: TComboBox;
    FGoalFieldHintEdit: TEdit;
    FGoalIdEdit: TEdit;
    FGoalRejectReasonEdit: TEdit;
    FGoalList: TListBox;
    FGoalJson: TStringList;
    FGoalIds: TStringList;
    FGoalStatusLabel: TLabel;
    FSecondaryStatusLabel: TLabel;
    FSecondaryStartButton: TButton;
    FSecondaryStopButton: TButton;
    FSecondaryOpenButton: TButton;
    { 1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025/026/033）。 }
    FPageIdEdit: TEdit;
    FPageTitleEdit: TEdit;
    FPageCombo: TComboBox;
    FPageIds: TStringList;
    FPageVersionEdit: TEdit;
    FPageInstructionEdit: TEdit;
    FPageProposalId: string;
    procedure SavePlayerPage(Sender: TObject);
    procedure ListPlayerPages(Sender: TObject);
    procedure SetSecondaryScreenPage(Sender: TObject);
    procedure ListPlayerPageVersions(Sender: TObject);
    procedure RestorePlayerPageVersion(Sender: TObject);
    procedure ProposePlayerPage(Sender: TObject);
    procedure ConfirmPlayerPageProposal(Sender: TObject);
    procedure RejectPlayerPageProposal(Sender: TObject);
    procedure SearchGcmGames(Sender: TObject);
    procedure MatchGcmProcess(Sender: TObject);
    procedure ScanGcmCheatFiles(Sender: TObject);
    procedure ListPublishedCheatFiles(Sender: TObject);
    procedure ImportCheatFileIntoLibrary(Sender: TObject);
    procedure PublishCheatFileToLibrary(Sender: TObject);
    procedure PlayerNavChange(Sender: TObject);
    procedure StartGameSession(Sender: TObject);
    procedure DeclareField(Sender: TObject);
    procedure DeclareChainFromCT(Sender: TObject);
    procedure LoadChainFromSelectedCTEntry(Sender: TObject);
    procedure SaveGameProfileClick(Sender: TObject);
    procedure RestoreGameProfileClick(Sender: TObject);
    procedure RefreshPlayerFields(Sender: TObject);
    procedure CaptureSelectedField(Sender: TObject);
    procedure VerifySelectedFieldWritable(Sender: TObject);
    procedure WriteSelectedField(Sender: TObject);
    procedure RenderSecondaryScreen(Sender: TObject);
    procedure EnumerateDisplays(Sender: TObject);
    procedure SavePlayerPlacement(Sender: TObject);
    procedure LoadPlayerPlacement(Sender: TObject);
    procedure StartSecondaryScreen(Sender: TObject);
    procedure StopSecondaryScreen(Sender: TObject);
    procedure OpenSecondaryScreen(Sender: TObject);
    procedure UpdateSecondaryStatus;
    procedure MarkPlayerEvent(Sender: TObject);
    procedure ShowPlayerEvents(Sender: TObject);
    procedure SelectPlayerEvent(Sender: TObject);
    procedure AnalyzePlayerEvent(Sender: TObject);
    procedure ShowPlayerEventTrend(Sender: TObject);
    procedure AnalyzePlayerEventWithModel(Sender: TObject);
    procedure StartPlayerRecording(Sender: TObject);
    procedure StopPlayerRecording(Sender: TObject);
    procedure RefreshRecordingSegments(Sender: TObject);
    procedure ToggleRecordingSegmentLock(Sender: TObject);
    procedure UpdateRecordingStatus;
    procedure ShowRecordingSegments(const ADataJson: string);
    procedure ShowFieldWriteHistory(Sender: TObject);
    procedure SelectFieldWriteHistory(Sender: TObject);
    procedure ShowFieldEvidence(Sender: TObject);
    procedure SelectFieldEvidence(Sender: TObject);
    procedure SaveFieldConstraints(Sender: TObject);
    procedure ClearFieldConstraints(Sender: TObject);
    procedure PlanDiscoveryRoundClick(Sender: TObject);
    procedure CompleteDiscoveryRoundClick(Sender: TObject);
    procedure AbandonDiscoveryRoundClick(Sender: TObject);
    procedure ShowCurrentDiscoveryRound(Sender: TObject);
    procedure ShowDiscoveryRounds(Sender: TObject);
    procedure SelectDiscoveryRound(Sender: TObject);
    procedure ProposeGoalClick(Sender: TObject);
    procedure AcceptGoalClick(Sender: TObject);
    procedure RejectGoalClick(Sender: TObject);
    procedure ShowCurrentGoal(Sender: TObject);
    procedure ShowGoalList(Sender: TObject);
    procedure SelectGoal(Sender: TObject);
    procedure ConfirmFieldAsOperator(Sender: TObject);
    procedure SelectPlayerSection(const AIndex: Integer);
    procedure UpdatePlayerDetail;
    function SelectedFieldId: string;
    procedure RefreshProcesses(Sender: TObject);
    procedure AttachProcess(Sender: TObject);
    procedure StartValueScan(Sender: TObject);
    procedure StartProcessValueScan(Sender: TObject);
    procedure StartAobSignatureScan(Sender: TObject);
    procedure JudgeAobUniqueness(Sender: TObject);
    procedure PollValueScan;
    procedure AuthorizeMCPValueScanScope(Sender: TObject);
    procedure RevokeMCPValueScanScope(Sender: TObject);
    procedure RefineValueScan(Sender: TObject);
    procedure CancelValueScan(Sender: TObject);
    procedure PlanMemoryWrite(Sender: TObject);
    procedure PlanMemoryFreeze(Sender: TObject);
    procedure StopMemoryFreeze(Sender: TObject);
    procedure ReconcileEffect(Sender: TObject);
    procedure BrowseAndImportCT(Sender: TObject);
    procedure SearchCT(Sender: TObject);
    procedure TranslateCTDescriptions(Sender: TObject);
    procedure BrowseAndInspectSave(Sender: TObject);
    procedure BrowseAndScanSaveDirectory(Sender: TObject);
    procedure CancelSaveDirectoryScan(Sender: TObject);
    procedure RevokeSaveDirectoryScope(Sender: TObject);
    procedure InspectDiscoveredSave(Sender: TObject);
    procedure CompleteSaveDiscoveryIfReady;
    procedure ResetSaveSelection;
    procedure PresentSaveSnapshot(const ASnapshot: TCEASaveSnapshot;
      const ADisplayPath: string);
    procedure BackupSave(Sender: TObject);
    procedure ProposeSaveEdit(Sender: TObject);
    procedure ApproveSaveEdit(Sender: TObject);
    procedure RestoreSave(Sender: TObject);
    procedure ApproveRequestedBackup(Sender: TObject);
    procedure EmergencyStop(Sender: TObject);
    procedure RunLLM(Sender: TObject);
    procedure CancelLLM(Sender: TObject);
    procedure CompleteLLMIfReady;
    procedure SaveLLMCredential(Sender: TObject);
    procedure PumpTimerTick(Sender: TObject);
    procedure AddPlaceholder(const APage: TTabSheet;
      const AText: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  CEAMainForm: TCEAMainForm;

implementation

constructor TCEALLMWorker.Create(const ARuntime: TCEAStandaloneRuntime;
  const APrompt, ARagContextJson: string;
  const ACancellation: ICEACancellationToken);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRuntime := ARuntime;
  FPrompt := APrompt;
  FRagContextJson := ARagContextJson;
  FCancellation := ACancellation;
  InitCriticalSection(FStreamLock);
end;

destructor TCEALLMWorker.Destroy;
begin
  DoneCriticalSection(FStreamLock);
  inherited Destroy;
end;

procedure TCEALLMWorker.Execute;
begin
  try
    FResult := FRuntime.ChatWithContext(FPrompt, FRagContextJson,
      FCancellation, Self);
  except
    on E: Exception do
      FResult := TCEAResult.Error(rcInternalError,
        'model_worker_exception', '{}');
  end;
  InterlockedExchange(FCompleted, 1);
end;

procedure TCEALLMWorker.OnTextDelta(const AText: string);
begin
  EnterCriticalSection(FStreamLock);
  try
    FStreamText := FStreamText + AText;
  finally
    LeaveCriticalSection(FStreamLock);
  end;
end;

function TCEALLMWorker.StreamText: string;
begin
  EnterCriticalSection(FStreamLock);
  try
    Result := FStreamText;
  finally
    LeaveCriticalSection(FStreamLock);
  end;
end;

function TCEALLMWorker.Completed: Boolean;
begin
  Result := InterlockedCompareExchange(FCompleted, 0, 0) <> 0;
end;

constructor TCEASaveDiscoveryWorker.Create(
  const ARuntime: TCEAStandaloneRuntime; const AScopeId: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FRuntime := ARuntime;
  FScopeId := AScopeId;
end;

procedure TCEASaveDiscoveryWorker.Execute;
begin
  try
    FResult := FRuntime.ScanSaveDirectory(FScopeId, FCandidates);
  except
    on E: Exception do
      FResult := TCEAResult.Error(rcInternalError,
        'save_discovery_worker_exception', '{}');
  end;
  InterlockedExchange(FCompleted, 1);
end;

function TCEASaveDiscoveryWorker.Completed: Boolean;
begin
  Result := InterlockedCompareExchange(FCompleted, 0, 0) <> 0;
end;

constructor TCEAMainForm.Create(AOwner: TComponent);
var
  Header: TPanel;
  RefreshButton, AttachButton, WriteButton, FreezeButton, StopFreezeButton,
    RecoveryButton, SaveSecretButton, StopButton, TranslateButton: TButton;
  ProcessTools, ScanTools, WriteTools, CTTools, LLMTools, SaveTools: TPanel;
  FieldLabel: TLabel;
  Pages: TPageControl;
  AgentPage, ProcessPage, CTPage, SavePage, LLMPage, MCPPage,
    SecurityPage: TTabSheet;
  SecurityMemo: TMemo;
  ReleaseReader: TCEAReleaseIdentity;
  ReleaseInfo: TCEAReleaseIdentityInfo;
  ReleaseResult: TCEAResult;
  StartResult: TCEAResult;
  PlayerTab: TTabSheet;
  PlayerNavPanel, PlayerDetailPanel, PlayerTopPanel, PlayerCenterPanel: TPanel;
  PlayerHeaderLabel, PlayerPageLabel: TLabel;
  Button: TButton;
begin
  inherited Create(AOwner);
  Caption := 'Game Companion Console';
  Width := 1100;
  Height := 720;
  Position := poScreenCenter;

  Header := TPanel.Create(Self);
  Header.Parent := Self;
  Header.Align := alTop;
  Header.Height := 48;
  Header.BevelOuter := bvNone;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Header;
  FStatusLabel.Left := 16;
  FStatusLabel.Top := 16;
  FStatusLabel.Caption := '治理服务：正在启动';

  RefreshButton := TButton.Create(Self);
  RefreshButton.Parent := Header;
  RefreshButton.Align := alRight;
  RefreshButton.Width := 140;
  RefreshButton.Caption := '刷新进程';
  RefreshButton.OnClick := @RefreshProcesses;

  StopButton := TButton.Create(Self);
  StopButton.Parent := Header;
  StopButton.Align := alRight;
  StopButton.Width := 140;
  StopButton.Caption := '紧急停止';
  StopButton.OnClick := @EmergencyStop;

  Pages := TPageControl.Create(Self);
  Pages.Parent := Self;
  Pages.Align := alClient;

  { ---------------------------------------------------------------------
    1H 玩家工作台：PRD 7.5 三栏线框。左栏导航 / 中栏内容 / 右栏详情。
    现有 7 个诊断页保留为次级页签，不再作为主入口。
    --------------------------------------------------------------------- }
  PlayerTab := TTabSheet.Create(Self);
  PlayerTab.PageControl := Pages;
  PlayerTab.Caption := '玩家工作台';

  PlayerTopPanel := TPanel.Create(Self);
  PlayerTopPanel.Parent := PlayerTab;
  PlayerTopPanel.Align := alTop;
  PlayerTopPanel.Height := 44;
  PlayerTopPanel.BevelOuter := bvNone;
  PlayerHeaderLabel := TLabel.Create(Self);
  PlayerHeaderLabel.Parent := PlayerTopPanel;
  PlayerHeaderLabel.Left := 12;
  PlayerHeaderLabel.Top := 14;
  PlayerHeaderLabel.Caption := '游戏:';
  FGameNameEdit := TEdit.Create(Self);
  FGameNameEdit.Parent := PlayerTopPanel;
  FGameNameEdit.Left := 52;
  FGameNameEdit.Top := 10;
  FGameNameEdit.Width := 200;
  FGameNameEdit.TextHint := '游戏名称';
  PlayerPageLabel := TLabel.Create(Self);
  PlayerPageLabel.Parent := PlayerTopPanel;
  PlayerPageLabel.Left := 262;
  PlayerPageLabel.Top := 14;
  PlayerPageLabel.Caption := '版本:';
  FGameVersionEdit := TEdit.Create(Self);
  FGameVersionEdit.Parent := PlayerTopPanel;
  FGameVersionEdit.Left := 302;
  FGameVersionEdit.Top := 10;
  FGameVersionEdit.Width := 120;
  FGameVersionEdit.TextHint := '版本';
  Button := TButton.Create(Self);
  Button.Parent := PlayerTopPanel;
  Button.Left := 434;
  Button.Top := 8;
  Button.Width := 190;
  Button.Caption := '开始游戏会话（读当前进程）';
  Button.OnClick := @StartGameSession;
  FPlayerStatusLabel := TLabel.Create(Self);
  FPlayerStatusLabel.Parent := PlayerTopPanel;
  FPlayerStatusLabel.Left := 634;
  FPlayerStatusLabel.Top := 14;
  FPlayerStatusLabel.Caption := '会话未开始';
  FPlayerStatusLabel.AutoSize := True;

  PlayerNavPanel := TPanel.Create(Self);
  PlayerNavPanel.Parent := PlayerTab;
  PlayerNavPanel.Align := alLeft;
  PlayerNavPanel.Width := 168;
  PlayerNavPanel.BevelOuter := bvNone;
  FPlayerNav := TListBox.Create(Self);
  FPlayerNav.Parent := PlayerNavPanel;
  FPlayerNav.Align := alClient;
  FPlayerNav.Items.Add('游戏概览');
  FPlayerNav.Items.Add('游戏字段');
  FPlayerNav.Items.Add('写入验证');
  FPlayerNav.Items.Add('事件证据');
  FPlayerNav.Items.Add('分轮计划');
  FPlayerNav.Items.Add('副屏页面');
  FPlayerNav.Items.Add('CE 文件库');
  FPlayerNav.Items.Add('设置与诊断');
  FPlayerNav.ItemIndex := 0;
  FPlayerNav.OnClick := @PlayerNavChange;

  PlayerDetailPanel := TPanel.Create(Self);
  PlayerDetailPanel.Parent := PlayerTab;
  PlayerDetailPanel.Align := alRight;
  PlayerDetailPanel.Width := 320;
  PlayerDetailPanel.BevelOuter := bvNone;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := PlayerDetailPanel;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '字段详情（语义 / 类型 / 来源 / 状态）';
  FPlayerDetailMemo := TMemo.Create(Self);
  FPlayerDetailMemo.Parent := PlayerDetailPanel;
  FPlayerDetailMemo.Left := 8;
  FPlayerDetailMemo.Top := 32;
  FPlayerDetailMemo.Width := 304;
  FPlayerDetailMemo.Height := 400;
  FPlayerDetailMemo.Anchors := [akLeft, akTop, akRight, akBottom];
  FPlayerDetailMemo.ReadOnly := True;
  FPlayerDetailMemo.ScrollBars := ssAutoBoth;
  FPlayerDetailMemo.WordWrap := True;
  FPlayerDetailMemo.Text := '选择字段后显示其语义与可写状态。' + LineEnding +
    '只读 / 待验证字段不会出现可提交的写入入口（FR-022 / AC-005）。';

  PlayerCenterPanel := TPanel.Create(Self);
  PlayerCenterPanel.Parent := PlayerTab;
  PlayerCenterPanel.Align := alClient;
  PlayerCenterPanel.BevelOuter := bvNone;

  FSecOverview := TPanel.Create(Self);
  FSecOverview.Parent := PlayerCenterPanel;
  FSecOverview.Align := alClient;
  FSecOverview.BevelOuter := bvNone;
  FPlayerOutputMemo := TMemo.Create(Self);
  FPlayerOutputMemo.Parent := FSecOverview;
  FPlayerOutputMemo.Align := alClient;
  FPlayerOutputMemo.ReadOnly := True;
  FPlayerOutputMemo.ScrollBars := ssAutoBoth;
  FPlayerOutputMemo.WordWrap := False;
  FPlayerOutputMemo.Text := '开始游戏会话后，这里显示当前游戏状态与字段统计。';

  FSecFields := TPanel.Create(Self);
  FSecFields.Parent := PlayerCenterPanel;
  FSecFields.Align := alClient;
  FSecFields.BevelOuter := bvNone;
  FSecFields.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecFields;
  FieldLabel.Left := 12;
  FieldLabel.Top := 8;
  FieldLabel.Caption := '声明一个字段（人工确认的地址 → 语义字段映射）';
  FFieldIdEdit := TEdit.Create(Self);
  FFieldIdEdit.Parent := FSecFields;
  FFieldIdEdit.Left := 12;
  FFieldIdEdit.Top := 32;
  FFieldIdEdit.Width := 150;
  FFieldIdEdit.TextHint := 'player.geo';
  FFieldNameEdit := TEdit.Create(Self);
  FFieldNameEdit.Parent := FSecFields;
  FFieldNameEdit.Left := 168;
  FFieldNameEdit.Top := 32;
  FFieldNameEdit.Width := 150;
  FFieldNameEdit.TextHint := '显示名';
  FFieldTypeBox := TComboBox.Create(Self);
  FFieldTypeBox.Parent := FSecFields;
  FFieldTypeBox.Left := 324;
  FFieldTypeBox.Top := 32;
  FFieldTypeBox.Width := 100;
  FFieldTypeBox.Style := csDropDownList;
  FFieldTypeBox.Items.Add('byte');
  FFieldTypeBox.Items.Add('word');
  FFieldTypeBox.Items.Add('dword');
  FFieldTypeBox.Items.Add('qword');
  FFieldTypeBox.Items.Add('single');
  FFieldTypeBox.Items.Add('double');
  FFieldTypeBox.ItemIndex := 2;
  FFieldAddressEdit := TEdit.Create(Self);
  FFieldAddressEdit.Parent := FSecFields;
  FFieldAddressEdit.Left := 430;
  FFieldAddressEdit.Top := 32;
  FFieldAddressEdit.Width := 160;
  FFieldAddressEdit.TextHint := '0x...';
  Button := TButton.Create(Self);
  Button.Parent := FSecFields;
  Button.Left := 596;
  Button.Top := 30;
  Button.Width := 120;
  Button.Caption := '声明字段';
  Button.OnClick := @DeclareField;
  Button := TButton.Create(Self);
  Button.Parent := FSecFields;
  Button.Left := 722;
  Button.Top := 30;
  Button.Width := 120;
  Button.Caption := '刷新字段列表';
  Button.OnClick := @RefreshPlayerFields;
  FFieldList := TListBox.Create(Self);
  FFieldList.Parent := FSecFields;
  FFieldList.Left := 12;
  FFieldList.Top := 62;
  FFieldList.Width := 470;
  FFieldList.Height := 380;
  FFieldList.Anchors := [akLeft, akTop, akBottom];
  FFieldList.OnClick := @RefreshPlayerFields;
  FSelectedFieldLabel := TLabel.Create(Self);
  FSelectedFieldLabel.Parent := FSecFields;
  FSelectedFieldLabel.Left := 500;
  FSelectedFieldLabel.Top := 66;
  FSelectedFieldLabel.Caption := '当前字段：未选择';
  FSelectedFieldLabel.AutoSize := True;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecFields;
  FieldLabel.Left := 500;
  FieldLabel.Top := 92;
  FieldLabel.Caption := '当前值（读取后回填）:';
  FFieldExpectedEdit := TEdit.Create(Self);
  FFieldExpectedEdit.Parent := FSecFields;
  FFieldExpectedEdit.Left := 500;
  FFieldExpectedEdit.Top := 112;
  FFieldExpectedEdit.Width := 180;
  FFieldExpectedEdit.TextHint := '期望当前值';
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecFields;
  FieldLabel.Left := 500;
  FieldLabel.Top := 142;
  FieldLabel.Caption := '目标值:';
  FFieldTargetEdit := TEdit.Create(Self);
  FFieldTargetEdit.Parent := FSecFields;
  FFieldTargetEdit.Left := 500;
  FFieldTargetEdit.Top := 162;
  FFieldTargetEdit.Width := 180;
  FFieldTargetEdit.TextHint := '目标值';
  Button := TButton.Create(Self);
  Button.Parent := FSecFields;
  Button.Left := 500;
  Button.Top := 194;
  Button.Width := 180;
  Button.Caption := '读取当前值（采集）';
  Button.OnClick := @CaptureSelectedField;
  { 指针链：重启后地址会变，只有模块基址 + 偏移能重放。可以从已导入的
    CT 条目里直接取现成链，避免手工抄偏移抄错。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecFields;
  FieldLabel.Left := 500;
  FieldLabel.Top := 228;
  FieldLabel.Caption := '指针链：模块名 + 偏移（可先从 CT 条目填入）';
  FFieldChainModuleEdit := TEdit.Create(Self);
  FFieldChainModuleEdit.Parent := FSecFields;
  FFieldChainModuleEdit.Left := 500;
  FFieldChainModuleEdit.Top := 250;
  FFieldChainModuleEdit.Width := 180;
  FFieldChainModuleEdit.TextHint := '模块名，如 game.exe';
  FFieldChainOffsetsEdit := TEdit.Create(Self);
  FFieldChainOffsetsEdit.Parent := FSecFields;
  FFieldChainOffsetsEdit.Left := 690;
  FFieldChainOffsetsEdit.Top := 250;
  FFieldChainOffsetsEdit.Width := 230;
  FFieldChainOffsetsEdit.TextHint := '{"base":"0x20","offsets":["10","8"]}';
  FFieldChainEntryEdit := TEdit.Create(Self);
  FFieldChainEntryEdit.Parent := FSecFields;
  FFieldChainEntryEdit.Left := 500;
  FFieldChainEntryEdit.Top := 280;
  FFieldChainEntryEdit.Width := 180;
  FFieldChainEntryEdit.TextHint := 'CT entry_key';
  FFieldChainButton := TButton.Create(Self);
  FFieldChainButton.Parent := FSecFields;
  FFieldChainButton.Left := 690;
  FFieldChainButton.Top := 278;
  FFieldChainButton.Width := 110;
  FFieldChainButton.Caption := '从 CT 条目填入';
  FFieldChainButton.OnClick := @LoadChainFromSelectedCTEntry;
  Button := TButton.Create(Self);
  Button.Parent := FSecFields;
  Button.Left := 810;
  Button.Top := 278;
  Button.Width := 150;
  Button.Caption := '声明指针链字段';
  Button.OnClick := @DeclareChainFromCT;
  { Game Profile（FR-055/FR-061/FR-062）：把这一局的字段集合连定位配方
    存下来，下次开局直接还原。还原后字段一律退回只读，因为上一轮的可写
    证明对新进程无效。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecFields;
  FieldLabel.Left := 500;
  FieldLabel.Top := 312;
  FieldLabel.Caption := 'Game Profile：保存当前字段集合 / 按游戏名还原';
  Button := TButton.Create(Self);
  Button.Parent := FSecFields;
  Button.Left := 500;
  Button.Top := 334;
  Button.Width := 180;
  Button.Caption := '保存当前 Profile';
  Button.OnClick := @SaveGameProfileClick;
  FProfileNameEdit := TEdit.Create(Self);
  FProfileNameEdit.Parent := FSecFields;
  FProfileNameEdit.Left := 690;
  FProfileNameEdit.Top := 334;
  FProfileNameEdit.Width := 160;
  FProfileNameEdit.TextHint := '游戏名（还原时用）';
  FProfileRestoreButton := TButton.Create(Self);
  FProfileRestoreButton.Parent := FSecFields;
  FProfileRestoreButton.Left := 860;
  FProfileRestoreButton.Top := 334;
  FProfileRestoreButton.Width := 100;
  FProfileRestoreButton.Caption := '还原 Profile';
  FProfileRestoreButton.OnClick := @RestoreGameProfileClick;

  FSecWrite := TPanel.Create(Self);
  FSecWrite.Parent := PlayerCenterPanel;
  FSecWrite.Align := alClient;
  FSecWrite.BevelOuter := bvNone;
  FSecWrite.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecWrite;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '写入必须经过：权限 → verified_writable → 进程一致性 → ' +
    '类型/范围 → 二次确认 → 写后重读验证（FR-041~045）';
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 12;
  Button.Top := 44;
  Button.Width := 260;
  Button.Caption := '① 验证字段可写（写入→重读→一致）';
  Button.OnClick := @VerifySelectedFieldWritable;
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 282;
  Button.Top := 44;
  Button.Width := 260;
  Button.Caption := '② 通过命令总线写入目标值';
  Button.OnClick := @WriteSelectedField;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecWrite;
  FieldLabel.Left := 12;
  FieldLabel.Top := 84;
  FieldLabel.Caption := '“命令已发送”不等于“修改成功”。结果会区分已验证 / 被游戏覆盖 / 未生效。';
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecWrite;
  FieldLabel.Left := 12;
  FieldLabel.Top := 112;
  FieldLabel.Caption := '操作历史（FR-046）：时间 / 字段 / 原值→目标值 / 适配器 / 结果。';
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 12;
  Button.Top := 136;
  Button.Width := 200;
  Button.Caption := '刷新操作历史';
  Button.OnClick := @ShowFieldWriteHistory;
  FWriteHistoryList := TListBox.Create(Self);
  FWriteHistoryList.Parent := FSecWrite;
  FWriteHistoryList.Left := 12;
  FWriteHistoryList.Top := 168;
  FWriteHistoryList.Width := 678;
  FWriteHistoryList.Height := 130;
  FWriteHistoryList.Anchors := [akLeft, akTop, akRight];
  FWriteHistoryList.OnClick := @SelectFieldWriteHistory;
  { FR-052 证据记录：每一次真实采集和每一次真实验证都会留下一条证据。
    列表里的「可支撑写入」列才是关键——用户陈述只命名字段，不证明可写。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecWrite;
  FieldLabel.Left := 12;
  FieldLabel.Top := 306;
  FieldLabel.Caption := '证据记录（FR-052）：类型 / 结果 / 观察值 / 是否支撑“可写”结论。';
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 12;
  Button.Top := 330;
  Button.Width := 200;
  Button.Caption := '刷新证据记录';
  Button.OnClick := @ShowFieldEvidence;
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 222;
  Button.Top := 330;
  Button.Width := 240;
  Button.Caption := '我确认这个字段就是它（留证据）';
  Button.OnClick := @ConfirmFieldAsOperator;
  FFieldEvidenceList := TListBox.Create(Self);
  FFieldEvidenceList.Parent := FSecWrite;
  FFieldEvidenceList.Left := 12;
  FFieldEvidenceList.Top := 362;
  FFieldEvidenceList.Width := 678;
  FFieldEvidenceList.Height := 110;
  FFieldEvidenceList.Anchors := [akLeft, akTop, akRight];
  FFieldEvidenceList.OnClick := @SelectFieldEvidence;
  { FR-041 输入校验。约束在这里声明，但真正的拦截发生在写入与预览路径上：
    这一行只是把「这个字段能接受什么值」写进模型，不是一道可以绕过的 UI 检查。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecWrite;
  FieldLabel.Left := 12;
  FieldLabel.Top := 478;
  FieldLabel.Caption := '字段约束（FR-041）：如 {"min":0,"max":99999} 或 {"allowed_values":["0","1"]}。留空表示不加约束。';
  FFieldConstraintsEdit := TEdit.Create(Self);
  FFieldConstraintsEdit.Parent := FSecWrite;
  FFieldConstraintsEdit.Left := 12;
  FFieldConstraintsEdit.Top := 502;
  FFieldConstraintsEdit.Width := 360;
  FFieldConstraintsEdit.TextHint := '{"min":0,"max":99999}';
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 382;
  Button.Top := 500;
  Button.Width := 130;
  Button.Caption := '保存约束';
  Button.OnClick := @SaveFieldConstraints;
  Button := TButton.Create(Self);
  Button.Parent := FSecWrite;
  Button.Left := 522;
  Button.Top := 500;
  Button.Width := 130;
  Button.Caption := '清除约束';
  Button.OnClick := @ClearFieldConstraints;
  FFieldConstraintsStatusLabel := TLabel.Create(Self);
  FFieldConstraintsStatusLabel.Parent := FSecWrite;
  FFieldConstraintsStatusLabel.Left := 12;
  FFieldConstraintsStatusLabel.Top := 530;
  FFieldConstraintsStatusLabel.Width := 678;
  FFieldConstraintsStatusLabel.Caption := '未声明约束。';

  FSecDiscovery := TPanel.Create(Self);
  FSecDiscovery.Parent := PlayerCenterPanel;
  FSecDiscovery.Align := alClient;
  FSecDiscovery.BevelOuter := bvNone;
  FSecDiscovery.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecDiscovery;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '分轮验证（FR-051）：每轮先声明目的、操作、预期观察，再动手。' +
    '同一时刻只允许一个未收尾轮次。';
  FDiscoveryKindBox := TComboBox.Create(Self);
  FDiscoveryKindBox.Parent := FSecDiscovery;
  FDiscoveryKindBox.Left := 12;
  FDiscoveryKindBox.Top := 40;
  FDiscoveryKindBox.Width := 90;
  FDiscoveryKindBox.Style := csDropDownList;
  FDiscoveryKindBox.Items.Add('scan');
  FDiscoveryKindBox.Items.Add('refine');
  FDiscoveryKindBox.Items.Add('compare');
  FDiscoveryKindBox.Items.Add('write');
  FDiscoveryKindBox.ItemIndex := 0;
  FDiscoveryPurposeEdit := TEdit.Create(Self);
  FDiscoveryPurposeEdit.Parent := FSecDiscovery;
  FDiscoveryPurposeEdit.Left := 108;
  FDiscoveryPurposeEdit.Top := 40;
  FDiscoveryPurposeEdit.Width := 170;
  FDiscoveryPurposeEdit.TextHint := '目的：想确认什么';
  FDiscoveryOperationEdit := TEdit.Create(Self);
  FDiscoveryOperationEdit.Parent := FSecDiscovery;
  FDiscoveryOperationEdit.Left := 284;
  FDiscoveryOperationEdit.Top := 40;
  FDiscoveryOperationEdit.Width := 170;
  FDiscoveryOperationEdit.TextHint := '操作：要执行什么';
  FDiscoveryExpectedEdit := TEdit.Create(Self);
  FDiscoveryExpectedEdit.Parent := FSecDiscovery;
  FDiscoveryExpectedEdit.Left := 460;
  FDiscoveryExpectedEdit.Top := 40;
  FDiscoveryExpectedEdit.Width := 200;
  FDiscoveryExpectedEdit.TextHint := '预期观察：应该看到什么';
  { 字段可以留空：有些轮次（比如先确认进程是否稳定）跟具体字段无关。
    但「预期看到什么」必须由操作者写下来，事后不许补。 }
  FDiscoveryFieldEdit := TEdit.Create(Self);
  FDiscoveryFieldEdit.Parent := FSecDiscovery;
  FDiscoveryFieldEdit.Left := 12;
  FDiscoveryFieldEdit.Top := 70;
  FDiscoveryFieldEdit.Width := 150;
  FDiscoveryFieldEdit.TextHint := '字段 ID（可选）';
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 172;
  Button.Top := 68;
  Button.Width := 140;
  Button.Caption := '规划本轮';
  Button.OnClick := @PlanDiscoveryRoundClick;
  FDiscoveryRoundIdEdit := TEdit.Create(Self);
  FDiscoveryRoundIdEdit.Parent := FSecDiscovery;
  FDiscoveryRoundIdEdit.Left := 322;
  FDiscoveryRoundIdEdit.Top := 70;
  FDiscoveryRoundIdEdit.Width := 180;
  FDiscoveryRoundIdEdit.TextHint := '轮次 ID（点列表填入）';
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 512;
  Button.Top := 68;
  Button.Width := 148;
  Button.Caption := '查看当前轮次';
  Button.OnClick := @ShowCurrentDiscoveryRound;
  FDiscoveryOutcomeEdit := TEdit.Create(Self);
  FDiscoveryOutcomeEdit.Parent := FSecDiscovery;
  FDiscoveryOutcomeEdit.Left := 12;
  FDiscoveryOutcomeEdit.Top := 100;
  FDiscoveryOutcomeEdit.Width := 200;
  FDiscoveryOutcomeEdit.TextHint := '实际观察结果';
  FDiscoveryMatchedCheck := TCheckBox.Create(Self);
  FDiscoveryMatchedCheck.Parent := FSecDiscovery;
  FDiscoveryMatchedCheck.Left := 222;
  FDiscoveryMatchedCheck.Top := 103;
  FDiscoveryMatchedCheck.Width := 120;
  FDiscoveryMatchedCheck.Caption := '符合预期';
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 352;
  Button.Top := 98;
  Button.Width := 120;
  Button.Caption := '收尾本轮';
  Button.OnClick := @CompleteDiscoveryRoundClick;
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 482;
  Button.Top := 98;
  Button.Width := 120;
  Button.Caption := '放弃本轮';
  Button.OnClick := @AbandonDiscoveryRoundClick;
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 12;
  Button.Top := 132;
  Button.Width := 160;
  Button.Caption := '刷新轮次列表';
  Button.OnClick := @ShowDiscoveryRounds;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecDiscovery;
  FieldLabel.Left := 12;
  FieldLabel.Top := 164;
  FieldLabel.Caption := '轮次列表（最新在前）：点一条把轮次 ID 填进来。';
  FDiscoveryRoundList := TListBox.Create(Self);
  FDiscoveryRoundList.Parent := FSecDiscovery;
  FDiscoveryRoundList.Left := 12;
  FDiscoveryRoundList.Top := 188;
  FDiscoveryRoundList.Width := 678;
  FDiscoveryRoundList.Height := 140;
  FDiscoveryRoundList.Anchors := [akLeft, akTop, akRight];
  FDiscoveryRoundList.OnClick := @SelectDiscoveryRound;
  FDiscoveryRoundJson := TStringList.Create;
  FDiscoveryRoundIds := TStringList.Create;

  { FR-050 目标描述：先用自然语言说想找什么，再让分轮计划去服务这个目标。
    目标只是意图，不是证据：接受它不授权扫描、写入，也不证明地址或可写性。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecDiscovery;
  FieldLabel.Left := 12;
  FieldLabel.Top := 336;
  FieldLabel.Caption :=
    '目标（FR-050）：用你自己的话描述想找的字段。目标只是意图，不是证据。';
  FGoalDescriptionEdit := TEdit.Create(Self);
  FGoalDescriptionEdit.Parent := FSecDiscovery;
  FGoalDescriptionEdit.Left := 12;
  FGoalDescriptionEdit.Top := 360;
  FGoalDescriptionEdit.Width := 320;
  FGoalDescriptionEdit.TextHint := '例如：捡起金币时变大的那个数值';
  FGoalValueTypeBox := TComboBox.Create(Self);
  FGoalValueTypeBox.Parent := FSecDiscovery;
  FGoalValueTypeBox.Left := 340;
  FGoalValueTypeBox.Top := 360;
  FGoalValueTypeBox.Width := 100;
  FGoalValueTypeBox.Style := csDropDownList;
  FGoalValueTypeBox.Items.Add('（类型不限）');
  FGoalValueTypeBox.Items.Add('byte');
  FGoalValueTypeBox.Items.Add('word');
  FGoalValueTypeBox.Items.Add('dword');
  FGoalValueTypeBox.Items.Add('qword');
  FGoalValueTypeBox.Items.Add('integer');
  FGoalValueTypeBox.Items.Add('single');
  FGoalValueTypeBox.Items.Add('double');
  FGoalValueTypeBox.Items.Add('bool');
  FGoalValueTypeBox.Items.Add('enum');
  FGoalValueTypeBox.Items.Add('string');
  FGoalValueTypeBox.ItemIndex := 0;
  FGoalBehaviorBox := TComboBox.Create(Self);
  FGoalBehaviorBox.Parent := FSecDiscovery;
  FGoalBehaviorBox.Left := 448;
  FGoalBehaviorBox.Top := 360;
  FGoalBehaviorBox.Width := 120;
  FGoalBehaviorBox.Style := csDropDownList;
  FGoalBehaviorBox.Items.Add('（变化未知）');
  FGoalBehaviorBox.Items.Add('increase');
  FGoalBehaviorBox.Items.Add('decrease');
  FGoalBehaviorBox.Items.Add('constant');
  FGoalBehaviorBox.ItemIndex := 0;
  FGoalFieldHintEdit := TEdit.Create(Self);
  FGoalFieldHintEdit.Parent := FSecDiscovery;
  FGoalFieldHintEdit.Left := 576;
  FGoalFieldHintEdit.Top := 360;
  FGoalFieldHintEdit.Width := 114;
  FGoalFieldHintEdit.TextHint := '字段 ID（可选）';
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 12;
  Button.Top := 390;
  Button.Width := 160;
  Button.Caption := '记下这个目标';
  Button.OnClick := @ProposeGoalClick;
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 180;
  Button.Top := 390;
  Button.Width := 140;
  Button.Caption := '接受为当前目标';
  Button.OnClick := @AcceptGoalClick;
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 328;
  Button.Top := 390;
  Button.Width := 130;
  Button.Caption := '否决目标';
  Button.OnClick := @RejectGoalClick;
  FGoalRejectReasonEdit := TEdit.Create(Self);
  FGoalRejectReasonEdit.Parent := FSecDiscovery;
  FGoalRejectReasonEdit.Left := 466;
  FGoalRejectReasonEdit.Top := 392;
  FGoalRejectReasonEdit.Width := 224;
  FGoalRejectReasonEdit.TextHint := '否决理由（必填）';
  FGoalStatusLabel := TLabel.Create(Self);
  FGoalStatusLabel.Parent := FSecDiscovery;
  FGoalStatusLabel.Left := 12;
  FGoalStatusLabel.Top := 422;
  FGoalStatusLabel.Caption := '当前目标：无。';
  FGoalIdEdit := TEdit.Create(Self);
  FGoalIdEdit.Parent := FSecDiscovery;
  FGoalIdEdit.Left := 12;
  FGoalIdEdit.Top := 446;
  FGoalIdEdit.Width := 200;
  FGoalIdEdit.TextHint := '目标 ID（点列表填入）';
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 220;
  Button.Top := 444;
  Button.Width := 140;
  Button.Caption := '显示当前目标';
  Button.OnClick := @ShowCurrentGoal;
  Button := TButton.Create(Self);
  Button.Parent := FSecDiscovery;
  Button.Left := 368;
  Button.Top := 444;
  Button.Width := 140;
  Button.Caption := '刷新目标列表';
  Button.OnClick := @ShowGoalList;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecDiscovery;
  FieldLabel.Left := 516;
  FieldLabel.Top := 448;
  FieldLabel.Caption := '（目标列表在下方）';
  FGoalList := TListBox.Create(Self);
  FGoalList.Parent := FSecDiscovery;
  FGoalList.Left := 12;
  FGoalList.Top := 474;
  FGoalList.Width := 678;
  FGoalList.Height := 120;
  FGoalList.Anchors := [akLeft, akTop, akRight, akBottom];
  FGoalList.OnClick := @SelectGoal;
  FGoalJson := TStringList.Create;
  FGoalIds := TStringList.Create;

  FSecEvents := TPanel.Create(Self);
  FSecEvents.Parent := PlayerCenterPanel;
  FSecEvents.Align := alClient;
  FSecEvents.BevelOuter := bvNone;
  FSecEvents.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecEvents;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '事件标记（本地确定性触发，不依赖 AI 逐帧调用）';
  FEventTagEdit := TEdit.Create(Self);
  FEventTagEdit.Parent := FSecEvents;
  FEventTagEdit.Left := 12;
  FEventTagEdit.Top := 34;
  FEventTagEdit.Width := 240;
  FEventTagEdit.TextHint := '标签，例如 关键选择';
  Button := TButton.Create(Self);
  Button.Parent := FSecEvents;
  Button.Left := 258;
  Button.Top := 32;
  Button.Width := 160;
  Button.Caption := '标记当前时刻';
  Button.OnClick := @MarkPlayerEvent;
  Button := TButton.Create(Self);
  Button.Parent := FSecEvents;
  Button.Left := 424;
  Button.Top := 32;
  Button.Width := 160;
  Button.Caption := '查看事件时间线';
  Button.OnClick := @ShowPlayerEvents;

  { PRD 6.9：事件分析入口。本地分级/关联不上网，第三行按钮会把事件里的
    实际数值发给模型，因此单独一个按钮并在点击时二次确认（FR-091 / FR-093）。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecEvents;
  FieldLabel.Left := 12;
  FieldLabel.Top := 68;
  FieldLabel.Caption :=
    '事件分析：分级只说明证据强度；建议仅作参考，执行扫描/写入仍需授权。';
  FEventIdEdit := TEdit.Create(Self);
  FEventIdEdit.Parent := FSecEvents;
  FEventIdEdit.Left := 12;
  FEventIdEdit.Top := 92;
  FEventIdEdit.Width := 240;
  FEventIdEdit.TextHint := '事件 ID，例如 event-00000001';
  FEventFieldEdit := TEdit.Create(Self);
  FEventFieldEdit.Parent := FSecEvents;
  FEventFieldEdit.Left := 258;
  FEventFieldEdit.Top := 92;
  FEventFieldEdit.Width := 160;
  FEventFieldEdit.TextHint := '字段 ID（可选）';
  FEventAnalysisButton := TButton.Create(Self);
  FEventAnalysisButton.Parent := FSecEvents;
  FEventAnalysisButton.Left := 424;
  FEventAnalysisButton.Top := 90;
  FEventAnalysisButton.Width := 130;
  FEventAnalysisButton.Caption := '分析证据强度';
  FEventAnalysisButton.OnClick := @AnalyzePlayerEvent;
  FEventTrendButton := TButton.Create(Self);
  FEventTrendButton.Parent := FSecEvents;
  FEventTrendButton.Left := 560;
  FEventTrendButton.Top := 90;
  FEventTrendButton.Width := 130;
  FEventTrendButton.Caption := '关联该字段变化';
  FEventTrendButton.OnClick := @ShowPlayerEventTrend;
  FEventCloudButton := TButton.Create(Self);
  FEventCloudButton.Parent := FSecEvents;
  FEventCloudButton.Left := 12;
  FEventCloudButton.Top := 124;
  FEventCloudButton.Width := 240;
  FEventCloudButton.Caption := '交给模型解读（会外发数值）';
  FEventCloudButton.OnClick := @AnalyzePlayerEventWithModel;
  { 事件 ID 不该靠手打：时间线里点一条就填进来。 }
  FEventList := TListBox.Create(Self);
  FEventList.Parent := FSecEvents;
  FEventList.Left := 12;
  FEventList.Top := 160;
  FEventList.Width := 678;
  FEventList.Height := 150;
  FEventList.Anchors := [akLeft, akTop, akRight];
  FEventList.OnClick := @SelectPlayerEvent;
  FEventIds := TStringList.Create;
  FWriteHistoryJson := TStringList.Create;
  FFieldEvidenceJson := TStringList.Create;

  { 事件录像（FR-071/074/079）：录像抓的是游戏窗口画面，只在本机落盘。
    开启录像会把「标记前 5 秒 / 后 5 秒」的帧真正存下来，因此和写入一样
    需要二次确认。 }
  FRecordingStatusLabel := TLabel.Create(Self);
  FRecordingStatusLabel.Parent := FSecEvents;
  FRecordingStatusLabel.Left := 12;
  FRecordingStatusLabel.Top := 322;
  FRecordingStatusLabel.Width := 678;
  FRecordingStatusLabel.Caption := '事件录像：未开启（开启后事件包会带上录像片段引用）';
  FRecordingStartButton := TButton.Create(Self);
  FRecordingStartButton.Parent := FSecEvents;
  FRecordingStartButton.Left := 12;
  FRecordingStartButton.Top := 346;
  FRecordingStartButton.Width := 150;
  FRecordingStartButton.Caption := '开启事件录像';
  FRecordingStartButton.OnClick := @StartPlayerRecording;
  FRecordingStopButton := TButton.Create(Self);
  FRecordingStopButton.Parent := FSecEvents;
  FRecordingStopButton.Left := 172;
  FRecordingStopButton.Top := 346;
  FRecordingStopButton.Width := 130;
  FRecordingStopButton.Caption := '停止录像';
  FRecordingStopButton.Enabled := False;
  FRecordingStopButton.OnClick := @StopPlayerRecording;
  FRecordingRefreshButton := TButton.Create(Self);
  FRecordingRefreshButton.Parent := FSecEvents;
  FRecordingRefreshButton.Left := 312;
  FRecordingRefreshButton.Top := 346;
  FRecordingRefreshButton.Width := 150;
  FRecordingRefreshButton.Caption := '刷新录像片段';
  FRecordingRefreshButton.OnClick := @RefreshRecordingSegments;
  FRecordingLockButton := TButton.Create(Self);
  FRecordingLockButton.Parent := FSecEvents;
  FRecordingLockButton.Left := 472;
  FRecordingLockButton.Top := 346;
  FRecordingLockButton.Width := 180;
  FRecordingLockButton.Caption := '锁定/解锁选中片段';
  FRecordingLockButton.OnClick := @ToggleRecordingSegmentLock;
  FRecordingList := TListBox.Create(Self);
  FRecordingList.Parent := FSecEvents;
  FRecordingList.Left := 12;
  FRecordingList.Top := 378;
  FRecordingList.Width := 678;
  FRecordingList.Height := 120;
  FRecordingList.Anchors := [akLeft, akTop, akRight, akBottom];
  FRecordingSegmentIds := TStringList.Create;

  FSecSecondary := TPanel.Create(Self);
  FSecSecondary.Parent := PlayerCenterPanel;
  FSecSecondary.Align := alClient;
  FSecSecondary.BevelOuter := bvNone;
  FSecSecondary.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '副屏页面：按游戏状态生成首版布局；只读字段不渲染可提交控件。';
  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 12;
  Button.Top := 36;
  Button.Width := 190;
  Button.Caption := '生成副屏渲染 JSON';
  Button.OnClick := @RenderSecondaryScreen;
  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 208;
  Button.Top := 36;
  Button.Width := 150;
  Button.Caption := '枚举显示器';
  Button.OnClick := @EnumerateDisplays;
  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 364;
  Button.Top := 36;
  Button.Width := 150;
  Button.Caption := '保存窗口位置';
  Button.OnClick := @SavePlayerPlacement;
  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 520;
  Button.Top := 36;
  Button.Width := 150;
  Button.Caption := '读取窗口位置';
  Button.OnClick := @LoadPlayerPlacement;

  FSecondaryStatusLabel := TLabel.Create(Self);
  FSecondaryStatusLabel.Parent := FSecSecondary;
  FSecondaryStatusLabel.Left := 12;
  FSecondaryStatusLabel.Top := 76;
  FSecondaryStatusLabel.Caption := '副屏宿主未启动（本地回环，仅本机可访问）';
  FSecondaryStatusLabel.AutoSize := True;

  FSecondaryStartButton := TButton.Create(Self);
  FSecondaryStartButton.Parent := FSecSecondary;
  FSecondaryStartButton.Left := 12;
  FSecondaryStartButton.Top := 100;
  FSecondaryStartButton.Width := 210;
  FSecondaryStartButton.Caption := '启动副屏宿主（只读）';
  FSecondaryStartButton.OnClick := @StartSecondaryScreen;

  FSecondaryOpenButton := TButton.Create(Self);
  FSecondaryOpenButton.Parent := FSecSecondary;
  FSecondaryOpenButton.Left := 228;
  FSecondaryOpenButton.Top := 100;
  FSecondaryOpenButton.Width := 150;
  FSecondaryOpenButton.Caption := '在浏览器打开';
  FSecondaryOpenButton.Enabled := False;
  FSecondaryOpenButton.OnClick := @OpenSecondaryScreen;

  FSecondaryStopButton := TButton.Create(Self);
  FSecondaryStopButton.Parent := FSecSecondary;
  FSecondaryStopButton.Left := 384;
  FSecondaryStopButton.Top := 100;
  FSecondaryStopButton.Width := 120;
  FSecondaryStopButton.Caption := '停止副屏';
  FSecondaryStopButton.Enabled := False;
  FSecondaryStopButton.OnClick := @StopSecondaryScreen;

  { 多页面与版本历史（FR-026 / FR-033）：页面存的是布局 schema，
    不是状态快照，因此回退只换布局、绝不会把旧数值写回游戏。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 148;
  FieldLabel.Caption := '页面：把当前布局存为具名页面后可切换；版本历史只追加，回退=另存为新版本。';
  FieldLabel.AutoSize := True;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 176;
  FieldLabel.Caption := '页面 ID';
  FieldLabel.AutoSize := True;
  FPageIdEdit := TEdit.Create(Self);
  FPageIdEdit.Parent := FSecSecondary;
  FPageIdEdit.Left := 76;
  FPageIdEdit.Top := 172;
  FPageIdEdit.Width := 130;
  FPageIdEdit.TextHint := 'attributes';

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 216;
  FieldLabel.Top := 176;
  FieldLabel.Caption := '标题';
  FieldLabel.AutoSize := True;
  FPageTitleEdit := TEdit.Create(Self);
  FPageTitleEdit.Parent := FSecSecondary;
  FPageTitleEdit.Left := 256;
  FPageTitleEdit.Top := 172;
  FPageTitleEdit.Width := 170;
  FPageTitleEdit.TextHint := '属性';

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 436;
  Button.Top := 170;
  Button.Width := 170;
  Button.Caption := '保存当前页面';
  Button.OnClick := @SavePlayerPage;

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 616;
  Button.Top := 170;
  Button.Width := 130;
  Button.Caption := '列出页面';
  Button.OnClick := @ListPlayerPages;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 212;
  FieldLabel.Caption := '副屏渲染页';
  FieldLabel.AutoSize := True;
  FPageCombo := TComboBox.Create(Self);
  FPageCombo.Parent := FSecSecondary;
  FPageCombo.Left := 92;
  FPageCombo.Top := 208;
  FPageCombo.Width := 200;
  FPageCombo.Style := csDropDownList;
  FPageIds := TStringList.Create;
  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 300;
  Button.Top := 206;
  Button.Width := 190;
  Button.Caption := '让副屏渲染该页';
  Button.OnClick := @SetSecondaryScreenPage;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 248;
  FieldLabel.Caption := '版本号';
  FieldLabel.AutoSize := True;
  FPageVersionEdit := TEdit.Create(Self);
  FPageVersionEdit.Parent := FSecSecondary;
  FPageVersionEdit.Left := 72;
  FPageVersionEdit.Top := 244;
  FPageVersionEdit.Width := 80;
  FPageVersionEdit.Text := '1';

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 160;
  Button.Top := 242;
  Button.Width := 150;
  Button.Caption := '列出历史版本';
  Button.OnClick := @ListPlayerPageVersions;

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 318;
  Button.Top := 242;
  Button.Width := 150;
  Button.Caption := '回退到该版本';
  Button.OnClick := @RestorePlayerPageVersion;

  { 自然语言定制（FR-025）：模型只出提案，必须本地确认才落盘。 }
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSecondary;
  FieldLabel.Left := 12;
  FieldLabel.Top := 288;
  FieldLabel.Caption := '自然语言改版（模型只出提案，确认后才保存）';
  FieldLabel.AutoSize := True;
  FPageInstructionEdit := TEdit.Create(Self);
  FPageInstructionEdit.Parent := FSecSecondary;
  FPageInstructionEdit.Left := 12;
  FPageInstructionEdit.Top := 312;
  FPageInstructionEdit.Width := 480;
  FPageInstructionEdit.TextHint := '例如：把装备和属性放在一起';

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 12;
  Button.Top := 344;
  Button.Width := 150;
  Button.Caption := '生成改版提案';
  Button.OnClick := @ProposePlayerPage;

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 170;
  Button.Top := 344;
  Button.Width := 150;
  Button.Caption := '确认并保存';
  Button.OnClick := @ConfirmPlayerPageProposal;

  Button := TButton.Create(Self);
  Button.Parent := FSecSecondary;
  Button.Left := 328;
  Button.Top := 344;
  Button.Width := 150;
  Button.Caption := '丢弃提案';
  Button.OnClick := @RejectPlayerPageProposal;

  { CE 文件库：本地复用 GCM 已下载的 .CT + 操作者手动导入。
    全程不联网——`gcm_url` 是 S3 filePath，真实下载需要他人私有凭据，
    所以只读本地已有文件，再由操作者决定是否发布到不可变库。 }
  FSecGcm := TPanel.Create(Self);
  FSecGcm.Parent := PlayerCenterPanel;
  FSecGcm.Align := alClient;
  FSecGcm.BevelOuter := bvNone;
  FSecGcm.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecGcm;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := 'CE 文件库：只读本地已有的 .CT（GCM 已下载目录 / 手动选择），' +
    '发布时校验大小并计算 SHA-256；不联网、不执行脚本。';
  FieldLabel.AutoSize := True;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecGcm;
  FieldLabel.Left := 12;
  FieldLabel.Top := 40;
  FieldLabel.Caption := '搜索游戏';
  FieldLabel.AutoSize := True;
  FGcmQueryEdit := TEdit.Create(Self);
  FGcmQueryEdit.Parent := FSecGcm;
  FGcmQueryEdit.Left := 82;
  FGcmQueryEdit.Top := 36;
  FGcmQueryEdit.Width := 250;
  FGcmQueryEdit.TextHint := '中文名或英文名';
  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 340;
  Button.Top := 34;
  Button.Width := 130;
  Button.Caption := '搜索 GCM 目录';
  Button.OnClick := @SearchGcmGames;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecGcm;
  FieldLabel.Left := 12;
  FieldLabel.Top := 72;
  FieldLabel.Caption := '进程名';
  FieldLabel.AutoSize := True;
  FGcmProcessEdit := TEdit.Create(Self);
  FGcmProcessEdit.Parent := FSecGcm;
  FGcmProcessEdit.Left := 82;
  FGcmProcessEdit.Top := 68;
  FGcmProcessEdit.Width := 250;
  FGcmProcessEdit.TextHint := '例如 Stardew Valley.exe';
  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 340;
  Button.Top := 66;
  Button.Width := 130;
  Button.Caption := '匹配游戏';
  Button.OnClick := @MatchGcmProcess;

  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 12;
  Button.Top := 100;
  Button.Width := 180;
  Button.Caption := '扫描本地已有 .CT';
  Button.OnClick := @ScanGcmCheatFiles;
  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 200;
  Button.Top := 100;
  Button.Width := 180;
  Button.Caption := '列出已发布文件';
  Button.OnClick := @ListPublishedCheatFiles;
  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 388;
  Button.Top := 100;
  Button.Width := 160;
  Button.Caption := '导入 .CT';
  Button.OnClick := @ImportCheatFileIntoLibrary;
  Button := TButton.Create(Self);
  Button.Parent := FSecGcm;
  Button.Left := 556;
  Button.Top := 100;
  Button.Width := 180;
  Button.Caption := '发布到文件库';
  Button.OnClick := @PublishCheatFileToLibrary;

  FGcmMemo := TMemo.Create(Self);
  FGcmMemo.Parent := FSecGcm;
  FGcmMemo.Left := 12;
  FGcmMemo.Top := 134;
  FGcmMemo.Width := 724;
  FGcmMemo.Height := 420;
  FGcmMemo.Anchors := [akLeft, akTop, akRight, akBottom];
  FGcmMemo.ReadOnly := True;
  FGcmMemo.ScrollBars := ssAutoBoth;
  FGcmMemo.WordWrap := False;
  FGcmMemo.Text := '候选文件列表会显示游戏名、来源、版本与字节数；' +
    '内容哈希在发布时才计算（导入只做校验，不改动原文件）。';

  FSecSettings := TPanel.Create(Self);
  FSecSettings.Parent := PlayerCenterPanel;
  FSecSettings.Align := alClient;
  FSecSettings.BevelOuter := bvNone;
  FSecSettings.Visible := False;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := FSecSettings;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '底层诊断与治理页签仍在右侧页签中保留：治理与安全 / 进程与内存 / ' +
    'CT RAG / 存档工作台 / LLM 工作台 / MCP / 关于与安全。';
  FieldLabel.AutoSize := True;

  AgentPage := TTabSheet.Create(Self);
  AgentPage.PageControl := Pages;
  AgentPage.Caption := '治理与安全';
  AddPlaceholder(AgentPage,
    '治理内核：任务、Lease、Effect、Receipt、Proof 与审计状态。');

  ProcessPage := TTabSheet.Create(Self);
  ProcessPage.PageControl := Pages;
  ProcessPage.Caption := '进程与内存';
  FOutputMemo := TMemo.Create(Self);
  FOutputMemo.Parent := ProcessPage;
  FOutputMemo.Align := alClient;
  FOutputMemo.ReadOnly := True;
  FOutputMemo.ScrollBars := ssAutoBoth;
  FOutputMemo.WordWrap := False;

  ProcessTools := TPanel.Create(Self);
  ProcessTools.Parent := ProcessPage;
  ProcessTools.Align := alTop;
  ProcessTools.Height := 48;
  ProcessTools.BevelOuter := bvNone;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := ProcessTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 16;
  FieldLabel.Caption := 'PID:';
  FPidEdit := TEdit.Create(Self);
  FPidEdit.Parent := ProcessTools;
  FPidEdit.Left := 48;
  FPidEdit.Top := 10;
  FPidEdit.Width := 100;
  AttachButton := TButton.Create(Self);
  AttachButton.Parent := ProcessTools;
  AttachButton.Left := 160;
  AttachButton.Top := 8;
  AttachButton.Width := 190;
  AttachButton.Caption := '声明为授权单机并附加';
  AttachButton.OnClick := @AttachProcess;

  ScanTools := TPanel.Create(Self);
  ScanTools.Parent := ProcessPage;
  ScanTools.Align := alTop;
  ScanTools.Height := 204;
  ScanTools.BevelOuter := bvNone;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := ScanTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 5;
  FieldLabel.Caption := '只读数值扫描：明确地址范围，或本机确认的进程区域类型（上限 512 MiB）';
  FScanStartEdit := TEdit.Create(Self);
  FScanStartEdit.Parent := ScanTools;
  FScanStartEdit.Left := 12;
  FScanStartEdit.Top := 27;
  FScanStartEdit.Width := 185;
  FScanStartEdit.TextHint := '起始地址 0x...';
  FScanSizeEdit := TEdit.Create(Self);
  FScanSizeEdit.Parent := ScanTools;
  FScanSizeEdit.Left := 205;
  FScanSizeEdit.Top := 27;
  FScanSizeEdit.Width := 95;
  FScanSizeEdit.Text := '4096';
  FScanSizeEdit.TextHint := '字节数';
  FScanValueTypeBox := TComboBox.Create(Self);
  FScanValueTypeBox.Parent := ScanTools;
  FScanValueTypeBox.Left := 308;
  FScanValueTypeBox.Top := 27;
  FScanValueTypeBox.Width := 100;
  FScanValueTypeBox.Style := csDropDownList;
  FScanValueTypeBox.Items.Add('byte');
  FScanValueTypeBox.Items.Add('word');
  FScanValueTypeBox.Items.Add('dword');
  FScanValueTypeBox.Items.Add('qword');
  FScanValueTypeBox.Items.Add('single');
  FScanValueTypeBox.Items.Add('double');
  FScanValueTypeBox.ItemIndex := 2;
  FScanValueEdit := TEdit.Create(Self);
  FScanValueEdit.Parent := ScanTools;
  FScanValueEdit.Left := 416;
  FScanValueEdit.Top := 27;
  FScanValueEdit.Width := 110;
  FScanValueEdit.TextHint := '当前数值';
  FScanMaxResultsEdit := TEdit.Create(Self);
  FScanMaxResultsEdit.Parent := ScanTools;
  FScanMaxResultsEdit.Left := 534;
  FScanMaxResultsEdit.Top := 27;
  FScanMaxResultsEdit.Width := 75;
  FScanMaxResultsEdit.Text := '100';
  FScanMaxResultsEdit.TextHint := '结果上限';
  with TButton.Create(Self) do
  begin
    Parent := ScanTools;
    Left := 617;
    Top := 25;
    Width := 145;
    Caption := '确认范围并扫描';
    OnClick := @StartValueScan;
  end;
  FScanRefineButton := TButton.Create(Self);
  FScanRefineButton.Parent := ScanTools;
  FScanRefineButton.Left := 770;
  FScanRefineButton.Top := 25;
  FScanRefineButton.Width := 100;
  FScanRefineButton.Caption := '按新值复筛';
  FScanRefineButton.Enabled := False;
  FScanRefineButton.OnClick := @RefineValueScan;
  FScanCancelButton := TButton.Create(Self);
  FScanCancelButton.Parent := ScanTools;
  FScanCancelButton.Left := 878;
  FScanCancelButton.Top := 25;
  FScanCancelButton.Width := 125;
  FScanCancelButton.Caption := '结束扫描会话';
  FScanCancelButton.Enabled := False;
  FScanCancelButton.OnClick := @CancelValueScan;
  FScanRegionKindsBox := TComboBox.Create(Self);
  FScanRegionKindsBox.Parent := ScanTools;
  FScanRegionKindsBox.Left := 12;
  FScanRegionKindsBox.Top := 64;
  FScanRegionKindsBox.Width := 190;
  FScanRegionKindsBox.Style := csDropDownList;
  FScanRegionKindsBox.Items.Add('private');
  FScanRegionKindsBox.Items.Add('private,image');
  FScanRegionKindsBox.Items.Add('private,mapped');
  FScanRegionKindsBox.Items.Add('private,image,mapped');
  FScanRegionKindsBox.ItemIndex := 0;
  with TButton.Create(Self) do
  begin
    Parent := ScanTools;
    Left := 210;
    Top := 62;
    Width := 170;
    Caption := '确认进程区域并扫描';
    OnClick := @StartProcessValueScan;
  end;
  with TButton.Create(Self) do
  begin
    Parent := ScanTools;
    Left := 388;
    Top := 62;
    Width := 210;
    Caption := '单独授权 MCP 只读范围';
    OnClick := @AuthorizeMCPValueScanScope;
  end;
  FScanScopeRevokeButton := TButton.Create(Self);
  FScanScopeRevokeButton.Parent := ScanTools;
  FScanScopeRevokeButton.Left := 606;
  FScanScopeRevokeButton.Top := 62;
  FScanScopeRevokeButton.Width := 120;
  FScanScopeRevokeButton.Caption := '撤销 MCP 范围';
  FScanScopeRevokeButton.Enabled := False;
  FScanScopeRevokeButton.OnClick := @RevokeMCPValueScanScope;
  FScanScopeLabel := TLabel.Create(Self);
  FScanScopeLabel.Parent := ScanTools;
  FScanScopeLabel.Left := 12;
  FScanScopeLabel.Top := 106;
  FScanScopeLabel.Caption := '尚未单独授权 MCP 扫描范围。';
  FScanModuleEdit := TEdit.Create(Self);
  FScanModuleEdit.Parent := ScanTools;
  FScanModuleEdit.Left := 12;
  FScanModuleEdit.Top := 128;
  FScanModuleEdit.Width := 150;
  FScanModuleEdit.TextHint := '模块名（如 game.exe）';
  FScanAobEdit := TEdit.Create(Self);
  FScanAobEdit.Parent := ScanTools;
  FScanAobEdit.Left := 170;
  FScanAobEdit.Top := 128;
  FScanAobEdit.Width := 320;
  FScanAobEdit.TextHint := 'AOB 签名，如 48 8B ?? ?? 48 85';
  with TButton.Create(Self) do
  begin
    Parent := ScanTools;
    Left := 498;
    Top := 126;
    Width := 170;
    Caption := '扫描签名并判定唯一性';
    OnClick := @StartAobSignatureScan;
  end;
  FScanAobJudgeButton := TButton.Create(Self);
  FScanAobJudgeButton.Parent := ScanTools;
  FScanAobJudgeButton.Left := 676;
  FScanAobJudgeButton.Top := 126;
  FScanAobJudgeButton.Width := 130;
  FScanAobJudgeButton.Caption := '重新判定唯一性';
  FScanAobJudgeButton.Enabled := False;
  FScanAobJudgeButton.OnClick := @JudgeAobUniqueness;
  FScanAobLabel := TLabel.Create(Self);
  FScanAobLabel.Parent := ScanTools;
  FScanAobLabel.Left := 812;
  FScanAobLabel.Top := 131;
  FScanAobLabel.Caption := '签名未扫描。';
  FScanCoverageLabel := TLabel.Create(Self);
  FScanCoverageLabel.Parent := ScanTools;
  FScanCoverageLabel.Left := 12;
  FScanCoverageLabel.Top := 172;
  FScanCoverageLabel.Caption :=
    '覆盖率只针对所选范围；未扫描的进程区域不可解释为“未找到”。';

  WriteTools := TPanel.Create(Self);
  WriteTools.Parent := ProcessPage;
  WriteTools.Align := alBottom;
  WriteTools.Height := 154;
  WriteTools.BevelOuter := bvNone;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '地址 (0x...)';
  FAddressEdit := TEdit.Create(Self);
  FAddressEdit.Parent := WriteTools;
  FAddressEdit.Left := 12;
  FAddressEdit.Top := 30;
  FAddressEdit.Width := 180;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 205;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '预期原字节 (hex)';
  FExpectedEdit := TEdit.Create(Self);
  FExpectedEdit.Parent := WriteTools;
  FExpectedEdit.Left := 205;
  FExpectedEdit.Top := 30;
  FExpectedEdit.Width := 190;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 408;
  FieldLabel.Top := 10;
  FieldLabel.Caption := '替换字节 (hex)';
  FReplacementEdit := TEdit.Create(Self);
  FReplacementEdit.Parent := WriteTools;
  FReplacementEdit.Left := 408;
  FReplacementEdit.Top := 30;
  FReplacementEdit.Width := 190;
  WriteButton := TButton.Create(Self);
  WriteButton.Parent := WriteTools;
  WriteButton.Left := 615;
  WriteButton.Top := 27;
  WriteButton.Width := 180;
  WriteButton.Caption := '计划并本机审批写入';
  WriteButton.OnClick := @PlanMemoryWrite;

  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 62;
  FieldLabel.Caption := '冻结间隔(ms)';
  FFreezeIntervalEdit := TEdit.Create(Self);
  FFreezeIntervalEdit.Parent := WriteTools;
  FFreezeIntervalEdit.Left := 105;
  FFreezeIntervalEdit.Top := 57;
  FFreezeIntervalEdit.Width := 70;
  FFreezeIntervalEdit.Text := '250';
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 185;
  FieldLabel.Top := 62;
  FieldLabel.Caption := '最大写入';
  FFreezeMaxWritesEdit := TEdit.Create(Self);
  FFreezeMaxWritesEdit.Parent := WriteTools;
  FFreezeMaxWritesEdit.Left := 250;
  FFreezeMaxWritesEdit.Top := 57;
  FFreezeMaxWritesEdit.Width := 70;
  FFreezeMaxWritesEdit.Text := '120';
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 330;
  FieldLabel.Top := 62;
  FieldLabel.Caption := '持续秒数';
  FFreezeDurationEdit := TEdit.Create(Self);
  FFreezeDurationEdit.Parent := WriteTools;
  FFreezeDurationEdit.Left := 395;
  FFreezeDurationEdit.Top := 57;
  FFreezeDurationEdit.Width := 70;
  FFreezeDurationEdit.Text := '60';
  FreezeButton := TButton.Create(Self);
  FreezeButton.Parent := WriteTools;
  FreezeButton.Left := 480;
  FreezeButton.Top := 55;
  FreezeButton.Width := 200;
  FreezeButton.Caption := '计划并本机审批冻结';
  FreezeButton.OnClick := @PlanMemoryFreeze;
  StopFreezeButton := TButton.Create(Self);
  StopFreezeButton.Parent := WriteTools;
  StopFreezeButton.Left := 690;
  StopFreezeButton.Top := 55;
  StopFreezeButton.Width := 130;
  StopFreezeButton.Caption := '停止冻结';
  StopFreezeButton.OnClick := @StopMemoryFreeze;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := WriteTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 120;
  FieldLabel.Caption := 'Unknown Effect ID:';
  FEffectIdEdit := TEdit.Create(Self);
  FEffectIdEdit.Parent := WriteTools;
  FEffectIdEdit.Left := 135;
  FEffectIdEdit.Top := 114;
  FEffectIdEdit.Width := 460;
  FEffectIdEdit.TextHint := '崩溃后只读对账；不会自动重试或回滚';
  RecoveryButton := TButton.Create(Self);
  RecoveryButton.Parent := WriteTools;
  RecoveryButton.Left := 615;
  RecoveryButton.Top := 112;
  RecoveryButton.Width := 180;
  RecoveryButton.Caption := '显式对账 Unknown';
  RecoveryButton.OnClick := @ReconcileEffect;

  CTPage := TTabSheet.Create(Self);
  CTPage.PageControl := Pages;
  CTPage.Caption := 'CT RAG';
  CTTools := TPanel.Create(Self);
  CTTools.Parent := CTPage;
  CTTools.Align := alTop;
  CTTools.Height := 118;
  CTTools.BevelOuter := bvNone;
  FCTPathEdit := TEdit.Create(Self);
  FCTPathEdit.Parent := CTTools;
  FCTPathEdit.Left := 12;
  FCTPathEdit.Top := 10;
  FCTPathEdit.Width := 650;
  FCTPathEdit.TextHint := '选择本地 .CT；脚本只作为文本证据解析，绝不执行';
  RefreshButton := TButton.Create(Self);
  RefreshButton.Parent := CTTools;
  RefreshButton.Left := 675;
  RefreshButton.Top := 8;
  RefreshButton.Width := 150;
  RefreshButton.Caption := '选择并导入 CT';
  RefreshButton.OnClick := @BrowseAndImportCT;
  FCTQueryEdit := TEdit.Create(Self);
  FCTQueryEdit.Parent := CTTools;
  FCTQueryEdit.Left := 12;
  FCTQueryEdit.Top := 46;
  FCTQueryEdit.Width := 650;
  FCTQueryEdit.TextHint := '搜索游戏、功能、模块、地址或 AOB';
  RefreshButton := TButton.Create(Self);
  RefreshButton.Parent := CTTools;
  RefreshButton.Left := 675;
  RefreshButton.Top := 44;
  RefreshButton.Width := 150;
  RefreshButton.Caption := '检索 RAG';
  RefreshButton.OnClick := @SearchCT;
  FCTMemo := TMemo.Create(Self);
  FCTMemo.Parent := CTPage;
  FCTMemo.Align := alClient;
  FCTMemo.ReadOnly := True;
  FCTMemo.ScrollBars := ssAutoBoth;
  FCTMemo.WordWrap := False;

  // 描述翻译（Phase C）：只把 <Description> 文本发给模型，脚本永不外发；
  // 结果标注为机器翻译，仅作参考，不参与字段/地址/写入决策。
  TranslateButton := TButton.Create(Self);
  TranslateButton.Parent := CTTools;
  TranslateButton.Left := 12;
  TranslateButton.Top := 82;
  TranslateButton.Width := 190;
  TranslateButton.Caption := '翻译描述（机器）';
  TranslateButton.OnClick := @TranslateCTDescriptions;
  SavePage := TTabSheet.Create(Self);
  SavePage.PageControl := Pages;
  SavePage.Caption := '存档工作台';
  SaveTools := TPanel.Create(Self);
  SaveTools.Parent := SavePage;
  SaveTools.Align := alTop;
  SaveTools.Height := 348;
  SaveTools.BevelOuter := bvNone;
  FSaveDiscoveryRootEdit := TEdit.Create(Self);
  FSaveDiscoveryRootEdit.Parent := SaveTools;
  FSaveDiscoveryRootEdit.Left := 12;
  FSaveDiscoveryRootEdit.Top := 10;
  FSaveDiscoveryRootEdit.Width := 630;
  FSaveDiscoveryRootEdit.ReadOnly := True;
  FSaveDiscoveryRootEdit.TextHint := '先由玩家选择并授权一个存档目录；不会自动搜索整台电脑';
  FSaveDiscoveryScanButton := TButton.Create(Self);
  FSaveDiscoveryScanButton.Parent := SaveTools;
  FSaveDiscoveryScanButton.Left := 654;
  FSaveDiscoveryScanButton.Top := 8;
  FSaveDiscoveryScanButton.Width := 170;
  FSaveDiscoveryScanButton.Caption := '选择目录并扫描';
  FSaveDiscoveryScanButton.OnClick := @BrowseAndScanSaveDirectory;
  FSaveDiscoveryCancelButton := TButton.Create(Self);
  FSaveDiscoveryCancelButton.Parent := SaveTools;
  FSaveDiscoveryCancelButton.Left := 836;
  FSaveDiscoveryCancelButton.Top := 8;
  FSaveDiscoveryCancelButton.Width := 90;
  FSaveDiscoveryCancelButton.Caption := '取消扫描';
  FSaveDiscoveryCancelButton.Enabled := False;
  FSaveDiscoveryCancelButton.OnClick := @CancelSaveDirectoryScan;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := SaveTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 42;
  FieldLabel.Caption := '建议位置（仅提示）：文档\\My Games、Saved Games、LocalAppData；程序不会未经授权自动遍历。';
  FSaveDiscoveryList := TListBox.Create(Self);
  FSaveDiscoveryList.Parent := SaveTools;
  FSaveDiscoveryList.Left := 12;
  FSaveDiscoveryList.Top := 64;
  FSaveDiscoveryList.Width := 630;
  FSaveDiscoveryList.Height := 78;
  FSaveDiscoveryInspectButton := TButton.Create(Self);
  FSaveDiscoveryInspectButton.Parent := SaveTools;
  FSaveDiscoveryInspectButton.Left := 654;
  FSaveDiscoveryInspectButton.Top := 64;
  FSaveDiscoveryInspectButton.Width := 170;
  FSaveDiscoveryInspectButton.Caption := '只读检查所选候选';
  FSaveDiscoveryInspectButton.Enabled := False;
  FSaveDiscoveryInspectButton.OnClick := @InspectDiscoveredSave;
  FSaveDiscoveryRevokeButton := TButton.Create(Self);
  FSaveDiscoveryRevokeButton.Parent := SaveTools;
  FSaveDiscoveryRevokeButton.Left := 836;
  FSaveDiscoveryRevokeButton.Top := 64;
  FSaveDiscoveryRevokeButton.Width := 90;
  FSaveDiscoveryRevokeButton.Caption := '撤销授权';
  FSaveDiscoveryRevokeButton.Enabled := False;
  FSaveDiscoveryRevokeButton.OnClick := @RevokeSaveDirectoryScope;
  FSavePathEdit := TEdit.Create(Self);
  FSavePathEdit.Parent := SaveTools;
  FSavePathEdit.Left := 12;
  FSavePathEdit.Top := 164;
  FSavePathEdit.Width := 630;
  FSavePathEdit.ReadOnly := True;
  FSavePathEdit.TextHint := '本机选择授权的单机离线存档';
  RefreshButton := TButton.Create(Self);
  RefreshButton.Parent := SaveTools;
  RefreshButton.Left := 654;
  RefreshButton.Top := 162;
  RefreshButton.Width := 160;
  RefreshButton.Caption := '选择并只读检查';
  RefreshButton.OnClick := @BrowseAndInspectSave;
  FSaveBackupButton := TButton.Create(Self);
  FSaveBackupButton.Parent := SaveTools;
  FSaveBackupButton.Left := 12;
  FSaveBackupButton.Top := 206;
  FSaveBackupButton.Width := 160;
  FSaveBackupButton.Caption := '本机审批并备份';
  FSaveBackupButton.Enabled := False;
  FSaveBackupButton.OnClick := @BackupSave;
  FSaveEditButton := TButton.Create(Self);
  FSaveEditButton.Parent := SaveTools;
  FSaveEditButton.Left := 184;
  FSaveEditButton.Top := 206;
  FSaveEditButton.Width := 180;
  FSaveEditButton.Caption := '本机审批字段编辑';
  FSaveEditButton.Enabled := False;
  FSaveEditButton.OnClick := @ApproveSaveEdit;
  FSaveRestoreButton := TButton.Create(Self);
  FSaveRestoreButton.Parent := SaveTools;
  FSaveRestoreButton.Left := 376;
  FSaveRestoreButton.Top := 206;
  FSaveRestoreButton.Width := 180;
  FSaveRestoreButton.Caption := '本机审批恢复备份';
  FSaveRestoreButton.Enabled := False;
  FSaveRestoreButton.OnClick := @RestoreSave;
  FSaveFieldEdit := TEdit.Create(Self);
  FSaveFieldEdit.Parent := SaveTools;
  FSaveFieldEdit.Left := 12;
  FSaveFieldEdit.Top := 251;
  FSaveFieldEdit.Width := 130;
  FSaveFieldEdit.TextHint := '字段，如 /hp';
  FSaveExpectedEdit := TEdit.Create(Self);
  FSaveExpectedEdit.Parent := SaveTools;
  FSaveExpectedEdit.Left := 154;
  FSaveExpectedEdit.Top := 251;
  FSaveExpectedEdit.Width := 130;
  FSaveExpectedEdit.TextHint := '预期原值';
  FSaveNewEdit := TEdit.Create(Self);
  FSaveNewEdit.Parent := SaveTools;
  FSaveNewEdit.Left := 296;
  FSaveNewEdit.Top := 251;
  FSaveNewEdit.Width := 130;
  FSaveNewEdit.TextHint := '建议新值';
  FSaveProposeButton := TButton.Create(Self);
  FSaveProposeButton.Parent := SaveTools;
  FSaveProposeButton.Left := 438;
  FSaveProposeButton.Top := 249;
  FSaveProposeButton.Width := 170;
  FSaveProposeButton.Caption := '仅生成字段提议';
  FSaveProposeButton.Enabled := False;
  FSaveProposeButton.OnClick := @ProposeSaveEdit;
  FSaveMCPIdEdit := TEdit.Create(Self);
  FSaveMCPIdEdit.Parent := SaveTools;
  FSaveMCPIdEdit.Left := 12;
  FSaveMCPIdEdit.Top := 293;
  FSaveMCPIdEdit.Width := 414;
  FSaveMCPIdEdit.TextHint := 'MCP 请求生成的备份 Effect ID';
  RefreshButton := TButton.Create(Self);
  RefreshButton.Parent := SaveTools;
  RefreshButton.Left := 438;
  RefreshButton.Top := 291;
  RefreshButton.Width := 170;
  RefreshButton.Caption := '本机审批 MCP 备份';
  RefreshButton.OnClick := @ApproveRequestedBackup;
  FSaveMemo := TMemo.Create(Self);
  FSaveMemo.Parent := SavePage;
  FSaveMemo.Align := alClient;
  FSaveMemo.ReadOnly := True;
  FSaveMemo.ScrollBars := ssAutoBoth;
  FSaveMemo.Text := '未知格式只读。当前阶段不提供写入入口；测试格式不能代表真实游戏兼容。';

  LLMPage := TTabSheet.Create(Self);
  LLMPage.PageControl := Pages;
  LLMPage.Caption := 'LLM 工作台';
  LLMTools := TPanel.Create(Self);
  LLMTools.Parent := LLMPage;
  LLMTools.Align := alTop;
  LLMTools.Height := 150;
  LLMTools.BevelOuter := bvNone;
  FLLMProviderBox := TComboBox.Create(Self);
  FLLMProviderBox.Parent := LLMTools;
  FLLMProviderBox.Left := 12;
  FLLMProviderBox.Top := 8;
  FLLMProviderBox.Width := 158;
  FLLMProviderBox.Style := csDropDownList;
  FLLMProviderBox.Items.Add('openai-compatible');
  FLLMProviderBox.Items.Add('anthropic-compatible');
  FLLMProviderBox.ItemIndex := 0;
  FLLMEndpointEdit := TEdit.Create(Self);
  FLLMEndpointEdit.Parent := LLMTools;
  FLLMEndpointEdit.Left := 180;
  FLLMEndpointEdit.Top := 8;
  FLLMEndpointEdit.Width := 400;
  FLLMEndpointEdit.Text := 'https://api.openai.com/v1/chat/completions';
  FLLMModelEdit := TEdit.Create(Self);
  FLLMModelEdit.Parent := LLMTools;
  FLLMModelEdit.Left := 590;
  FLLMModelEdit.Top := 8;
  FLLMModelEdit.Width := 180;
  FLLMModelEdit.TextHint := '模型 ID';
  FLLMSecretRefEdit := TEdit.Create(Self);
  FLLMSecretRefEdit.Parent := LLMTools;
  FLLMSecretRefEdit.Left := 760;
  FLLMSecretRefEdit.Top := 8;
  FLLMSecretRefEdit.Width := 178;
  FLLMSecretRefEdit.Text := 'CheatEngineAgent/OpenAI';
  FLLMSecretRefEdit.Hint := 'Windows Credential Manager 通用凭据目标名';
  FLLMSecretRefEdit.ShowHint := True;
  FLLMApiKeyEdit := TEdit.Create(Self);
  FLLMApiKeyEdit.Parent := LLMTools;
  FLLMApiKeyEdit.Left := 12;
  FLLMApiKeyEdit.Top := 43;
  FLLMApiKeyEdit.Width := 480;
  FLLMApiKeyEdit.PasswordChar := '*';
  FLLMApiKeyEdit.TextHint := 'API Key（仅保存到 Windows Credential Manager）';
  SaveSecretButton := TButton.Create(Self);
  SaveSecretButton.Parent := LLMTools;
  SaveSecretButton.Left := 505;
  SaveSecretButton.Top := 41;
  SaveSecretButton.Width := 180;
  SaveSecretButton.Caption := '安全保存 API Key';
  SaveSecretButton.OnClick := @SaveLLMCredential;
  FLLMQueryEdit := TEdit.Create(Self);
  FLLMQueryEdit.Parent := LLMTools;
  FLLMQueryEdit.Left := 12;
  FLLMQueryEdit.Top := 78;
  FLLMQueryEdit.Width := 673;
  FLLMQueryEdit.TextHint := 'CT RAG 检索词';
  FLLMRunButton := TButton.Create(Self);
  FLLMRunButton.Parent := LLMTools;
  FLLMRunButton.Left := 698;
  FLLMRunButton.Top := 76;
  FLLMRunButton.Width := 155;
  FLLMRunButton.Caption := '调用模型（仅提议）';
  FLLMRunButton.OnClick := @RunLLM;
  FLLMCancelButton := TButton.Create(Self);
  FLLMCancelButton.Parent := LLMTools;
  FLLMCancelButton.Left := 861;
  FLLMCancelButton.Top := 76;
  FLLMCancelButton.Width := 77;
  FLLMCancelButton.Caption := '取消';
  FLLMCancelButton.Enabled := False;
  FLLMCancelButton.OnClick := @CancelLLM;
  FieldLabel := TLabel.Create(Self);
  FieldLabel.Parent := LLMTools;
  FieldLabel.Left := 12;
  FieldLabel.Top := 115;
  FieldLabel.Caption := 'API 密钥只从 Windows Credential Manager 读取，不保存到配置、数据库或输出。';
  FLLMPromptMemo := TMemo.Create(Self);
  FLLMPromptMemo.Parent := LLMPage;
  FLLMPromptMemo.Align := alTop;
  FLLMPromptMemo.Top := LLMTools.Height;
  FLLMPromptMemo.Height := 130;
  FLLMPromptMemo.Text := '根据 CT 证据提出定位和验证假设。不要直接执行写入。';
  FLLMOutputMemo := TMemo.Create(Self);
  FLLMOutputMemo.Parent := LLMPage;
  FLLMOutputMemo.Align := alClient;
  FLLMOutputMemo.ReadOnly := True;
  FLLMOutputMemo.ScrollBars := ssAutoBoth;

  MCPPage := TTabSheet.Create(Self);
  MCPPage.PageControl := Pages;
  MCPPage.Caption := 'MCP';
  FMCPMemo := TMemo.Create(Self);
  FMCPMemo.Parent := MCPPage;
  FMCPMemo.Align := alClient;
  FMCPMemo.ReadOnly := True;
  FMCPMemo.ScrollBars := ssAutoBoth;

  SecurityPage := TTabSheet.Create(Self);
  SecurityPage.PageControl := Pages;
  SecurityPage.Caption := '关于与安全';
  SecurityMemo := TMemo.Create(Self);
  SecurityMemo.Parent := SecurityPage;
  SecurityMemo.Align := alClient;
  SecurityMemo.ReadOnly := True;
  SecurityMemo.ScrollBars := ssAutoBoth;
  ReleaseReader := TCEAReleaseIdentity.Create;
  try
    ReleaseResult := ReleaseReader.ReadCurrent(ReleaseInfo);
    if ReleaseResult.Failed then
      SecurityMemo.Text := '构建身份读取失败：' + ReleaseResult.StableCode
    else
      SecurityMemo.Text := '版本：' + ReleaseInfo.Version + LineEnding +
        '渠道：' + ReleaseInfo.BuildChannel +
        '（内部测试，不可作为公开发布包）' + LineEnding +
        'EXE SHA-256：' + ReleaseInfo.Sha256 + LineEnding +
        'Authenticode：' + ReleaseInfo.SignatureStatus + LineEnding +
        '字节数：' + IntToStr(ReleaseInfo.ByteCount) + LineEnding + LineEnding +
        'Defender Antivirus 检测/隔离：暂停使用并记录检测名称与此哈希，' +
        '由维护者复核并通过微软开发者样本入口处理。' + LineEnding +
        'SmartScreen“未识别应用”：这是下载信誉/来源提示，不等同于' +
        ' Antivirus 误报。' + LineEnding +
        '本程序不会关闭 Defender、恢复隔离文件、添加排除项或绕过企业策略。';
  finally
    ReleaseReader.Free;
  end;

  FRuntime := TCEAStandaloneRuntime.Create;
  StartResult := FRuntime.Start;
  if StartResult.Failed then
    FStatusLabel.Caption := '治理服务：启动失败 / ' + StartResult.StableCode
  else
  begin
    FStatusLabel.Caption := '治理服务：已就绪（独立运行）';
    FMCPMemo.Text := 'Endpoint: ' + FRuntime.MCPEndpoint + LineEnding +
      'Bearer token（仅本次运行）: ' + FRuntime.MCPToken + LineEnding +
      LineEnding + '仅监听 127.0.0.1。MCP 可以查询、扫描、检索 CT 和创建 ' +
      'Effect，但不能批准自己的 Effect。紧急停止会立即撤销此令牌。';
  end;

  FPumpTimer := TTimer.Create(Self);
  FPumpTimer.Interval := 15;
  FPumpTimer.OnTimer := @PumpTimerTick;
  FPumpTimer.Enabled := not StartResult.Failed;

  // 默认进入玩家工作台；诊断页签仍可在右侧切换。
  Pages.ActivePage := PlayerTab;
  FFieldIds := TStringList.Create;
  SelectPlayerSection(0);
end;

procedure TCEAMainForm.StartProcessValueScan(Sender: TObject);
var
  Input: TCEAValueScanUiInput;
  R: TCEAResult;
  Data: TJSONData;
begin
  if FScanScopeId <> '' then
  begin
    MessageDlg('请先撤销单独授权的 MCP 范围，再启动本机扫描。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if (FAttachedIdentity.Id = '') or (FScanId <> '') then
  begin
    MessageDlg('请先附加授权单机进程并结束当前扫描会话。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  R := ValidateProcessValueScanUiInput(FScanRegionKindsBox.Text,
    Trim(FScanSizeEdit.Text), FScanValueTypeBox.Text,
    Trim(FScanValueEdit.Text), Trim(FScanMaxResultsEdit.Text), Input);
  if R.Failed then
  begin
    MessageDlg('进程区域扫描参数无效：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('确认进程区域只读扫描',
    '目标 PID ' + IntToStr(FAttachedIdentity.Pid) +
    ' / epoch ' + IntToStr(FAttachedIdentity.Epoch) + LineEnding +
    '区域类型：' + FScanRegionKindsBox.Text + '；最多读取 ' +
    IntToStr(Input.RangeBytes) + ' 字节、返回 ' +
    IntToStr(Input.MaxResults) + ' 个候选。' + LineEnding +
    'private 为默认；image/mapped 只有在此处明确选择才会包含。' +
    LineEnding + '达到预算将报告 partial，不会写入游戏。继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.StartProcessValueScan(FScanRegionKindsBox.Text,
    Input.RangeBytes, Input.ValueType, Input.ValueText, Input.MaxResults);
  if R.Failed then
  begin
    FScanCoverageLabel.Caption := '进程区域扫描失败：' + R.StableCode;
    MessageDlg('进程区域扫描失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FOutputMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    FScanId := TJSONObject(Data).Get('scan_id', '');
  finally
    Data.Free;
  end;
  FScanCancelButton.Enabled := FScanId <> '';
  FScanRefineButton.Enabled := False;
  FScanIsAob := False;
  FScanAobJudgeButton.Enabled := False;
  FScanAobLabel.Caption := '当前为数值扫描，不是签名会话。';
  if FScanId <> '' then
  begin
    FScanTypeAtStart := Input.ValueType;
    FScanStartEdit.Enabled := False;
    FScanSizeEdit.Enabled := False;
    FScanMaxResultsEdit.Enabled := False;
    FScanValueTypeBox.Enabled := False;
    FScanRegionKindsBox.Enabled := False;
    FScanModuleEdit.Enabled := False;
    FScanAobEdit.Enabled := False;
    FScanCoverageLabel.Caption :=
      '正在后台扫描本机已确认的进程区域；等待覆盖率结果…';
  end;
end;

procedure TCEAMainForm.StartAobSignatureScan(Sender: TObject);
var
  ModuleName, Pattern: string;
  MaxBytes, MaxResults: Cardinal;
  R: TCEAResult;
  Data: TJSONData;
begin
  if FScanScopeId <> '' then
  begin
    MessageDlg('请先撤销单独授权的 MCP 范围，再启动本机扫描。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if (FAttachedIdentity.Id = '') or (FScanId <> '') then
  begin
    MessageDlg('请先附加授权单机进程并结束当前扫描会话。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  ModuleName := Trim(FScanModuleEdit.Text);
  Pattern := Trim(FScanAobEdit.Text);
  if ModuleName = '' then
  begin
    MessageDlg('请填写要扫描的模块名（例如游戏主程序 exe）。',
      mtError, [mbOK], 0);
    Exit;
  end;
  if Pattern = '' then
  begin
    MessageDlg('请填写 AOB 签名，字节用空格分隔，通配符用 ??。',
      mtError, [mbOK], 0);
    Exit;
  end;
  if not TryStrToDWord(Trim(FScanSizeEdit.Text), MaxBytes) or
     (MaxBytes = 0) then
  begin
    MessageDlg('扫描字节上限无效。', mtError, [mbOK], 0);
    Exit;
  end;
  if not TryStrToDWord(Trim(FScanMaxResultsEdit.Text), MaxResults) or
     (MaxResults = 0) then
  begin
    MessageDlg('结果上限无效。', mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('确认签名扫描范围',
    '目标 PID ' + IntToStr(FAttachedIdentity.Pid) +
    ' / epoch ' + IntToStr(FAttachedIdentity.Epoch) + LineEnding +
    '模块：' + ModuleName + LineEnding +
    '签名：' + Pattern + LineEnding +
    '最多读取 ' + IntToStr(MaxBytes) + ' 字节、返回 ' +
    IntToStr(MaxResults) + ' 个候选。' + LineEnding +
    '签名必须在模块内唯一命中才能作为写入锚点；多命中会被判为歧义。' +
    LineEnding + '只读扫描，不写入游戏。继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.StartAobScan(ModuleName, Pattern, MaxBytes, MaxResults);
  if R.Failed then
  begin
    FScanAobLabel.Caption := '签名扫描失败：' + R.StableCode;
    MessageDlg('签名扫描失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FOutputMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    FScanId := TJSONObject(Data).Get('scan_id', '');
  finally
    Data.Free;
  end;
  FScanIsAob := True;
  FScanCancelButton.Enabled := FScanId <> '';
  FScanRefineButton.Enabled := False;
  FScanAobJudgeButton.Enabled := FScanId <> '';
  if FScanId <> '' then
  begin
    FScanTypeAtStart := '';
    FScanStartEdit.Enabled := False;
    FScanSizeEdit.Enabled := False;
    FScanMaxResultsEdit.Enabled := False;
    FScanValueTypeBox.Enabled := False;
    FScanRegionKindsBox.Enabled := False;
    FScanModuleEdit.Enabled := False;
    FScanAobEdit.Enabled := False;
    FScanAobLabel.Caption := '签名已提交，正在等待唯一性判定…';
    FScanCoverageLabel.Caption :=
      '覆盖率只针对该模块内的所选字节；未扫描的模块区域不可解释为“未找到”。';
  end;
end;

procedure TCEAMainForm.JudgeAobUniqueness(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  MatchCount: Int64;
  Verdict: string;
begin
  if (FScanId = '') or not FScanIsAob then
  begin
    MessageDlg('当前没有可判定的签名扫描会话。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.GetAobScanUniqueness(FScanId);
  if R.Failed then
  begin
    FScanAobLabel.Caption := '唯一性判定失败：' + R.StableCode;
    MessageDlg('唯一性判定失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FOutputMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    MatchCount := TJSONObject(Data).Get('match_count', Int64(0));
    Verdict := TJSONObject(Data).Get('verdict', '');
    if TJSONObject(Data).Get('unique', False) then
      FScanAobLabel.Caption := '唯一命中（1 处）：签名可作为写入锚点。'
    else if Verdict = 'not_found' then
      FScanAobLabel.Caption :=
        '零命中：签名在此模块内不存在，可能版本不同或签名错误。'
    else
      FScanAobLabel.Caption := '命中 ' + IntToStr(MatchCount) +
        ' 处：签名歧义，不能作为写入锚点。';
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.ApproveRequestedBackup(Sender: TObject);
var
  Effect: TCEAEffect;
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  if FSaveSnapshot.Id = '' then
  begin
    MessageDlg('请先在本机选择并检查目标存档。', mtError, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.LoadEffect(Trim(FSaveMCPIdEdit.Text), Effect);
  if R.Failed then
  begin
    MessageDlg('Effect 不存在：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  if (Effect.CapabilityId <> 'save_backup') or
     (Effect.ResourceKind <> rkSaveFile) or
     (Effect.ResourceIdentityId <> FSaveSnapshot.FileIdentityId) or
     (Effect.State <> esPlanned) then
  begin
    MessageDlg('Effect 与当前存档或操作类型不匹配。',
      mtError, [mbOK], 0);
    Exit;
  end;
  Data := nil;
  try
    try
      Data := GetJSON(Effect.RequestJson);
    except
      MessageDlg('Effect 请求无效。', mtError, [mbOK], 0);
      Exit;
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then Exit;
    Obj := TJSONObject(Data);
    if (Obj.Get('snapshot_id', '') <> FSaveSnapshot.Id) or
       (Obj.Get('sha256', '') <> FSaveSnapshot.Sha256) or
       (Obj.Get('source_path', '') <> FSaveSnapshot.CanonicalPath) then
    begin
      MessageDlg('Effect 基线与当前选择不匹配。', mtError, [mbOK], 0);
      Exit;
    end;
  finally
    Data.Free;
  end;
  if MessageDlg('本机审批 MCP 备份请求',
    'MCP 只能计划此备份；现在由你本机审批。' + LineEnding +
    'Effect ID：' + Effect.Id + LineEnding +
    '源 SHA-256：' + FSaveSnapshot.Sha256 + LineEnding +
    '批准一次性备份并读回？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(Effect.Id);
    Exit;
  end;
  R := FRuntime.ApproveAndExecute(Effect.Id);
  FSaveMemo.Lines.Add('MCP 请求备份结果：' + R.StableCode);
  FSaveMemo.Lines.Add('Receipt：' + R.ReceiptId);
  FSaveMemo.Lines.Add('Proof：' + R.ProofId);
  if R.Failed then
    MessageDlg('备份未确认成功：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FSaveBackupEffectId := Effect.Id;
    FSaveEditButton.Enabled := (FSaveProposal.Id <> '') and
      (FSaveSnapshot.FormatDescriptor.Id = 'cea-fixture-save');
    MessageDlg('备份验证完成。', mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.ResetSaveSelection;
begin
  FillChar(FSaveSnapshot, SizeOf(FSaveSnapshot), 0);
  FillChar(FSaveProposal, SizeOf(FSaveProposal), 0);
  FSaveBackupEffectId := '';
  FSavePathEdit.Clear;
  FSaveBackupButton.Enabled := False;
  FSaveProposeButton.Enabled := False;
  FSaveEditButton.Enabled := False;
  FSaveRestoreButton.Enabled := False;
end;

procedure TCEAMainForm.PresentSaveSnapshot(
  const ASnapshot: TCEASaveSnapshot; const ADisplayPath: string);
var
  Fields: TCEASaveFieldArray;
  FormatText: string;
  I: Integer;
begin
  FSavePathEdit.Text := ADisplayPath;
  FSaveSnapshot := ASnapshot;
  FSaveBackupButton.Enabled := True;
  FSaveProposeButton.Enabled := ASnapshot.FormatDescriptor.Id <> '';
  FormatText := ASnapshot.FormatDescriptor.Id;
    if FormatText = '' then FormatText := '未知（只读）'
    else FormatText := FormatText + ' / 版本 ' +
      ASnapshot.FormatDescriptor.Version;
  FSaveMemo.Text := '快照 ID：' + ASnapshot.Id + LineEnding +
      '文件身份：' + ASnapshot.FileIdentityId + LineEnding +
      '字节数：' + IntToStr(ASnapshot.ByteCount) + LineEnding +
      'SHA-256：' + ASnapshot.Sha256 + LineEnding +
      '读取覆盖：' + IntToStr(ASnapshot.ReadCoverage) + '/' +
      IntToStr(ASnapshot.ByteCount) + LineEnding +
      '格式：' + FormatText + LineEnding +
      '可编辑：否（即使测试格式识别成功，仍需备份与编辑审批闭环）。' +
      LineEnding + '可创建独立备份；编辑和恢复仍不可用。';
  if not FRuntime.GetSaveFields(ASnapshot, Fields).Failed then
  begin
    FSaveMemo.Lines.Add('只读字段观察：');
    for I := 0 to High(Fields) do
      FSaveMemo.Lines.Add(Fields[I].Path + ' = ' + Fields[I].ValueJson);
  end;
end;

procedure TCEAMainForm.BrowseAndInspectSave(Sender: TObject);
var
  Dialog: TOpenDialog;
  Snapshot: TCEASaveSnapshot;
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then Exit;
  if Assigned(FSaveDiscoveryWorker) then
  begin
    MessageDlg('请先取消或等待目录扫描完成。', mtInformation,
      [mbOK], 0);
    Exit;
  end;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Title := '选择你有权操作的单机离线存档';
    if not Dialog.Execute then Exit;
    if MessageDlg('存档授权确认',
      '确认这是你有权读取的单机离线存档？本操作只读，不会修改文件。',
      mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
    if FSaveDiscoveryScope.Id <> '' then
    begin
      FRuntime.RevokeSaveDirectory(FSaveDiscoveryScope.Id);
      FillChar(FSaveDiscoveryScope, SizeOf(FSaveDiscoveryScope), 0);
      SetLength(FSaveDiscoveryCandidates, 0);
      FSaveDiscoveryList.Clear;
      FSaveDiscoveryRootEdit.Clear;
      FSaveDiscoveryInspectButton.Enabled := False;
      FSaveDiscoveryRevokeButton.Enabled := False;
    end;
    ResetSaveSelection;
    R := FRuntime.InspectSaveFile('task-ui-save-inspect', Dialog.FileName,
      Snapshot);
    if R.Failed then
    begin
      FSaveMemo.Text := '只读检查失败：' + R.StableCode;
      MessageDlg('存档检查失败：' + R.StableCode, mtError, [mbOK], 0);
      Exit;
    end;
    PresentSaveSnapshot(Snapshot, Dialog.FileName);
  finally
    Dialog.Free;
  end;
end;

procedure TCEAMainForm.BrowseAndScanSaveDirectory(Sender: TObject);
var
  DirectoryName: string;
  Budget: TCEADiscoveryBudget;
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started or
     Assigned(FSaveDiscoveryWorker) then Exit;
  DirectoryName := '';
  if not SelectDirectory('选择你有权读取的单机存档目录', '',
    DirectoryName) then Exit;
  if MessageDlg('目录读取授权',
    '只扫描此目录及最多 4 层子目录，最多 4096 个文件、30 秒。' +
    LineEnding + '不会自动扩展到父目录，也不会把目录扫描能力暴露给 MCP。' +
    LineEnding + '确认授权本次会话只读扫描？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  Budget.MaxFiles := 4096;
  Budget.MaxDepth := 4;
  Budget.MaxDurationMs := 30000;
  ResetSaveSelection;
  FSaveDiscoveryList.Clear;
  SetLength(FSaveDiscoveryCandidates, 0);
  R := FRuntime.AuthorizeSaveDirectory(DirectoryName, Budget,
    FSaveDiscoveryScope);
  if R.Failed then
  begin
    MessageDlg('目录授权失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FSaveDiscoveryRootEdit.Text := FSaveDiscoveryScope.RootPath;
  FSaveDiscoveryScanButton.Enabled := False;
  FSaveDiscoveryCancelButton.Enabled := True;
  FSaveDiscoveryRevokeButton.Enabled := True;
  FSaveDiscoveryInspectButton.Enabled := False;
  FSaveMemo.Text := '正在后台扫描授权目录；候选列表只显示相对路径、大小和时间。';
  FSaveDiscoveryWorker := TCEASaveDiscoveryWorker.Create(FRuntime,
    FSaveDiscoveryScope.Id);
  FSaveDiscoveryWorker.Start;
end;

procedure TCEAMainForm.CancelSaveDirectoryScan(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FSaveDiscoveryWorker) or
     (FSaveDiscoveryScope.Id = '') then Exit;
  R := FRuntime.CancelSaveDirectory(FSaveDiscoveryScope.Id);
  FSaveDiscoveryCancelButton.Enabled := False;
  FSaveMemo.Lines.Add('取消请求：' + R.StableCode +
    '（将在下一个目录枚举边界生效）');
end;

procedure TCEAMainForm.RevokeSaveDirectoryScope(Sender: TObject);
var
  R: TCEAResult;
begin
  if FSaveDiscoveryScope.Id = '' then Exit;
  if Assigned(FSaveDiscoveryWorker) then
  begin
    FRuntime.CancelSaveDirectory(FSaveDiscoveryScope.Id);
    FSaveDiscoveryWorker.WaitFor;
    FreeAndNil(FSaveDiscoveryWorker);
  end;
  R := FRuntime.RevokeSaveDirectory(FSaveDiscoveryScope.Id);
  ResetSaveSelection;
  SetLength(FSaveDiscoveryCandidates, 0);
  FSaveDiscoveryList.Clear;
  FSaveDiscoveryRootEdit.Clear;
  FillChar(FSaveDiscoveryScope, SizeOf(FSaveDiscoveryScope), 0);
  FSaveDiscoveryScanButton.Enabled := True;
  FSaveDiscoveryCancelButton.Enabled := False;
  FSaveDiscoveryInspectButton.Enabled := False;
  FSaveDiscoveryRevokeButton.Enabled := False;
  FSaveMemo.Text := '目录授权已撤销：' + R.StableCode +
    LineEnding + '该目录选择产生的待审批写入计划已被拒绝。';
end;

procedure TCEAMainForm.InspectDiscoveredSave(Sender: TObject);
var
  Snapshot: TCEASaveSnapshot;
  R: TCEAResult;
  I: Integer;
begin
  I := FSaveDiscoveryList.ItemIndex;
  if (FSaveDiscoveryScope.Id = '') or (I < 0) or
     (I > High(FSaveDiscoveryCandidates)) then Exit;
  ResetSaveSelection;
  R := FRuntime.SelectSaveCandidate(FSaveDiscoveryScope.Id,
    FSaveDiscoveryCandidates[I].Id, Snapshot);
  if R.Failed then
  begin
    FSaveMemo.Text := '候选文件已变化或不再安全：' + R.StableCode;
    MessageDlg('只读检查失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  PresentSaveSnapshot(Snapshot,
    FSaveDiscoveryCandidates[I].RelativePath);
end;

procedure TCEAMainForm.CompleteSaveDiscoveryIfReady;
var
  I: Integer;
  R: TCEAResult;
begin
  if not Assigned(FSaveDiscoveryWorker) or
     not FSaveDiscoveryWorker.Completed then Exit;
  FSaveDiscoveryWorker.WaitFor;
  R := FSaveDiscoveryWorker.ScanResult;
  FSaveDiscoveryCandidates := FSaveDiscoveryWorker.Candidates;
  FreeAndNil(FSaveDiscoveryWorker);
  FSaveDiscoveryList.Clear;
  for I := 0 to High(FSaveDiscoveryCandidates) do
    FSaveDiscoveryList.Items.Add(
      FSaveDiscoveryCandidates[I].RelativePath + '  (' +
      IntToStr(FSaveDiscoveryCandidates[I].ByteCount) + ' bytes, ' +
      FormatDateTime('yyyy-mm-dd hh:nn:ss',
        FSaveDiscoveryCandidates[I].ModifiedAt) + ')');
  FSaveDiscoveryScanButton.Enabled := True;
  FSaveDiscoveryCancelButton.Enabled := False;
  FSaveDiscoveryInspectButton.Enabled :=
    (not R.Failed) and (Length(FSaveDiscoveryCandidates) > 0);
  FSaveDiscoveryRevokeButton.Enabled := FSaveDiscoveryScope.Id <> '';
  if R.Failed then
    FSaveMemo.Text := '目录扫描结束：' + R.StableCode
  else
    FSaveMemo.Text := '目录扫描完成：' + R.DataJson + LineEnding +
      '请选择一个候选，再执行只读检查；扫描本身不会解锁写入。';
end;

procedure TCEAMainForm.ProposeSaveEdit(Sender: TObject);
var
  R: TCEAResult;
begin
  if FSaveSnapshot.FormatDescriptor.Id = '' then Exit;
  FillChar(FSaveProposal, SizeOf(FSaveProposal), 0);
  FSaveEditButton.Enabled := False;
  R := FRuntime.ProposeSaveFieldEdit(FSaveSnapshot,
    Trim(FSaveFieldEdit.Text), Trim(FSaveExpectedEdit.Text),
    Trim(FSaveNewEdit.Text), FSaveProposal);
  if R.Failed then
  begin
    MessageDlg('提议未通过验证：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FSaveMemo.Lines.Add('字段提议（无执行权限）：' + R.DataJson);
  FSaveEditButton.Enabled := (FSaveBackupEffectId <> '') and
    (FSaveProposal.Id <> '') and
    (FSaveSnapshot.FormatDescriptor.Id = 'cea-fixture-save');
end;

procedure TCEAMainForm.ApproveSaveEdit(Sender: TObject);
var
  R: TCEAResult;
  EffectId: string;
  SavePath: string;
begin
  if (FSaveSnapshot.FormatDescriptor.Id <> 'cea-fixture-save') or
     (FSaveBackupEffectId = '') or (FSaveProposal.Id = '') then Exit;
  R := FRuntime.PlanSaveEdit('task-ui-save-edit', FSaveSnapshot,
    FSaveProposal, FSaveBackupEffectId, EffectId);
  if R.Code <> rcApprovalRequired then
  begin
    MessageDlg('无法计划编辑：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('本机一次性存档编辑审批',
    '仅支持内置测试格式 CEA-SAVE-1，不代表真实游戏兼容。' +
    LineEnding + '字段：' + FSaveProposal.FieldPath +
    LineEnding + '原值：' + FSaveProposal.ExpectedJson +
    LineEnding + '新值：' + FSaveProposal.NewJson +
    LineEnding + '原始 SHA-256：' + FSaveSnapshot.Sha256 +
    LineEnding + '备份 Effect：' + FSaveBackupEffectId +
    LineEnding + '批准一次性替换并读回？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(EffectId);
    Exit;
  end;
  R := FRuntime.ApproveAndExecute(EffectId);
  FSaveMemo.Lines.Add('编辑结果：' + R.StableCode);
  FSaveMemo.Lines.Add('Receipt：' + R.ReceiptId);
  FSaveMemo.Lines.Add('Proof：' + R.ProofId);
  FSaveEditButton.Enabled := False;
  FSaveProposeButton.Enabled := False;
  FSaveBackupButton.Enabled := False;
  if R.Failed then
    MessageDlg('编辑未确认成功：' + R.StableCode +
      '。请保留备份并检查当前文件，勿自动重试。', mtError, [mbOK], 0)
  else
  begin
    SavePath := FSaveSnapshot.CanonicalPath;
    R := FRuntime.InspectSaveFile('task-ui-save-after-edit',
      SavePath, FSaveSnapshot);
    if not R.Failed then
      FSaveRestoreButton.Enabled := True;
    MessageDlg('测试格式字段编辑与读回完成。可单独审批恢复备份。',
      mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.RestoreSave(Sender: TObject);
var
  EffectId: string;
  R: TCEAResult;
begin
  if (FSaveSnapshot.Id = '') or (FSaveBackupEffectId = '') then Exit;
  R := FRuntime.PlanSaveRestore('task-ui-save-restore', FSaveSnapshot,
    FSaveBackupEffectId, FSaveSnapshot.Sha256, EffectId);
  if R.Code <> rcApprovalRequired then
  begin
    MessageDlg('无法计划恢复：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('独立恢复审批',
    '将用已验证的备份覆盖当前存档。此操作会丢失编辑后产生的进度。' +
    LineEnding + '当前 SHA-256：' + FSaveSnapshot.Sha256 +
    LineEnding + '备份 Effect：' + FSaveBackupEffectId +
    LineEnding + '新恢复 Effect：' + EffectId +
    LineEnding + '确认一次性恢复并读回？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(EffectId);
    Exit;
  end;
  R := FRuntime.ApproveAndExecute(EffectId);
  FSaveMemo.Lines.Add('恢复结果：' + R.StableCode);
  FSaveMemo.Lines.Add('Receipt：' + R.ReceiptId);
  FSaveMemo.Lines.Add('Proof：' + R.ProofId);
  FSaveRestoreButton.Enabled := False;
  if R.Failed then
    MessageDlg('恢复未确认成功：' + R.StableCode +
      '。勿自动重试，请人工检查文件与备份。', mtError, [mbOK], 0)
  else
    MessageDlg('独立恢复及读回完成。', mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.BackupSave(Sender: TObject);
var
  EffectId: string;
  R: TCEAResult;
begin
  if FSaveSnapshot.Id = '' then Exit;
  R := FRuntime.RequestSaveBackup('task-ui-save-backup', FSaveSnapshot,
    EffectId);
  if R.Code <> rcApprovalRequired then
  begin
    MessageDlg('无法计划备份：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('本机备份审批',
    '将创建此快照的独立、不可覆盖备份。' + LineEnding +
    '原始 SHA-256：' + FSaveSnapshot.Sha256 + LineEnding +
    'Effect ID：' + EffectId + LineEnding + '批准一次性执行？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(EffectId);
    Exit;
  end;
  R := FRuntime.ApproveAndExecute(EffectId);
  FSaveMemo.Lines.Add('备份结果：' + R.StableCode);
  FSaveMemo.Lines.Add('Receipt：' + R.ReceiptId);
  FSaveMemo.Lines.Add('Proof：' + R.ProofId);
  if R.Failed then
    MessageDlg('备份未确认成功：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FSaveBackupEffectId := EffectId;
    FSaveEditButton.Enabled := (FSaveProposal.Id <> '') and
      (FSaveSnapshot.FormatDescriptor.Id = 'cea-fixture-save');
    MessageDlg('备份读回验证完成。', mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.AttachProcess(Sender: TObject);
var
  Pid: Cardinal;
  R: TCEAResult;
begin
  if not TryStrToDWord(Trim(FPidEdit.Text), Pid) or (Pid = 0) then
  begin
    MessageDlg('PID 无效。', mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('授权声明',
    '仅当该进程属于你有权修改的单机/离线游戏时继续。确认附加？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  R := FRuntime.AttachAuthorizedOffline('task-ui-' + IntToStr(Pid), Pid,
    FAttachedIdentity);
  if R.Failed then
    MessageDlg('附加失败：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FScanId := '';
    FScanCancelButton.Enabled := False;
    FStatusLabel.Caption := '已附加 PID ' + IntToStr(Pid) +
      ' / epoch ' + IntToStr(FAttachedIdentity.Epoch);
    FOutputMemo.Text := R.DataJson;
  end;
end;

procedure TCEAMainForm.StartValueScan(Sender: TObject);
var
  Input: TCEAValueScanUiInput;
  R: TCEAResult;
  Data: TJSONData;
  Complete: Boolean;
begin
  if FScanScopeId <> '' then
  begin
    MessageDlg('请先撤销单独授权的 MCP 范围，再启动本机扫描。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if FAttachedIdentity.Id = '' then
  begin
    MessageDlg('请先明确授权并附加单机离线进程。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  R := ValidateValueScanUiInput(Trim(FScanStartEdit.Text),
    Trim(FScanSizeEdit.Text), FScanValueTypeBox.Text,
    Trim(FScanValueEdit.Text), Trim(FScanMaxResultsEdit.Text), Input);
  if R.Failed then
  begin
    MessageDlg('扫描参数无效：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('确认只读范围',
    '目标 PID ' + IntToStr(FAttachedIdentity.Pid) +
    ' / epoch ' + IntToStr(FAttachedIdentity.Epoch) + LineEnding +
    '起始 0x' + IntToHex(Input.StartAddress, 16) +
    '，长度 ' + IntToStr(Input.RangeBytes) + ' 字节；最多 ' +
    IntToStr(Input.MaxResults) + ' 个候选。' + LineEnding +
    '仅扫描所选范围，不写入游戏。继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.StartLocalValueScan('0x' +
    IntToHex(Input.StartAddress, 16), Input.RangeBytes,
    Input.ValueType, Input.ValueText, Input.MaxResults);
  if R.Failed then
  begin
    FScanCoverageLabel.Caption := '扫描失败：' + R.StableCode;
    MessageDlg('只读扫描失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FOutputMemo.Text := R.DataJson;
  Data := nil;
  try
    Data := GetJSON(R.DataJson);
    FScanId := TJSONObject(Data).Get('scan_id', '');
    Complete := TJSONObject(Data).Get('complete', False);
    if TJSONObject(Data).Get('state', '') = 'running' then
      FScanCoverageLabel.Caption := '正在后台扫描所选范围…'
    else if Complete then
      FScanCoverageLabel.Caption := '所选范围完整读取；其他区域未检查。'
    else
      FScanCoverageLabel.Caption := '部分覆盖：' +
        TJSONObject(Data).Get('partial_reason', 'unknown') +
        '；零候选不能解释为整个进程未找到。';
  finally
    Data.Free;
  end;
  FScanCancelButton.Enabled := FScanId <> '';
  FScanRefineButton.Enabled := False;
  FScanIsAob := False;
  FScanAobJudgeButton.Enabled := False;
  FScanAobLabel.Caption := '当前为数值扫描，不是签名会话。';
  if FScanId <> '' then
  begin
    FScanTypeAtStart := Input.ValueType;
    FScanStartEdit.Enabled := False;
    FScanSizeEdit.Enabled := False;
    FScanMaxResultsEdit.Enabled := False;
    FScanValueTypeBox.Enabled := False;
    FScanRegionKindsBox.Enabled := False;
    FScanModuleEdit.Enabled := False;
    FScanAobEdit.Enabled := False;
  end;
end;

procedure TCEAMainForm.PollValueScan;
var
  R: TCEAResult;
  Data: TJSONData;
  State: string;
begin
  if (FScanId = '') or not Assigned(FRuntime) then Exit;
  R := FRuntime.GetLocalValueScanStatus(FScanId);
  if R.Failed then
  begin
    FScanCoverageLabel.Caption := '扫描状态失败：' + R.StableCode;
    Exit;
  end;
  Data := GetJSON(R.DataJson);
  try
    State := TJSONObject(Data).Get('state', '');
    if State = 'running' then Exit;
    FOutputMemo.Text := R.DataJson;
    if State = 'ready' then
    begin
      FScanRefineButton.Enabled := True;
      if TJSONObject(Data).Get('complete', False) then
        FScanCoverageLabel.Caption := '所选范围完整读取；其他区域未检查。'
      else
        FScanCoverageLabel.Caption := '部分覆盖：' +
          TJSONObject(Data).Get('partial_reason', 'unknown') +
          '；零候选不能解释为整个进程未找到。';
    end
    else
    begin
      FScanRefineButton.Enabled := False;
      FScanCoverageLabel.Caption := '扫描已结束：' + State;
    end;
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.AuthorizeMCPValueScanScope(Sender: TObject);
var
  Input: TCEAValueScanUiInput;
  R: TCEAResult;
  Data: TJSONData;
begin
  if (FAttachedIdentity.Id = '') or (FScanId <> '') then
  begin
    MessageDlg('请先附加授权单机进程并结束当前扫描会话。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  R := ValidateValueScanScopeUiInput(Trim(FScanStartEdit.Text),
    Trim(FScanSizeEdit.Text), Trim(FScanMaxResultsEdit.Text), Input);
  if R.Failed then
  begin
    MessageDlg('MCP 范围参数无效：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('单独授权 MCP 只读扫描范围',
    '目标 PID ' + IntToStr(FAttachedIdentity.Pid) +
    ' / epoch ' + IntToStr(FAttachedIdentity.Epoch) + LineEnding +
    '起始 0x' + IntToHex(Input.StartAddress, 16) +
    '，长度 ' + IntToStr(Input.RangeBytes) + ' 字节；最多 ' +
    IntToStr(Input.MaxResults) + ' 个候选。' + LineEnding +
    'MCP 只能在此范围内执行只读扫描，不能创建或扩大范围；' +
    '请在使用完毕后撤销。继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.AuthorizeLocalValueScanScope('0x' +
    IntToHex(Input.StartAddress, 16), Input.RangeBytes,
    Input.MaxResults);
  if R.Failed then
  begin
    MessageDlg('MCP 范围授权失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  Data := GetJSON(R.DataJson);
  try
    FScanScopeId := TJSONObject(Data).Get('scope_id', '');
  finally
    Data.Free;
  end;
  FScanScopeRevokeButton.Enabled := FScanScopeId <> '';
  FScanScopeLabel.Caption := '仅当前会话 Scope ID：' + FScanScopeId;
  FOutputMemo.Text := R.DataJson;
end;

procedure TCEAMainForm.RevokeMCPValueScanScope(Sender: TObject);
var
  R: TCEAResult;
begin
  if FScanScopeId = '' then Exit;
  R := FRuntime.RevokeLocalValueScanScope(FScanScopeId);
  if R.Failed then
  begin
    MessageDlg('撤销范围失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FScanScopeId := '';
  FScanScopeRevokeButton.Enabled := False;
  FScanScopeLabel.Caption := 'MCP 只读范围已撤销。';
  FOutputMemo.Text := R.DataJson;
end;

procedure TCEAMainForm.RefineValueScan(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
begin
  R := ValidateValueRefineUiInput(FScanId, FScanTypeAtStart,
    FScanValueTypeBox.Text, Trim(FScanValueEdit.Text));
  if R.Failed then
  begin
    MessageDlg('复筛参数无效：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.RefineLocalValueScan(FScanId,
    Trim(FScanValueEdit.Text));
  if R.Failed then
  begin
    FScanCoverageLabel.Caption := '复筛失败：' + R.StableCode;
    MessageDlg('只读复筛失败：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FOutputMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    if TJSONObject(Data).Get('complete', False) then
      FScanCoverageLabel.Caption := '复筛完成；覆盖率仍仅针对初次所选范围。'
    else
      FScanCoverageLabel.Caption := '复筛候选来自部分覆盖范围：' +
        TJSONObject(Data).Get('partial_reason', 'unknown') +
        '；零候选不能解释为整个进程未找到。';
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.CancelValueScan(Sender: TObject);
var
  R: TCEAResult;
begin
  if FScanId = '' then Exit;
  R := FRuntime.CancelLocalValueScan(FScanId);
  if R.Failed then
    MessageDlg('结束扫描会话失败：' + R.StableCode,
      mtError, [mbOK], 0)
  else
  begin
    FScanId := '';
    FScanTypeAtStart := '';
    FScanIsAob := False;
    FScanRefineButton.Enabled := False;
    FScanCancelButton.Enabled := False;
    FScanAobJudgeButton.Enabled := False;
    FScanAobLabel.Caption := '签名会话已结束。';
    FScanStartEdit.Enabled := True;
    FScanSizeEdit.Enabled := True;
    FScanMaxResultsEdit.Enabled := True;
    FScanValueTypeBox.Enabled := True;
    FScanRegionKindsBox.Enabled := True;
    FScanModuleEdit.Enabled := True;
    FScanAobEdit.Enabled := True;
    FScanCoverageLabel.Caption := '扫描会话已结束；候选地址不再有效。';
  end;
end;

procedure TCEAMainForm.PlanMemoryWrite(Sender: TObject);
var
  Effect: TCEAEffect;
  R: TCEAResult;
  ApprovalText: string;
begin
  if FAttachedIdentity.Id = '' then
  begin
    MessageDlg('请先附加已授权的单机离线进程。', mtError, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.PlanMemoryWrite('task-ui-write', Trim(FAddressEdit.Text),
    Trim(FExpectedEdit.Text), Trim(FReplacementEdit.Text), Effect);
  if R.Code <> rcApprovalRequired then
  begin
    MessageDlg('无法创建写入 Effect：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  ApprovalText := '这是一次真实进程内存写入。' + LineEnding + LineEnding +
    '目标：' + Effect.ProcessIdentityId + LineEnding +
    '请求哈希：' + Effect.RequestHash + LineEnding +
    '请求：' + Effect.RequestJson + LineEnding + LineEnding +
    '将先核对原字节，写入后立即读回，并保存 Receipt/Proof。' +
    LineEnding + '批准一次性执行？';
  if MessageDlg('本机一次性审批', ApprovalText,
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(Effect.Id);
    FOutputMemo.Text := '{"effect_id":"' + Effect.Id +
      '","state":"rejected_by_local_user"}';
    Exit;
  end;
  R := FRuntime.ApproveAndExecute(Effect.Id);
  if R.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
    FEffectIdEdit.Text := Effect.Id;
  FOutputMemo.Text := R.DataJson + LineEnding +
    'receipt_id=' + R.ReceiptId + LineEnding + 'proof_id=' + R.ProofId;
  if R.Failed then
    MessageDlg('写入未成功：' + R.StableCode,
      mtError, [mbOK], 0)
  else
    MessageDlg('写入并读回验证成功。Receipt/Proof 已保存。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.ReconcileEffect(Sender: TObject);
var
  R: TCEAResult;
begin
  if Trim(FEffectIdEdit.Text) = '' then
  begin
    MessageDlg('请输入 Unknown Effect ID。', mtError, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('显式恢复对账',
    '将只读检查当前字节，判断先前写入是否已生效。不会自动重试，也不会自动回滚。继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  R := FRuntime.ReconcileUnknownEffect(Trim(FEffectIdEdit.Text));
  FOutputMemo.Text := R.DataJson + LineEnding +
    'receipt_id=' + R.ReceiptId + LineEnding + 'proof_id=' + R.ProofId;
  if R.Failed then
    MessageDlg('对账未得出确定结论：' + R.StableCode,
      mtError, [mbOK], 0)
  else
    MessageDlg('对账完成：' + R.StableCode + '。结果与 Proof 已保存。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.PlanMemoryFreeze(Sender: TObject);
var
  Effect: TCEAEffect;
  R: TCEAResult;
  IntervalMs, MaxWrites, DurationSeconds: Cardinal;
  ApprovalText: string;
begin
  if FAttachedIdentity.Id = '' then
  begin
    MessageDlg('请先附加已授权的单机离线进程。', mtError, [mbOK], 0);
    Exit;
  end;
  if not TryStrToDWord(Trim(FFreezeIntervalEdit.Text), IntervalMs) or
     not TryStrToDWord(Trim(FFreezeMaxWritesEdit.Text), MaxWrites) or
     not TryStrToDWord(Trim(FFreezeDurationEdit.Text), DurationSeconds) then
  begin
    MessageDlg('冻结间隔、最大写入和持续秒数必须是整数。',
      mtError, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.PlanMemoryFreeze('task-ui-freeze', Trim(FAddressEdit.Text),
    Trim(FExpectedEdit.Text), Trim(FReplacementEdit.Text), IntervalMs,
    MaxWrites, DurationSeconds, Effect);
  if R.Code <> rcApprovalRequired then
  begin
    MessageDlg('无法创建冻结 Effect：' + R.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  ApprovalText := '这是一个真实进程的有界重复写入会话。' +
    LineEnding + LineEnding + '目标：' + Effect.ProcessIdentityId +
    LineEnding + '请求哈希：' + Effect.RequestHash + LineEnding +
    '请求：' + Effect.RequestJson + LineEnding + LineEnding +
    '只有当前值等于预期原值或替换值时会继续；出现第三种值立即停止。' +
    LineEnding + '每次真实写入都会读回并保存 Receipt/Proof。' +
    LineEnding + '达到次数或期限后停止；崩溃后不恢复；不会自动还原。批准启动？';
  if MessageDlg('本机有界冻结审批', ApprovalText,
    mtWarning, [mbYes, mbNo], 0) <> mrYes then
  begin
    FRuntime.RejectEffect(Effect.Id);
    FOutputMemo.Text := '{"effect_id":"' + Effect.Id +
      '","state":"rejected_by_local_user"}';
    Exit;
  end;
  R := FRuntime.ApproveAndStartFreeze(Effect.Id);
  FOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('冻结未启动：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FStatusLabel.Caption := '冻结会话已启动（有界、不会自动恢复）';
    MessageDlg('冻结会话已启动。停止后若需还原，请另行执行一次性写入审批。',
      mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.StopMemoryFreeze(Sender: TObject);
var
  R: TCEAResult;
begin
  R := FRuntime.StopFreeze('stopped_by_local_user');
  FOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('停止冻结失败：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FStatusLabel.Caption := '冻结会话已停止（未自动还原）';
    MessageDlg('冻结已停止，未自动还原目标值。还原需要单独审批。',
      mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.BrowseAndImportCT(Sender: TObject);
var
  Dialog: TOpenDialog;
  R: TCEAResult;
begin
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Cheat Engine Table (*.CT)|*.CT|All files (*.*)|*.*';
    if not Dialog.Execute then Exit;
    FCTPathEdit.Text := Dialog.FileName;
  finally
    Dialog.Free;
  end;
  R := FRuntime.ImportCTFile(FCTPathEdit.Text);
  FCTMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('CT 导入失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    MessageDlg('CT 已作为带来源与哈希的静态 RAG 证据导入；其中脚本未执行。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.SearchCT(Sender: TObject);
var
  R: TCEAResult;
begin
  R := FRuntime.BuildCTRagContext(Trim(FCTQueryEdit.Text), 20);
  FCTMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('CT 检索失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.TranslateCTDescriptions(Sender: TObject);
var
  Path: string;
  R: TCEAResult;
begin
  Path := Trim(FCTPathEdit.Text);
  if Path = '' then
  begin
    MessageDlg('请先选择并导入一个 .CT 文件。', mtInformation, [mbOK], 0);
    Exit;
  end;
  // 翻译只处理 <Description>；确认一次，避免用户误以为会翻译脚本或地址。
  if MessageDlg('将把该 CT 中的功能描述文本发送给已配置的模型进行翻译。' +
    LineEnding + '脚本、地址与 AOB 不会外发，结果仅作参考。继续？',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.TranslateCheatFileDescriptions(Path);
  FCTMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('描述翻译失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    MessageDlg('描述翻译完成；结果标注为机器翻译，仅作参考。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.EmergencyStop(Sender: TObject);
var
  R: TCEAResult;
begin
  R := FRuntime.EmergencyStop;
  FMCPMemo.Text := 'MCP token 已撤销；重启应用后才会生成新令牌。';
  FillChar(FAttachedIdentity, SizeOf(FAttachedIdentity), 0);
  FScanId := '';
  FScanCancelButton.Enabled := False;
  FOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('紧急停止结果不确定：' + R.StableCode,
      mtError, [mbOK], 0)
  else
  begin
    FStatusLabel.Caption := '治理服务：已紧急停止（操作授权已撤销，目标已分离）';
    MessageDlg('已撤销 Lease、拒绝待执行 Effect 并分离目标。',
      mtInformation, [mbOK], 0);
  end;
end;

procedure TCEAMainForm.RunLLM(Sender: TObject);
var
  R, ContextResult: TCEAResult;
begin
  if Assigned(FLLMWorker) then Exit;
  R := FRuntime.ConfigureLLM(FLLMEndpointEdit.Text, FLLMModelEdit.Text,
    FLLMSecretRefEdit.Text, FLLMProviderBox.Text);
  if R.Failed then
  begin
    MessageDlg('LLM 配置无效：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  ContextResult := FRuntime.BuildCTRagContext(FLLMQueryEdit.Text, 20);
  if ContextResult.Failed then
  begin
    MessageDlg('CT RAG 构建失败：' + ContextResult.StableCode,
      mtError, [mbOK], 0);
    Exit;
  end;
  FLLMCancellation := TCEACancellationToken.Create;
  FLLMWorker := TCEALLMWorker.Create(FRuntime, FLLMPromptMemo.Text,
    ContextResult.DataJson, FLLMCancellation);
  FLLMRunButton.Enabled := False;
  FLLMCancelButton.Enabled := True;
  FLLMOutputMemo.Text := '{"status":"running","authority":"proposal_only"}';
  FLLMWorker.Start;
end;

procedure TCEAMainForm.CancelLLM(Sender: TObject);
begin
  if Assigned(FLLMCancellation) then
  begin
    FLLMCancellation.Cancel;
    FLLMCancelButton.Enabled := False;
    FLLMOutputMemo.Text := '{"status":"cancelling"}';
  end;
end;

procedure TCEAMainForm.CompleteLLMIfReady;
var
  R: TCEAResult;
begin
  if not Assigned(FLLMWorker) or not FLLMWorker.Completed then Exit;
  FLLMWorker.WaitFor;
  R := FLLMWorker.InvokeResult;
  FreeAndNil(FLLMWorker);
  FreeAndNil(FLLMCancellation);
  FLLMRunButton.Enabled := True;
  FLLMCancelButton.Enabled := False;
  FLLMOutputMemo.Text := R.DataJson;
  if R.Failed and (R.Code <> rcCancelled) then
    MessageDlg('模型调用失败：' + R.StableCode +
      '。请确认预算、凭据目标、端点和模型。', mtError, [mbOK], 0);
end;

procedure TCEAMainForm.SaveLLMCredential(Sender: TObject);
var
  R: TCEAResult;
  SecretValue: string;
begin
  SecretValue := FLLMApiKeyEdit.Text;
  FLLMApiKeyEdit.Clear;
  try
    R := FRuntime.SaveLLMCredential(FLLMSecretRefEdit.Text, SecretValue);
  finally
    SecretValue := StringOfChar(#0, Length(SecretValue));
    SecretValue := '';
  end;
  if R.Failed then
    MessageDlg('保存凭据失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    MessageDlg('API Key 已保存到当前 Windows 用户的 Credential Manager。',
      mtInformation, [mbOK], 0);
end;

destructor TCEAMainForm.Destroy;
begin
  FPumpTimer.Enabled := False;
  if Assigned(FSaveDiscoveryWorker) then
  begin
    if Assigned(FRuntime) and (FSaveDiscoveryScope.Id <> '') then
      FRuntime.CancelSaveDirectory(FSaveDiscoveryScope.Id);
    FSaveDiscoveryWorker.WaitFor;
    FreeAndNil(FSaveDiscoveryWorker);
  end;
  if Assigned(FLLMCancellation) then FLLMCancellation.Cancel;
  if Assigned(FLLMWorker) then
  begin
    FLLMWorker.WaitFor;
    FreeAndNil(FLLMWorker);
  end;
  FreeAndNil(FLLMCancellation);
  FreeAndNil(FFieldIds);
  FreeAndNil(FPageIds);
  FreeAndNil(FEventIds);
  FreeAndNil(FRecordingSegmentIds);
  FreeAndNil(FWriteHistoryJson);
  FreeAndNil(FFieldEvidenceJson);
  FreeAndNil(FDiscoveryRoundJson);
  FreeAndNil(FDiscoveryRoundIds);
  FreeAndNil(FGoalJson);
  FreeAndNil(FGoalIds);
  if Assigned(FRuntime) then
    FRuntime.StopSecondaryScreen;
  FreeAndNil(FRuntime);
  inherited Destroy;
end;

procedure TCEAMainForm.AddPlaceholder(const APage: TTabSheet;
  const AText: string);
var
  LabelControl: TLabel;
begin
  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := APage;
  LabelControl.Left := 20;
  LabelControl.Top := 24;
  LabelControl.Caption := AText;
  LabelControl.AutoSize := True;
end;

procedure TCEAMainForm.SelectPlayerSection(const AIndex: Integer);
begin
  if FSecOverview = nil then Exit;
  FSecOverview.Visible := AIndex = 0;
  FSecFields.Visible := AIndex = 1;
  FSecWrite.Visible := AIndex = 2;
  FSecEvents.Visible := AIndex = 3;
  FSecDiscovery.Visible := AIndex = 4;
  FSecSecondary.Visible := AIndex = 5;
  FSecGcm.Visible := AIndex = 6;
  FSecSettings.Visible := AIndex = 7;
end;

procedure TCEAMainForm.PlayerNavChange(Sender: TObject);
begin
  SelectPlayerSection(FPlayerNav.ItemIndex);
  if FPlayerNav.ItemIndex = 1 then RefreshPlayerFields(nil);
  if FPlayerNav.ItemIndex = 2 then
  begin
    ShowFieldWriteHistory(nil);
    ShowFieldEvidence(nil);
  end;
  if FPlayerNav.ItemIndex = 3 then ShowPlayerEvents(nil);
  if FPlayerNav.ItemIndex = 4 then
  begin
    ShowDiscoveryRounds(nil);
    ShowCurrentGoal(nil);
    ShowGoalList(nil);
  end;
end;

procedure TCEAMainForm.StartGameSession(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if Trim(FGameNameEdit.Text) = '' then
  begin
    MessageDlg('请先填写游戏名称。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.StartGameSession(FGameNameEdit.Text, FGameVersionEdit.Text);
  if R.Failed then
  begin
    FPlayerStatusLabel.Caption := '会话启动失败：' + R.StableCode;
    Exit;
  end;
  FPlayerStatusLabel.Caption := '会话已开始（只读起步）';
  FPlayerOutputMemo.Text := R.DataJson;
  FFieldIds.Free;
  FFieldIds := TStringList.Create;
  FFieldList.Items.Clear;
  FPlayerDetailMemo.Text := '字段已就绪后，用「游戏字段」页声明语义字段。';
  RefreshPlayerFields(nil);
end;

procedure TCEAMainForm.RefreshPlayerFields(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Fields: TJSONArray;
  I: Integer;
  FieldObj: TJSONObject;
  FieldId: string;
  Selected: Integer;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then Exit;
  R := FRuntime.ListGameFields;
  if R.Failed then
  begin
    FSelectedFieldLabel.Caption := '字段列表不可用：' + R.StableCode;
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  Selected := FFieldList.ItemIndex;
  Data := GetJSON(R.DataJson);
  try
    if not (Data is TJSONObject) then Exit;
    Fields := TJSONArray(TJSONObject(Data).Find('fields'));
    if Fields = nil then Exit;
    FFieldList.Items.BeginUpdate;
    try
      FFieldList.Items.Clear;
      if FFieldIds = nil then FFieldIds := TStringList.Create;
      FFieldIds.Clear;
      for I := 0 to Fields.Count - 1 do
      begin
        FieldObj := TJSONObject(Fields.Items[I]);
        FieldId := FieldObj.Get('field_id', '');
        FFieldIds.Add(FieldId);
        FFieldList.Items.Add(FieldId + '  [' +
          FieldObj.Get('access', '') + ']  ' + FieldObj.Get('value', ''));
      end;
    finally
      FFieldList.Items.EndUpdate;
    end;
    if (Selected >= 0) and (Selected < FFieldList.Items.Count) then
      FFieldList.ItemIndex := Selected;
  finally
    Data.Free;
  end;
  UpdatePlayerDetail;
end;

function TCEAMainForm.SelectedFieldId: string;
begin
  Result := '';
  if (FFieldList = nil) or (FFieldList.ItemIndex < 0) then Exit;
  if (FFieldIds = nil) or (FFieldList.ItemIndex >= FFieldIds.Count) then Exit;
  Result := FFieldIds[FFieldList.ItemIndex];
end;

procedure TCEAMainForm.UpdatePlayerDetail;
var
  R: TCEAResult;
  Data: TJSONData;
  Fields: TJSONArray;
  I: Integer;
  FieldObj: TJSONObject;
  FieldId: string;
begin
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    FSelectedFieldLabel.Caption := '当前字段：未选择';
    Exit;
  end;
  FSelectedFieldLabel.Caption := '当前字段：' + FieldId;
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListGameFields;
  if R.Failed then Exit;
  Data := GetJSON(R.DataJson);
  try
    if not (Data is TJSONObject) then Exit;
    Fields := TJSONArray(TJSONObject(Data).Find('fields'));
    if Fields = nil then Exit;
    for I := 0 to Fields.Count - 1 do
    begin
      FieldObj := TJSONObject(Fields.Items[I]);
      if FieldObj.Get('field_id', '') <> FieldId then Continue;
      FPlayerDetailMemo.Text :=
        '字段 ID：' + FieldId + LineEnding +
        '显示名：' + FieldObj.Get('display_name', '') + LineEnding +
        '类型：' + FieldObj.Get('value_type', '') + LineEnding +
        '当前值：' + FieldObj.Get('value', '') + LineEnding +
        '来源：' + FieldObj.Get('source', '') + LineEnding +
        '读写状态：' + FieldObj.Get('access', '') + LineEnding +
        '验证状态：' + FieldObj.Get('validation_status', '') + LineEnding +
        '地址：' + FieldObj.Get('address_hex', '') + LineEnding +
        '最后更新：' + FieldObj.Get('last_updated', '') + LineEnding + LineEnding +
        '读写状态说明：' + LineEnding +
        'read_only 只读（锁）：不提供写入入口' + LineEnding +
        'pending_write 待验证（时钟）：仍需重读一致后才可写' + LineEnding +
        'verified_writable 可写（笔）：已通过写入→重读→一致验证' + LineEnding +
        'invalid 失效（警告）：目标已变化，需重新定位';
      if FFieldExpectedEdit.Text = '' then
        FFieldExpectedEdit.Text := FieldObj.Get('value', '');
      Break;
    end;
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.DeclareField(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if (Trim(FFieldIdEdit.Text) = '') or (Trim(FFieldAddressEdit.Text) = '') then
  begin
    MessageDlg('字段 ID 与地址都必须填写。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.DeclareField(Trim(FFieldIdEdit.Text), Trim(FFieldNameEdit.Text),
    FFieldTypeBox.Text, Trim(FFieldAddressEdit.Text));
  if R.Failed then
  begin
    MessageDlg('声明字段失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  RefreshPlayerFields(nil);
end;

procedure TCEAMainForm.LoadChainFromSelectedCTEntry(Sender: TObject);
var
  EntryKey: string;
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  Offsets: TJSONArray;
  ModuleName, AddressExpr, OffsetsJson, BaseText, ParsedModule: string;
  BaseOffset: QWord;
  PlusAt: SizeInt;
  I: Integer;
begin
  EntryKey := Trim(FFieldChainEntryEdit.Text);
  if EntryKey = '' then
  begin
    MessageDlg('请填写 CT 条目键（检索结果里的 entry_key，形如 artifact:N）。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.GetCTEntry(EntryKey);
  if R.Failed then
  begin
    MessageDlg('读取 CT 条目失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FCTMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    Obj := TJSONObject(Data);
    ModuleName := Obj.Get('module', '');
    AddressExpr := Trim(Obj.Get('address_expression', ''));
    OffsetsJson := '';
    Offsets := TJSONArray(Obj.Find('pointer_offsets'));
    if Offsets <> nil then
    begin
      for I := 0 to Offsets.Count - 1 do
      begin
        if OffsetsJson <> '' then OffsetsJson := OffsetsJson + ',';
        OffsetsJson := OffsetsJson + '"' + Offsets.Items[I].AsString + '"';
      end;
    end;
  finally
    Data.Free;
  end;
  if ModuleName = '' then
  begin
    MessageDlg('该 CT 条目没有模块名（不是模块相对地址），无法生成可重放的链。' +
      LineEnding + '地址表达式：' + AddressExpr,
      mtWarning, [mbOK], 0);
    Exit;
  end;

  // CE 把模块基址偏移写在地址表达式里（module.exe+20），而 <Offsets> 只存
  // 解引用之后的各级偏移。丢掉基址偏移会让整条链从模块基址 0 开始解析，
  // 算出的地址是错的，所以必须把 + 后面那段一并搬进链定义。
  R := ParseCTAddressExpression(AddressExpr, ParsedModule, BaseOffset);
  if R.Failed then
  begin
    if R.StableCode = 'ct_address_expression_not_module_relative' then
      MessageDlg('该条目的地址表达式没有模块基址偏移（' + AddressExpr + '）。' +
        LineEnding + '本工具只支持模块相对链（module.exe+offset），' +
        '绝对地址链重启后无法重放，请手工确认。',
        mtWarning, [mbOK], 0)
    else
      MessageDlg('无法解析地址表达式：' + R.StableCode + LineEnding +
        AddressExpr, mtError, [mbOK], 0);
    Exit;
  end;
  if (ParsedModule <> '') and (ModuleName = '') then
    ModuleName := ParsedModule;
  if not SameText(ParsedModule, ModuleName) then
  begin
    // parser 与 catalog 的模块名不一致意味着条目本身矛盾；以 catalog 的
    // module 字段为准，但要让操作者知道。
    MessageDlg('地址表达式里的模块（' + ParsedModule +
      '）与条目 module 字段（' + ModuleName + '）不一致；将以 module 字段为准。',
      mtWarning, [mbOK], 0);
  end;

  if OffsetsJson = '' then
  begin
    // Zero offsets is a plain module-relative address: still a valid chain, but
    // say so explicitly so the operator does not expect dereferences.
    MessageDlg('该条目没有 <Offsets>：将声明为模块相对地址（0 级解引用）。' +
      LineEnding + '地址表达式：' + AddressExpr,
      mtInformation, [mbOK], 0);
  end;
  FFieldChainModuleEdit.Text := ModuleName;
  FFieldChainOffsetsEdit.Text := '{"base":"0x' + IntToHex(BaseOffset, 1) +
    '","offsets":[' + OffsetsJson + ']}';
end;

procedure TCEAMainForm.DeclareChainFromCT(Sender: TObject);
var
  FieldId, ModuleName, OffsetsJson, AddressExpr: string;
  BaseOffset: QWord;
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  Spec: TCEAPointerChainSpec;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  FieldId := Trim(FFieldIdEdit.Text);
  ModuleName := Trim(FFieldChainModuleEdit.Text);
  OffsetsJson := Trim(FFieldChainOffsetsEdit.Text);
  if FieldId = '' then
  begin
    MessageDlg('字段 ID 必须填写（链字段不需要地址，但需要字段 ID）。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if ModuleName = '' then
  begin
    MessageDlg('指针链必须指定模块名（模块外地址重启后不可重放）。',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  if OffsetsJson = '' then OffsetsJson := '[]';
  // 先用纯函数校验一次链的形态，避免把明显写错的链提交给运行时后
  // 才在解析阶段失败（那时字段已经被物化，错误更难看懂）。
  R := ParsePointerChainSpec(OffsetsJson, ModuleName, 0, 64, Spec);
  if R.Failed then
  begin
    MessageDlg('指针链格式无效：' + R.StableCode + LineEnding +
      '期望形如 {"base":"0x20","offsets":["10","8"]} 或 ["10","8"]。',
      mtError, [mbOK], 0);
    Exit;
  end;
  BaseOffset := Spec.ModuleBaseOffset;
  AddressExpr := ModuleName + '+0x' + IntToHex(BaseOffset, 1);
  if MessageDlg('声明指针链字段',
    '字段 ID：' + FieldId + LineEnding +
    '模块：' + ModuleName + LineEnding +
    '基址偏移：0x' + IntToHex(BaseOffset, 16) + LineEnding +
    '解引用层数：' + IntToStr(Spec.Depth) + LineEnding +
    '地址表达式：' + AddressExpr + LineEnding + LineEnding +
    '声明后字段初始为只读；必须再走「验证字段可写」才能写入。' +
    LineEnding + '继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.DeclarePointerField(FieldId, Trim(FFieldNameEdit.Text),
    FFieldTypeBox.Text, ModuleName, OffsetsJson, 64);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    Data := nil;
    try
      Data := GetJSON(R.DataJson);
      if (Data <> nil) and (Data.JSONType = jtObject) and
         (TJSONObject(Data).IndexOfName('resolved') >= 0) then
      begin
        Obj := TJSONObject(Data);
        MessageDlg('字段已声明，但当前无法解析该链：' + R.StableCode +
          LineEnding + 'detail=' + Obj.Get('detail', '') + LineEnding +
          '常见原因：模块名拼写、游戏还没进入存档、基址偏移失效。',
          mtWarning, [mbOK], 0);
        RefreshPlayerFields(nil);
        Exit;
      end;
    finally
      Data.Free;
    end;
    MessageDlg('声明指针链字段失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  RefreshPlayerFields(nil);
end;

procedure TCEAMainForm.SaveGameProfileClick(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  ProfileId: string;
  FieldCount: Integer;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if not FRuntime.GameSessionActive then
  begin
    MessageDlg('请先开始游戏会话（游戏概览页）。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.SaveGameProfile;
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    if R.StableCode = 'profile_has_no_fields' then
      MessageDlg('当前会话还没有任何字段，没有可保存的内容。' + LineEnding +
        '请先在「游戏字段」页声明或还原字段。', mtInformation, [mbOK], 0)
    else
      MessageDlg('保存 Profile 失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  Data := GetJSON(R.DataJson);
  try
    Obj := TJSONObject(Data);
    ProfileId := Obj.Get('profile_id', '');
    FieldCount := Obj.Get('field_count', 0);
  finally
    Data.Free;
  end;
  FProfileNameEdit.Text := '';
  MessageDlg('已保存 Profile。' + LineEnding +
    '标识：' + ProfileId + LineEnding +
    '字段数：' + IntToStr(FieldCount) + LineEnding + LineEnding +
    '注意：Profile 只保存字段定义与定位配方（模块 + 偏移），' +
    '不保存当前数值，也不保存「可写」状态。还原后所有字段都是只读，' +
    '要写入必须重新走「验证字段可写」。',
    mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.RestoreGameProfileClick(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  GameName: string;
  Restored, Downgraded: Integer;
  Compatible: Boolean;
  Reason: string;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if not FRuntime.GameSessionActive then
  begin
    MessageDlg('请先开始游戏会话（游戏概览页）。', mtWarning, [mbOK], 0);
    Exit;
  end;
  GameName := Trim(FProfileNameEdit.Text);
  if GameName = '' then
  begin
    MessageDlg('请填写要还原的游戏名（与保存时一致）。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('还原 Profile',
    '游戏名：' + GameName + LineEnding + LineEnding +
    '还原会把这些字段加进当前会话，但一律为只读，且不会带上一轮的数值。' +
    LineEnding + '若可执行文件版本与保存时不同，字段会被标记为失效。' +
    LineEnding + LineEnding + '继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.RestoreGameProfile(GameName);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    if R.StableCode = 'profile_not_found' then
      MessageDlg('没有找到该游戏的 Profile：' + GameName, mtInformation,
        [mbOK], 0)
    else
      MessageDlg('还原 Profile 失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  Data := GetJSON(R.DataJson);
  try
    Obj := TJSONObject(Data);
    Restored := Obj.Get('restored', 0);
    Downgraded := Obj.Get('downgraded', 0);
    Compatible := Obj.Get('compatible', False);
    Reason := Obj.Get('reason', '');
  finally
    Data.Free;
  end;
  RefreshPlayerFields(nil);
  if Compatible then
    MessageDlg('已还原 ' + IntToStr(Restored) + ' 个字段（全部只读）。' +
      LineEnding + '要写入请对具体字段点「验证字段可写」。',
      mtInformation, [mbOK], 0)
  else
    MessageDlg('已还原 ' + IntToStr(Restored) + ' 个字段，但版本不匹配（' +
      Reason + '），其中 ' + IntToStr(Downgraded) + ' 个已标记为失效。' +
      LineEnding + '失效字段的地址不可信，需要重新定位。',
      mtWarning, [mbOK], 0);
end;

procedure TCEAMainForm.CaptureSelectedField(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  FieldId: string;
begin
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('请先在字段列表中选择一个字段。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.CaptureFieldValue(FieldId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('读取字段失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  Data := GetJSON(R.DataJson);
  try
    if Data is TJSONObject then
      FFieldExpectedEdit.Text := TJSONObject(Data).Get('value', '');
  finally
    Data.Free;
  end;
  RefreshPlayerFields(nil);
end;

procedure TCEAMainForm.VerifySelectedFieldWritable(Sender: TObject);
var
  R: TCEAResult;
  FieldId: string;
begin
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('请先在字段列表中选择一个字段。', mtWarning, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('验证字段可写',
    '将对 ' + FieldId + ' 执行一次受治理的写入，并立即重读比对。' + LineEnding +
    '这是把字段从「只读」提升为「可写」的唯一途径。' + LineEnding +
    '仅在你被授权调试的单机游戏上继续。是否继续？',
    mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.ConfirmFieldWritable(FieldId, Trim(FFieldTargetEdit.Text),
    Trim(FFieldExpectedEdit.Text));
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('验证失败：' + R.StableCode + LineEnding +
      '字段已标记为失效，请重新定位。', mtError, [mbOK], 0);
    RefreshPlayerFields(nil);
    Exit;
  end;
  MessageDlg('验证通过：字段已提升为可写。', mtInformation, [mbOK], 0);
  RefreshPlayerFields(nil);
end;

procedure TCEAMainForm.WriteSelectedField(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Preview, Detail: TJSONObject;
  Outcome: string;
  FieldId, OriginalValue, TargetValue, AdapterId, BlockingReason,
    LiveCode, Summary: string;
  Conflict, CanExecute: Boolean;
begin
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('请先在字段列表中选择一个字段。', mtWarning, [mbOK], 0);
    Exit;
  end;
  TargetValue := Trim(FFieldTargetEdit.Text);

  { FR-042：提交前必须先摆出「字段、原值、目标值、目标适配器」。原值取自实时
    读取而不是模型缓存——缓存里的值是上一次采集时的，可能早就不是即将被覆盖
    的那个值了。 }
  R := FRuntime.PreviewFieldWrite(FieldId, TargetValue,
    Trim(FFieldExpectedEdit.Text));
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('无法预览这次写入：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  OriginalValue := '';
  AdapterId := '';
  BlockingReason := '';
  LiveCode := '';
  Conflict := False;
  CanExecute := False;
  Data := GetJSON(R.DataJson);
  try
    if Data is TJSONObject then
    begin
      Preview := TJSONObject(Data);
      OriginalValue := Preview.Get('original_value', '');
      AdapterId := Preview.Get('adapter_id', '');
      BlockingReason := Preview.Get('blocking_reason', '');
      LiveCode := Preview.Get('live_read_stable_code', '');
      Conflict := Preview.Get('conflict', False);
      CanExecute := Preview.Get('can_execute', False);
    end;
  finally
    Data.Free;
  end;

  if OriginalValue = '' then OriginalValue := '（未能读到）';
  if AdapterId = '' then AdapterId := '（未声明）';

  { FR-045：原值在编辑期间已经变了，必须提示刷新或重新确认，而不是拿新值当旧
    值覆盖掉。冲突本身不是错误——预览成功了，只是这次写入被挡住。 }
  if not CanExecute then
  begin
    Detail := TJSONObject.Create;
    try
      Detail.Add('blocking_reason', BlockingReason);
      Detail.Add('conflict', Conflict);
      Detail.Add('live_read_failed', LiveCode <> '');
      Detail.Add('live_read_stable_code', LiveCode);
      Detail.Add('original_value', OriginalValue);
      Detail.Add('target_value', TargetValue);
      Summary := Detail.AsJSON;
    finally
      Detail.Free;
    end;
    if Conflict then
      MessageDlg('原值已变化，写入被阻止',
        '你依据的原值是：' + Trim(FFieldExpectedEdit.Text) + LineEnding +
        '游戏里现在的原值是：' + OriginalValue + LineEnding + LineEnding +
        '请刷新字段后重新确认，或重新填写「期望原值」。' + LineEnding +
        Summary, mtWarning, [mbOK], 0)
    else if LiveCode <> '' then
      MessageDlg('无法读取当前原值，写入被阻止',
        '读取失败：' + LiveCode + LineEnding +
        '没有实时原值就无法判断这次写入会覆盖什么。' + LineEnding +
        Summary, mtError, [mbOK], 0)
    else
      MessageDlg('该字段当前不可写',
        '阻止原因：' + BlockingReason + LineEnding +
        '只有 verified_writable 字段才会被接受。' + LineEnding +
        Summary, mtWarning, [mbOK], 0);
    Exit;
  end;

  { FR-043：确认框里必须包含这次写入的全部事实，玩家据此决定是否继续。 }
  if MessageDlg('写入字段',
    '字段：' + FieldId + LineEnding +
    '原值（实时读取）：' + OriginalValue + LineEnding +
    '目标值：' + TargetValue + LineEnding +
    '目标适配器：' + AdapterId + LineEnding + LineEnding +
    '只有 verified_writable 字段会被接受；其余会被拒绝。' + LineEnding +
    '是否继续？', mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.WriteFieldValue(FieldId, TargetValue,
    Trim(FFieldExpectedEdit.Text));
  FPlayerOutputMemo.Text := R.DataJson;
  Data := GetJSON(R.DataJson);
  try
    if Data is TJSONObject then
      Outcome := TJSONObject(Data).Get('outcome', '')
    else
      Outcome := '';
  finally
    Data.Free;
  end;
  if R.Failed then
    MessageDlg('写入未成功：' + R.StableCode + LineEnding + '结果：' + Outcome,
      mtError, [mbOK], 0)
  else if Outcome = 'verified' then
    MessageDlg('写入已发送并验证一致。', mtInformation, [mbOK], 0)
  else
    MessageDlg('命令已发送，但尚未验证为修改成功。' + LineEnding +
      '结果：' + Outcome, mtWarning, [mbOK], 0);
  RefreshPlayerFields(nil);
end;

{ FR-046 操作历史：写入是唯一会改变玩家游戏的动作，账本要能被玩家自己读到。
  列表按最新在前排列，点一条就把明细放进右下输出区。 }
procedure TCEAMainForm.ShowFieldWriteHistory(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Item: TJSONObject;
  RecordId, Outcome, FieldId, Original, Target, Adapter, RecordedAt,
    Line: string;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListFieldWriteHistory('', 50);
  FPlayerOutputMemo.Text := R.DataJson;
  if FWriteHistoryList = nil then Exit;
  FWriteHistoryList.Items.BeginUpdate;
  try
    FWriteHistoryList.Items.Clear;
    if FWriteHistoryJson = nil then FWriteHistoryJson := TStringList.Create;
    FWriteHistoryJson.Clear;
    if R.Failed then Exit;
    Data := GetJSON(R.DataJson);
    try
      if not (Data is TJSONObject) then Exit;
      Obj := TJSONObject(Data);
      if not (Obj.Find('writes') is TJSONArray) then Exit;
      Arr := TJSONArray(Obj.Find('writes'));
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then Continue;
        Item := TJSONObject(Arr[I]);
        RecordId := Item.Get('record_id', '');
        if RecordId = '' then Continue;
        Outcome := Item.Get('outcome', '');
        FieldId := Item.Get('field_id', '');
        Original := Item.Get('original_value', '');
        Target := Item.Get('target_value', '');
        Adapter := Item.Get('adapter_id', '');
        RecordedAt := Item.Get('recorded_at', '');
        Line := RecordedAt + '  ' + FieldId + '  ' + Original + '→' + Target +
          '  ' + Outcome + '  ' + Adapter;
        FWriteHistoryJson.Add(Item.AsJSON);
        FWriteHistoryList.Items.Add(Line);
      end;
    finally
      Data.Free;
    end;
  finally
    FWriteHistoryList.Items.EndUpdate;
  end;
end;

procedure TCEAMainForm.SelectFieldWriteHistory(Sender: TObject);
begin
  if (FWriteHistoryList = nil) or (FWriteHistoryJson = nil) then Exit;
  if (FWriteHistoryList.ItemIndex < 0) or
    (FWriteHistoryList.ItemIndex >= FWriteHistoryJson.Count) then Exit;
  FPlayerOutputMemo.Text := FWriteHistoryJson[FWriteHistoryList.ItemIndex];
end;

procedure TCEAMainForm.ShowFieldEvidence(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  Item: TJSONObject;
  I: Integer;
  EvidenceId, FieldId, Kind, Outcome, Observed, RecordedAt, Supports,
    Line: string;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListFieldEvidence('', 50);
  FPlayerOutputMemo.Text := R.DataJson;
  if FFieldEvidenceList = nil then Exit;
  FFieldEvidenceList.Items.BeginUpdate;
  try
    FFieldEvidenceList.Items.Clear;
    if FFieldEvidenceJson = nil then FFieldEvidenceJson := TStringList.Create;
    FFieldEvidenceJson.Clear;
    if R.Failed then Exit;
    Data := GetJSON(R.DataJson);
    try
      if not (Data is TJSONObject) then Exit;
      Obj := TJSONObject(Data);
      if not (Obj.Find('evidence') is TJSONArray) then Exit;
      Arr := TJSONArray(Obj.Find('evidence'));
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then Continue;
        Item := TJSONObject(Arr[I]);
        EvidenceId := Item.Get('evidence_id', '');
        if EvidenceId = '' then Continue;
        FieldId := Item.Get('field_id', '');
        Kind := Item.Get('kind', '');
        Outcome := Item.Get('outcome', '');
        Observed := Item.Get('observed_value', '');
        RecordedAt := Item.Get('recorded_at', '');
        if Item.Get('supports_write_claim', False) then
          Supports := '可支撑写入'
        else
          Supports := '不支撑写入';
        Line := RecordedAt + '  ' + FieldId + '  ' + Kind + '/' + Outcome +
          '  观察=' + Observed + '  ' + Supports;
        FFieldEvidenceJson.Add(Item.AsJSON);
        FFieldEvidenceList.Items.Add(Line);
      end;
    finally
      Data.Free;
    end;
  finally
    FFieldEvidenceList.Items.EndUpdate;
  end;
end;

procedure TCEAMainForm.SelectFieldEvidence(Sender: TObject);
begin
  if (FFieldEvidenceList = nil) or (FFieldEvidenceJson = nil) then Exit;
  if (FFieldEvidenceList.ItemIndex < 0) or
    (FFieldEvidenceList.ItemIndex >= FFieldEvidenceJson.Count) then Exit;
  FPlayerOutputMemo.Text := FFieldEvidenceJson[FFieldEvidenceList.ItemIndex];
end;

procedure TCEAMainForm.ConfirmFieldAsOperator(Sender: TObject);
var
  FieldId: string;
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('先在「游戏字段」里选中一个字段，再回到这里确认。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  { 操作者确认只证明「这个字段指的是这个语义」，不证明它可写，
    所以这里不需要二次确认，也不改任何字段状态。 }
  if MessageDlg('确认「' + FieldId + '」就是你在游戏里看到的那个数值？' +
    LineEnding + LineEnding +
    '这会留下一条 user_statement 证据，用于日后解释“为什么当时这么判断”。' +
    LineEnding + '它不会把字段标成可写，也不会写入游戏。',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.RecordFieldUserConfirmation(FieldId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('记录确认失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    ShowFieldEvidence(nil);
end;

{ FR-051 分轮验证。这里的三个按钮都不会自动把「符合预期」算成真：
  预期是操作者在动手前写下的，结论也必须由操作者给出，否则事后补一句
  「本来就想看到这个」就变成了自我证明。 }
{ FR-041 输入校验。约束的形态在这里就被校验：畸形 JSON 如果等到写入时才报错，
  操作者会以为「已经加过限制了」，而实际上每次写入都会以他看不见的原因失败。 }
procedure TCEAMainForm.SaveFieldConstraints(Sender: TObject);
var
  FieldId: string;
  R: TCEAResult;
  Raw: string;
begin
  if not Assigned(FRuntime) then Exit;
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('先在「游戏字段」里选中一个字段，再回来声明约束。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  if FFieldConstraintsEdit = nil then Exit;
  Raw := Trim(FFieldConstraintsEdit.Text);
  if Raw = '' then
  begin
    MessageDlg('约束是空的。要取消已有约束请用「清除约束」。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  { 加约束只会让写入更难，不会让写入更容易，所以不需要二次确认；
     但去掉约束会放宽写入范围，那个方向必须确认（见 ClearFieldConstraints）。 }
  R := FRuntime.SetFieldConstraints(FieldId, Raw);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    if Pos('field_constraints_unknown_key', R.DataJson) > 0 then
      MessageDlg('约束里出现了不认识的键。' + LineEnding + LineEnding +
        '拼错的键（例如 maximun）会被静默忽略，从而让上限形同虚设，' +
        '所以这里直接拒绝。可用键：min、max、allowed_values。',
        mtError, [mbOK], 0)
    else
      MessageDlg('保存约束失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FFieldConstraintsStatusLabel.Caption := '已声明约束：' + Raw;
  ShowFieldEvidence(nil);
end;

{ 清除约束会放宽这个字段的写入范围，所以必须二次确认。 }
procedure TCEAMainForm.ClearFieldConstraints(Sender: TObject);
var
  FieldId: string;
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  FieldId := SelectedFieldId;
  if FieldId = '' then
  begin
    MessageDlg('先在「游戏字段」里选中一个字段。', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('清除「' + FieldId + '」的所有约束？' + LineEnding + LineEnding +
    '清除之后这个字段可以接受任意值，写入不再被范围或枚举拦住。',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.SetFieldConstraints(FieldId, '');
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('清除约束失败：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    if FFieldConstraintsEdit <> nil then FFieldConstraintsEdit.Text := '';
    FFieldConstraintsStatusLabel.Caption := '未声明约束。';
  end;
end;

procedure TCEAMainForm.PlanDiscoveryRoundClick(Sender: TObject);
var
  R: TCEAResult;
  Kind, Purpose, Operation, Expected, FieldId: string;
begin
  if not Assigned(FRuntime) then Exit;
  Kind := FDiscoveryKindBox.Text;
  Purpose := Trim(FDiscoveryPurposeEdit.Text);
  Operation := Trim(FDiscoveryOperationEdit.Text);
  Expected := Trim(FDiscoveryExpectedEdit.Text);
  FieldId := Trim(FDiscoveryFieldEdit.Text);
  if (Purpose = '') or (Operation = '') or (Expected = '') then
  begin
    MessageDlg('目的、操作、预期观察三项都必须填写。' + LineEnding +
      '写不出「预期看到什么」，说明这一轮还不该动手。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('规划本轮「' + Kind + '」？' + LineEnding + LineEnding +
    '目的：' + Purpose + LineEnding +
    '操作：' + Operation + LineEnding +
    '预期：' + Expected + LineEnding + LineEnding +
    '规划本身不执行扫描或写入，只是先把预期固定下来，避免事后改口。',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.PlanDiscoveryRound(Kind, Purpose, Operation, Expected, FieldId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    if R.StableCode = 'discovery_round_active' then
      MessageDlg('上一轮还没收尾，先收尾或放弃它再规划新一轮。',
        mtInformation, [mbOK], 0)
    else if R.StableCode = 'game_session_not_started' then
      MessageDlg('请先开始游戏会话（游戏概览页）。', mtWarning, [mbOK], 0)
    else
      MessageDlg('规划轮次失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FDiscoveryRoundIdEdit.Text := '';
  ShowDiscoveryRounds(nil);
end;

procedure TCEAMainForm.CompleteDiscoveryRoundClick(Sender: TObject);
var
  R: TCEAResult;
  RoundId, Outcome: string;
  Matched: Boolean;
  Answer: Integer;
begin
  if not Assigned(FRuntime) then Exit;
  RoundId := Trim(FDiscoveryRoundIdEdit.Text);
  Outcome := Trim(FDiscoveryOutcomeEdit.Text);
  if RoundId = '' then
  begin
    MessageDlg('先在列表里点一条轮次，把轮次 ID 填进来。', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Outcome = '' then
  begin
    MessageDlg('必须写下实际观察结果——空着收尾等于没有验证。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  Matched := FDiscoveryMatchedCheck.Checked;
  if Matched then
    Answer := MessageDlg('确认本轮观察结果与预期相符？' + LineEnding + LineEnding +
      '实际观察：' + Outcome + LineEnding + LineEnding +
      '这条结论会留在轮次记录里；如果其实不符，请取消勾选。',
      mtConfirmation, [mbYes, mbNo], 0)
  else
    Answer := MessageDlg('收尾本轮（标记为不符合预期）？' + LineEnding + LineEnding +
      '实际观察：' + Outcome,
      mtConfirmation, [mbYes, mbNo], 0);
  if Answer <> mrYes then Exit;
  R := FRuntime.CompleteDiscoveryRound(RoundId, Outcome, Matched);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('收尾轮次失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FDiscoveryRoundIdEdit.Text := '';
  FDiscoveryOutcomeEdit.Text := '';
  FDiscoveryMatchedCheck.Checked := False;
  ShowDiscoveryRounds(nil);
end;

procedure TCEAMainForm.AbandonDiscoveryRoundClick(Sender: TObject);
var
  R: TCEAResult;
  RoundId, Reason: string;
begin
  if not Assigned(FRuntime) then Exit;
  RoundId := Trim(FDiscoveryRoundIdEdit.Text);
  if RoundId = '' then
  begin
    MessageDlg('先在列表里点一条轮次，把轮次 ID 填进来。', mtInformation, [mbOK], 0);
    Exit;
  end;
  Reason := Trim(InputBox('放弃本轮', '为什么这一轮不做了？' + LineEnding +
    '（理由会留在轮次记录里，不能为空）', ''));
  if Reason = '' then Exit;
  R := FRuntime.AbandonDiscoveryRound(RoundId, Reason);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('放弃轮次失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FDiscoveryRoundIdEdit.Text := '';
  ShowDiscoveryRounds(nil);
end;

procedure TCEAMainForm.ShowCurrentDiscoveryRound(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.CurrentDiscoveryRound;
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('读取当前轮次失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ShowDiscoveryRounds(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj, Item: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  RoundId, Kind, State, Purpose, Outcome, Line: string;
  Matched: Boolean;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListDiscoveryRounds(50);
  FPlayerOutputMemo.Text := R.DataJson;
  if FDiscoveryRoundList = nil then Exit;
  FDiscoveryRoundList.Items.BeginUpdate;
  try
    FDiscoveryRoundList.Items.Clear;
    if FDiscoveryRoundJson = nil then FDiscoveryRoundJson := TStringList.Create;
    if FDiscoveryRoundIds = nil then FDiscoveryRoundIds := TStringList.Create;
    FDiscoveryRoundJson.Clear;
    FDiscoveryRoundIds.Clear;
    if R.Failed then Exit;
    Data := GetJSON(R.DataJson);
    try
      if not (Data is TJSONObject) then Exit;
      Obj := TJSONObject(Data);
      if not (Obj.Find('rounds') is TJSONArray) then Exit;
      Arr := TJSONArray(Obj.Find('rounds'));
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then Continue;
        Item := TJSONObject(Arr[I]);
        RoundId := Item.Get('round_id', '');
        if RoundId = '' then Continue;
        Kind := Item.Get('kind', '');
        State := Item.Get('state', '');
        Purpose := Item.Get('purpose', '');
        Outcome := Item.Get('observed_outcome', '');
        Matched := Item.Get('matched_expectation', False);
        Line := RoundId + '  [' + Kind + '/' + State + ']  ' + Purpose;
        if State = 'completed' then
          if Matched then
            Line := Line + '  → 符合预期'
          else
            Line := Line + '  → 不符合预期'
        else if State = 'abandoned' then
          Line := Line + '  → 放弃：' + Outcome;
        FDiscoveryRoundJson.Add(Item.AsJSON);
        FDiscoveryRoundIds.Add(RoundId);
        FDiscoveryRoundList.Items.Add(Line);
      end;
    finally
      Data.Free;
    end;
  finally
    FDiscoveryRoundList.Items.EndUpdate;
  end;
end;

procedure TCEAMainForm.SelectDiscoveryRound(Sender: TObject);
begin
  if (FDiscoveryRoundList = nil) or (FDiscoveryRoundJson = nil) then Exit;
  if (FDiscoveryRoundList.ItemIndex < 0) or
    (FDiscoveryRoundList.ItemIndex >= FDiscoveryRoundJson.Count) then Exit;
  FPlayerOutputMemo.Text := FDiscoveryRoundJson[FDiscoveryRoundList.ItemIndex];
  { 列表行是给人看的摘要，轮次 ID 要取原始值，不能从摘要里切。 }
  if (FDiscoveryRoundIds <> nil) and
    (FDiscoveryRoundList.ItemIndex < FDiscoveryRoundIds.Count) and
    (FDiscoveryRoundIdEdit <> nil) then
    FDiscoveryRoundIdEdit.Text := FDiscoveryRoundIds[FDiscoveryRoundList.ItemIndex];
end;

procedure TCEAMainForm.ProposeGoalClick(Sender: TObject);
var
  R: TCEAResult;
  Description: string;
  ValueType: string;
  Behavior: string;
begin
  if not Assigned(FRuntime) then Exit;
  Description := Trim(FGoalDescriptionEdit.Text);
  if Description = '' then
  begin
    MessageDlg('目标描述', '先用你自己的话写一句想找什么。', mtInformation, [mbOK], 0);
    Exit;
  end;
  { 下拉框的「不限」项是给人看的，传给运行时的必须是空串：
    "（类型不限）" 会被当成一个不存在的值类型而整体拒绝。 }
  ValueType := '';
  if FGoalValueTypeBox.ItemIndex > 0 then
    ValueType := FGoalValueTypeBox.Text;
  Behavior := '';
  if FGoalBehaviorBox.ItemIndex > 0 then
    Behavior := FGoalBehaviorBox.Text;
  R := FRuntime.ProposeDiscoveryGoal(Description, Trim(FGoalFieldHintEdit.Text),
    ValueType, Behavior);
  if R.Failed then
  begin
    MessageDlg('目标未记下', R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  ShowGoalList(nil);
  MessageDlg('目标已记下',
    '目标已记下，但它还只是「提案」。要让它成为当前目标，必须显式接受——' +
    '接受只表示「我在找这个」，不授权扫描，也不授权写入。',
    mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.AcceptGoalClick(Sender: TObject);
var
  R: TCEAResult;
  GoalId: string;
begin
  if not Assigned(FRuntime) then Exit;
  GoalId := Trim(FGoalIdEdit.Text);
  if GoalId = '' then
  begin
    MessageDlg('接受目标', '先选中或填入一个目标 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('接受为当前目标',
    '接受目标 ID：' + GoalId + LineEnding + LineEnding +
    '接受只表示「我在找这个」。它不会授权扫描，也不会授权写入——' +
    '扫描仍要走分轮计划与治理租约，写入仍要字段先被验证为可写。' +
    LineEnding + LineEnding + '如果已有当前目标，它会被标成「已被取代」。',
    mtConfirmation, [mbOK, mbCancel], 0) <> mrOk then
    Exit;
  R := FRuntime.AcceptDiscoveryGoal(GoalId);
  if R.Failed then
  begin
    MessageDlg('接受失败', R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  ShowCurrentGoal(nil);
  ShowGoalList(nil);
end;

procedure TCEAMainForm.RejectGoalClick(Sender: TObject);
var
  R: TCEAResult;
  GoalId: string;
  Reason: string;
begin
  if not Assigned(FRuntime) then Exit;
  GoalId := Trim(FGoalIdEdit.Text);
  if GoalId = '' then
  begin
    MessageDlg('否决目标', '先选中或填入一个目标 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  Reason := Trim(FGoalRejectReasonEdit.Text);
  if Reason = '' then
  begin
    MessageDlg('否决目标',
      '必须写清理由。没有理由的否决和没否决一样，下一个人看不出为什么。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.RejectDiscoveryGoal(GoalId, Reason);
  if R.Failed then
  begin
    MessageDlg('否决失败', R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  FGoalRejectReasonEdit.Text := '';
  ShowCurrentGoal(nil);
  ShowGoalList(nil);
end;

procedure TCEAMainForm.ShowCurrentGoal(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  GoalData: TJSONData;
  GoalText: string;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.CurrentDiscoveryGoal;
  if R.Failed then
  begin
    FGoalStatusLabel.Caption := '当前目标：读取失败（' + R.StableCode + '）。';
    Exit;
  end;
  FPlayerOutputMemo.Text := R.DataJson;
  Data := GetJSON(Utf8JsonText(R.DataJson));
  try
    GoalData := Data.FindPath('goal');
    if not Data.FindPath('has_active_goal').AsBoolean or (GoalData = nil) then
    begin
      FGoalStatusLabel.Caption := '当前目标：无（先接受一个目标）。';
      Exit;
    end;
    GoalText := GoalData.FindPath('description').AsString;
    FGoalStatusLabel.Caption := '当前目标：' + GoalText + '   [字段提示 ' +
      GoalData.FindPath('field_id_hint').AsString + ' / 类型 ' +
      GoalData.FindPath('value_type_hint').AsString + ' / 变化 ' +
      GoalData.FindPath('behavior_hint').AsString + ']';
    if FGoalIdEdit <> nil then
      FGoalIdEdit.Text := GoalData.FindPath('goal_id').AsString;
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.ShowGoalList(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Items: TJSONArray;
  Item: TJSONData;
  I: Integer;
  GoalId: string;
  Line: string;
begin
  if not Assigned(FRuntime) then Exit;
  if FGoalList = nil then Exit;
  R := FRuntime.ListDiscoveryGoals(50);
  if R.Failed then
  begin
    FGoalStatusLabel.Caption := '目标列表读取失败（' + R.StableCode + '）。';
    Exit;
  end;
  if FGoalJson = nil then FGoalJson := TStringList.Create;
  if FGoalIds = nil then FGoalIds := TStringList.Create;
  FGoalJson.Clear;
  FGoalIds.Clear;
  FGoalList.Items.BeginUpdate;
  try
    FGoalList.Items.Clear;
    Data := GetJSON(Utf8JsonText(R.DataJson));
    try
      Items := TJSONArray(Data.FindPath('goals'));
      if Items <> nil then
        for I := 0 to Items.Count - 1 do
        begin
          Item := Items.Items[I];
          GoalId := Item.FindPath('goal_id').AsString;
          { 列表行只放摘要：整段 JSON 塞进列表会立刻不可读，
            完整内容靠点击看。 }
          Line := GoalId + '  [' + Item.FindPath('state').AsString + ']  ' +
            Item.FindPath('description').AsString + '  (' +
            Item.FindPath('source').AsString + ')';
          if Item.FindPath('advisory').AsBoolean then
            Line := Line + '  模型建议';
          FGoalList.Items.Add(Line);
          FGoalJson.Add(Item.AsJSON);
          FGoalIds.Add(GoalId);
        end;
    finally
      Data.Free;
    end;
  finally
    FGoalList.Items.EndUpdate;
  end;
  if FGoalList.Items.Count = 0 then
    FGoalStatusLabel.Caption := '目标列表：空。先用自然语言记下一个目标。';
end;

procedure TCEAMainForm.SelectGoal(Sender: TObject);
begin
  if (FGoalList = nil) or (FGoalJson = nil) then Exit;
  if (FGoalList.ItemIndex < 0) or
    (FGoalList.ItemIndex >= FGoalJson.Count) then Exit;
  FPlayerOutputMemo.Text := FGoalJson[FGoalList.ItemIndex];
  { 摘要里有人读的字段，目标 ID 必须取原始值。 }
  if (FGoalIds <> nil) and (FGoalList.ItemIndex < FGoalIds.Count) and
    (FGoalIdEdit <> nil) then
    FGoalIdEdit.Text := FGoalIds[FGoalList.ItemIndex];
end;

procedure TCEAMainForm.RenderSecondaryScreen(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.BuildUiRenderJson('');
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('生成副屏渲染失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.EnumerateDisplays(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.EnumerateDisplays;
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('枚举显示器失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.SavePlayerPlacement(Sender: TObject);
var
  R: TCEAResult;
  SchemaId: string;
begin
  if not Assigned(FRuntime) then Exit;
  SchemaId := 'ui-' + Trim(FGameNameEdit.Text);
  R := FRuntime.SaveWindowPlacement(SchemaId, '\\.\DISPLAY1',
    Left, Top, Width, Height, 100, False);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('保存窗口位置失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.LoadPlayerPlacement(Sender: TObject);
var
  R: TCEAResult;
  SchemaId: string;
begin
  if not Assigned(FRuntime) then Exit;
  SchemaId := 'ui-' + Trim(FGameNameEdit.Text);
  R := FRuntime.LoadWindowPlacement(SchemaId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('读取窗口位置失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.UpdateSecondaryStatus;
var
  Endpoint: string;
  Running: Boolean;
begin
  if not Assigned(FRuntime) then Exit;
  Running := FRuntime.SecondaryScreenRunning;
  Endpoint := FRuntime.SecondaryScreenEndpoint;
  if Running then
    FSecondaryStatusLabel.Caption :=
      '副屏宿主运行中（仅本机可访问）：' + Endpoint
  else
    FSecondaryStatusLabel.Caption :=
      '副屏宿主未启动（本地回环，仅本机可访问）';
  FSecondaryOpenButton.Enabled := Running and (Endpoint <> '');
  FSecondaryStopButton.Enabled := Running;
end;

procedure TCEAMainForm.StartSecondaryScreen(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  // 只读模式启动：写入入口默认关闭，副屏页面不能成为绕过治理写入的通道。
  R := FRuntime.StartSecondaryScreen(False, 32146, 5);
  if R.Failed then
    MessageDlg('启动副屏宿主失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    FPlayerOutputMemo.Text := R.DataJson;
  UpdateSecondaryStatus;
end;

procedure TCEAMainForm.StopSecondaryScreen(Sender: TObject);
begin
  if not Assigned(FRuntime) then Exit;
  FRuntime.StopSecondaryScreen;
  UpdateSecondaryStatus;
end;

procedure TCEAMainForm.OpenSecondaryScreen(Sender: TObject);
var
  Endpoint: string;
begin
  if not Assigned(FRuntime) then Exit;
  Endpoint := FRuntime.SecondaryScreenEndpoint;
  if Endpoint = '' then
  begin
    MessageDlg('副屏宿主尚未启动。', mtInformation, [mbOK], 0);
    Exit;
  end;
  OpenURL(Endpoint);
end;

procedure TCEAMainForm.MarkPlayerEvent(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.MarkEvent(Trim(FEventTagEdit.Text));
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('标记事件失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.SavePlayerPage(Sender: TObject);
var
  R: TCEAResult;
  PageId, Title, SchemaJson: string;
begin
  if not Assigned(FRuntime) then Exit;
  PageId := Trim(FPageIdEdit.Text);
  Title := Trim(FPageTitleEdit.Text);
  if PageId = '' then
  begin
    MessageDlg('请先填写页面 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Title = '' then Title := PageId;
  // 保存的是「当前布局」：先把当前状态模型渲染成 schema，再存为具名页面。
  R := FRuntime.BuildUiRenderJson(Title);
  if R.Failed then
  begin
    MessageDlg('生成当前布局失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  SchemaJson := R.DataJson;
  R := FRuntime.SaveUiPage(PageId, Title, 'ui-' + Trim(FGameNameEdit.Text),
    SchemaJson);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('保存页面失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    ListPlayerPages(nil);
end;

procedure TCEAMainForm.ListPlayerPages(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Arr: TJSONArray;
  I: Integer;
  Obj: TJSONObject;
  PageId: string;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListUiPages;
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('列出页面失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPageIds.Clear;
  FPageCombo.Items.Clear;
  Data := GetJSON(R.DataJson);
  try
    if Data is TJSONObject then
    begin
      Arr := TJSONArray(TJSONObject(Data).Find('pages'));
      if Assigned(Arr) then
        for I := 0 to Arr.Count - 1 do
        begin
          Obj := TJSONObject(Arr.Items[I]);
          PageId := Obj.Get('page_id', '');
          if PageId = '' then Continue;
          FPageIds.Add(PageId);
          FPageCombo.Items.Add(PageId + ' / ' + Obj.Get('title', ''));
        end;
    end;
  finally
    Data.Free;
  end;
end;

procedure TCEAMainForm.SetSecondaryScreenPage(Sender: TObject);
var
  R: TCEAResult;
  Index: Integer;
begin
  if not Assigned(FRuntime) then Exit;
  Index := FPageCombo.ItemIndex;
  if (Index < 0) or (Index >= FPageIds.Count) then
  begin
    MessageDlg('请先选择一个页面。', mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.SetSecondaryScreenPage(FPageIds[Index]);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('切换副屏页面失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ListPlayerPageVersions(Sender: TObject);
var
  R: TCEAResult;
  SchemaId: string;
begin
  if not Assigned(FRuntime) then Exit;
  SchemaId := 'ui-' + Trim(FGameNameEdit.Text);
  R := FRuntime.ListUiSchemaVersions(SchemaId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('列出历史版本失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.RestorePlayerPageVersion(Sender: TObject);
var
  R: TCEAResult;
  SchemaId: string;
  Version: Integer;
begin
  if not Assigned(FRuntime) then Exit;
  SchemaId := 'ui-' + Trim(FGameNameEdit.Text);
  if not TryStrToInt(Trim(FPageVersionEdit.Text), Version) or (Version <= 0) then
  begin
    MessageDlg('版本号必须是正整数。', mtInformation, [mbOK], 0);
    Exit;
  end;
  // 回退只新增一个版本（旧布局另存为新版本），旧版本永不销毁。
  R := FRuntime.RestoreUiSchemaVersion(SchemaId, Version);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('回退失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ProposePlayerPage(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ProposeUiCustomization(Trim(FPageInstructionEdit.Text));
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('生成改版提案失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FPageProposalId := '';
  Data := GetJSON(R.DataJson);
  try
    if Data is TJSONObject then
      FPageProposalId := TJSONObject(Data).Get('proposal_id', '');
  finally
    Data.Free;
  end;
  MessageDlg('提案已生成，尚未保存。确认后才写入页面库。',
    mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.ConfirmPlayerPageProposal(Sender: TObject);
var
  R: TCEAResult;
  PageId, Title: string;
begin
  if not Assigned(FRuntime) then Exit;
  if FPageProposalId = '' then
  begin
    MessageDlg('没有待确认的提案，请先生成提案。', mtInformation, [mbOK], 0);
    Exit;
  end;
  PageId := Trim(FPageIdEdit.Text);
  Title := Trim(FPageTitleEdit.Text);
  if PageId = '' then
  begin
    MessageDlg('请先填写要保存到的页面 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Title = '' then Title := PageId;
  // 确认是本地操作者动作：MCP 侧同一动作只会返回 rcApprovalRequired。
  R := FRuntime.ConfirmUiCustomization(FPageProposalId, PageId, Title);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('确认提案失败：' + R.StableCode, mtError, [mbOK], 0)
  else
  begin
    FPageProposalId := '';
    ListPlayerPages(nil);
  end;
end;

procedure TCEAMainForm.RejectPlayerPageProposal(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  if FPageProposalId = '' then
  begin
    MessageDlg('没有待确认的提案。', mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.RejectUiCustomization(FPageProposalId);
  FPlayerOutputMemo.Text := R.DataJson;
  FPageProposalId := '';
  if R.Failed then
    MessageDlg('丢弃提案失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ShowPlayerEvents(Sender: TObject);
var
  R: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Id, Grade: string;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListEvents;
  FPlayerOutputMemo.Text := R.DataJson;
  if FEventList = nil then Exit;
  FEventList.Items.BeginUpdate;
  try
    FEventList.Items.Clear;
    if FEventIds = nil then FEventIds := TStringList.Create;
    FEventIds.Clear;
    if R.Failed then Exit;
    Data := GetJSON(R.DataJson);
    try
      if not (Data is TJSONObject) then Exit;
      Obj := TJSONObject(Data);
      if Obj.Find('events') = nil then Exit;
      if not (Obj.Find('events') is TJSONArray) then Exit;
      Arr := TJSONArray(Obj.Find('events'));
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then Continue;
        Id := TJSONObject(Arr[I]).Get('event_id', '');
        if Id = '' then Continue;
        Grade := TJSONObject(Arr[I]).Get('analysis_state', '');
        FEventIds.Add(Id);
        FEventList.Items.Add(Id + '  ' + Grade);
      end;
    finally
      Data.Free;
    end;
  finally
    FEventList.Items.EndUpdate;
  end;
end;

{ 时间线里选一条就把事件 ID 填进分析输入框：手抄 16 位 ID 是纯浪费。 }
procedure TCEAMainForm.SelectPlayerEvent(Sender: TObject);
begin
  if (FEventList = nil) or (FEventIds = nil) then Exit;
  if (FEventList.ItemIndex < 0) or (FEventList.ItemIndex >= FEventIds.Count) then
    Exit;
  FEventIdEdit.Text := FEventIds[FEventList.ItemIndex];
end;

procedure TCEAMainForm.AnalyzePlayerEvent(Sender: TObject);
var
  R: TCEAResult;
  EventId, FieldId: string;
begin
  if not Assigned(FRuntime) then Exit;
  EventId := Trim(FEventIdEdit.Text);
  FieldId := Trim(FEventFieldEdit.Text);
  if EventId = '' then
  begin
    MessageDlg('请先填写事件 ID（可从「查看事件时间线」的结果里取）。',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.AnalyzeEvent(EventId, FieldId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('分析失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ShowPlayerEventTrend(Sender: TObject);
var
  R: TCEAResult;
  FieldId: string;
begin
  if not Assigned(FRuntime) then Exit;
  FieldId := Trim(FEventFieldEdit.Text);
  if FieldId = '' then
  begin
    MessageDlg('请填写要关联的字段 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.CorrelateEventField(FieldId);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('关联失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.AnalyzePlayerEventWithModel(Sender: TObject);
var
  R: TCEAResult;
  EventId, FieldId: string;
begin
  if not Assigned(FRuntime) then Exit;
  EventId := Trim(FEventIdEdit.Text);
  FieldId := Trim(FEventFieldEdit.Text);
  if EventId = '' then
  begin
    MessageDlg('请先填写事件 ID。', mtInformation, [mbOK], 0);
    Exit;
  end;
  // 这一步会把事件里的实际数值发到模型服务端，必须当场确认（FR-091）。
  if MessageDlg('将把该事件的字段值与标签发送给已配置的模型服务，' +
    '用于生成解读。发送后无法撤回，确定继续？',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  R := FRuntime.AnalyzeEventWithProvider(EventId, FieldId, True);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('模型解读失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.StartPlayerRecording(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  // 抓帧会把游戏画面写到本机磁盘，并持续占用带宽与空间，必须先确认。
  if MessageDlg('将开始录制当前游戏窗口（约每 0.5 秒一帧），片段只保存在本机，' +
    '并受缓存时长与磁盘上限约束。确定开始？',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  R := FRuntime.StartEventRecording('', 500, 5 * 60 * 1000,
    QWord(512) * 1024 * 1024, 0);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    if R.StableCode = 'window_not_found' then
      MessageDlg('找不到该进程的可见窗口，无法录像。请确认游戏窗口已显示（未最小化）。',
        mtInformation, [mbOK], 0)
    else
      MessageDlg('开启录像失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  UpdateRecordingStatus;
end;

procedure TCEAMainForm.StopPlayerRecording(Sender: TObject);
begin
  if not Assigned(FRuntime) then Exit;
  FRuntime.StopEventRecording;
  UpdateRecordingStatus;
  FPlayerOutputMemo.Text := '事件录像已停止。已抓到的片段仍保存在本机，' +
    '受缓存时长与磁盘上限约束（锁定片段不受淘汰）。';
end;

procedure TCEAMainForm.UpdateRecordingStatus;
var
  R: TCEAResult;
  IsActive: Boolean;
begin
  if (FRecordingStatusLabel = nil) or (not Assigned(FRuntime)) then Exit;
  IsActive := FRuntime.EventRecordingActive;
  FRecordingStartButton.Enabled := not IsActive;
  FRecordingStopButton.Enabled := IsActive;
  if IsActive then
    FRecordingStatusLabel.Caption :=
      '事件录像：进行中（片段目录 ' + FRuntime.EventRecordingEndpoint + '）'
  else
    FRecordingStatusLabel.Caption :=
      '事件录像：未开启（开启后事件包会带上录像片段引用）';
  // 顺带刷新一次片段列表，避免界面显示的是开启前的旧快照。
  R := FRuntime.ListRecordingSegments;
  if R.Code = rcOk then
    ShowRecordingSegments(R.DataJson);
end;

procedure TCEAMainForm.ShowRecordingSegments(const ADataJson: string);
var
  Data: TJSONData;
  Segments: TJSONData;
  Item: TJSONData;
  I: Integer;
  Locked: Boolean;
  Marker: string;
begin
  if (FRecordingList = nil) or (FRecordingSegmentIds = nil) then Exit;
  FRecordingList.Items.BeginUpdate;
  try
    FRecordingList.Items.Clear;
    FRecordingSegmentIds.Clear;
    try
      Data := GetJSON(ADataJson);
    except
      Exit;
    end;
    try
      Segments := Data.FindPath('segments');
      if (Segments = nil) or (Segments.JSONType <> jtArray) then Exit;
      for I := 0 to Segments.Count - 1 do
      begin
        Item := Segments.Items[I];
        Locked := Item.FindPath('locked').AsBoolean;
        if Locked then Marker := '[锁定] ' else Marker := '';
        // 摘要进列表，完整 JSON 靠点击时看详情。
        FRecordingSegmentIds.Add(Item.FindPath('segment_id').AsString);
        FRecordingList.Items.Add(Marker +
          Item.FindPath('segment_id').AsString + '  ' +
          IntToStr(Item.FindPath('duration_ms').AsLargeInt) + 'ms  ' +
          IntToStr(Item.FindPath('frame_count').AsInteger) + ' 帧  ' +
          IntToStr(Item.FindPath('size_bytes').AsLargeInt) + ' 字节');
      end;
    finally
      Data.Free;
    end;
  finally
    FRecordingList.Items.EndUpdate;
  end;
end;

procedure TCEAMainForm.RefreshRecordingSegments(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) then Exit;
  R := FRuntime.ListRecordingSegments;
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('读取录像片段失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  ShowRecordingSegments(R.DataJson);
end;

procedure TCEAMainForm.ToggleRecordingSegmentLock(Sender: TObject);
var
  R: TCEAResult;
  Index: Integer;
  Locked: Boolean;
  SegmentId: string;
begin
  if (not Assigned(FRuntime)) or (FRecordingList = nil) then Exit;
  Index := FRecordingList.ItemIndex;
  if (Index < 0) or (Index >= FRecordingSegmentIds.Count) then
  begin
    MessageDlg('请先在列表里选中一个录像片段。', mtInformation, [mbOK], 0);
    Exit;
  end;
  SegmentId := FRecordingSegmentIds[Index];
  // 锁定 = 该片段永久保留，不受缓存时长/磁盘上限淘汰；这是不可逆的保留承诺，
  // 所以解锁前要问一次。
  Locked := Pos('[锁定]', FRecordingList.Items[Index]) = 0;
  if Locked then
  begin
    if MessageDlg('锁定片段 ' + SegmentId + '？锁定后它不会被自动清理。',
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;
  end;
  R := FRuntime.SetRecordingSegmentLocked(SegmentId, Locked);
  FPlayerOutputMemo.Text := R.DataJson;
  if R.Failed then
  begin
    MessageDlg('修改锁定状态失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  RefreshRecordingSegments(nil);
end;

procedure TCEAMainForm.SearchGcmGames(Sender: TObject);
var
  R: TCEAResult;
  Query: string;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  Query := Trim(FGcmQueryEdit.Text);
  if Query = '' then
  begin
    MessageDlg('请输入要搜索的游戏名（中文或英文）。', mtInformation, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.SearchGcmGames(Query);
  if R.Failed then
  begin
    FGcmMemo.Text := R.DataJson;
    MessageDlg('搜索失败：' + R.StableCode + LineEnding +
      'GCM 目录来自 Game Cheats Manager 的设置库；若未安装 GCM，请改用「扫描本地已有 .CT」。',
      mtError, [mbOK], 0);
    Exit;
  end;
  FGcmMemo.Text := R.DataJson;
end;

procedure TCEAMainForm.MatchGcmProcess(Sender: TObject);
var
  R: TCEAResult;
  ProcessName: string;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  ProcessName := Trim(FGcmProcessEdit.Text);
  if ProcessName = '' then
  begin
    MessageDlg('请输入进程名，例如 Stardew Valley.exe。', mtInformation, [mbOK], 0);
    Exit;
  end;
  // 60 分是「前缀/子串命中」的下限：更低的分数只会返回噪声匹配。
  R := FRuntime.MatchGcmGame(ProcessName, 60);
  if R.Failed then
  begin
    FGcmMemo.Text := R.DataJson;
    MessageDlg('匹配失败：' + R.StableCode, mtError, [mbOK], 0);
    Exit;
  end;
  FGcmMemo.Text := R.DataJson;
end;

procedure TCEAMainForm.ScanGcmCheatFiles(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  // 只枚举本地已存在的 .CT，不下载、不执行；候选列表交给操作者判断。
  R := FRuntime.ScanGcmCheatFiles;
  FGcmMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('扫描失败：' + R.StableCode, mtError, [mbOK], 0)
  else if Pos('"count":0', R.DataJson) > 0 then
    MessageDlg('未发现本地 .CT 文件。可继续用「导入 .CT」手动选择。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.ListPublishedCheatFiles(Sender: TObject);
var
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  R := FRuntime.ListPublishedCheatFiles;
  FGcmMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('列出失败：' + R.StableCode, mtError, [mbOK], 0);
end;

procedure TCEAMainForm.ImportCheatFileIntoLibrary(Sender: TObject);
var
  Dialog: TOpenDialog;
  R: TCEAResult;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Cheat Engine Table (*.CT)|*.CT|All files (*.*)|*.*';
    if not Dialog.Execute then Exit;
    // 导入只校验扩展名与大小上限，不改动原文件，也不解析其中的脚本。
    R := FRuntime.ImportCheatFile(Dialog.FileName);
  finally
    Dialog.Free;
  end;
  FGcmMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('导入失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    MessageDlg('已校验该 .CT（未执行、未修改原文件）。' + LineEnding +
      '若要把副本放进受管文件库，请用「发布到文件库」。',
      mtInformation, [mbOK], 0);
end;

procedure TCEAMainForm.PublishCheatFileToLibrary(Sender: TObject);
var
  Dialog: TOpenDialog;
  R: TCEAResult;
  SourcePath: string;
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
  begin
    MessageDlg('运行时尚未就绪。', mtWarning, [mbOK], 0);
    Exit;
  end;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.Filter := 'Cheat Engine Table (*.CT)|*.CT|All files (*.*)|*.*';
    if not Dialog.Execute then Exit;
    SourcePath := Dialog.FileName;
  finally
    Dialog.Free;
  end;
  // 发布会把副本写入不可变文件库并记录 SHA-256，属不可逆的本地写入。
  if MessageDlg('将把该 .CT 的副本发布到受管文件库，并记录 SHA-256。' +
    LineEnding + '发布不执行脚本、不联网。继续？',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  R := FRuntime.PublishCheatFile(SourcePath);
  FGcmMemo.Text := R.DataJson;
  if R.Failed then
    MessageDlg('发布失败：' + R.StableCode, mtError, [mbOK], 0)
  else
    ListPublishedCheatFiles(nil);
end;

procedure TCEAMainForm.RefreshProcesses(Sender: TObject);
begin
  if not Assigned(FRuntime) or not FRuntime.Started then
    Exit;
  FOutputMemo.Text := FRuntime.HandleMCP(
    '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"cea.list_processes","arguments":{}}}');
end;

procedure TCEAMainForm.PumpTimerTick(Sender: TObject);
var
  PartialText: string;
begin
  if Assigned(FLLMWorker) and not FLLMWorker.Completed then
  begin
    PartialText := FLLMWorker.StreamText;
    if PartialText <> '' then FLLMOutputMemo.Text := PartialText;
  end;
  CompleteLLMIfReady;
  CompleteSaveDiscoveryIfReady;
  PollValueScan;
  if Assigned(FRuntime) then
    FRuntime.PumpCommands(8);
end;

end.

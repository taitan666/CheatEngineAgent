unit cea_application_runtime;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_ports, cea_mcp_registry, cea_mcp_protocol,
  cea_sqlite_store, cea_system_clock, cea_windows_sha256,
  cea_local_approval_port, cea_policy_model, cea_lease_service,
  cea_effect_service, cea_freeze_service, cea_governance_gateway,
  cea_win32_effect_backend, cea_win32_governed_capability_port,
  cea_ct_model, cea_ct_parser, cea_ct_catalog, cea_llm_provider,
  cea_openai_compatible, cea_anthropic_compatible, cea_secret_store,
  cea_winhttp_transport,
  cea_mcp_http_server, cea_save_types, cea_save_service,
  cea_win32_save_reader, cea_win32_save_effect_port,
  cea_fixture_save_codec, cea_save_discovery_types,
  cea_save_discovery_service, Classes,
  cea_profile_types, cea_profile_ports, cea_profile_store,
  cea_profile_service,
  cea_field_model, cea_game_state_model, cea_mapping_service,
  cea_ui_schema_types, cea_ui_schema_codec, cea_ui_schema_builder,
  cea_ui_layout_types, cea_ui_schema_runtime, cea_ui_layout_store,
  cea_command_types, cea_command_bus, cea_write_journal_types,
  cea_write_journal, cea_write_preview, cea_field_constraints, cea_write_access,
  cea_state_capture_service,
  cea_value_scan_types,
  cea_event_types, cea_event_service, cea_event_repository, cea_win32_recording,
  cea_event_analysis_service,
  cea_win32_display_enumerator, cea_secondary_screen_host,
  cea_gcm_types, cea_gcm_cheat_file, cea_gcm_catalog, cea_gcm_cheat_library,
  cea_gcm_cheat_publisher, cea_gcm_description_translator,
  cea_ui_page_types, cea_ui_page_store, cea_ui_customization_service,
  cea_pointer_chain, cea_win32_pointer_reader,
  cea_win32_window_locator, cea_recording_service, cea_event_recording_bridge,
  cea_event_wake_queue,
  cea_reverse_types, cea_field_evidence, cea_field_evidence_store,
  cea_discovery_round, cea_discovery_goal;

var
  { Portable data directory override. When non-empty, every database is stored
    under this path instead of %APPDATA%\CheatEngineAgent. It is assigned from
    the --data-dir command line option before any runtime is created, and it
    never changes after Start. }
  CeaDatabasePathOverride: string = '';

type
  TCEAStandaloneRuntime = class;

  TCEAStandaloneMCPDispatcher = class(TObject, IMCPToolDispatcher)
  private
    FOwner: TCEAStandaloneRuntime;
    FDelegate: IMCPToolDispatcher;
  public
    constructor Create(const AOwner: TCEAStandaloneRuntime;
      const ADelegate: IMCPToolDispatcher);
    function DispatchTool(const AToolName,
      AArgumentsJson: string): TCEAResult;
  end;

  TCEAStandaloneRuntime = class
  private
    FStarted: Boolean;
    FDispatcher: IMCPToolDispatcher;
    FRegistry: TMCPToolRegistry;
    FProtocol: TMCPProtocol;
    FMCPServer: TCEAMCPHttpServer;
    FMCPToken: string;
    FMCPEndpoint: string;
    FMCPPreferredPort: Word;
    FDatabasePath: string;
    FStore: TCEASqliteStore;
    FClock: TCEASystemClock;
    FHasher: TCEAWindowsSha256;
    FApprovals: TCEALocalApprovalPort;
    FPolicy: TCEAPolicyModel;
    FLeases: TCEALeaseService;
    FEffects: TCEAEffectService;
    FFreezeService: TCEAFreezeService;
    FFreezeNextTick: QWord;
    FEffectBackend: TCEAWin32EffectBackend;
    FCapabilityPort: TCEAWin32GovernedCapabilityPort;
    FGateway: TCEAGovernanceGateway;
    FCTParser: TCTParser;
    FCTCatalog: TCTCatalog;
    FSecretStore: TCEASecretStore;
    FLLMTransport: TCEAWinHttpTransport;
    FLLMProvider: TCEALLMChatProvider;
    FSaveReader: TCEAWin32SaveReader;
    FSaveService: TCEASaveService;
    FSaveEffects: TCEAWin32SaveEffectPort;
    FFixtureSaveCodec: TCEAFixtureSaveCodec;
    FSelectedSaveSnapshot: TCEASaveSnapshot;
    FSaveDiscoveryService: TCEASaveDiscoveryService;
    FProfileStore: TCEAProfileStore;
    FProfileService: TCEAProfileService;
    FGcmCatalog: TCEAGcmCatalog;
    FGcmCheatLibrary: TCEAGcmCheatLibrary;
    FGcmCheatPublisher: TCEAGcmCheatPublisher;
    FMappingService: TCEAMappingService;
    FGameModel: TCEAGameStateModel;
    FUiRuntime: TCEAUiSchemaRuntime;
    FUiLayoutStore: TCEAUiLayoutStore;
    FDisplayEnumerator: TCEAWin32DisplayEnumerator;
    FEventService: TCEAEventService;
    FEventStore: TCEAEventRepository;
    FEventAnalysisService: TCEAEventAnalysisService;
    // 事件录像证据层（FR-070/074/077/079）。三段结构：
    // 窗口定位器给出 HWND -> 帧源抓帧 -> 捕获器写片段 -> 桥登记进缓存。
    // 未装配时事件包的 recording_refs_json 恒为 []（不假装录了）。
    FWindowLocator: TCEAWin32WindowLocator;
    // 帧源按类持有（不按接口持有）：CORBA 接口不参与引用计数，
    // 用接口字段保存会导致帧源对象永远没有所有者来释放它。
    FFrameSource: TCEAWin32WindowFrameSource;
    FRecordingCapture: TCEAWin32RecordingCapture;
    FRecordingCache: TCEARecordingService;
    FRecordingBridge: TCEAEventRecordingBridge;
    FRecordingPid: Cardinal;
    FRecordingStorageDir: string;
    // 按需唤醒 AI 的任务队列（FR-077）：只排队，不调用模型。
    FWakeQueue: TCEAEventWakeQueue;
    // FR-052 证据记录：采集、验证、用户确认各落一条可审计证据。
    // 证据只是记录，不是权限——能否写入仍由 verified_writable 决定。
    FFieldEvidenceStore: TCEAFieldEvidenceStore;
    FFieldEvidenceService: TCEAFieldEvidenceService;
    FWriteJournal: TCEAWriteJournal;
    FWriteSequence: Int64;
    // FR-051 分轮验证：会话内的探索计划（目的/操作/预期），不落盘。
    FDiscoveryRounds: TCEADiscoveryRoundService;
    // FR-050 目标描述：操作者用自然语言说想找什么。目标只是意图，不是证据。
    FDiscoveryGoals: TCEADiscoveryGoalService;
    // FR-054 写入隔离：写入默认关闭，操作者必须显式开启并说明理由。
    // 该授予绑定当前进程身份与 epoch，重新 attach 即失效。
    FWriteAccess: TCEAWriteAccess;
    FSecondaryScreen: TCEASecondaryScreenHost;
    FSecondaryScreenPort: Word;
    FSecondaryScreenPageId: string;
    FUiPageStore: TCEAUiPageStore;
    FUiCustomizationService: TCEAUiCustomizationService;
    // 未确认的定制提案：Propose 存、Confirm/Reject 取。只存在内存里，
    // 未确认的模型产物永不落盘（FR-025 + PRD 7.6）。
    FUiProposalIds: TStringList;
    FUiProposalSchemas: TStringList;
    FCaptureService: TCEAStateCaptureService;
    FCapturePid: Cardinal;
    FCaptureIdentityId: string;
    FCaptureEpoch: QWord;
    FDiscoveryEffectScope: TStringList;
    FRevokedDiscoveryScopes: TStringList;
    FSelectedDiscoveryScopeId: string;
    FSelectedDiscoverySnapshotId: string;
    FRevokedDiscoverySnapshotId: string;
    FLocalScanId: string;
    FLocalScanAttachmentSerial: QWord;
    FLocalScanScopeId: string;
    FLocalScanIdentityId: string;
    FLocalScanEpoch: QWord;
    FLocalScanStartHex: string;
    FLocalScanRangeBytes: Cardinal;
    FLocalScanMaxResults: Cardinal;
    FLocalScanValueType: string;
    FLocalScanRanges: TCEScanRangeArray;
    FLocalScanScopePartialReason: string;
    // AOB 扫描复用同一会话槽位：同一时刻只允许一个扫描，
    // 用这两个字段记住这次扫的是签名而非数值，状态/取消才能正确解读。
    FLocalScanIsAob: Boolean;
    FLocalScanAobPattern: string;
    function NextWriteRecordId: string;
    function JournalWrite(const AField: TCEAGameField;
      const AIdentity: TCEProcessIdentity; const AAdapterId,
      AOriginalValue, ATargetValue, AOutcome, AStableCode, AErrorText,
      ADetailJson: string; const ACommandSent, AVerified: Boolean;
      out ARecorded: Boolean): TCEAResult;
    function CurrentIdentity(out AIdentity: TCEProcessIdentity): TCEAResult;
    { FR-041: checks a target value against the field's declared constraints.
      Returns rcOk when the field declares nothing. Used by every write path so
      the preview, the verification write and the plain write cannot disagree
      about whether a value is acceptable. }
    function CheckFieldConstraints(const AField: TCEAGameField;
      const ATargetValue: string): TCEAResult;
    { Re-resolves a field's pointer chain against the current target and stores
      the resulting address. Shared by declaration, capture and write so all
      three see the same address in one operation. }
    function ResolvePointerFieldAddress(const AFieldId: string;
      out AField: TCEAGameField): TCEAResult;
    function SecondaryScreenRender(const ALayoutSchemaId: string): TCEAResult;
    function SecondaryScreenWrite(const AFieldId, ATargetValue,
      AExpectedCurrentValue: string): TCEAResult;
    // 副屏的页面列表与切页（FR-033）：只影响呈现，不触碰目标内存。
    function SecondaryScreenListPages: TCEAResult;
    function SecondaryScreenSelectPage(const APageId: string): TCEAResult;
    // 渲染一份已存储的 UI Schema（FR-026/033）：页面绑定的是 schema JSON，
    // 与「按状态模型即时生成」是两条路径，回退版本后才能看到旧布局。
    function RenderUiSchemaJson(const ASchemaJson: string): TCEAResult;
    function FindProposalIndex(const AProposalId: string): Integer;
    function CheckSaveTargetUnsettled(const AIdentityId, APath,
      AExcludeEffectId: string): TCEAResult;
    procedure RefreshLocalScanAttachment;
    function CheckSaveDiscoveryAuthority(const AEffectId,
      ASnapshotId: string): TCEAResult;
    procedure BindDiscoveryEffect(const AEffectId,
      ASnapshotId: string);
    function RejectDiscoveryPlannedEffects(
      const AScopeId: string): TCEAResult;
  public
    constructor Create(const ADatabasePath: string = '';
      const AMCPPreferredPort: Word = 32145);
    destructor Destroy; override;
    function Start: TCEAResult;
    procedure Stop;
    function PumpCommands(const AMaxItems: Cardinal): Cardinal;
    function HandleMCP(const ARequestJson: string): string;
    function AttachAuthorizedOffline(const ATaskId: string;
      const APid: Cardinal; out AIdentity: TCEProcessIdentity): TCEAResult;
    function AuthorizeLocalValueScanScope(const AStartHex: string;
      const ARangeBytes, AMaxResults: Cardinal): TCEAResult;
    function RevokeLocalValueScanScope(
      const AScopeId: string): TCEAResult;
    function StartLocalValueScan(const AStartHex: string;
      const ARangeBytes: Cardinal; const AValueType, AValueText: string;
      const AMaxResults: Cardinal): TCEAResult;
    function StartProcessValueScan(const ARegionKinds: string;
      const AMaxBytes: Cardinal; const AValueType, AValueText: string;
      const AMaxResults: Cardinal): TCEAResult;
    { AOB 签名扫描（真实写入验证的唯一性前置）：签名不唯一就不能当写入锚点，
      因此这里只负责扫出 match_count，唯一性判定在 GetAobScanUniqueness 里做。 }
    function StartAobScan(const AModuleName, AAobPattern: string;
      const AMaxBytes: Cardinal; const AMaxResults: Cardinal): TCEAResult;
    function GetAobScanUniqueness(const AScanId: string): TCEAResult;
    { 唯一性判定本身是只读的：它只读扫描会话的 match_count，因此不绑定
      本地发起的会话。MCP 发起的扫描同样可以被判唯一性，但发起扫描仍必须
      由本地操作者授权（租约在网关校验）。 }
    function JudgeAobUniqueness(const AScanId: string): TCEAResult;
    function GetLocalValueScanStatus(
      const AScanId: string): TCEAResult;
    function RefineLocalValueScan(const AScanId,
      AValueText: string): TCEAResult;
    function CancelLocalValueScan(const AScanId: string): TCEAResult;
    function PlanMemoryWrite(const ATaskId, AAddressHex,
      AExpectedHex, AReplacementHex: string;
      out AEffect: TCEAEffect): TCEAResult;
    function PlanMemoryFreeze(const ATaskId, AAddressHex,
      AExpectedHex, AReplacementHex: string; const AIntervalMs,
      AMaxWrites, ADurationSeconds: Cardinal;
      out AEffect: TCEAEffect): TCEAResult;
    function ApproveAndStartFreeze(const AEffectId: string): TCEAResult;
    function TickFreeze: TCEAResult;
    function StopFreeze(const AReason: string = ''): TCEAResult;
    function FreezeActive: Boolean;
    function ApproveAndExecute(const AEffectId: string): TCEAResult;
    function RejectEffect(const AEffectId: string): TCEAResult;
    function LoadEffect(const AEffectId: string;
      out AEffect: TCEAEffect): TCEAResult;
    function ReconcileUnknownEffect(const AEffectId: string): TCEAResult;
    function ImportCTFile(const APath: string): TCEAResult;
    function InspectSaveFile(const ATaskId, APath: string;
      out ASnapshot: TCEASaveSnapshot): TCEAResult;
    function AuthorizeSaveDirectory(const ARoot: string;
      const ABudget: TCEADiscoveryBudget;
      out AScope: TCEADiscoveryScope): TCEAResult;
    function ScanSaveDirectory(const AScopeId: string;
      out ACandidates: TCEASaveCandidateArray): TCEAResult;
    function CancelSaveDirectory(const AScopeId: string): TCEAResult;
    function SelectSaveCandidate(const AScopeId,
      ACandidateId: string;
      out ASnapshot: TCEASaveSnapshot): TCEAResult;
    function RevokeSaveDirectory(const AScopeId: string): TCEAResult;
    function GetSaveFields(const ASnapshot: TCEASaveSnapshot;
      out AFields: TCEASaveFieldArray): TCEAResult;
    function GetSelectedSaveSnapshot: TCEAResult;
    function RequestSelectedSaveBackup(const ATaskId: string): TCEAResult;
    function GetSaveEffect(const AEffectId: string): TCEAResult;
    function ProposeSelectedSaveEdit(const AFieldPath,
      AExpectedJson, ANewJson: string): TCEAResult;
    function RequestSaveBackup(const ATaskId: string;
      const ASnapshot: TCEASaveSnapshot;
      out AEffectId: string): TCEAResult;
    function ProposeSaveFieldEdit(const ASnapshot: TCEASaveSnapshot;
      const AFieldPath, AExpectedJson, ANewJson: string;
      out AProposal: TCEASaveEditProposal): TCEAResult;
    function PlanSaveEdit(const ATaskId: string;
      const ASnapshot: TCEASaveSnapshot;
      const AProposal: TCEASaveEditProposal;
      const ABackupEffectId: string;
      out AEffectId: string): TCEAResult;
    function ExecuteSaveEdit(const AEffectId: string): TCEAResult;
    function PlanSaveRestore(const ATaskId: string;
      const ACurrent: TCEASaveSnapshot;
      const ABackupEffectId, AExpectedCurrentHash: string;
      out AEffectId: string): TCEAResult;
    function ReconcileUnsettledSaveEffects: TCEAResult;
    function GetSaveRecoveryCase(const AEffectId: string;
      out AAssessment, AObservedHash: string): TCEAResult;
    function SearchCT(const AText: string;
      const AMaxResults: Cardinal = 20): TCEAResult;
    function GetCTEntry(const AEntryKey: string): TCEAResult;
    function BuildCTRagContext(const AText: string;
      const AMaxResults: Cardinal = 20): TCEAResult;
    function EmergencyStop: TCEAResult;
    function ConfigureLLM(const AEndpoint, AModelId,
      ASecretRef: string; const AProviderId: string = ''): TCEAResult;
    function SaveLLMCredential(const ASecretRef,
      ASecretValue: string): TCEAResult;
    function ChatWithRag(const APrompt, ACTQuery: string): TCEAResult;
    function ChatWithContext(const APrompt, ARagContextJson: string;
      const ACancellation: ICEACancellationToken;
      const AStreamSink: ICEALLMTextStreamSink = nil): TCEAResult;
    { Phase 1 player-level capabilities (PRD 6.1-6.8): semantic field model,
      field mapping, state capture, governed writes, secondary-screen render,
      display/window memory, event evidence layer. }
    function StartGameSession(const AGameName, AGameVersion: string): TCEAResult;
    procedure EndGameSession;
    function GameSessionActive: Boolean;
    function DeclareField(const AFieldId, ADisplayName, AValueType,
      AAddressHex: string): TCEAResult;
    { FR-041: declares the acceptable range / allowed set for a field. An empty
      string clears the constraints. The block is parsed here so a malformed
      one is rejected now rather than failing every later write. }
    function SetFieldConstraints(const AFieldId,
      AConstraintsJson: string): TCEAResult;
    { Pointer chain declaration (real-game verification): the address is not an
      absolute snapshot but re-resolved from module + offsets, so a field keeps
      working after the target restarts. Resolution is read-only. }
    function DeclarePointerField(const AFieldId, ADisplayName, AValueType,
      AModuleName, AOffsetsJson: string;
      const AAddressWidthBits: Cardinal = 64): TCEAResult;
    function ResolveFieldAddress(const AFieldId: string): TCEAResult;
    function ProposeAiFieldMapping(const AFieldId, ADisplayName, AValueType,
      AAddressHex, AEvidenceRefsJson: string; const AConfidence: Double;
      const ACreatedAt: string): TCEAResult;
    function ConfirmFieldMapping(const AMappingId: string): TCEAResult;
    function RejectFieldMapping(const AMappingId: string): TCEAResult;
    function ListFieldMappings: TCEAResult;
    function ListGameFields: TCEAResult;
    { Game Profile（FR-055 配置复用 / FR-061 版本兼容性检测）：把当前会话的
      字段集合连定位配方一起存成 Profile，下次开局直接还原。
      还原出的字段一律 read_only：Profile 只能证明字段存在过，不能证明地址
      现在还能写；可写必须重新走写-重读验证（FR-044）。 }
    function SaveGameProfile: TCEAResult;
    function RestoreGameProfile(const AGameName: string): TCEAResult;
    function ConfirmFieldWritable(const AFieldId, ATargetValue,
      AExpectedCurrentValue: string): TCEAResult;
    function CaptureFieldValue(const AFieldId: string): TCEAResult;
    { FR-052 证据记录：把「观察到什么、在哪个进程版本上、验证结果如何」
      落成可查询的证据，供候选地址与 Profile 引用。
      证据不是权限：字段能否写入只由 verified_writable 决定。 }
    function ListFieldEvidence(const AFieldId: string;
      const ALimit: Cardinal = CeaFieldEvidenceDefaultLimit): TCEAResult;
    function RecordFieldUserConfirmation(const AFieldId: string): TCEAResult;
    { FR-051 分轮验证：每轮扫描/修改之前先声明目的、操作、预期观察结果。
      轮次是会话内计划，不落盘；同一时刻只允许一个未收尾轮次。 }
    function PlanDiscoveryRound(const AKind, APurpose, AOperation,
      AExpectedObservation, AFieldId: string): TCEAResult;
    function CompleteDiscoveryRound(const ARoundId, AObservedOutcome: string;
      const AMatchedExpectation: Boolean): TCEAResult;
    function AbandonDiscoveryRound(const ARoundId, AReason: string): TCEAResult;
    function ListDiscoveryRounds(const ALimit: Cardinal): TCEAResult;
    function CurrentDiscoveryRound: TCEAResult;
    { FR-050 目标描述：操作者用自己的话描述想找的字段。目标只是意图，
      不是证据：接受目标不授权扫描、写入，也不证明地址或可写性。 }
    function ProposeDiscoveryGoal(const ADescription, AFieldIdHint,
      AValueTypeHint, ABehaviorHint: string): TCEAResult;
    function ProposeDiscoveryGoalWithModel(const ADescription: string;
      const AMaxOutputTokens: Cardinal): TCEAResult;
    function AcceptDiscoveryGoal(const AGoalId: string): TCEAResult;
    function RejectDiscoveryGoal(const AGoalId, AReason: string): TCEAResult;
    function ListDiscoveryGoals(const ALimit: Cardinal): TCEAResult;
    function CurrentDiscoveryGoal: TCEAResult;
    function WriteFieldValue(const AFieldId, ATargetValue,
      AExpectedCurrentValue: string): TCEAResult;
    { FR-042 / FR-045: preview a write command before it is sent. The preview
      reads the field's current value live (never the cached model value) so the
      operator sees what would actually be overwritten, and reports a conflict
      when that value no longer matches the one they based their edit on.
      A preview never writes and never mutates the model, so it is safe to
      expose to any caller; the write itself still needs local approval. }
    function PreviewFieldWrite(const AFieldId, ATargetValue,
      AExpectedCurrentValue: string): TCEAResult;
    { FR-054 写入隔离：写入与会话级授权分离，默认只读。开启写入必须说明理由，
      且只对当前进程身份与 epoch 生效；重新 attach 或换游戏即撤销。
      FR-040 四态标记：请求写入把字段从 read_only 推进到 pending_write，
      只有写-重读验证通过才成为 verified_writable。pending_write 是意图，
      不是权限——真正写入仍要求 verified_writable。 }
    function EnableWriteAccess(const AReason: string): TCEAResult;
    function DisableWriteAccess: TCEAResult;
    function GetWriteAccess: TCEAResult;
    function RequestFieldWrite(const AFieldId: string): TCEAResult;
    function BuildUiRenderJson(const APageTitle: string): TCEAResult;
    function EnumerateDisplays: TCEAResult;
    function SaveWindowPlacement(const ASchemaId, ADisplayId: string;
      const ALeft, ATop, AWidth, AHeight, AScalePercent: Integer;
      const AMaximized: Boolean): TCEAResult;
    function LoadWindowPlacement(const ASchemaId: string): TCEAResult;
    function ConfigureFieldChangeRule(const AFieldId, ACondition: string;
      const AThreshold: Double; const ACooldownMs: Int64): TCEAResult;
    function MarkEvent(const ATag: string): TCEAResult;
    function ListEvents: TCEAResult;
    function DeleteEvent(const AEventId: string): TCEAResult;
    { FR-046 操作历史：玩家写入的持久审计面。两条写入路径
      （命令总线 / 直接验证）都会记账，成功与失败都记。 }
    function ListFieldWriteHistory(const AFieldId: string;
      const ALimit: Integer): TCEAResult;
    // PRD 6.9 事件分析与证据关联（FR-090~094）。本地分析恒可用；外发模型必须
    // 每次显式同意，且推断级证据永不参与写入判定。
    function AnalyzeEvent(const AEventId, AFieldId: string): TCEAResult;
    function CorrelateEventField(const AFieldId: string): TCEAResult;
    function SuggestEventVerification(const AEventId: string): TCEAResult;
    function AnalyzeEventWithProvider(const AEventId, AFieldId: string;
      const AConsentToSendValues: Boolean): TCEAResult;
    // 事件录像证据层（FR-070/074/077/079）。默认关闭：只有本地操作者显式
    // 开启才会抓屏，且抓的是本机窗口像素、不碰目标进程内存（FR-080）。
    function StartEventRecording(const AStorageDirectory: string;
      const AFrameIntervalMs: Int64; const ACacheDurationMs: Int64;
      const AMaxDiskBytes: QWord; const ARetentionMs: Int64): TCEAResult;
    procedure StopEventRecording;
    function EventRecordingActive: Boolean;
    function EventRecordingEndpoint: string;
    function ListRecordingSegments: TCEAResult;
    function SetRecordingSegmentLocked(const ASegmentId: string;
      const ALocked: Boolean): TCEAResult;
    // FR-077 按需唤醒：把事件排进本地待办队列，不调用模型。
    function QueueEventForAnalysis(const AEventId: string): TCEAResult;
    function PeekAnalysisQueue: TCEAResult;
    // Secondary screen (local loopback page). Writes stay disabled unless the
    // caller explicitly opts in; even then every write goes through the
    // governed WriteFieldValue path.
    function StartSecondaryScreen(const AEnableWrites: Boolean;
      const APreferredPort, AAttempts: Word): TCEAResult;
    procedure StopSecondaryScreen;
    function SecondaryScreenEndpoint: string;
    function SecondaryScreenRunning: Boolean;
    // GCM 目录与 CE 文件库（Phase A/B）。全部本地读取，不联网、不执行。
    function LoadGcmCatalog: TCEAResult;
    function MatchGcmGame(const AProcessName: string;
      const AMinScore: Integer): TCEAResult;
    function SearchGcmGames(const AText: string): TCEAResult;
    function ScanGcmCheatFiles: TCEAResult;
    function ImportCheatFile(const APath: string): TCEAResult;
    function PublishCheatFile(const ASourcePath: string): TCEAResult;
    function ListPublishedCheatFiles: TCEAResult;
    // CE 表描述文本的机器翻译（Phase C）。只翻译 <Description>，不触碰脚本；
    // 结果仅作参考，不参与字段/地址/写入决策。
    function TranslateCheatFileDescriptions(const APath: string;
      const ACancellation: ICEACancellationToken = nil): TCEAResult;
    { 1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025/026/033） }
    function SaveUiPage(const APageId, ATitle, ASchemaId,
      ASchemaJson: string): TCEAResult;
    function ListUiPages: TCEAResult;
    function GetUiPage(const APageId: string): TCEAResult;
    function SetActiveUiPage(const APageId: string): TCEAResult;
    function GetActiveUiPage: TCEAResult;
    function ListUiSchemaVersions(const ASchemaId: string): TCEAResult;
    function RestoreUiSchemaVersion(const ASchemaId: string;
      const AVersion: Integer): TCEAResult;
    function SetSecondaryScreenPage(const APageId: string): TCEAResult;
    function ProposeUiCustomization(const AInstruction: string): TCEAResult;
    function ConfirmUiCustomization(const AProposalId, APageId,
      ATitle: string): TCEAResult;
    function RejectUiCustomization(const AProposalId: string): TCEAResult;
    property Started: Boolean read FStarted;
    property MCPToken: string read FMCPToken;
    property MCPEndpoint: string read FMCPEndpoint;
  end;

implementation

uses
  SysUtils, Windows, fpjson, cea_win32_engine_runtime, cea_win32_engine_bootstrap,
  cea_engine_mcp_dispatcher;

{ The JSON helpers live further down with the player-level section, but the
  scan APIs above them already need them, so declare them up front. }
function JsonEscapeText(const AValue: string): string; forward;
function JsonBool(const AValue: Boolean): string; forward;

function EffectStateName(const AState: TCEAEffectState): string;
begin
  case AState of
    esPlanned: Result := 'planned';
    esExecuting: Result := 'executing';
    esApplied: Result := 'applied';
    esRejected: Result := 'rejected';
    esUnknown: Result := 'unknown';
  end;
end;

// Event recording evidence layer defaults (FR-070/074/077):
// 5s pre-roll and post-roll, 512 snapshots, 30s cooldown.
function DefaultEventServiceConfig: TCEAEventServiceConfig;
begin
  Result.PreRollMs := 5000;
  Result.PostRollMs := 5000;
  Result.SnapshotCapacity := 512;
  Result.DefaultCooldownMs := 30000;
end;

// Recording cache defaults (FR-079): 5 minutes rolling, 512 MiB disk cap,
// event segments kept forever unless the operator locks or deletes them.
function DefaultRecordingPolicy: TCEARecordingPolicy;
begin
  Result.CacheDurationMs := 5 * 60 * 1000;
  Result.MaxDiskBytes := QWord(512) * 1024 * 1024;
  Result.RetentionMs := 0;
end;

const
  // Directory under the application data directory where recording segments
  // (raw .bgr frames + .index.json) are written. Raw frames never leave the
  // machine; only summaries may be sent to a model after explicit consent.
  CeaRecordingStorageDirectoryName = 'recordings';

// MCP callers can propose player-level actions but never approve them: the
// local operator UI is the only approval surface (FR-043 / AC-007).
function ApprovalRequiredWithSurface(const ASurface,
  AExtraJson: string): TCEAResult;
var
  Extra: string;
begin
  Extra := AExtraJson;
  if (Extra = '') or (Extra = '{}') then
    Extra := '{}';
  Result := TCEAResult.Error(rcApprovalRequired,
    'local_operator_approval_required',
    '{"approval_surface":"local_ui_only","surface":"' + ASurface +
    '","detail":' + Extra + '}');
end;

function ValidSaveSnapshotId(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AValue) = Length('snapshot-') + 32) and
    (Copy(AValue, 1, Length('snapshot-')) = 'snapshot-');
  if not Result then Exit;
  for I := Length('snapshot-') + 1 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function SaveEffectSourcePath(const ARequestJson: string): string;
var
  Data: TJSONData;
begin
  Result := '';
  Data := nil;
  try
    try
      Data := GetJSON(ARequestJson);
      if (Data <> nil) and (Data.JSONType = jtObject) then
        Result := TJSONObject(Data).Get('source_path', '');
    except
      Result := '';
    end;
  finally
    Data.Free;
  end;
end;

function TCEAStandaloneRuntime.CheckSaveTargetUnsettled(
  const AIdentityId, APath, AExcludeEffectId: string): TCEAResult;
var
  Ids: TCEASaveEffectIdArray;
  Effect: TCEAEffect;
  SourcePath: string;
  I: Integer;
begin
  if FStore = nil then
    Exit(TCEAResult.Error(rcConflict, 'save_store_unavailable', '{}'));
  Result := FStore.ListUnsettledSaveEffectIds(Ids);
  if Result.Failed then Exit;
  for I := 0 to High(Ids) do
  begin
    if Ids[I] = AExcludeEffectId then Continue;
    Result := FStore.LoadEffect(Ids[I], Effect);
    if Result.Failed then Exit;
    SourcePath := SaveEffectSourcePath(Effect.RequestJson);
    if ((AIdentityId <> '') and
        (Effect.ResourceIdentityId = AIdentityId)) or
       ((APath <> '') and (SourcePath <> '') and
        SameText(ExpandFileName(APath), ExpandFileName(SourcePath))) then
      Exit(TCEAResult.Error(rcConflict,
        'save_target_has_unsettled_effect', '{}'));
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEAStandaloneRuntime.CheckSaveDiscoveryAuthority(
  const AEffectId, ASnapshotId: string): TCEAResult;
var
  ScopeId: string;
begin
  if (ASnapshotId <> '') and
     (ASnapshotId = FRevokedDiscoverySnapshotId) then
    Exit(TCEAResult.Error(rcUnauthorized,
      'save_discovery_scope_revoked', '{}'));
  if (AEffectId <> '') and (FDiscoveryEffectScope <> nil) and
     (FRevokedDiscoveryScopes <> nil) then
  begin
    ScopeId := FDiscoveryEffectScope.Values[AEffectId];
    if (ScopeId <> '') and
       (FRevokedDiscoveryScopes.IndexOf(ScopeId) >= 0) then
      Exit(TCEAResult.Error(rcUnauthorized,
        'save_discovery_scope_revoked', '{}'));
  end;
  Result := TCEAResult.Ok('{}');
end;

procedure TCEAStandaloneRuntime.BindDiscoveryEffect(
  const AEffectId, ASnapshotId: string);
begin
  if (AEffectId <> '') and (FSelectedDiscoveryScopeId <> '') and
     (ASnapshotId = FSelectedDiscoverySnapshotId) and
     (FDiscoveryEffectScope <> nil) then
    FDiscoveryEffectScope.Values[AEffectId] :=
      FSelectedDiscoveryScopeId;
end;

function TCEAStandaloneRuntime.RejectDiscoveryPlannedEffects(
  const AScopeId: string): TCEAResult;
var
  I: Integer;
  Effect: TCEAEffect;
begin
  if (FDiscoveryEffectScope = nil) or (FStore = nil) then
    Exit(TCEAResult.Error(rcConflict,
      'save_discovery_effect_store_unavailable', '{}'));
  for I := 0 to FDiscoveryEffectScope.Count - 1 do
  begin
    if FDiscoveryEffectScope.ValueFromIndex[I] <> AScopeId then
      Continue;
    Result := FStore.LoadEffect(FDiscoveryEffectScope.Names[I], Effect);
    if Result.Failed then Exit;
    if Effect.State <> esPlanned then Continue;
    Result := FApprovals.Reject(Effect);
    if Result.Failed then Exit;
    Effect.State := esRejected;
    Effect.UpdatedAt := FClock.UtcNowIso8601;
    Effect.ResultJson := '{"reason":"save_discovery_scope_revoked"}';
    Result := FStore.SaveEffect(Effect);
    if Result.Failed then Exit;
  end;
  Result := TCEAResult.Ok('{"planned_effects_rejected":true}');
end;

constructor TCEAStandaloneMCPDispatcher.Create(
  const AOwner: TCEAStandaloneRuntime;
  const ADelegate: IMCPToolDispatcher);
begin
  inherited Create;
  FOwner := AOwner;
  FDelegate := ADelegate;
end;

function TCEAStandaloneMCPDispatcher.DispatchTool(const AToolName,
  AArgumentsJson: string): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Effect: TCEAEffect;
  MaxResults: Cardinal;
begin
  if FOwner = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'standalone_dispatcher_owner_missing', '{}'));
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'tool_arguments_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'tool_arguments_object_required', '{}'));
    Obj := TJSONObject(Data);
    if AToolName = 'cea.search_ct' then
    begin
      MaxResults := Obj.Get('max_results', 20);
      Exit(FOwner.SearchCT(Obj.Get('query', ''), MaxResults));
    end;
    if AToolName = 'cea.build_rag_context' then
    begin
      MaxResults := Obj.Get('max_results', 20);
      Exit(FOwner.BuildCTRagContext(Obj.Get('query', ''), MaxResults));
    end;
    if AToolName = 'cea.get_ct_entry' then
      Exit(FOwner.GetCTEntry(Obj.Get('entry_key', '')));
    if (AToolName = 'cea.inspect_save') or
       (AToolName = 'cea.get_save_snapshot') then
      Exit(FOwner.GetSelectedSaveSnapshot);
    if AToolName = 'cea.propose_save_edit' then
      Exit(FOwner.ProposeSelectedSaveEdit(Obj.Get('field_path', ''),
        Obj.Get('expected_json', ''), Obj.Get('new_json', '')));
    if AToolName = 'cea.request_save_backup' then
      Exit(FOwner.RequestSelectedSaveBackup(Obj.Get('task_id', '')));
    if AToolName = 'cea.get_save_effect' then
      Exit(FOwner.GetSaveEffect(Obj.Get('effect_id', '')));
    if AToolName = 'cea.import_ct' then
      Exit(TCEAResult.Error(rcApprovalRequired,
        'local_ct_import_required', '{}'));
    if AToolName = 'cea.request_memory_write' then
    begin
      Result := FOwner.PlanMemoryWrite(Obj.Get('task_id', ''),
        Obj.Get('address', ''), Obj.Get('expected_original_bytes', ''),
        Obj.Get('replacement_bytes', ''), Effect);
      if Result.Code = rcApprovalRequired then
        Result.DataJson := '{"effect_id":"' + Effect.Id +
          '","state":"planned","request_hash":"' +
          Effect.RequestHash + '","approval_surface":"local_ui_only"}';
      Exit;
    end;
    if AToolName = 'cea.request_freeze' then
    begin
      Result := FOwner.PlanMemoryFreeze(Obj.Get('task_id', ''),
        Obj.Get('address', ''), Obj.Get('expected_original_bytes', ''),
        Obj.Get('replacement_bytes', ''), Obj.Get('interval_ms', 0),
        Obj.Get('max_writes', 0), Obj.Get('duration_seconds', 0), Effect);
      if Result.Code = rcApprovalRequired then
        Result.DataJson := '{"effect_id":"' + Effect.Id +
          '","state":"planned","request_hash":"' +
          Effect.RequestHash + '","approval_surface":"local_ui_only"}';
      Exit;
    end;
    if AToolName = 'cea.get_effect_status' then
    begin
      Result := FOwner.LoadEffect(Obj.Get('effect_id', ''), Effect);
      if not Result.Failed then
        Result := TCEAResult.Ok('{"effect_id":"' + Effect.Id +
          '","state":"' + EffectStateName(Effect.State) +
          '","request_hash":"' + Effect.RequestHash + '"}');
      Exit;
    end;
    if AToolName = 'cea.emergency_stop' then
      Exit(FOwner.EmergencyStop);
    { AOB 唯一性判定只读扫描状态，不改目标，因此 MCP 可以直接执行；
      真正发起扫描仍由 cea.start_scan 走租约与本地授权。 }
    if AToolName = 'cea.judge_aob_uniqueness' then
      Exit(FOwner.JudgeAobUniqueness(Obj.Get('scan_id', '')));
    { Phase 1 player-level tools. Mutating player actions stay local-only: they
      answer rcApprovalRequired with the local_ui_only surface so an MCP client
      can never become an approval path (FR-043). }
    if AToolName = 'cea.start_game_session' then
      Exit(FOwner.StartGameSession(Obj.Get('game_name', ''),
        Obj.Get('game_version', '')));
    if AToolName = 'cea.end_game_session' then
    begin
      FOwner.EndGameSession;
      Exit(TCEAResult.Ok('{"session_active":false}'));
    end;
    if AToolName = 'cea.list_game_fields' then
      Exit(FOwner.ListGameFields);
    { Game Profile 写入的是持久配置、还原的是活的 Game State Model：
      两者都会改变「下次开局看到什么」，因此都只申请、不执行。 }
    if AToolName = 'cea.save_game_profile' then
      Exit(ApprovalRequiredWithSurface('save_game_profile', '{}'));
    if AToolName = 'cea.restore_game_profile' then
      Exit(ApprovalRequiredWithSurface('restore_game_profile', '{}'));
    if AToolName = 'cea.capture_field_value' then
      Exit(FOwner.CaptureFieldValue(Obj.Get('field_id', '')));
    if AToolName = 'cea.list_field_mappings' then
      Exit(FOwner.ListFieldMappings);
    { Constraints decide which values a write may ever carry, so widening or
      loosening them is a governance decision, not a read. }
    if AToolName = 'cea.set_field_constraints' then
      Exit(ApprovalRequiredWithSurface('field_constraints', '{}'));
    if AToolName = 'cea.declare_field' then
      Exit(ApprovalRequiredWithSurface('declare_field', '{}'));
    if AToolName = 'cea.declare_pointer_field' then
      Exit(ApprovalRequiredWithSurface('declare_pointer_field', '{}'));
    { Resolution is read-only: it only reads target memory to follow the chain
      and updates the field's cached address, so MCP may run it directly. }
    if AToolName = 'cea.resolve_field_address' then
      Exit(FOwner.ResolveFieldAddress(Obj.Get('field_id', '')));
    if AToolName = 'cea.propose_ai_field_mapping' then
      Exit(ApprovalRequiredWithSurface('propose_ai_field_mapping', '{}'));
    if (AToolName = 'cea.confirm_field_mapping') or
       (AToolName = 'cea.reject_field_mapping') then
      Exit(ApprovalRequiredWithSurface('field_mapping_review', '{}'));
    if (AToolName = 'cea.write_field_value') or
       (AToolName = 'cea.confirm_field_writable') then
      Exit(ApprovalRequiredWithSurface('field_write', '{}'));
    { FR-040/FR-054: granting write access, revoking it, and declaring a field
      as intended-for-write are all operator intent, so MCP may only ask. The
      grant itself is session-scoped and bound to one process identity; even
      with a grant, a write still has to pass the verified_writable gate. }
    if AToolName = 'cea.enable_write_access' then
      Exit(ApprovalRequiredWithSurface('write_access', '{}'));
    if AToolName = 'cea.disable_write_access' then
      Exit(ApprovalRequiredWithSurface('write_access', '{}'));
    if AToolName = 'cea.request_field_write' then
      Exit(ApprovalRequiredWithSurface('field_write', '{}'));
    if AToolName = 'cea.get_write_access' then
      Exit(FOwner.GetWriteAccess);
    { FR-042/FR-045: a preview only reads the live value and compares it with
      the expected original, so it changes nothing and MCP may run it. The
      payload reports can_execute=false when the write would be blocked. }
    if AToolName = 'cea.preview_field_write' then
      Exit(FOwner.PreviewFieldWrite(Obj.Get('field_id', ''),
        Obj.Get('target_value', ''), Obj.Get('expected_current_value', '')));
    if AToolName = 'cea.build_ui_render_json' then
      Exit(FOwner.BuildUiRenderJson(Obj.Get('page_title', '')));
    if AToolName = 'cea.enumerate_displays' then
      Exit(FOwner.EnumerateDisplays);
    if AToolName = 'cea.mark_event' then
      Exit(FOwner.MarkEvent(Obj.Get('tag', '')));
    if AToolName = 'cea.list_events' then
      Exit(FOwner.ListEvents);
    if AToolName = 'cea.delete_event' then
      Exit(FOwner.DeleteEvent(Obj.Get('event_id', '')));
    { PRD 6.9：证据分级 / 多轮关联 / 验证建议都是只读推导，MCP 可以直接问；
      但把事件里的实际数值外发给模型会离开本机，必须本地操作者当场同意，
      所以那条路径固定要求审批（FR-091 / FR-093）。 }
    if AToolName = 'cea.analyze_event' then
      Exit(FOwner.AnalyzeEvent(Obj.Get('event_id', ''), Obj.Get('field_id', '')));
    if AToolName = 'cea.get_field_trend' then
      Exit(FOwner.CorrelateEventField(Obj.Get('field_id', '')));
    { FR-046：操作历史只读。MCP 能查，但没有任何 MCP 工具能写入字段，
      写入仍只能由本地操作者在桌面端发起。 }
    if AToolName = 'cea.list_field_write_history' then
      Exit(FOwner.ListFieldWriteHistory(Obj.Get('field_id', ''),
        Obj.Get('limit', CeaWriteJournalDefaultLimit)));
    if AToolName = 'cea.analyze_event_with_model' then
      Exit(ApprovalRequiredWithSurface('event_analysis_cloud', '{}'));
    { FR-071/074/079：开启或停止录像会驱动真实抓帧并写盘，锁定片段会改变
      保留策略——这三类必须由本地操作者当场确认。查询片段、把事件放进待办
      队列、查看队列都是本地只读或纯排队动作（队列自己绝不调用模型），
      MCP 可以直接执行。 }
    if AToolName = 'cea.start_event_recording' then
      Exit(ApprovalRequiredWithSurface('event_recording', '{}'));
    if AToolName = 'cea.stop_event_recording' then
      Exit(ApprovalRequiredWithSurface('event_recording', '{}'));
    if AToolName = 'cea.list_recording_segments' then
      Exit(FOwner.ListRecordingSegments);
    if AToolName = 'cea.lock_recording_segment' then
      Exit(ApprovalRequiredWithSurface('event_recording', '{}'));
    if AToolName = 'cea.queue_event_for_analysis' then
      Exit(FOwner.QueueEventForAnalysis(Obj.Get('event_id', '')));
    if AToolName = 'cea.peek_analysis_queue' then
      Exit(FOwner.PeekAnalysisQueue);
    { FR-052：证据查询只读，MCP 可以直接执行；新增证据必须来自真实采集或
      真实验证，因此没有「写证据」工具，操作者确认也只能本地发起。 }
    if AToolName = 'cea.list_field_evidence' then
      Exit(FOwner.ListFieldEvidence(Obj.Get('field_id', ''),
        Obj.Get('limit', CeaFieldEvidenceDefaultLimit)));
    if AToolName = 'cea.record_field_confirmation' then
      Exit(ApprovalRequiredWithSurface('field_evidence', '{}'));
    { FR-051：计划与收尾都是操作者的判断，MCP 只能读——替操作者声明
      「我预期看到 X」等于伪造验收标准。 }
    if AToolName = 'cea.plan_discovery_round' then
      Exit(ApprovalRequiredWithSurface('discovery_round', '{}'));
    if AToolName = 'cea.complete_discovery_round' then
      Exit(ApprovalRequiredWithSurface('discovery_round', '{}'));
    if AToolName = 'cea.abandon_discovery_round' then
      Exit(ApprovalRequiredWithSurface('discovery_round', '{}'));
    if AToolName = 'cea.list_discovery_rounds' then
      Exit(FOwner.ListDiscoveryRounds(
        Obj.Get('limit', CeaDiscoveryRoundDefaultLimit)));
    if AToolName = 'cea.get_current_discovery_round' then
      Exit(FOwner.CurrentDiscoveryRound);
    { FR-050：描述与接受都是操作者的意图表达。MCP 可以读目标，但不能
      替操作者声明「我要找这个」，也不能替他接受——意图只能由人给出。 }
    if AToolName = 'cea.propose_discovery_goal' then
      Exit(ApprovalRequiredWithSurface('discovery_goal', '{}'));
    if AToolName = 'cea.propose_discovery_goal_with_model' then
      Exit(ApprovalRequiredWithSurface('discovery_goal_model', '{}'));
    if AToolName = 'cea.accept_discovery_goal' then
      Exit(ApprovalRequiredWithSurface('discovery_goal', '{}'));
    if AToolName = 'cea.reject_discovery_goal' then
      Exit(ApprovalRequiredWithSurface('discovery_goal', '{}'));
    if AToolName = 'cea.list_discovery_goals' then
      Exit(FOwner.ListDiscoveryGoals(
        Obj.Get('limit', CeaDiscoveryGoalDefaultLimit)));
    if AToolName = 'cea.get_current_discovery_goal' then
      Exit(FOwner.CurrentDiscoveryGoal);
    if AToolName = 'cea.match_gcm_game' then
      Exit(FOwner.MatchGcmGame(Obj.Get('text', ''), 60));
    if AToolName = 'cea.search_gcm_games' then
      Exit(FOwner.SearchGcmGames(Obj.Get('text', '')));
    if AToolName = 'cea.scan_gcm_cheat_files' then
      Exit(FOwner.ScanGcmCheatFiles);
    if AToolName = 'cea.list_published_cheat_files' then
      Exit(FOwner.ListPublishedCheatFiles);
    if AToolName = 'cea.import_cheat_file' then
      Exit(ApprovalRequiredWithSurface('cheat_file_import', '{}'));
    if AToolName = 'cea.publish_cheat_file' then
      Exit(ApprovalRequiredWithSurface('cheat_file_publish', '{}'));
    if AToolName = 'cea.translate_cheat_descriptions' then
      Exit(ApprovalRequiredWithSurface('cheat_file_translate', '{}'));
    { 1D 增强：页面存储与切页是本地文件级操作，MCP 可直接执行；模型改写页面
      结构的提案只能创建，确认/拒绝仍归本地操作者（FR-025 / FR-043）。 }
    if AToolName = 'cea.save_ui_page' then
      Exit(FOwner.SaveUiPage(Obj.Get('page_id', ''), Obj.Get('title', ''),
        Obj.Get('schema_id', ''), Obj.Get('schema_json', '')));
    if AToolName = 'cea.list_ui_pages' then
      Exit(FOwner.ListUiPages);
    if AToolName = 'cea.get_ui_page' then
      Exit(FOwner.GetUiPage(Obj.Get('page_id', '')));
    if AToolName = 'cea.set_active_ui_page' then
      Exit(FOwner.SetActiveUiPage(Obj.Get('page_id', '')));
    if AToolName = 'cea.get_active_ui_page' then
      Exit(FOwner.GetActiveUiPage);
    if AToolName = 'cea.list_ui_schema_versions' then
      Exit(FOwner.ListUiSchemaVersions(Obj.Get('schema_id', '')));
    if AToolName = 'cea.restore_ui_schema_version' then
      Exit(FOwner.RestoreUiSchemaVersion(Obj.Get('schema_id', ''),
        Obj.Get('version', 0)));
    if AToolName = 'cea.set_secondary_screen_page' then
      Exit(FOwner.SetSecondaryScreenPage(Obj.Get('page_id', '')));
    if AToolName = 'cea.propose_ui_customization' then
      Exit(FOwner.ProposeUiCustomization(Obj.Get('instruction', '')));
    if AToolName = 'cea.confirm_ui_customization' then
      Exit(ApprovalRequiredWithSurface('ui_customization_confirm', '{}'));
    if AToolName = 'cea.reject_ui_customization' then
      Exit(FOwner.RejectUiCustomization(Obj.Get('proposal_id', '')));
  finally
    Data.Free;
  end;
  if FDelegate = nil then
    Exit(TCEAResult.Error(rcNotImplemented,
      'mcp_tool_not_implemented', '{}'));
  Result := FDelegate.DispatchTool(AToolName, AArgumentsJson);
end;

constructor TCEAStandaloneRuntime.Create(const ADatabasePath: string;
  const AMCPPreferredPort: Word);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FMCPPreferredPort := AMCPPreferredPort;
  FUiProposalIds := TStringList.Create;
  FUiProposalSchemas := TStringList.Create;
  FSecondaryScreenPageId := '';
end;

destructor TCEAStandaloneRuntime.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TCEAStandaloneRuntime.Start: TCEAResult;
var
  DataDirectory: string;
  SelectedPort: Word;
begin
  if FStarted then
    Exit(TCEAResult.Error(rcConflict,
      'standalone_runtime_already_started', '{}'));
  Result := StartWin32Engine;
  if Result.Failed then
    Exit;
  try
    FHasher := TCEAWindowsSha256.Create;
    FSaveReader := TCEAWin32SaveReader.Create;
    FSaveDiscoveryService := TCEASaveDiscoveryService.Create;
    FDiscoveryEffectScope := TStringList.Create;
    FRevokedDiscoveryScopes := TStringList.Create;
    FFixtureSaveCodec := TCEAFixtureSaveCodec.Create;
    FClock := TCEASystemClock.Create;
    FSecretStore := TCEASecretStore.Create;
    FLLMTransport := TCEAWinHttpTransport.Create(4 * 1024 * 1024);
    if FDatabasePath = '' then
    begin
      if CeaDatabasePathOverride <> '' then
        FDatabasePath := CeaDatabasePathOverride
      else
      begin
        DataDirectory := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) +
          'CheatEngineAgent';
        if not ForceDirectories(DataDirectory) then
          raise Exception.Create('Could not create application data directory');
        FDatabasePath := IncludeTrailingPathDelimiter(DataDirectory) +
          'governance.sqlite3';
      end;
    end;
    FCTParser := TCTParser.Create(FHasher, 16 * 1024 * 1024);
    FCTCatalog := TCTCatalog.Create(FDatabasePath);
    Result := FCTCatalog.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FreeAndNil(FCTCatalog);
    FStore := TCEASqliteStore.Create(FDatabasePath);
    Result := FStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    Result := FStore.ReconcileExecutingEffects(FClock.UtcNowIso8601);
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FProfileStore := TCEAProfileStore.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'profiles.sqlite3');
    Result := FProfileStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FProfileService := TCEAProfileService.Create(FProfileStore);
    // GCM 目录与 CE 文件库：纯本地读取，不联网、不执行下载内容
    FGcmCatalog := TCEAGcmCatalog.Create;
    FGcmCheatLibrary := TCEAGcmCheatLibrary.Create(
      DefaultGcmTrainersDirectory);
    FGcmCheatPublisher := TCEAGcmCheatPublisher.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      CeaCheatFileLibraryDirectoryName, FHasher);
    FMappingService := TCEAMappingService.Create;
    FUiRuntime := TCEAUiSchemaRuntime.Create;
    FUiLayoutStore := TCEAUiLayoutStore.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'ui-layout.sqlite3');
    Result := FUiLayoutStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FDisplayEnumerator := TCEAWin32DisplayEnumerator.Create;
    FEventStore := TCEAEventRepository.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'events.sqlite3');
    Result := FEventStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FEventService := TCEAEventService.Create(DefaultEventServiceConfig);
    FEventService.SetEventStore(FEventStore);
    // 重启后恢复历史事件，并从已落盘的最大事件序号继续（不覆盖历史）
    Result := FEventService.ReloadFromStore;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    // PRD 6.9：事件分析服务无状态、无外部依赖，本地分析恒可用。
    FEventAnalysisService := TCEAEventAnalysisService.Create;
    // FR-077 按需唤醒：队列先装配好，录像与模型都不参与排队决策。
    FWakeQueue := TCEAEventWakeQueue.Create(32);
    FEventService.SetWakePort(FWakeQueue);
    // 录像证据层（FR-070/079）：定位器与缓存常备，实际抓屏要等操作者
    // 调 StartEventRecording —— 默认不录，避免无授权的持续截屏。
    FWindowLocator := TCEAWin32WindowLocator.Create;
    FRecordingCache := TCEARecordingService.Create(DefaultRecordingPolicy);
    // FR-046 操作历史：玩家写入走命令总线，不产生 Effect/Receipt/Proof，
    // 因此必须有一条独立的写入账本，否则「谁在什么时候把哪个值改成了
    // 什么、结果如何」在治理账本里完全看不到。
    FWriteJournal := TCEAWriteJournal.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'write-journal.sqlite3');
    Result := FWriteJournal.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FWriteSequence := 0;
    // FR-052 证据记录：与写入账本分开，因为证据描述的是「观察到了什么」，
    // 账本描述的是「下过什么命令」。两者混在一张表里会让「值没变」和
    // 「命令没发出去」无法区分。
    FFieldEvidenceStore := TCEAFieldEvidenceStore.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'field-evidence.sqlite3');
    Result := FFieldEvidenceStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FFieldEvidenceService := TCEAFieldEvidenceService.Create(FHasher,
      FFieldEvidenceStore);
    // FR-051 分轮验证：只存内存。轮次是「这次探索想干什么」的计划，
    // 持久事实已在证据表与写入账本里；存旧计划只会让下一轮误以为
    // 还有没交代完的意图。
    FDiscoveryRounds := TCEADiscoveryRoundService.Create;
    // FR-050 目标描述：同样只存内存。没有证据的目标是悬空意图，
    // 落盘会让下一次会话把旧愿望当成还没做完的义务。
    FDiscoveryGoals := TCEADiscoveryGoalService.Create;
    // FR-054 写入隔离：会话启动时写入是关着的。默认只读不是「还没设置」，
    // 而是一个明确的初始状态——操作者必须先说明为什么这次允许写入，
    // 否则每一次写入都只能靠调用方记得确认。
    FWriteAccess := DefaultWriteAccess;
    // 多页面 + 版本历史（FR-026/FR-033）：页面与 schema 版本同库，
    // 历史 append-only，回退只新增版本、不销毁旧版本。
    FUiPageStore := TCEAUiPageStore.Create(
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'ui-pages.sqlite3');
    Result := FUiPageStore.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    // 自然语言定制（FR-025）：provider 在 ConfigureLLM 之后才存在，
    // 因此服务在这里先建，provider 每次调用时再解析。
    FUiCustomizationService := TCEAUiCustomizationService.Create(nil);
    FCTCatalog := TCTCatalog.Create(FDatabasePath);
    Result := FCTCatalog.Initialize;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FApprovals := TCEALocalApprovalPort.Create(FStore, FClock, FHasher);
    FPolicy := TCEAPolicyModel.Create;
    FLeases := TCEALeaseService.Create(FStore, FClock);
    FEffects := TCEAEffectService.Create(FStore, FClock, FApprovals, FHasher);
    FEffectBackend := TCEAWin32EffectBackend.Create(4096);
    FSaveEffects := TCEAWin32SaveEffectPort.Create(FSaveReader, FHasher,
      IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      'backups', FFixtureSaveCodec);
    FFreezeService := TCEAFreezeService.Create(FStore, FClock, FHasher,
      FEffects, FLeases, FEffectBackend);
    FCapabilityPort := TCEAWin32GovernedCapabilityPort.Create(
      EngineRuntime, FEffectBackend, FHasher, FSaveEffects);
    FGateway := TCEAGovernanceGateway.Create(FPolicy, FLeases, FEffects,
      FCapabilityPort);
    FSaveService := TCEASaveService.Create(FSaveReader, FStore, FClock,
      FHasher, FGateway, FFixtureSaveCodec);
    Result := ReconcileUnsettledSaveEffects;
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FDispatcher := TCEAStandaloneMCPDispatcher.Create(Self,
      TCEAMCPRuntimeDispatcher.Create(EngineRuntime, 60000));
    FRegistry := TMCPToolRegistry.Create(FDispatcher);
    RegisterDefaultFoundationTools(FRegistry);
    FProtocol := TMCPProtocol.Create(FRegistry);
    FMCPToken := ResolveMCPToken('CEA_MCP_TOKEN');
    FMCPServer := TCEAMCPHttpServer.Create(FProtocol, FMCPToken);
    Result := FMCPServer.Start(FMCPPreferredPort, 1, SelectedPort);
    if Result.Failed then
      raise Exception.Create(Result.StableCode);
    FMCPEndpoint := FMCPServer.Endpoint;
    FStarted := True;
    Result := TCEAResult.Ok(
      '{"started":true,"mode":"standalone_governed",' +
      '"mcp_endpoint":"' + FMCPEndpoint + '"}');
  except
    on E: Exception do
    begin
      Stop;
      Result := TCEAResult.Error(rcInternalError,
        'standalone_runtime_start_failed', '{"detail":"' +
        JsonEscapeText(E.Message) + '"}');
    end;
  end;
end;

procedure TCEAStandaloneRuntime.Stop;
var
  I: Integer;
begin
  FLocalScanId := '';
  FLocalScanScopeId := '';
  SetLength(FLocalScanRanges, 0);
  FLocalScanScopePartialReason := '';
  FLocalScanIsAob := False;
  FLocalScanAobPattern := '';
  if Assigned(FFreezeService) and FFreezeService.Active then
    FFreezeService.Stop('application_stop');
  { Discovery authority is deliberately session-only.  Close every still
    planned Effect while the store and approval service are available, so a
    restart cannot revive a plan whose directory authority disappeared. }
  if Assigned(FDiscoveryEffectScope) and Assigned(FStore) and
     Assigned(FApprovals) then
    for I := 0 to FDiscoveryEffectScope.Count - 1 do
      RejectDiscoveryPlannedEffects(
        FDiscoveryEffectScope.ValueFromIndex[I]);
  FStarted := False;
  FreeAndNil(FMCPServer);
  FMCPToken := StringOfChar(#0, Length(FMCPToken));
  FMCPToken := '';
  FMCPEndpoint := '';
  FreeAndNil(FProtocol);
  FreeAndNil(FRegistry);
  FDispatcher := nil;
  FreeAndNil(FGateway);
  FreeAndNil(FSaveService);
  FreeAndNil(FSaveDiscoveryService);
  FreeAndNil(FDiscoveryEffectScope);
  FreeAndNil(FRevokedDiscoveryScopes);
  FSelectedDiscoveryScopeId := '';
  FSelectedDiscoverySnapshotId := '';
  FRevokedDiscoverySnapshotId := '';
  FreeAndNil(FSaveReader);
  FreeAndNil(FFixtureSaveCodec);
  FreeAndNil(FSaveEffects);
  FillChar(FSelectedSaveSnapshot, SizeOf(FSelectedSaveSnapshot), 0);
  FreeAndNil(FCapabilityPort);
  FreeAndNil(FFreezeService);
  FreeAndNil(FEffectBackend);
  FreeAndNil(FEffects);
  FreeAndNil(FLeases);
  FreeAndNil(FPolicy);
  FreeAndNil(FApprovals);
  FreeAndNil(FCTCatalog);
  FreeAndNil(FCTParser);
  FreeAndNil(FProfileService);
  FreeAndNil(FProfileStore);
  FreeAndNil(FGcmCheatPublisher);
  FreeAndNil(FGcmCheatLibrary);
  FreeAndNil(FGcmCatalog);
  FreeAndNil(FCaptureService);
  FCapturePid := 0;
  FCaptureIdentityId := '';
  FCaptureEpoch := 0;
  FreeAndNil(FSecondaryScreen);
  FSecondaryScreenPort := 0;
  FSecondaryScreenPageId := '';
  FreeAndNil(FUiCustomizationService);
  FreeAndNil(FUiPageStore);
  FUiProposalIds.Clear;
  FUiProposalSchemas.Clear;
  FreeAndNil(FEventAnalysisService);
  FreeAndNil(FDiscoveryRounds);
  FreeAndNil(FDiscoveryGoals);
  FreeAndNil(FFieldEvidenceService);
  FreeAndNil(FFieldEvidenceStore);
  FreeAndNil(FWriteJournal);
  // 录像层先拆：事件服务仍持有 recorder 引用，必须先解除再释放捕获器。
  StopEventRecording;
  FreeAndNil(FRecordingCache);
  FreeAndNil(FWindowLocator);
  FreeAndNil(FWakeQueue);
  FreeAndNil(FEventService);
  FreeAndNil(FEventStore);
  FreeAndNil(FDisplayEnumerator);
  FreeAndNil(FUiLayoutStore);
  FreeAndNil(FUiRuntime);
  FreeAndNil(FMappingService);
  FreeAndNil(FGameModel);
  FreeAndNil(FLLMProvider);
  FreeAndNil(FLLMTransport);
  FreeAndNil(FSecretStore);
  FreeAndNil(FStore);
  FreeAndNil(FClock);
  FreeAndNil(FHasher);
  StopWin32Engine;
end;

procedure TCEAStandaloneRuntime.RefreshLocalScanAttachment;
begin
  if (FLocalScanId <> '') and Assigned(EngineRuntime) and
     (FLocalScanAttachmentSerial <>
       EngineRuntime.Processes.AttachmentSerial) then
  begin
    FLocalScanId := '';
    FLocalScanScopeId := '';
    SetLength(FLocalScanRanges, 0);
    FLocalScanScopePartialReason := '';
    FLocalScanIsAob := False;
    FLocalScanAobPattern := '';
  end;
end;

function TCEAStandaloneRuntime.PumpCommands(
  const AMaxItems: Cardinal): Cardinal;
begin
  if FStarted and Assigned(EngineRuntime) then
  begin
    Result := EngineRuntime.PumpCommands(AMaxItems);
    if Assigned(FFreezeService) and FFreezeService.Active and
       (GetTickCount64 >= FFreezeNextTick) then
    begin
      TickFreeze;
      if FFreezeService.Active then
        FFreezeNextTick := GetTickCount64 + FFreezeService.IntervalMs;
    end;
  end
  else
    Result := 0;
end;

function TCEAStandaloneRuntime.HandleMCP(
  const ARequestJson: string): string;
begin
  if not FStarted or not Assigned(FProtocol) then
    Exit('{"jsonrpc":"2.0","id":null,"error":{' +
      '"code":-32603,"message":"Runtime not started"}}');
  Result := FProtocol.HandleJsonRpc(ARequestJson);
end;

function TCEAStandaloneRuntime.AttachAuthorizedOffline(
  const ATaskId: string; const APid: Cardinal;
  out AIdentity: TCEProcessIdentity): TCEAResult;
var
  Request: TCEAttachRequest;
begin
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  if not FStarted or not Assigned(EngineRuntime) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  FillChar(Request, SizeOf(Request), 0);
  Request.TaskId := ATaskId;
  Request.LeaseId := 'attach-local-' + IntToStr(APid);
  Request.Pid := APid;
  Request.OperatorAttestsAuthorizedDebugging := True;
  Result := EngineRuntime.Processes.Attach(Request,
    tcSinglePlayerOffline, AIdentity);
end;

function TCEAStandaloneRuntime.AuthorizeLocalValueScanScope(
  const AStartHex: string; const ARangeBytes,
  AMaxResults: Cardinal): TCEAResult;
var
  Identity: TCEProcessIdentity;
  StartAddress: QWord;
  ScopeId: string;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  if (Copy(AStartHex, 1, 2) <> '0x') or
     not TryStrToQWord('$' + Copy(AStartHex, 3, MaxInt), StartAddress) or
     (StartAddress = 0) or
     (ARangeBytes = 0) or
     (QWord(ARangeBytes) > QWord(512) * 1024 * 1024) or
     (AMaxResults = 0) or (AMaxResults > 10000) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'local_scan_scope_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := EngineRuntime.Scanner.AuthorizeLocalScope(
    Identity, StartAddress, ARangeBytes, ARangeBytes,
    AMaxResults, ScopeId);
end;

function TCEAStandaloneRuntime.RevokeLocalValueScanScope(
  const AScopeId: string): TCEAResult;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  Result := EngineRuntime.Scanner.RevokeLocalScope(AScopeId);
end;

function TCEAStandaloneRuntime.StartLocalValueScan(
  const AStartHex: string; const ARangeBytes: Cardinal;
  const AValueType, AValueText: string;
  const AMaxResults: Cardinal): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  StartAddress: QWord;
  ScopeId: string;
  RequestObject, BudgetObject, RangeObject: TJSONObject;
  Ranges: TJSONArray;
  ResultData: TJSONData;
begin
  if not FStarted or (FGateway = nil) or
     (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if FLocalScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning,
      'local_scan_session_active', '{}'));
  if (Copy(AStartHex, 1, 2) <> '0x') or
     not TryStrToQWord('$' + Copy(AStartHex, 3, MaxInt), StartAddress) or
     (AValueType = '') or (AValueText = '') or
     (ARangeBytes = 0) or
     (QWord(ARangeBytes) > QWord(512) * 1024 * 1024) or
     (AMaxResults = 0) or (AMaxResults > 10000) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'local_value_scan_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := EngineRuntime.Scanner.AuthorizeLocalScope(
    Identity, StartAddress, ARangeBytes, ARangeBytes, AMaxResults, ScopeId);
  if Result.Failed then Exit;

  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := 'task-local-value-scan';
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + Copy(FHasher.HashUtf8(ScopeId), 8, 32);
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_scan_start';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := FClock.UtcAfterMinutes(5);
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := ARangeBytes;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', Context.TaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('scan_kind', 'value');
    RequestObject.Add('value_type', AValueType);
    RequestObject.Add('value', AValueText);
    RequestObject.Add('scope_id', ScopeId);
    RequestObject.Add('epoch', Int64(Identity.Epoch));
    BudgetObject := TJSONObject.Create;
    BudgetObject.Add('max_bytes', Int64(ARangeBytes));
    BudgetObject.Add('max_results', Int64(AMaxResults));
    BudgetObject.Add('max_duration_ms', 30000);
    BudgetObject.Add('max_regions', 4096);
    RequestObject.Add('budget', BudgetObject);
    Ranges := TJSONArray.Create;
    RangeObject := TJSONObject.Create;
    RangeObject.Add('start', LowerCase(AStartHex));
    RangeObject.Add('size', Int64(ARangeBytes));
    Ranges.Add(RangeObject);
    RequestObject.Add('ranges', Ranges);
    Result := FGateway.InvokeRead('memory_scan_start', Context,
      RequestObject.AsJSON);
    if not Result.Failed then
    begin
      ResultData := GetJSON(Result.DataJson);
      try
        FLocalScanId := TJSONObject(ResultData).Get('scan_id', '');
      finally
        ResultData.Free;
      end;
      if FLocalScanId = '' then
        Exit(TCEAResult.Error(rcInternalError,
          'local_scan_backend_missing_id', '{}'));
      FLocalScanScopeId := ScopeId;
      FLocalScanAttachmentSerial :=
        EngineRuntime.Processes.AttachmentSerial;
      FLocalScanIdentityId := Identity.Id;
      FLocalScanEpoch := Identity.Epoch;
      FLocalScanStartHex := LowerCase(AStartHex);
      FLocalScanRangeBytes := ARangeBytes;
      FLocalScanMaxResults := AMaxResults;
      FLocalScanValueType := AValueType;
      SetLength(FLocalScanRanges, 1);
      FLocalScanRanges[0].StartAddress := StartAddress;
      FLocalScanRanges[0].Size := ARangeBytes;
      FLocalScanScopePartialReason := '';
      FLocalScanIsAob := False;
      FLocalScanAobPattern := '';
    end;
  finally
    RequestObject.Free;
  end;
end;

function TCEAStandaloneRuntime.StartProcessValueScan(
  const ARegionKinds: string; const AMaxBytes: Cardinal;
  const AValueType, AValueText: string;
  const AMaxResults: Cardinal): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  ScopeId, PartialReason: string;
  PlannedRanges: TCEScanRangeArray;
  RequestObject, BudgetObject, RangeObject: TJSONObject;
  Ranges: TJSONArray;
  ResultData: TJSONData;
  I: Integer;
begin
  if not FStarted or (FGateway = nil) or
     (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if FLocalScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning,
      'local_scan_session_active', '{}'));
  if (Trim(ARegionKinds) = '') or (Trim(AValueType) = '') or
     (Trim(AValueText) = '') or (AMaxBytes = 0) or
     (QWord(AMaxBytes) > QWord(512) * 1024 * 1024) or
     (AMaxResults = 0) or (AMaxResults > 10000) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'local_process_scan_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := EngineRuntime.Scanner.AuthorizeProcessScope(Identity,
    Trim(ARegionKinds), AMaxBytes, AMaxResults, 4096, PlannedRanges,
    ScopeId, PartialReason);
  if Result.Failed then Exit;

  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := 'task-local-process-value-scan';
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + Copy(FHasher.HashUtf8(ScopeId), 8, 32);
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_scan_start';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := FClock.UtcAfterMinutes(5);
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := AMaxBytes;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', Context.TaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('scan_kind', 'value');
    RequestObject.Add('value_type', Trim(AValueType));
    RequestObject.Add('value', Trim(AValueText));
    RequestObject.Add('scope_id', ScopeId);
    RequestObject.Add('epoch', Int64(Identity.Epoch));
    BudgetObject := TJSONObject.Create;
    BudgetObject.Add('max_bytes', Int64(AMaxBytes));
    BudgetObject.Add('max_results', Int64(AMaxResults));
    BudgetObject.Add('max_duration_ms', 30000);
    BudgetObject.Add('max_regions', 4096);
    RequestObject.Add('budget', BudgetObject);
    Ranges := TJSONArray.Create;
    for I := 0 to High(PlannedRanges) do
    begin
      RangeObject := TJSONObject.Create;
      RangeObject.Add('start', '0x' +
        IntToHex(PlannedRanges[I].StartAddress, 16));
      RangeObject.Add('size', Int64(PlannedRanges[I].Size));
      Ranges.Add(RangeObject);
    end;
    RequestObject.Add('ranges', Ranges);
    Result := FGateway.InvokeRead('memory_scan_start', Context,
      RequestObject.AsJSON);
    if not Result.Failed then
    begin
      ResultData := GetJSON(Result.DataJson);
      try
        FLocalScanId := TJSONObject(ResultData).Get('scan_id', '');
      finally
        ResultData.Free;
      end;
      if FLocalScanId = '' then
        Exit(TCEAResult.Error(rcInternalError,
          'local_scan_backend_missing_id', '{}'));
      FLocalScanScopeId := ScopeId;
      FLocalScanAttachmentSerial :=
        EngineRuntime.Processes.AttachmentSerial;
      FLocalScanIdentityId := Identity.Id;
      FLocalScanEpoch := Identity.Epoch;
      FLocalScanStartHex := '';
      FLocalScanRangeBytes := AMaxBytes;
      FLocalScanMaxResults := AMaxResults;
      FLocalScanValueType := Trim(AValueType);
      FLocalScanRanges := Copy(PlannedRanges, 0, Length(PlannedRanges));
      FLocalScanScopePartialReason := PartialReason;
      FLocalScanIsAob := False;
      FLocalScanAobPattern := '';
    end;
  finally
    RequestObject.Free;
  end;
end;

function TCEAStandaloneRuntime.StartAobScan(const AModuleName,
  AAobPattern: string; const AMaxBytes: Cardinal;
  const AMaxResults: Cardinal): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  Reader: TCEAWin32PointerReader;
  ModuleResult: TCEAResult;
  ModuleData: TJSONData;
  ModuleBase: QWord;
  ModuleSize, ScanBytes: QWord;
  RequestObject, BudgetObject, RangeObject: TJSONObject;
  Ranges: TJSONArray;
  ResultData: TJSONData;
  ModuleJson: string;
begin
  if not FStarted or (FGateway = nil) or
     (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if FLocalScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning,
      'local_scan_session_active', '{}'));
  if (Trim(AModuleName) = '') or (Trim(AAobPattern) = '') or
     (AMaxBytes = 0) or
     (QWord(AMaxBytes) > QWord(512) * 1024 * 1024) or
     (AMaxResults = 0) or (AMaxResults > 10000) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'aob_scan_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;

  // 签名必须在某个具体模块里找：模块外扫描等于全地址空间扫描，
  // 既超出预算也无法在重启后重放，所以先用模块基址把范围钉住。
  Reader := TCEAWin32PointerReader.Create(Identity.Pid, 64);
  try
    ModuleResult := Reader.ModuleBaseAddress(Trim(AModuleName), ModuleBase);
    if ModuleResult.Failed then
      Exit(TCEAResult.Error(ModuleResult.Code, ModuleResult.StableCode,
        ModuleResult.DataJson));
    ModuleJson := ModuleResult.DataJson;
  finally
    Reader.Free;
  end;
  ModuleSize := 0;
  ModuleData := GetJSON(ModuleJson);
  try
    ModuleSize := QWord(TJSONObject(ModuleData).Get('size', Int64(0)));
  finally
    ModuleData.Free;
  end;
  if ModuleSize = 0 then
    Exit(TCEAResult.Error(rcInternalError, 'aob_scan_module_size_missing',
      '{}'));
  // 预算上限可能小于模块大小：截断到预算，扫描报告里会带 complete=false。
  if ModuleSize > QWord(AMaxBytes) then
    ScanBytes := QWord(AMaxBytes)
  else
    ScanBytes := ModuleSize;

  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := 'task-local-aob-scan';
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + Copy(FHasher.HashUtf8(Context.TaskId + #0 +
    Identity.Id + #0 + Trim(AAobPattern)), 8, 32);
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_scan_start';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := FClock.UtcAfterMinutes(5);
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := ScanBytes;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', Context.TaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('scan_kind', 'aob');
    RequestObject.Add('aob_pattern', Trim(AAobPattern));
    RequestObject.Add('epoch', Int64(Identity.Epoch));
    BudgetObject := TJSONObject.Create;
    BudgetObject.Add('max_bytes', Int64(ScanBytes));
    BudgetObject.Add('max_results', Int64(AMaxResults));
    BudgetObject.Add('max_duration_ms', 30000);
    BudgetObject.Add('max_regions', 1);
    RequestObject.Add('budget', BudgetObject);
    Ranges := TJSONArray.Create;
    RangeObject := TJSONObject.Create;
    RangeObject.Add('start', '0x' + IntToHex(ModuleBase, 16));
    RangeObject.Add('size', Int64(ScanBytes));
    Ranges.Add(RangeObject);
    RequestObject.Add('ranges', Ranges);
    Result := FGateway.InvokeRead('memory_scan_start', Context,
      RequestObject.AsJSON);
    if not Result.Failed then
    begin
      ResultData := GetJSON(Result.DataJson);
      try
        FLocalScanId := TJSONObject(ResultData).Get('scan_id', '');
      finally
        ResultData.Free;
      end;
      if FLocalScanId = '' then
        Exit(TCEAResult.Error(rcInternalError,
          'local_scan_backend_missing_id', '{}'));
      FLocalScanScopeId := '';
      FLocalScanAttachmentSerial :=
        EngineRuntime.Processes.AttachmentSerial;
      FLocalScanIdentityId := Identity.Id;
      FLocalScanEpoch := Identity.Epoch;
      FLocalScanStartHex := '0x' + IntToHex(ModuleBase, 16);
      FLocalScanRangeBytes := Cardinal(ScanBytes);
      FLocalScanMaxResults := AMaxResults;
      FLocalScanValueType := '';
      SetLength(FLocalScanRanges, 1);
      FLocalScanRanges[0].StartAddress := ModuleBase;
      FLocalScanRanges[0].Size := ScanBytes;
      FLocalScanScopePartialReason := '';
      FLocalScanIsAob := True;
      FLocalScanAobPattern := Trim(AAobPattern);
    end;
  finally
    RequestObject.Free;
  end;
end;

function TCEAStandaloneRuntime.JudgeAobUniqueness(
  const AScanId: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
  StatusResult: TCEAResult;
  StatusData: TJSONData;
  StatusObject: TJSONObject;
  MatchCount: Int64;
  State, Verdict, ModuleText, PatternText: string;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // 这里不要求 owner thread：判定只读扫描状态，后端的状态读取本身由
  // 临界区保护，故 MCP 线程可以直接问判定结果（发起扫描仍须本地授权）。
  if Trim(AScanId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'scan_id_required', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  StatusResult := EngineRuntime.Scanner.GetStatus(AScanId, Identity);
  if StatusResult.Failed then
    Exit(TCEAResult.Error(StatusResult.Code, StatusResult.StableCode,
      StatusResult.DataJson));
  MatchCount := 0;
  State := '';
  StatusData := GetJSON(StatusResult.DataJson);
  try
    StatusObject := TJSONObject(StatusData);
    MatchCount := StatusObject.Get('match_count', Int64(0));
    State := StatusObject.Get('state', '');
  finally
    StatusData.Free;
  end;
  // 只有唯一命中才能当写入锚点：零命中说明签名失效，多命中说明签名
  // 太短或有多个副本，任何一种都不足以支撑「写这里就是改那个字段」。
  if MatchCount = 1 then
    Verdict := 'unique'
  else if MatchCount = 0 then
    Verdict := 'not_found'
  else
    Verdict := 'ambiguous';
  // 本地会话知道签名来自哪个模块；MCP 发起的会话只报判定结果。
  ModuleText := '';
  PatternText := '';
  if AScanId = FLocalScanId then
  begin
    ModuleText := FLocalScanStartHex;
    PatternText := FLocalScanAobPattern;
  end;
  Result := TCEAResult.Ok('{"scan_id":"' + JsonEscapeText(AScanId) +
    '","state":"' + JsonEscapeText(State) +
    '","match_count":' + IntToStr(MatchCount) +
    ',"unique":' + JsonBool(MatchCount = 1) +
    ',"verdict":"' + Verdict +
    '","module":"' + JsonEscapeText(ModuleText) +
    '","pattern":"' + JsonEscapeText(PatternText) +
    '","writable_anchor":' + JsonBool(MatchCount = 1) + '}');
end;

function TCEAStandaloneRuntime.GetAobScanUniqueness(
  const AScanId: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if (AScanId = '') or (AScanId <> FLocalScanId) then
    Exit(TCEAResult.Error(rcConflict,
      'local_scan_session_invalid', '{}'));
  if not FLocalScanIsAob then
    Exit(TCEAResult.Error(rcInvalidArgument, 'aob_scan_session_required',
      '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  if (Identity.Id <> FLocalScanIdentityId) or
     (Identity.Epoch <> FLocalScanEpoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'local_scan_target_changed', '{}'));
  Result := JudgeAobUniqueness(AScanId);
end;

function TCEAStandaloneRuntime.GetLocalValueScanStatus(
  const AScanId: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if (AScanId = '') or (AScanId <> FLocalScanId) then
    Exit(TCEAResult.Error(rcConflict,
      'local_scan_session_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  if (Identity.Id <> FLocalScanIdentityId) or
     (Identity.Epoch <> FLocalScanEpoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'local_scan_target_changed', '{}'));
  Result := EngineRuntime.Scanner.GetStatus(AScanId, Identity);
end;

function TCEAStandaloneRuntime.RefineLocalValueScan(
  const AScanId, AValueText: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  LeaseGuid: TGUID;
  RequestObject, BudgetObject, RangeObject: TJSONObject;
  Ranges: TJSONArray;
  I: Integer;
begin
  if not FStarted or (FGateway = nil) or
     (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  if (AScanId = '') or (AScanId <> FLocalScanId) or
     (Trim(AValueText) = '') then
    Exit(TCEAResult.Error(rcConflict,
      'local_scan_session_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  if (Identity.Id <> FLocalScanIdentityId) or
     (Identity.Epoch <> FLocalScanEpoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'local_scan_target_changed', '{}'));
  if CreateGUID(LeaseGuid) <> 0 then
    Exit(TCEAResult.Error(rcInternalError,
      'local_scan_lease_id_failed', '{}'));
  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := 'task-local-value-scan';
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + GUIDToString(LeaseGuid);
  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_scan_refine';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := FClock.UtcAfterMinutes(5);
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := FLocalScanRangeBytes;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', Context.TaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('scan_id', AScanId);
    RequestObject.Add('scan_kind', 'value');
    RequestObject.Add('value_type', FLocalScanValueType);
    RequestObject.Add('value', Trim(AValueText));
    RequestObject.Add('scope_id', FLocalScanScopeId);
    RequestObject.Add('epoch', Int64(Identity.Epoch));
    BudgetObject := TJSONObject.Create;
    BudgetObject.Add('max_bytes', Int64(FLocalScanRangeBytes));
    BudgetObject.Add('max_results', Int64(FLocalScanMaxResults));
    BudgetObject.Add('max_duration_ms', 30000);
    BudgetObject.Add('max_regions', 4096);
    RequestObject.Add('budget', BudgetObject);
    Ranges := TJSONArray.Create;
    for I := 0 to High(FLocalScanRanges) do
    begin
      RangeObject := TJSONObject.Create;
      RangeObject.Add('start', '0x' +
        IntToHex(FLocalScanRanges[I].StartAddress, 16));
      RangeObject.Add('size', Int64(FLocalScanRanges[I].Size));
      Ranges.Add(RangeObject);
    end;
    RequestObject.Add('ranges', Ranges);
    Result := FGateway.InvokeRead('memory_scan_refine', Context,
      RequestObject.AsJSON);
  finally
    RequestObject.Free;
  end;
end;

function TCEAStandaloneRuntime.CancelLocalValueScan(
  const AScanId: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (EngineRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'local_scan_owner_thread_required', '{}'));
  RefreshLocalScanAttachment;
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := EngineRuntime.Scanner.CancelScan(AScanId, Identity);
  if not Result.Failed then
  begin
    FLocalScanId := '';
    FLocalScanScopeId := '';
    SetLength(FLocalScanRanges, 0);
    FLocalScanScopePartialReason := '';
    FLocalScanIsAob := False;
    FLocalScanAobPattern := '';
  end;
end;

function TCEAStandaloneRuntime.PlanMemoryWrite(const ATaskId,
  AAddressHex, AExpectedHex, AReplacementHex: string;
  out AEffect: TCEAEffect): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  RequestObject: TJSONObject;
  ResultData: TJSONData;
  RequestJson, IdempotencyKey, PlannedEffectId: string;
begin
  FillChar(AEffect, SizeOf(AEffect), 0);
  if not FStarted or (FGateway = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if (ATaskId = '') or (AAddressHex = '') or (AExpectedHex = '') or
     Odd(Length(AExpectedHex)) or
     (Length(AExpectedHex) <> Length(AReplacementHex)) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_write_plan_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;

  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := ATaskId;
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + Copy(FHasher.HashUtf8(ATaskId + #0 +
    Identity.Id + #0 + AAddressHex + #0 + AReplacementHex), 8, 32);

  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_write';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := FClock.UtcAfterMinutes(5);
  Lease.RemainingCalls := 1;
  Lease.RemainingBytes := Length(AReplacementHex) div 2;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', ATaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('target_pid', Int64(Identity.Pid));
    RequestObject.Add('target_started_at', Identity.StartedAt);
    RequestObject.Add('target_executable_sha256', Identity.ExecutableSha256);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('address', LowerCase(AAddressHex));
    RequestObject.Add('expected_original_bytes', LowerCase(AExpectedHex));
    RequestObject.Add('replacement_bytes', LowerCase(AReplacementHex));
    RequestJson := RequestObject.AsJSON;
  finally
    RequestObject.Free;
  end;
  IdempotencyKey := 'write-' + Copy(FHasher.HashUtf8(RequestJson), 8, 32);
  Result := FGateway.RequestEffect('memory_write', Context, RequestJson,
    IdempotencyKey);
  if Result.Code = rcApprovalRequired then
  begin
    ResultData := nil;
    try
      try
        ResultData := GetJSON(Result.DataJson);
      except
        Exit(TCEAResult.Error(rcInternalError,
          'planned_effect_reference_invalid', '{}'));
      end;
      if (ResultData = nil) or (ResultData.JSONType <> jtObject) then
        Exit(TCEAResult.Error(rcInternalError,
          'planned_effect_reference_invalid', '{}'));
      PlannedEffectId := TJSONObject(ResultData).Get('effect_id', '');
      if PlannedEffectId = '' then
        Exit(TCEAResult.Error(rcInternalError,
          'planned_effect_reference_missing', '{}'));
    finally
      ResultData.Free;
    end;
    if FStore.LoadEffect(PlannedEffectId, AEffect).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'planned_effect_load_failed', '{}'));
  end;
end;

function TCEAStandaloneRuntime.ApproveAndExecute(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
begin
  Result := LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  Result := CheckSaveDiscoveryAuthority(AEffectId, '');
  if Result.Failed then Exit;
  if Effect.State in [esApplied, esUnknown] then
    Exit(FGateway.ExecuteApprovedEffect(AEffectId));
  if Effect.ResourceKind = rkSaveFile then
  begin
    Result := CheckSaveTargetUnsettled(Effect.ResourceIdentityId,
      SaveEffectSourcePath(Effect.RequestJson), Effect.Id);
    if Result.Failed then Exit;
  end;
  Result := FApprovals.Approve(Effect, FClock.UtcAfterMinutes(1));
  if Result.Failed then Exit;
  Result := FGateway.ExecuteApprovedEffect(AEffectId);
end;

function TCEAStandaloneRuntime.PlanMemoryFreeze(const ATaskId,
  AAddressHex, AExpectedHex, AReplacementHex: string;
  const AIntervalMs, AMaxWrites, ADurationSeconds: Cardinal;
  out AEffect: TCEAEffect): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  RequestObject: TJSONObject;
  ResultData: TJSONData;
  RequestJson, IdempotencyKey, PlannedEffectId, ExpiresAt: string;
  ByteCount: QWord;
begin
  FillChar(AEffect, SizeOf(AEffect), 0);
  if not FStarted or (FGateway = nil) or (FFreezeService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FFreezeService.Active then
    Exit(TCEAResult.Error(rcConflict, 'freeze_session_running', '{}'));
  if (ATaskId = '') or (AAddressHex = '') or (AExpectedHex = '') or
     Odd(Length(AExpectedHex)) or
     (Length(AExpectedHex) <> Length(AReplacementHex)) or
     SameText(AExpectedHex, AReplacementHex) or
     (AIntervalMs < 100) or (AIntervalMs > 60000) or
     (AMaxWrites = 0) or (AMaxWrites > 10000) or
     (ADurationSeconds = 0) or (ADurationSeconds > 3600) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_freeze_plan_invalid', '{}'));
  ByteCount := QWord(Length(AReplacementHex) div 2);
  if (ByteCount = 0) or (ByteCount > 4096) or
     (ByteCount > High(QWord) div AMaxWrites) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'memory_freeze_budget_invalid', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  ExpiresAt := FClock.UtcAfterSeconds(ADurationSeconds);

  FillChar(Context, SizeOf(Context), 0);
  Context.TaskId := ATaskId;
  Context.ProcessIdentityId := Identity.Id;
  Context.PolicySnapshotId := 'policy:single-player-v1';
  Context.TargetClassification := tcSinglePlayerOffline;
  Context.Epoch := Identity.Epoch;
  Context.RequesterOrigin := aoLocalUserInterface;
  Context.LeaseId := 'lease-' + Copy(FHasher.HashUtf8(ATaskId + #0 +
    Identity.Id + #0 + AAddressHex + #0 + AReplacementHex + #0 +
    IntToStr(AMaxWrites) + #0 + ExpiresAt), 8, 32);

  FillChar(Lease, SizeOf(Lease), 0);
  Lease.Id := Context.LeaseId;
  Lease.CapabilityId := 'memory_freeze';
  Lease.ProcessIdentityId := Identity.Id;
  Lease.Epoch := Identity.Epoch;
  Lease.IssuedAt := FClock.UtcNowIso8601;
  Lease.ExpiresAt := ExpiresAt;
  Lease.RemainingCalls := AMaxWrites;
  Lease.RemainingBytes := ByteCount * AMaxWrites;
  Result := FStore.SaveLease(Lease);
  if Result.Failed then Exit;

  RequestObject := TJSONObject.Create;
  try
    RequestObject.Add('task_id', ATaskId);
    RequestObject.Add('process_identity_ref', Identity.Id);
    RequestObject.Add('target_pid', Int64(Identity.Pid));
    RequestObject.Add('target_started_at', Identity.StartedAt);
    RequestObject.Add('target_executable_sha256', Identity.ExecutableSha256);
    RequestObject.Add('lease_ref', Context.LeaseId);
    RequestObject.Add('address', LowerCase(AAddressHex));
    RequestObject.Add('expected_original_bytes', LowerCase(AExpectedHex));
    RequestObject.Add('replacement_bytes', LowerCase(AReplacementHex));
    RequestObject.Add('interval_ms', Int64(AIntervalMs));
    RequestObject.Add('max_writes', Int64(AMaxWrites));
    RequestObject.Add('expires_at', ExpiresAt);
    RequestObject.Add('automatic_resume', False);
    RequestObject.Add('automatic_restore', False);
    RequestJson := RequestObject.AsJSON;
  finally
    RequestObject.Free;
  end;
  IdempotencyKey := 'freeze-' + Copy(FHasher.HashUtf8(RequestJson), 8, 32);
  Result := FGateway.RequestEffect('memory_freeze', Context, RequestJson,
    IdempotencyKey);
  if Result.Code = rcApprovalRequired then
  begin
    ResultData := nil;
    try
      try
        ResultData := GetJSON(Result.DataJson);
      except
        Exit(TCEAResult.Error(rcInternalError,
          'planned_freeze_reference_invalid', '{}'));
      end;
      if (ResultData = nil) or (ResultData.JSONType <> jtObject) then
        Exit(TCEAResult.Error(rcInternalError,
          'planned_freeze_reference_invalid', '{}'));
      PlannedEffectId := TJSONObject(ResultData).Get('effect_id', '');
      if PlannedEffectId = '' then
        Exit(TCEAResult.Error(rcInternalError,
          'planned_freeze_reference_missing', '{}'));
    finally
      ResultData.Free;
    end;
    if FStore.LoadEffect(PlannedEffectId, AEffect).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'planned_freeze_load_failed', '{}'));
  end;
end;

function TCEAStandaloneRuntime.ApproveAndStartFreeze(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (FFreezeService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  Result := FApprovals.Approve(Effect, FClock.UtcAfterMinutes(1));
  if Result.Failed then Exit;
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := FFreezeService.Activate(AEffectId, Identity);
  if not Result.Failed then
    FFreezeNextTick := GetTickCount64 + FFreezeService.IntervalMs;
end;

function TCEAStandaloneRuntime.TickFreeze: TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (FFreezeService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Result := FFreezeService.Tick(Identity);
end;

function TCEAStandaloneRuntime.StopFreeze(
  const AReason: string): TCEAResult;
begin
  if not FStarted or (FFreezeService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FFreezeService.Stop(AReason);
end;

function TCEAStandaloneRuntime.FreezeActive: Boolean;
begin
  Result := FStarted and Assigned(FFreezeService) and FFreezeService.Active;
end;

function TCEAStandaloneRuntime.RejectEffect(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
begin
  Result := LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  Result := FApprovals.Reject(Effect);
end;

function TCEAStandaloneRuntime.LoadEffect(const AEffectId: string;
  out AEffect: TCEAEffect): TCEAResult;
begin
  if not FStarted or (FStore = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FStore.LoadEffect(AEffectId, AEffect);
end;

function TCEAStandaloneRuntime.ReconcileUnknownEffect(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
  Identity: TCEProcessIdentity;
  Data, ObservationData: TJSONData;
  RequestObject, ObservationObject: TJSONObject;
  AddressText, ExpectedHex, ReplacementHex, CurrentHex: string;
  TargetStartedAt, TargetExecutableSha256: string;
  TargetPid: Cardinal;
  Address: QWord;
  ByteCount: Cardinal;
  DetailsJson, OutcomeText: string;
  Receipt: TCEAReceipt;
  Proof: TCEAProof;
begin
  if not FStarted or (FStore = nil) or (FEffectBackend = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FStore.LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  if (Effect.State <> esUnknown) or
     (Effect.CapabilityId <> 'memory_write') then
    Exit(TCEAResult.Error(rcConflict,
      'effect_reconciliation_not_available', '{}'));
  Result := EngineRuntime.Processes.Current(Identity);
  if Result.Failed then Exit;
  Data := nil;
  ObservationData := nil;
  try
    try
      Data := GetJSON(Effect.RequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'effect_reconciliation_request_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'effect_reconciliation_request_invalid', '{}'));
    RequestObject := TJSONObject(Data);
    TargetPid := RequestObject.Get('target_pid', 0);
    TargetStartedAt := RequestObject.Get('target_started_at', '');
    TargetExecutableSha256 := RequestObject.Get(
      'target_executable_sha256', '');
    if (TargetPid <> Identity.Pid) or
       (TargetStartedAt = '') or
       (TargetStartedAt <> Identity.StartedAt) or
       (TargetExecutableSha256 = '') or
       (TargetExecutableSha256 <> Identity.ExecutableSha256) then
      Exit(TCEAResult.Error(rcStaleProcessIdentity,
        'effect_reconciliation_target_changed', '{}'));
    AddressText := RequestObject.Get('address', '');
    ExpectedHex := LowerCase(RequestObject.Get(
      'expected_original_bytes', ''));
    ReplacementHex := LowerCase(RequestObject.Get('replacement_bytes', ''));
    if (Copy(AddressText, 1, 2) <> '0x') or
       not TryStrToQWord('$' + Copy(AddressText, 3, MaxInt), Address) or
       (ExpectedHex = '') or Odd(Length(ExpectedHex)) or
       (Length(ExpectedHex) <> Length(ReplacementHex)) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'effect_reconciliation_request_invalid', '{}'));
    ByteCount := Length(ExpectedHex) div 2;
    Result := FEffectBackend.ReadCurrentHex(Identity.Pid, Address, ByteCount);
    if Result.Failed then Exit;
    try
      ObservationData := GetJSON(Result.DataJson);
    except
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_observation_invalid', '{}'));
    end;
    if (ObservationData = nil) or
       (ObservationData.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_observation_invalid', '{}'));
    ObservationObject := TJSONObject(ObservationData);
    CurrentHex := LowerCase(ObservationObject.Get('current', ''));

    if CurrentHex = ReplacementHex then
    begin
      Effect.State := esApplied;
      OutcomeText := 'applied';
      Result := TCEAResult.Ok('{}');
      Result.StableCode := 'effect_reconciled_applied';
    end
    else if CurrentHex = ExpectedHex then
    begin
      Effect.State := esRejected;
      OutcomeText := 'not_applied';
      Result := TCEAResult.Ok('{}');
      Result.StableCode := 'effect_reconciled_not_applied';
    end
    else
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_inconclusive',
        '{"current":"' + CurrentHex + '"}'));

    DetailsJson := '{"reconciled":true,"outcome":"' + OutcomeText +
      '","current":"' + CurrentHex + '",' +
      '"automatic_retry":false,"automatic_rollback":false}';
    Effect.ResultJson := DetailsJson;
    Effect.UpdatedAt := FClock.UtcNowIso8601;
    if FStore.SaveEffect(Effect).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_persist_failed', '{}'));

    FillChar(Receipt, SizeOf(Receipt), 0);
    Receipt.Id := 'receipt-' + Copy(FHasher.HashUtf8(Effect.Id + #0 +
      'reconciliation' + #0 + CurrentHex), 8, 32);
    Receipt.EffectId := Effect.Id;
    Receipt.Attempt := 2;
    Receipt.RecordedAt := Effect.UpdatedAt;
    if Effect.State = esApplied then Receipt.Outcome := roApplied
    else Receipt.Outcome := roRejected;
    Receipt.ResponseHash := FHasher.HashUtf8(DetailsJson);
    Receipt.DetailsJson := DetailsJson;
    if FStore.SaveReceipt(Receipt).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_receipt_failed', '{}'));

    FillChar(Proof, SizeOf(Proof), 0);
    Proof.Id := 'proof-' + Copy(FHasher.HashUtf8(Receipt.Id + #0 +
      Receipt.ResponseHash), 8, 32);
    Proof.EffectId := Effect.Id;
    Proof.ReceiptId := Receipt.Id;
    Proof.RecordedAt := Receipt.RecordedAt;
    Proof.Outcome := poPass;
    Proof.VerificationHash := FHasher.HashUtf8(
      Receipt.ResponseHash + #0 + CurrentHex);
    Proof.DetailsJson := DetailsJson;
    if FStore.SaveProof(Proof).Failed then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'effect_reconciliation_proof_failed', '{}'));
    Result.DataJson := DetailsJson;
    Result.ReceiptId := Receipt.Id;
    Result.ProofId := Proof.Id;
  finally
    ObservationData.Free;
    Data.Free;
  end;
end;

function TCEAStandaloneRuntime.ImportCTFile(
  const APath: string): TCEAResult;
var
  Artifact: TCTArtifact;
begin
  if not FStarted or (FCTParser = nil) or (FCTCatalog = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FCTParser.ParseFile(APath, 'file://local/' +
    ExtractFileName(APath), Artifact);
  if Result.Failed then Exit;
  Result := FCTCatalog.ImportParsedArtifact(Artifact);
end;

function TCEAStandaloneRuntime.InspectSaveFile(const ATaskId,
  APath: string; out ASnapshot: TCEASaveSnapshot): TCEAResult;
begin
  FillChar(ASnapshot, SizeOf(ASnapshot), 0);
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSaveService.Inspect(ATaskId, APath, ASnapshot);
  if not Result.Failed then
  begin
    FSelectedSaveSnapshot := ASnapshot;
    FSelectedDiscoveryScopeId := '';
    FSelectedDiscoverySnapshotId := '';
    FRevokedDiscoverySnapshotId := '';
  end;
end;

function TCEAStandaloneRuntime.AuthorizeSaveDirectory(
  const ARoot: string; const ABudget: TCEADiscoveryBudget;
  out AScope: TCEADiscoveryScope): TCEAResult;
var
  OldScopeId: string;
begin
  FillChar(AScope, SizeOf(AScope), 0);
  if not FStarted or (FSaveDiscoveryService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'save_discovery_owner_thread_required', '{}'));
  OldScopeId := FSelectedDiscoveryScopeId;
  Result := FSaveDiscoveryService.AuthorizeDirectory(ARoot,
    ABudget, AScope);
  if Result.Failed then Exit;
  if OldScopeId <> '' then
  begin
    FRevokedDiscoveryScopes.Add(OldScopeId);
    Result := RejectDiscoveryPlannedEffects(OldScopeId);
    if Result.Failed then Exit;
    FRevokedDiscoverySnapshotId := FSelectedDiscoverySnapshotId;
    FillChar(FSelectedSaveSnapshot, SizeOf(FSelectedSaveSnapshot), 0);
    FSelectedDiscoveryScopeId := '';
    FSelectedDiscoverySnapshotId := '';
  end;
end;

function TCEAStandaloneRuntime.ScanSaveDirectory(
  const AScopeId: string;
  out ACandidates: TCEASaveCandidateArray): TCEAResult;
begin
  SetLength(ACandidates, 0);
  if not FStarted or (FSaveDiscoveryService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSaveDiscoveryService.Scan(AScopeId, ACandidates);
end;

function TCEAStandaloneRuntime.CancelSaveDirectory(
  const AScopeId: string): TCEAResult;
begin
  if not FStarted or (FSaveDiscoveryService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSaveDiscoveryService.Cancel(AScopeId);
end;

function TCEAStandaloneRuntime.SelectSaveCandidate(
  const AScopeId, ACandidateId: string;
  out ASnapshot: TCEASaveSnapshot): TCEAResult;
var
  Candidate: TCEASaveCandidate;
  PathText: string;
begin
  FillChar(ASnapshot, SizeOf(ASnapshot), 0);
  if not FStarted or (FSaveDiscoveryService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'save_discovery_owner_thread_required', '{}'));
  Result := FSaveDiscoveryService.SelectCandidate(AScopeId,
    ACandidateId, PathText, Candidate);
  if Result.Failed then Exit;
  Result := InspectSaveFile('task-discovered-save', PathText, ASnapshot);
  if Result.Failed then Exit;
  if (ASnapshot.FileIdentityId <> Candidate.FileIdentityId) or
     (ASnapshot.ByteCount <> Candidate.ByteCount) then
  begin
    FillChar(FSelectedSaveSnapshot, SizeOf(FSelectedSaveSnapshot), 0);
    FillChar(ASnapshot, SizeOf(ASnapshot), 0);
    Exit(TCEAResult.Error(rcConflict,
      'save_candidate_changed_before_inspect', '{}'));
  end;
  FSelectedDiscoveryScopeId := AScopeId;
  FSelectedDiscoverySnapshotId := ASnapshot.Id;
end;

function TCEAStandaloneRuntime.RevokeSaveDirectory(
  const AScopeId: string): TCEAResult;
begin
  if not FStarted or (FSaveDiscoveryService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if GetCurrentThreadId <> EngineRuntime.CommandQueue.OwnerThreadId then
    Exit(TCEAResult.Error(rcUnauthorized,
      'save_discovery_owner_thread_required', '{}'));
  Result := FSaveDiscoveryService.Revoke(AScopeId);
  if Result.Failed then Exit;
  FRevokedDiscoveryScopes.Add(AScopeId);
  Result := RejectDiscoveryPlannedEffects(AScopeId);
  if Result.Failed then Exit;
  if FSelectedDiscoveryScopeId = AScopeId then
  begin
    FRevokedDiscoverySnapshotId := FSelectedDiscoverySnapshotId;
    FillChar(FSelectedSaveSnapshot, SizeOf(FSelectedSaveSnapshot), 0);
    FSelectedDiscoveryScopeId := '';
    FSelectedDiscoverySnapshotId := '';
  end;
end;

function TCEAStandaloneRuntime.GetSelectedSaveSnapshot: TCEAResult;
var
  Current: TCEASaveSnapshot;
  Projection: TJSONObject;
begin
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FSelectedSaveSnapshot.Id = '' then
    Exit(TCEAResult.Error(rcApprovalRequired,
      'local_save_selection_required', '{}'));
  Result := FSaveService.Inspect('mcp-save-recheck',
    FSelectedSaveSnapshot.CanonicalPath, Current);
  if Result.Failed then Exit;
  if (Current.FileIdentityId <> FSelectedSaveSnapshot.FileIdentityId) or
     (Current.Sha256 <> FSelectedSaveSnapshot.Sha256) then
    Exit(TCEAResult.Error(rcConflict, 'save_snapshot_stale', '{}'));
  Projection := TJSONObject.Create;
  try
    Projection.Add('schema_version', '1.0');
    Projection.Add('id', Current.Id);
    Projection.Add('target_id', Current.TargetId);
    Projection.Add('file_identity_id', Current.FileIdentityId);
    Projection.Add('byte_count', Current.ByteCount);
    Projection.Add('sha256', Current.Sha256);
    Projection.Add('read_coverage', Current.ReadCoverage);
    Projection.Add('format_id', Current.FormatDescriptor.Id);
    Projection.Add('editable', False);
    Result := TCEAResult.Ok(Projection.AsJSON);
  finally
    Projection.Free;
  end;
end;

function TCEAStandaloneRuntime.RequestSelectedSaveBackup(
  const ATaskId: string): TCEAResult;
var
  Check: TCEAResult;
  EffectId: string;
begin
  if (ATaskId = '') or (Length(ATaskId) > 128) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'save_backup_task_invalid', '{}'));
  Check := GetSelectedSaveSnapshot;
  if Check.Failed then Exit(Check);
  Result := RequestSaveBackup(ATaskId, FSelectedSaveSnapshot, EffectId);
  if Result.Code = rcApprovalRequired then
    Result.DataJson := '{"effect_id":"' + EffectId +
      '","state":"planned","approval_surface":"local_ui_only"}';
end;

function TCEAStandaloneRuntime.GetSaveEffect(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
  Assessment, ObservedHash: string;
  Projection: TJSONObject;
begin
  Result := LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  if Effect.ResourceKind <> rkSaveFile then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'not_a_save_effect', '{}'));
  Projection := TJSONObject.Create;
  try
    Projection.Add('effect_id', Effect.Id);
    Projection.Add('capability_id', Effect.CapabilityId);
    Projection.Add('state', EffectStateName(Effect.State));
    Projection.Add('request_hash', Effect.RequestHash);
    if (Effect.State = esUnknown) and
       not FStore.LoadRecoveryCase(Effect.Id,
         Assessment, ObservedHash).Failed then
    begin
      Projection.Add('recovery_assessment', Assessment);
      Projection.Add('observed_sha256', ObservedHash);
    end;
    Result := TCEAResult.Ok(Projection.AsJSON);
  finally
    Projection.Free;
  end;
end;

function TCEAStandaloneRuntime.ProposeSelectedSaveEdit(const AFieldPath,
  AExpectedJson, ANewJson: string): TCEAResult;
var
  Proposal: TCEASaveEditProposal;
  Check: TCEAResult;
begin
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Check := GetSelectedSaveSnapshot;
  if Check.Failed then Exit(Check);
  Result := FSaveService.ProposeFieldEdit(FSelectedSaveSnapshot,
    AFieldPath, AExpectedJson, ANewJson, Proposal);
end;

function TCEAStandaloneRuntime.GetSaveFields(
  const ASnapshot: TCEASaveSnapshot;
  out AFields: TCEASaveFieldArray): TCEAResult;
begin
  SetLength(AFields, 0);
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSaveService.GetFields(ASnapshot, AFields);
end;

function TCEAStandaloneRuntime.RequestSaveBackup(const ATaskId: string;
  const ASnapshot: TCEASaveSnapshot; out AEffectId: string): TCEAResult;
begin
  AEffectId := '';
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := CheckSaveDiscoveryAuthority('', ASnapshot.Id);
  if Result.Failed then Exit;
  Result := CheckSaveTargetUnsettled(ASnapshot.FileIdentityId,
    ASnapshot.CanonicalPath, '');
  if Result.Failed then Exit;
  Result := FSaveService.RequestBackup(ATaskId, ASnapshot,
    FClock.UtcAfterMinutes(1), AEffectId);
  if Result.Code = rcApprovalRequired then
    BindDiscoveryEffect(AEffectId, ASnapshot.Id);
end;

function TCEAStandaloneRuntime.ProposeSaveFieldEdit(
  const ASnapshot: TCEASaveSnapshot;
  const AFieldPath, AExpectedJson, ANewJson: string;
  out AProposal: TCEASaveEditProposal): TCEAResult;
begin
  FillChar(AProposal, SizeOf(AProposal), 0);
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSaveService.ProposeFieldEdit(ASnapshot, AFieldPath,
    AExpectedJson, ANewJson, AProposal);
end;

function TCEAStandaloneRuntime.PlanSaveEdit(const ATaskId: string;
  const ASnapshot: TCEASaveSnapshot;
  const AProposal: TCEASaveEditProposal;
  const ABackupEffectId: string; out AEffectId: string): TCEAResult;
begin
  AEffectId := '';
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := CheckSaveDiscoveryAuthority('', ASnapshot.Id);
  if Result.Failed then Exit;
  Result := CheckSaveTargetUnsettled(ASnapshot.FileIdentityId,
    ASnapshot.CanonicalPath, '');
  if Result.Failed then Exit;
  Result := FSaveService.PlanEdit(ATaskId, ASnapshot, AProposal,
    ABackupEffectId, FClock.UtcAfterMinutes(1), AEffectId);
  if Result.Code = rcApprovalRequired then
    BindDiscoveryEffect(AEffectId, ASnapshot.Id);
end;

function TCEAStandaloneRuntime.ExecuteSaveEdit(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
begin
  if not FStarted or (FGateway = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := LoadEffect(AEffectId, Effect);
  if Result.Failed then Exit;
  Result := CheckSaveDiscoveryAuthority(AEffectId, '');
  if Result.Failed then Exit;
  if Effect.ResourceKind = rkSaveFile then
  begin
    Result := CheckSaveTargetUnsettled(Effect.ResourceIdentityId,
      SaveEffectSourcePath(Effect.RequestJson), Effect.Id);
    if Result.Failed then Exit;
  end;
  Result := FGateway.ExecuteApprovedEffect(AEffectId);
end;

function TCEAStandaloneRuntime.PlanSaveRestore(const ATaskId: string;
  const ACurrent: TCEASaveSnapshot;
  const ABackupEffectId, AExpectedCurrentHash: string;
  out AEffectId: string): TCEAResult;
begin
  AEffectId := '';
  if not FStarted or (FSaveService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := CheckSaveDiscoveryAuthority('', ACurrent.Id);
  if Result.Failed then Exit;
  Result := CheckSaveTargetUnsettled(ACurrent.FileIdentityId,
    ACurrent.CanonicalPath, '');
  if Result.Failed then Exit;
  Result := FSaveService.PlanRestore(ATaskId, ACurrent,
    ABackupEffectId, AExpectedCurrentHash, FClock.UtcAfterMinutes(1),
    AEffectId);
  if Result.Code = rcApprovalRequired then
    BindDiscoveryEffect(AEffectId, ACurrent.Id);
end;

function TCEAStandaloneRuntime.ReconcileUnsettledSaveEffects: TCEAResult;
var
  Ids: TCEASaveEffectIdArray;
  Effect: TCEAEffect;
  RequestData: TJSONData;
  Obj: TJSONObject;
  Observed: TCEASaveSnapshot;
  I: Integer;
  PathText, BaselineHash, AppliedHash, Assessment, ObservedHash: string;
  InspectResult: TCEAResult;
begin
  if (FStore = nil) or (FSaveReader = nil) or (FClock = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'save_recovery_dependencies_missing', '{}'));
  Result := FStore.ListUnsettledSaveEffectIds(Ids);
  if Result.Failed then Exit;
  for I := 0 to High(Ids) do
  begin
    Result := FStore.LoadEffect(Ids[I], Effect);
    if Result.Failed then Exit;
    Assessment := 'unknown';
    ObservedHash := '';
    RequestData := nil;
    try
      try
        RequestData := GetJSON(Effect.RequestJson);
      except
        RequestData := nil;
      end;
      if (RequestData <> nil) and (RequestData.JSONType = jtObject) then
      begin
        Obj := TJSONObject(RequestData);
        if Effect.CapabilityId = 'save_backup' then
        begin
          PathText := '';
          if ValidSaveSnapshotId(Obj.Get('snapshot_id', '')) then
            PathText := IncludeTrailingPathDelimiter(
              ExtractFileDir(FDatabasePath)) + 'backups' + PathDelim +
              Obj.Get('snapshot_id', '') + '.bak';
          BaselineHash := '';
          AppliedHash := Obj.Get('sha256', '');
        end
        else
        begin
          PathText := Obj.Get('source_path', '');
          if Effect.CapabilityId = 'save_restore' then
          begin
            BaselineHash := Obj.Get('current_sha256', '');
            AppliedHash := Obj.Get('backup_sha256', '');
          end
          else
          begin
            BaselineHash := Obj.Get('sha256', '');
            AppliedHash := Obj.Get('candidate_sha256', '');
          end;
        end;
        if PathText <> '' then
        begin
          InspectResult := FSaveReader.Inspect(PathText, Observed);
          if not InspectResult.Failed then
          begin
            ObservedHash := Observed.Sha256;
            if (AppliedHash <> '') and (ObservedHash = AppliedHash) then
              Assessment := 'observed_applied'
            else if (BaselineHash <> '') and
                    (ObservedHash = BaselineHash) then
              Assessment := 'observed_not_applied';
          end;
        end;
      end;
    finally
      RequestData.Free;
    end;
    Result := FStore.SaveRecoveryCase(Effect.Id, Assessment,
      ObservedHash, 'local_user', FClock.UtcAfterMinutes(1440),
      FClock.UtcAfterMinutes(60));
    if Result.Failed then Exit;
  end;
  Result := TCEAResult.Ok('{"reconciled_save_cases":' +
    IntToStr(Length(Ids)) + ',"automatic_retry":false}');
end;

function TCEAStandaloneRuntime.GetSaveRecoveryCase(
  const AEffectId: string; out AAssessment,
  AObservedHash: string): TCEAResult;
begin
  AAssessment := '';
  AObservedHash := '';
  if not FStarted or (FStore = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FStore.LoadRecoveryCase(AEffectId, AAssessment, AObservedHash);
end;

function TCEAStandaloneRuntime.SearchCT(const AText: string;
  const AMaxResults: Cardinal): TCEAResult;
begin
  if not FStarted or (FCTCatalog = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FCTCatalog.SearchText(AText, AMaxResults);
end;

function TCEAStandaloneRuntime.GetCTEntry(
  const AEntryKey: string): TCEAResult;
begin
  if not FStarted or (FCTCatalog = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FCTCatalog.GetEntry(AEntryKey);
end;

function TCEAStandaloneRuntime.BuildCTRagContext(const AText: string;
  const AMaxResults: Cardinal): TCEAResult;
begin
  if not FStarted or (FCTCatalog = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FCTCatalog.BuildRagContext(AText, AMaxResults);
end;

function TCEAStandaloneRuntime.EmergencyStop: TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (FStore = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if Assigned(FFreezeService) and FFreezeService.Active then
  begin
    Result := FFreezeService.Stop('emergency_stop');
    if Result.Failed then Exit;
  end;
  Result := FStore.RevokeAllLeases;
  if Result.Failed then Exit;
  Result := FStore.RejectPlannedEffects(FClock.UtcNowIso8601);
  if Result.Failed then Exit;
  if Assigned(EngineRuntime) and
     not EngineRuntime.Processes.Current(Identity).Failed then
    EngineRuntime.Processes.Detach(Identity);
  if Assigned(FMCPServer) then FMCPServer.RevokeToken;
  FMCPToken := '';
  Result := TCEAResult.Ok('{"emergency_stop_applied":true,' +
    '"leases_revoked":true,"planned_effects_rejected":true,' +
    '"process_detached":true}');
end;

function TCEAStandaloneRuntime.ConfigureLLM(const AEndpoint,
  AModelId, ASecretRef: string; const AProviderId: string): TCEAResult;
var
  Configuration: TCEAProviderConfiguration;
  ProviderId: string;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if (Trim(AEndpoint) = '') or (Trim(AModelId) = '') or
     (Trim(ASecretRef) = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'llm_configuration_invalid', '{}'));
  FillChar(Configuration, SizeOf(Configuration), 0);
  ProviderId := Trim(LowerCase(AProviderId));
  if ProviderId = '' then
    ProviderId := 'openai-compatible';
  if (ProviderId <> 'openai-compatible') and
     (ProviderId <> 'anthropic-compatible') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'llm_provider_unknown', '{}'));
  Configuration.ProviderId := ProviderId;
  Configuration.Endpoint := Trim(AEndpoint);
  Configuration.ModelId := Trim(AModelId);
  Configuration.SecretRef := Trim(ASecretRef);
  Configuration.TimeoutMs := 60000;
  Configuration.MaxPromptBytes := 64 * 1024;
  Configuration.MaxRagBytes := 1024 * 1024;
  Configuration.MaxOutputTokens := 4096;
  Configuration.MaxTotalTokens := 16384;
  Configuration.Enabled := True;
  FreeAndNil(FLLMProvider);
  if ProviderId = 'anthropic-compatible' then
    FLLMProvider := TAnthropicCompatibleProvider.Create(Configuration,
      FSecretStore, FLLMTransport)
  else
    FLLMProvider := TOpenAICompatibleProvider.Create(Configuration,
      FSecretStore, FLLMTransport);
  // 自然语言定制服务在 Start 时就建好了（那时还没有 provider），
  // 这里把新 provider 交回去，避免定制功能一直停在 llm_not_configured。
  if FUiCustomizationService <> nil then
    FUiCustomizationService.Provider := FLLMProvider;
  Result := TCEAResult.Ok('{"configured":true,' +
    '"provider_id":"' + ProviderId + '",' +
    '"secret_storage":"windows_credential_manager"}');
end;

function TCEAStandaloneRuntime.SaveLLMCredential(const ASecretRef,
  ASecretValue: string): TCEAResult;
begin
  if not FStarted or (FSecretStore = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FSecretStore.SaveValue(Trim(ASecretRef), ASecretValue);
end;

function TCEAStandaloneRuntime.ChatWithRag(const APrompt,
  ACTQuery: string): TCEAResult;
var
  ContextResult: TCEAResult;
begin
  if FLLMProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  ContextResult := BuildCTRagContext(ACTQuery, 20);
  if ContextResult.Failed then Exit(ContextResult);
  Result := ChatWithContext(APrompt, ContextResult.DataJson, nil);
end;

function TCEAStandaloneRuntime.ChatWithContext(const APrompt,
  ARagContextJson: string;
  const ACancellation: ICEACancellationToken;
  const AStreamSink: ICEALLMTextStreamSink): TCEAResult;
var
  Request: TCEALLMChatRequest;
begin
  if FLLMProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  FillChar(Request, SizeOf(Request), 0);
  Request.UserPrompt := APrompt;
  Request.RagContextJson := ARagContextJson;
  Request.MaxOutputTokens := 1024;
  Request.Temperature := 0.2;
  Request.Cancellation := ACancellation;
  Request.StreamSink := AStreamSink;
  Result := FLLMProvider.Chat(Request);
end;

{ ---------------------------------------------------------------------------
  Phase 1 player-level capabilities (PRD 6.1-6.8).
  These methods expose the already-implemented Phase 1 modules through the
  application runtime so the desktop UI and the secondary-screen surface can
  drive them without duplicating governance logic.
  --------------------------------------------------------------------------- }

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
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
    else
      Result := Result + C;
    end;
  end;
end;

{ JSON has no True/False literals: BoolToStr(Value, True) emits Pascal casing,
  which makes the payload unparseable. Every JSON boolean goes through here. }
function JsonBool(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

{ A trend with no samples still has to serialize as a JSON object, otherwise the
  caller cannot tell "not observed" from a malformed payload. }
function TrendJson(const ATrend: TCEAFieldTrend): string;
begin
  if not ATrend.IsValid then
    Exit('null');
  Result := '{"field_id":"' + JsonEscapeText(ATrend.FieldId) +
    '","samples":' + IntToStr(ATrend.SampleCount) +
    ',"changes":' + IntToStr(ATrend.ChangeCount) +
    ',"events":' + IntToStr(ATrend.EventCount) +
    ',"numeric":' + JsonBool(ATrend.Numeric) +
    ',"first":"' + JsonEscapeText(ATrend.FirstValueJson) +
    '","last":"' + JsonEscapeText(ATrend.LastValueJson) +
    '","direction":"' + ATrend.Direction + '"}';
end;

function TCEAStandaloneRuntime.NextWriteRecordId: string;
begin
  Inc(FWriteSequence);
  Result := 'write-' + IntToHex(FWriteSequence, 8);
end;

{ FR-046 操作历史。写入已经发生过，日志失败不能把结果翻成"没写"，
  但必须让操作者知道这条记录没留下，所以 journal_recorded 由调用方回报。 }
function TCEAStandaloneRuntime.JournalWrite(const AField: TCEAGameField;
  const AIdentity: TCEProcessIdentity; const AAdapterId, AOriginalValue,
  ATargetValue, AOutcome, AStableCode, AErrorText, ADetailJson: string;
  const ACommandSent, AVerified: Boolean; out ARecorded: Boolean): TCEAResult;
var
  Rec: TCEAFieldWriteRecord;
  NewId: string;
begin
  ARecorded := False;
  if FWriteJournal = nil then
    Exit(TCEAResult.Ok('{}'));
  FillChar(Rec, SizeOf(Rec), 0);
  Rec.RecordId := NextWriteRecordId;
  Rec.FieldId := AField.FieldId;
  Rec.DisplayName := AField.DisplayName;
  Rec.ValueType := AField.ValueType;
  Rec.OriginalValue := AOriginalValue;
  Rec.TargetValue := ATargetValue;
  Rec.AdapterId := AAdapterId;
  Rec.AddressHex := AField.AddressHex;
  Rec.ProcessIdentityId := AIdentity.Id;
  Rec.Pid := AIdentity.Pid;
  Rec.Epoch := AIdentity.Epoch;
  Rec.Outcome := AOutcome;
  Rec.StableCode := AStableCode;
  Rec.ErrorText := AErrorText;
  Rec.DetailJson := ADetailJson;
  Rec.CommandSent := ACommandSent;
  Rec.Verified := AVerified;
  Rec.RecordedAt := FClock.UtcNowIso8601;
  Result := FWriteJournal.AppendWrite(Rec, NewId);
  ARecorded := not Result.Failed;
  // 日志失败不覆盖写入结果：调用方拿到的 Result 只描述"记没记住"。
  if Result.Failed then
    Exit(TCEAResult.Ok('{}'));
end;

function HexToBytes(const AHex: string; out ABytes: TBytes): Boolean;
var
  I, Parsed: Integer;
begin
  SetLength(ABytes, 0);
  Result := (AHex <> '') and not Odd(Length(AHex));
  if not Result then Exit;
  SetLength(ABytes, Length(AHex) div 2);
  for I := 0 to High(ABytes) do
  begin
    if not TryStrToInt('$' + Copy(AHex, I * 2 + 1, 2), Parsed) then
    begin
      SetLength(ABytes, 0);
      Exit(False);
    end;
    ABytes[I] := Byte(Parsed);
  end;
end;

// Little-endian bytes -> lowercase hex string (matches the effect backend).
function BytesToHexLower(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + LowerCase(IntToHex(ABytes[I], 2));
end;

// Little-endian bytes -> human readable value text (matches EncodeExactValue).
function BytesToValueText(const ABytes: TBytes; const AValueType: string): string;
var
  Width: Cardinal;
  Bits: QWord;
  I: Integer;
  SingleValue: Single;
  DoubleValue: Double;
  Settings: TFormatSettings;
begin
  Result := '';
  if AValueType = 'byte' then Width := 1
  else if AValueType = 'word' then Width := 2
  else if (AValueType = 'dword') or (AValueType = 'single') or
          (AValueType = 'integer') or (AValueType = 'bool') then Width := 4
  else if (AValueType = 'qword') or (AValueType = 'double') then Width := 8
  else Exit;
  if Length(ABytes) <> Integer(Width) then Exit;

  Bits := 0;
  for I := 0 to Integer(Width) - 1 do
    Bits := Bits or (QWord(ABytes[I]) shl (I * 8));

  if AValueType = 'single' then
  begin
    SingleValue := 0;
    Move(Bits, SingleValue, SizeOf(SingleValue));
    Settings := DefaultFormatSettings;
    Settings.DecimalSeparator := '.';
    Result := FloatToStr(SingleValue, Settings);
  end
  else if AValueType = 'double' then
  begin
    DoubleValue := 0;
    Move(Bits, DoubleValue, SizeOf(DoubleValue));
    Settings := DefaultFormatSettings;
    Settings.DecimalSeparator := '.';
    Result := FloatToStr(DoubleValue, Settings);
  end
  else
    Result := UIntToStr(Bits);
end;

function TCEAStandaloneRuntime.CurrentIdentity(
  out AIdentity: TCEProcessIdentity): TCEAResult;
begin
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  if not FStarted or not Assigned(EngineRuntime) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := EngineRuntime.Processes.Current(AIdentity);
end;

function TCEAStandaloneRuntime.CheckFieldConstraints(const AField: TCEAGameField;
  const ATargetValue: string): TCEAResult;
var
  Constraints: TCEAFieldConstraints;
begin
  // An empty ConstraintsJson means "the field declares nothing", which is not
  // the same as "the field declares something we failed to read". Only the
  // latter may block a write.
  if Trim(AField.ConstraintsJson) = '' then
    Exit(TCEAResult.Ok('{}'));
  Result := ParseFieldConstraints(AField.ConstraintsJson, Constraints);
  if Result.Failed then Exit;
  Result := ValidateFieldValue(AField.ValueType, ATargetValue, Constraints);
end;

function TCEAStandaloneRuntime.StartGameSession(const AGameName,
  AGameVersion: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if not FStarted or (FMappingService = nil) or (FEventService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if Trim(AGameName) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'game_name_required', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  FreeAndNil(FGameModel);
  FGameModel := TCEAGameStateModel.Create(Trim(AGameName), Trim(AGameVersion),
    Identity.ExecutableSha256, Identity.ModuleSetHash);
  FreeAndNil(FCaptureService);
  FCapturePid := Identity.Pid;
  FCaptureIdentityId := Identity.Id;
  FCaptureEpoch := Identity.Epoch;
  Result := TCEAResult.Ok('{"game_name":"' + JsonEscapeText(AGameName) +
    '","game_version":"' + JsonEscapeText(AGameVersion) +
    '","target_pid":' + IntToStr(Identity.Pid) +
    ',"executable_sha256":"' + JsonEscapeText(Identity.ExecutableSha256) +
    '","module_set_hash":"' + JsonEscapeText(Identity.ModuleSetHash) + '"}');
end;

procedure TCEAStandaloneRuntime.EndGameSession;
begin
  // 录像绑定的是具体进程窗口：会话结束必须停录，否则后续事件会把
  // 已经退出的游戏的旧窗口画面当成证据。
  StopEventRecording;
  if FWakeQueue <> nil then
    FWakeQueue.Clear;
  // 轮次是「这次探索想干什么」的计划：会话结束后旧计划不再有效，
  // 留着会让下一轮以为还有未交代的意图。
  if FDiscoveryRounds <> nil then
    FDiscoveryRounds.Reset;
  // 目标同理：换了游戏，「我在找金币」这句话不再指任何东西。
  if FDiscoveryGoals <> nil then
    FDiscoveryGoals.Reset;
  // FR-054 写入隔离：写入授权属于某个具体进程身份与 epoch，会话结束即撤销。
  // 不撤销会让下一个游戏继承上一个游戏的操作者许可。
  FWriteAccess := cea_write_access.DisableWriteAccess;
  FreeAndNil(FCaptureService);
  FCapturePid := 0;
  FCaptureIdentityId := '';
  FCaptureEpoch := 0;
  FreeAndNil(FGameModel);
end;

function TCEAStandaloneRuntime.GameSessionActive: Boolean;
begin
  Result := FGameModel <> nil;
end;

function TCEAStandaloneRuntime.DeclareField(const AFieldId, ADisplayName,
  AValueType, AAddressHex: string): TCEAResult;
var
  Mapping, Declared: TCEAFieldMapping;
  Field: TCEAGameField;
  CreatedAt: string;
begin
  if (FMappingService = nil) or (FGameModel = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  CreatedAt := FClock.UtcNowIso8601;
  Result := FMappingService.ProposeUserDeclared(AFieldId, ADisplayName,
    AValueType, AAddressHex, CreatedAt, Mapping);
  if Result.Failed then Exit;
  Result := FMappingService.Confirm(Mapping.Id, Declared);
  if Result.Failed then Exit;
  Result := FMappingService.MaterializeField(Mapping.Id, CreatedAt, Field);
  if Result.Failed then Exit;
  // A declared field starts read_only and must be promoted explicitly after a
  // write -> reread -> match verification (FR-040 / AC-006).
  if not FGameModel.UpdateField(Field) then
    if not FGameModel.AddField(Field) then
      Exit(TCEAResult.Error(rcInternalError, 'field_model_rejected', '{}'));
  Result := TCEAResult.Ok('{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
    '","field_id":"' + JsonEscapeText(AFieldId) +
    '","access":"' + FieldAccessText(Field.Access) +
    '","validation_status":"' + ValidationStatusText(Field.ValidationStatus) +
    '"}');
end;

function TCEAStandaloneRuntime.SetFieldConstraints(const AFieldId,
  AConstraintsJson: string): TCEAResult;
var
  Field, Updated: TCEAGameField;
  Constraints: TCEAFieldConstraints;
begin
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if Trim(AFieldId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'field_id_required', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  // A malformed constraint block must be rejected at declaration time, not
  // silently stored: otherwise every later write would fail with a reason the
  // operator cannot see or fix.
  if Trim(AConstraintsJson) <> '' then
  begin
    Result := ParseFieldConstraints(AConstraintsJson, Constraints);
    if Result.Failed then Exit;
  end
  else
    Constraints := Default(TCEAFieldConstraints);
  Updated := Field;
  Updated.ConstraintsJson := Trim(AConstraintsJson);
  Updated.LastUpdated := FClock.UtcNowIso8601;
  if not FGameModel.UpdateField(Updated) then
    Exit(TCEAResult.Error(rcInternalError, 'field_model_rejected', '{}'));
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","constraints_json":"' + JsonEscapeText(Updated.ConstraintsJson) +
    '","has_min":' + JsonBool(Constraints.HasMin) +
    ',"has_max":' + JsonBool(Constraints.HasMax) +
    ',"allowed_count":' + IntToStr(Length(Constraints.AllowedValues)) + '}');
end;

function TCEAStandaloneRuntime.ResolvePointerFieldAddress(
  const AFieldId: string; out AField: TCEAGameField): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Spec: TCEAPointerChainSpec;
  Reader: TCEAWin32PointerReader;
  Resolver: TCEAPointerChainResolver;
  ModuleBase, Address: QWord;
begin
  FillChar(AField, SizeOf(AField), 0);
  if (FGameModel = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, AField) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  if not AField.HasPointerChain then
    Exit(TCEAResult.Error(rcInvalidArgument, 'field_has_no_pointer_chain', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;

  Result := ParsePointerChainSpec(AField.PointerOffsetsJson,
    AField.ModuleName, 0, AField.AddressWidthBits, Spec);
  if Result.Failed then Exit;

  Reader := TCEAWin32PointerReader.Create(Identity.Pid, 64);
  try
    Result := Reader.ModuleBaseAddress(AField.ModuleName, ModuleBase);
    if Result.Failed then Exit;
    Resolver := TCEAPointerChainResolver.Create(Reader);
    try
      Result := Resolver.Resolve(ModuleBase, Spec, Address);
    finally
      Resolver.Free;
    end;
    if Result.Failed then
    begin
      { A chain that no longer resolves means the target layout changed (module
        unloaded, patch, restart with different base). Marking the field invalid
        keeps a stale address from being used by a later write. }
      AField.Access := faInvalid;
      AField.LastUpdated := FClock.UtcNowIso8601;
      FGameModel.UpdateField(AField);
      Exit(Result);
    end;
  finally
    Reader.Free;
  end;

  AField.AddressHex := '0x' + LowerCase(IntToHex(Address, 16));
  AField.LastUpdated := FClock.UtcNowIso8601;
  FGameModel.UpdateField(AField);
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","address":"' + AField.AddressHex +
    '","module":"' + JsonEscapeText(AField.ModuleName) +
    '","depth":' + IntToStr(Spec.Depth) +
    ',"access":"' + FieldAccessText(AField.Access) + '"}');
end;

function TCEAStandaloneRuntime.DeclarePointerField(const AFieldId,
  ADisplayName, AValueType, AModuleName, AOffsetsJson: string;
  const AAddressWidthBits: Cardinal): TCEAResult;
var
  Mapping, Declared: TCEAFieldMapping;
  Field: TCEAGameField;
  CreatedAt: string;
  ResolveResult: TCEAResult;
begin
  if (FMappingService = nil) or (FGameModel = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if Trim(AModuleName) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'module_name_required', '{}'));
  CreatedAt := FClock.UtcNowIso8601;
  Result := FMappingService.ProposePointerChain(AFieldId, ADisplayName,
    AValueType, AModuleName, AOffsetsJson, AAddressWidthBits, CreatedAt,
    Mapping);
  if Result.Failed then Exit;
  Result := FMappingService.Confirm(Mapping.Id, Declared);
  if Result.Failed then Exit;
  Result := FMappingService.MaterializeField(Mapping.Id, CreatedAt, Field);
  if Result.Failed then Exit;
  if not FGameModel.UpdateField(Field) then
    if not FGameModel.AddField(Field) then
      Exit(TCEAResult.Error(rcInternalError, 'field_model_rejected', '{}'));

  // Resolve once at declaration so the caller learns immediately whether the
  // chain is sound. A failed resolution keeps the field (the chain may simply
  // need the game to reach the main menu) but reports the failure.
  ResolveResult := ResolvePointerFieldAddress(AFieldId, Field);
  if ResolveResult.Failed then
  begin
    Result := ResolveResult;
    Result.DataJson := '{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
      '","field_id":"' + JsonEscapeText(AFieldId) +
      '","resolved":false,"detail":' + ResolveResult.DataJson + '}';
    Exit;
  end;
  Result := TCEAResult.Ok('{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
    '","field_id":"' + JsonEscapeText(AFieldId) +
    '","module":"' + JsonEscapeText(Field.ModuleName) +
    '","address":"' + JsonEscapeText(Field.AddressHex) +
    '","access":"' + FieldAccessText(Field.Access) +
    '","validation_status":"' + ValidationStatusText(Field.ValidationStatus) +
    '","resolved":true}');
end;

function TCEAStandaloneRuntime.ResolveFieldAddress(
  const AFieldId: string): TCEAResult;
var
  Field: TCEAGameField;
begin
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Result := ResolvePointerFieldAddress(AFieldId, Field);
end;

function TCEAStandaloneRuntime.ProposeAiFieldMapping(const AFieldId,
  ADisplayName, AValueType, AAddressHex, AEvidenceRefsJson: string;
  const AConfidence: Double; const ACreatedAt: string): TCEAResult;
var
  Mapping: TCEAFieldMapping;
begin
  if FMappingService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // AI output always enters the pending state (AC-014): it is never usable
  // for a write until a human confirms it.
  Result := FMappingService.ProposeFromAi(AFieldId, ADisplayName, AValueType,
    AAddressHex, AEvidenceRefsJson, AConfidence, ACreatedAt, Mapping);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
    '","state":"' + MappingStateText(Mapping.State) +
    '","requires_confirmation":true}');
end;

function TCEAStandaloneRuntime.ConfirmFieldMapping(
  const AMappingId: string): TCEAResult;
var
  Mapping: TCEAFieldMapping;
begin
  if FMappingService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FMappingService.Confirm(AMappingId, Mapping);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
    '","state":"confirmed"}');
end;

function TCEAStandaloneRuntime.RejectFieldMapping(
  const AMappingId: string): TCEAResult;
var
  Mapping: TCEAFieldMapping;
begin
  if FMappingService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FMappingService.Reject(AMappingId, Mapping);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"mapping_id":"' + JsonEscapeText(Mapping.Id) +
    '","state":"rejected"}');
end;

function TCEAStandaloneRuntime.ListFieldMappings: TCEAResult;
var
  Mappings: TCEAFieldMappingArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FMappingService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Mappings := FMappingService.GetMappings;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Mappings) do
    begin
      O := TJSONObject.Create;
      O.Add('mapping_id', Mappings[I].Id);
      O.Add('field_id', Mappings[I].FieldId);
      O.Add('display_name', Mappings[I].DisplayName);
      O.Add('value_type', Mappings[I].ValueType);
      O.Add('source', MappingProposalKindText(Mappings[I].Source));
      O.Add('state', MappingStateText(Mappings[I].State));
      O.Add('confidence', Mappings[I].Confidence);
      O.Add('address_hex', Mappings[I].AddressHex);
      O.Add('module_name', Mappings[I].ModuleName);
      O.Add('pointer_offsets_json', Mappings[I].PointerOffsetsJson);
      O.Add('address_width_bits', Integer(Mappings[I].AddressWidthBits));
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"mappings":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Mappings)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.ListGameFields: TCEAResult;
var
  Fields: TCEAGameFieldArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Fields := FGameModel.GetFields;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Fields) do
    begin
      O := TJSONObject.Create;
      O.Add('field_id', Fields[I].FieldId);
      O.Add('display_name', Fields[I].DisplayName);
      O.Add('value_type', Fields[I].ValueType);
      O.Add('value', Fields[I].ValueJson);
      O.Add('source', Fields[I].Source);
      O.Add('access', FieldAccessText(Fields[I].Access));
      O.Add('validation_status', ValidationStatusText(Fields[I].ValidationStatus));
      O.Add('address_hex', Fields[I].AddressHex);
      O.Add('last_updated', Fields[I].LastUpdated);
      // Chain metadata lets a client tell an absolute snapshot apart from a
      // re-resolvable location (real-game verification).
      O.Add('module_name', Fields[I].ModuleName);
      O.Add('pointer_offsets_json', Fields[I].PointerOffsetsJson);
      O.Add('address_width_bits', Integer(Fields[I].AddressWidthBits));
      O.Add('has_pointer_chain', Fields[I].HasPointerChain);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"fields":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Fields)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.SaveGameProfile: TCEAResult;
var
  Identity: TCEProcessIdentity;
  Profile: TCEAGameProfile;
  UiSchemaJson: string;
  Page: TCEAUiPage;
  PageSchema: string;
begin
  if (FProfileService = nil) or (FGameModel = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  if FGameModel.FieldCount = 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_has_no_fields', '{}'));
  // The UI schema travels with the profile so a restore brings back the same
  // panel layout (FR-055). It is optional: a session without a saved page still
  // produces a usable profile.
  UiSchemaJson := '';
  if FUiPageStore <> nil then
    if FUiPageStore.GetActivePage(Page, PageSchema).Code = rcOk then
      UiSchemaJson := PageSchema;
  Result := FProfileService.SaveFromModel(FGameModel, 'win32_memory',
    UiSchemaJson, '', Profile);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"profile_id":"' + JsonEscapeText(Profile.Id) +
    '","game_name":"' + JsonEscapeText(Profile.GameName) +
    '","game_version":"' + JsonEscapeText(Profile.GameVersion) +
    '","field_count":' + IntToStr(FGameModel.FieldCount) +
    ',"has_ui_schema":' + JsonBool(UiSchemaJson <> '') + '}');
end;

function TCEAStandaloneRuntime.RestoreGameProfile(
  const AGameName: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
  Profile: TCEAGameProfile;
  Match: TCEAProfileMatchResult;
  Restored, Downgraded, I: Integer;
  Fields: TCEAGameFieldArray;
begin
  if (FProfileService = nil) or (FGameModel = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if Trim(AGameName) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'game_name_required', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  Result := FProfileService.LoadForGame(Trim(AGameName),
    Identity.ExecutableSha256, Identity.ModuleSetHash, Profile, Match);
  if Result.Failed then Exit;
  Result := FProfileService.RestoreInto(Profile, FGameModel, Restored);
  if Result.Failed then Exit;
  // FR-062: on a version mismatch the profile is still usable as a field
  // inventory, but its addresses are not trustworthy for the new build, so
  // every restored field is downgraded to invalid instead of silently
  // pretending it still works. The user re-declares or re-verifies it.
  Downgraded := 0;
  if not Match.Compatible then
  begin
    Fields := FGameModel.GetFields;
    for I := 0 to High(Fields) do
      if Fields[I].Source = 'win32_memory' then
      begin
        Fields[I].Access := faInvalid;
        FGameModel.UpdateField(Fields[I]);
        Inc(Downgraded);
      end;
  end;
  Result := TCEAResult.Ok('{"profile_id":"' + JsonEscapeText(Profile.Id) +
    '","compatible":' + JsonBool(Match.Compatible) +
    ',"reason":"' + JsonEscapeText(Match.Reason) +
    '","restored":' + IntToStr(Restored) +
    ',"downgraded":' + IntToStr(Downgraded) +
    ',"invalidation_reason":"' + JsonEscapeText(Profile.InvalidationReason) +
    '"}');
end;

function TCEAStandaloneRuntime.ConfirmFieldWritable(const AFieldId,
  ATargetValue, AExpectedCurrentValue: string): TCEAResult;
var
  Field, Updated: TCEAGameField;
  Identity: TCEProcessIdentity;
  Address: QWord;
  ExpectedBytes, ReplacementBytes: TBytes;
  Alignment: Cardinal;
  WriteResult: TCEAResult;
  CurrentResult: TCEAResult;
  CurrentData: TJSONData;
  AfterHex: string;
  Journaled: Boolean;
  EvidenceResult: TCEAResult;
  Evidence: TCEAFieldEvidence;
  EvidenceId: string;
  EvidenceRecorded: Boolean;
begin
  if (FGameModel = nil) or (FEffectBackend = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  // FR-054: writing is a separate permission from reading. The session grant is
  // checked before anything touches the target, so a caller that never enabled
  // writes cannot reach the verification write by any path.
  Result := CheckWriteAccess(FWriteAccess, Identity.Id, Identity.Epoch);
  if Result.Failed then Exit;
  // FR-040: the verification write is the transition pending_write ->
  // verified_writable. A read_only field has not been asked for yet, so
  // verifying it would promote a field the operator never intended to write;
  // an invalid field has lost its address and must be re-resolved first.
  // `faReadOnly` also names a file attribute in SysUtils ($01), and this unit
  // re-exports SysUtils through its dependency chain, so the bare name resolves
  // to the file attribute. It must be unit-qualified or the comparison silently
  // runs against faPendingWrite (ordinal 1) instead of read_only (ordinal 0).
  if Field.Access = cea_field_model.faReadOnly then
    Exit(TCEAResult.Error(rcUnauthorized, CeaWriteAccessNotRequestedCode,
      '{"hint":"call request_field_write before verifying a field",' +
      '"field_id":"' + JsonEscapeText(AFieldId) + '"}'));
  if Field.HasPointerChain then
  begin
    Result := ResolvePointerFieldAddress(AFieldId, Field);
    if Result.Failed then Exit;
  end;
  if (Field.AddressHex = '') or (Copy(Field.AddressHex, 1, 2) <> '0x') or
     not TryStrToQWord('$' + Copy(Field.AddressHex, 3, MaxInt), Address) or
     (Address = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'field_address_invalid', '{}'));

  Result := EncodeExactValue(Field.ValueType, AExpectedCurrentValue,
    ExpectedBytes, Alignment);
  if Result.Failed then Exit;
  Result := EncodeExactValue(Field.ValueType, ATargetValue,
    ReplacementBytes, Alignment);
  if Result.Failed then Exit;
  // FR-041: the field's own declared range wins over the caller's intent. This
  // runs before the effect so a rejected value never reaches the process.
  Result := CheckFieldConstraints(Field, ATargetValue);
  if Result.Failed then Exit;

  // Bootstrap verification write: this is the write -> reread -> match step
  // that promotes a field to verified_writable (FR-040 / AC-006).
  WriteResult := FEffectBackend.CompareWriteReadback(Identity.Pid, Address,
    BytesToHexLower(ExpectedBytes), BytesToHexLower(ReplacementBytes));
  if WriteResult.Failed then
  begin
    Updated := Field;
    Updated.Access := faInvalid;
    Updated.LastUpdated := FClock.UtcNowIso8601;
    FGameModel.UpdateField(Updated);
    // FR-046: a failed verification write is still an operation on the target
    // process and must be visible in the history.
    JournalWrite(Field, Identity, CeaWriteAdapterDirectVerify,
      AExpectedCurrentValue, ATargetValue, 'rejected', WriteResult.StableCode,
      WriteResult.StableCode, WriteResult.DataJson, False, False, Journaled);
    Exit(WriteResult);
  end;

  CurrentResult := FEffectBackend.ReadCurrentHex(Identity.Pid, Address,
    Length(ReplacementBytes));
  if CurrentResult.Failed then
  begin
    JournalWrite(Field, Identity, CeaWriteAdapterDirectVerify,
      AExpectedCurrentValue, ATargetValue, 'sent_not_applied',
      CurrentResult.StableCode, CurrentResult.StableCode, CurrentResult.DataJson,
      True, False, Journaled);
    Exit(CurrentResult);
  end;
  CurrentData := nil;
  try
    CurrentData := GetJSON(CurrentResult.DataJson);
    if (CurrentData <> nil) and (CurrentData.JSONType = jtObject) then
      AfterHex := TJSONObject(CurrentData).Get('current', '');
  finally
    CurrentData.Free;
  end;
  if not SameText(AfterHex, BytesToHexLower(ReplacementBytes)) then
  begin
    Updated := Field;
    Updated.Access := faInvalid;
    Updated.LastUpdated := FClock.UtcNowIso8601;
    FGameModel.UpdateField(Updated);
    JournalWrite(Field, Identity, CeaWriteAdapterDirectVerify,
      AExpectedCurrentValue, ATargetValue, 'overwritten',
      'field_verification_mismatch', 'field_verification_mismatch',
      '{"after":"' + JsonEscapeText(AfterHex) + '"}', True, False, Journaled);
    Exit(TCEAResult.Error(rcVerificationFailed,
      'field_verification_mismatch', '{}'));
  end;

  Updated := Field;
  Updated.ValueJson := ATargetValue;
  Updated.Access := faVerifiedWritable;
  Updated.ValidationStatus := vsVerified;
  Updated.LastUpdated := FClock.UtcNowIso8601;
  FGameModel.UpdateField(Updated);
  JournalWrite(Field, Identity, CeaWriteAdapterDirectVerify,
    AExpectedCurrentValue, ATargetValue, 'verified', 'verified', '',
    WriteResult.DataJson, True, True, Journaled);
  // FR-052: a verified write is the strongest evidence this layer can produce,
  // so it gets its own record with an explicit passing outcome.
  EvidenceId := '';
  EvidenceRecorded := False;
  if FFieldEvidenceService <> nil then
  begin
    EvidenceResult := FFieldEvidenceService.RecordVerification(AFieldId,
      Field.DisplayName, Field.AddressHex, Field.ValueType,
      AExpectedCurrentValue, AfterHex, '{"source":"confirm_field_writable"}',
      Identity, voPass, FClock.UtcNowIso8601, Evidence);
    EvidenceRecorded := not EvidenceResult.Failed;
    if EvidenceRecorded then
      EvidenceId := Evidence.EvidenceId;
  end;
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","access":"verified_writable","validation_status":"verified"' +
    ',"command_sent":true,"verified":true' +
    ',"journal_recorded":' + JsonBool(Journaled) +
    ',"evidence_id":"' + JsonEscapeText(EvidenceId) +
    '","evidence_recorded":' + JsonBool(EvidenceRecorded) + '}');
end;

function TCEAStandaloneRuntime.CaptureFieldValue(
  const AFieldId: string): TCEAResult;
var
  Field, Updated: TCEAGameField;
  Identity: TCEProcessIdentity;
  CaptureResult: TCEAFieldCaptureResult;
  Bytes: TBytes;
  ValueText: string;
  AtMs: Int64;
  ObserveResult, EvidenceResult: TCEAResult;
  Evidence: TCEAFieldEvidence;
  EvidenceId: string;
  EvidenceRecorded: Boolean;
begin
  if (FGameModel = nil) or (FEffectBackend = nil) or (FEventService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  // A chained field is re-resolved on every capture: the stored address is only
  // the previous resolution and would go stale across a restart.
  if Field.HasPointerChain then
  begin
    Result := ResolvePointerFieldAddress(AFieldId, Field);
    if Result.Failed then Exit;
  end;
  if (FCaptureService = nil) or (FCapturePid <> Identity.Pid) then
  begin
    FreeAndNil(FCaptureService);
    FCaptureService := TCEAStateCaptureService.Create(FEffectBackend,
      Identity.Pid);
    FCapturePid := Identity.Pid;
    FCaptureIdentityId := Identity.Id;
    FCaptureEpoch := Identity.Epoch;
  end
  else if (FCaptureIdentityId <> Identity.Id) or
          (FCaptureEpoch <> Identity.Epoch) then
  begin
    // A PID may remain stable while module identity / Epoch changes. Do not
    // compare a new target state against values observed under the old identity.
    FCaptureService.ResetBaseline;
    FCaptureIdentityId := Identity.Id;
    FCaptureEpoch := Identity.Epoch;
  end;
  Result := FCaptureService.CaptureField(Field, CaptureResult);
  if Result.Failed then Exit;

  ValueText := CaptureResult.BytesHex;
  if HexToBytes(CaptureResult.BytesHex, Bytes) then
    ValueText := BytesToValueText(Bytes, Field.ValueType);

  // FR-052: a successful read is evidence about this process. Record it before
  // mutating the model so the record keeps the value that was actually observed.
  EvidenceId := '';
  EvidenceRecorded := False;
  if FFieldEvidenceService <> nil then
  begin
    EvidenceResult := FFieldEvidenceService.RecordCapture(AFieldId,
      Field.DisplayName, Field.AddressHex, Field.ValueType, Field.ValueJson,
      ValueText, '{"source":"capture_field_value"}', Identity,
      FClock.UtcNowIso8601, Evidence);
    EvidenceRecorded := not EvidenceResult.Failed;
    if EvidenceRecorded then
      EvidenceId := Evidence.EvidenceId;
  end;

  Updated := Field;
  Updated.ValueJson := ValueText;
  Updated.LastUpdated := FClock.UtcNowIso8601;
  FGameModel.UpdateField(Updated);

  // Feed the unified timeline / change-trigger layer (FR-072, FR-075).
  AtMs := Int64(GetTickCount64);
  ObserveResult := FEventService.ObserveField(AFieldId, ValueText, AtMs,
    Identity.Id, Identity.Epoch);

  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","value":"' + JsonEscapeText(ValueText) +
    '","bytes_hex":"' + JsonEscapeText(CaptureResult.BytesHex) +
    '","changed":' + JsonBool(CaptureResult.Changed) +
    ',"captured_at_ms":' + IntToStr(AtMs) +
    ',"event_triggered":' +
    JsonBool((not ObserveResult.Failed) and
      (Pos('"triggered":true', ObserveResult.DataJson) > 0)) +
    ',"evidence_id":"' + JsonEscapeText(EvidenceId) +
    '","evidence_recorded":' + JsonBool(EvidenceRecorded) + '}');
end;

function TCEAStandaloneRuntime.WriteFieldValue(const AFieldId, ATargetValue,
  AExpectedCurrentValue: string): TCEAResult;
var
  Field: TCEAGameField;
  Identity: TCEProcessIdentity;
  Command: TCEAFieldWriteCommand;
  WriteResult: TCEAFieldWriteResult;
  Bus: TCEAFieldCommandBus;
  OutcomeText: string;
  Journaled: Boolean;
begin
  if (FGameModel = nil) or (FEffectBackend = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  // FR-054: writes need their own session grant. Reading a field and writing it
  // are different permissions; a session that only ever enabled reads cannot
  // reach the target through this path.
  Result := CheckWriteAccess(FWriteAccess, Identity.Id, Identity.Epoch);
  if Result.Failed then Exit;
  // Re-resolve a chained field right before writing: a write to a stale address
  // would either fail or corrupt an unrelated value.
  if Field.HasPointerChain then
  begin
    Result := ResolvePointerFieldAddress(AFieldId, Field);
    if Result.Failed then Exit;
  end;

  // FR-041: refuse a value the field's own constraints reject before the
  // command bus ever sees it, so the target process is never touched.
  Result := CheckFieldConstraints(Field, ATargetValue);
  if Result.Failed then Exit;

  FillChar(Command, SizeOf(Command), 0);
  Command.FieldId := AFieldId;
  Command.ValueType := Field.ValueType;
  Command.TargetValue := ATargetValue;
  Command.ExpectedCurrentValue := AExpectedCurrentValue;
  Command.AddressHex := Field.AddressHex;

  Bus := TCEAFieldCommandBus.Create(FEffectBackend, Identity.Pid,
    Identity.ExecutableSha256);
  try
    Result := Bus.ExecuteWrite(Field, Command, WriteResult);
  finally
    Bus.Free;
  end;

  OutcomeText := CommandOutcomeText(WriteResult.Outcome);
  // FR-046: every field write leaves a durable audit record. The command bus
  // bypasses the governance ledger (no Effect/Receipt/Proof), so without this
  // line the operator path would be completely unaudited.
  JournalWrite(Field, Identity, CeaWriteAdapterCommandBus, AExpectedCurrentValue,
    ATargetValue, OutcomeText, WriteResult.StableCode,
    WriteResult.StableCode, WriteResult.DetailJson,
    WriteResult.Outcome <> coRejected, WriteResult.Outcome = coVerified,
    Journaled);
  // Two-level feedback (FR-044 / AC-007): a submitted command is not a
  // verified state change.
  Result.DataJson := '{"field_id":"' + JsonEscapeText(AFieldId) +
    '","outcome":"' + OutcomeText +
    '","stable_code":"' + JsonEscapeText(WriteResult.StableCode) +
    '","command_sent":' +
    JsonBool(WriteResult.Outcome <> coRejected) +
    ',"verified":' +
    JsonBool(WriteResult.Outcome = coVerified) +
    ',"journal_recorded":' + JsonBool(Journaled) +
    ',"detail":' + WriteResult.DetailJson + '}';
  if Result.Failed then Exit;

  // The write path is the only place a field may be promoted.
  Field.ValueJson := ATargetValue;
  Field.Access := faVerifiedWritable;
  Field.ValidationStatus := vsVerified;
  Field.LastUpdated := FClock.UtcNowIso8601;
  FGameModel.UpdateField(Field);
end;

function TCEAStandaloneRuntime.PreviewFieldWrite(const AFieldId, ATargetValue,
  AExpectedCurrentValue: string): TCEAResult;
var
  Field: TCEAGameField;
  Identity: TCEProcessIdentity;
  Address: QWord;
  ExpectedBytes, ReplacementBytes: TBytes;
  Alignment: Cardinal;
  LiveResult: TCEAResult;
  LiveData: TJSONData;
  LiveHex, LiveText, LiveCode: string;
  Preview: TCEAWritePreview;
begin
  if (FGameModel = nil) or (FEffectBackend = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  LiveCode := '';
  // A chained field must be re-resolved for the preview as well: showing the
  // original value at a stale address would tell the operator what is *not*
  // about to be overwritten.
  if Field.HasPointerChain then
  begin
    Result := ResolvePointerFieldAddress(AFieldId, Field);
    if Result.Failed then
      // Resolution failure already marked the field invalid, so writability
      // blocks the write; keep the code so the payload still names the reason.
      LiveCode := Result.StableCode;
  end;
  if (Field.AddressHex = '') or (Copy(Field.AddressHex, 1, 2) <> '0x') or
     not TryStrToQWord('$' + Copy(Field.AddressHex, 3, MaxInt), Address) or
     (Address = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'field_address_invalid', '{}'));

  Result := EncodeExactValue(Field.ValueType, AExpectedCurrentValue,
    ExpectedBytes, Alignment);
  if Result.Failed then Exit;
  Result := EncodeExactValue(Field.ValueType, ATargetValue,
    ReplacementBytes, Alignment);
  if Result.Failed then Exit;

  LiveHex := '';
  LiveText := '';
  if LiveCode = '' then
  begin
    LiveResult := FEffectBackend.ReadCurrentHex(Identity.Pid, Address,
      Length(ReplacementBytes));
    if LiveResult.Failed then
      LiveCode := LiveResult.StableCode
    else
    begin
      LiveData := nil;
      try
        LiveData := GetJSON(Utf8JsonText(LiveResult.DataJson));
        if (LiveData <> nil) and (LiveData.JSONType = jtObject) then
          LiveHex := LowerCase(TJSONObject(LiveData).Get('current', ''));
      finally
        LiveData.Free;
      end;
      if LiveHex = '' then
        LiveCode := 'write_preview_live_read_invalid';
    end;
  end;
  if LiveHex <> '' then
  begin
    if HexToBytes(LiveHex, ExpectedBytes) then
      LiveText := BytesToValueText(ExpectedBytes, Field.ValueType);
  end;

  Result := BuildWritePreview(AFieldId, Field.DisplayName, Field.ValueType,
    Field.AddressHex, FieldAccessText(Field.Access), CeaWriteAdapterCommandBus,
    ATargetValue, AExpectedCurrentValue, LiveText, LiveHex,
    Field.HasPointerChain, Preview, LiveCode, Field.ConstraintsJson);
  if Result.Failed then Exit;
  Result.DataJson := Preview.ToJson;
end;

function TCEAStandaloneRuntime.BuildUiRenderJson(
  const APageTitle: string): TCEAResult;
var
  Builder: TCEAUiSchemaBuilder;
  Runtime: TCEAUiSchemaRuntime;
  Schema: TCEAUiSchema;
  Render, Applied: TCEAUiRenderModel;
  Layout: TCEAUiLayoutState;
  LayoutResult: TCEAResult;
  Title: string;
begin
  if (FGameModel = nil) or (FUiRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if FGameModel.FieldCount = 0 then
    Exit(TCEAResult.Error(rcConflict, 'model_empty', '{}'));
  Title := APageTitle;
  if Trim(Title) = '' then
    Title := FGameModel.Fingerprint.GameName;

  Builder := TCEAUiSchemaBuilder.Create;
  try
    Result := Builder.BuildFromModel(FGameModel, Title, Schema);
  finally
    Builder.Free;
  end;
  if Result.Failed then Exit;

  Runtime := FUiRuntime;
  Result := Runtime.Bind(Schema, FGameModel, Int64(GetTickCount64), Render);
  if Result.Failed then Exit;

  // Layout memory is optional: a missing record must not hide components
  // (FR-024 / FR-032).
  if (FUiLayoutStore <> nil) and (Schema.Id <> '') then
  begin
    LayoutResult := FUiLayoutStore.LoadLayout(Schema.Id, Layout);
    if not LayoutResult.Failed then
      if not Runtime.ApplyLayout(Render, Layout, Applied).Failed then
        Render := Applied;
  end;

  Result := TCEAResult.Ok(Runtime.RenderToJson(Render));
end;

function TCEAStandaloneRuntime.EnumerateDisplays: TCEAResult;
var
  Displays: TCEADisplayInfoArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FDisplayEnumerator = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FDisplayEnumerator.EnumerateDisplays(Displays);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Displays) do
    begin
      O := TJSONObject.Create;
      O.Add('display_id', Displays[I].DisplayId);
      O.Add('name', Displays[I].Name);
      O.Add('left', Displays[I].Left);
      O.Add('top', Displays[I].Top);
      O.Add('width', Displays[I].Width);
      O.Add('height', Displays[I].Height);
      O.Add('is_primary', Displays[I].IsPrimary);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"displays":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Displays)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.SaveWindowPlacement(const ASchemaId,
  ADisplayId: string; const ALeft, ATop, AWidth, AHeight,
  AScalePercent: Integer; const AMaximized: Boolean): TCEAResult;
var
  Placement: TCEASecondaryWindowPlacement;
begin
  if FUiLayoutStore = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  FillChar(Placement, SizeOf(Placement), 0);
  Placement.SchemaId := ASchemaId;
  Placement.DisplayId := ADisplayId;
  Placement.Left := ALeft;
  Placement.Top := ATop;
  Placement.Width := AWidth;
  Placement.Height := AHeight;
  Placement.Maximized := AMaximized;
  Placement.ScalePercent := AScalePercent;
  if not Placement.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'window_placement_invalid', '{}'));
  Result := FUiLayoutStore.SavePlacement(Placement);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"schema_id":"' + JsonEscapeText(ASchemaId) +
    '","saved":true}');
end;

function TCEAStandaloneRuntime.LoadWindowPlacement(
  const ASchemaId: string): TCEAResult;
var
  Placement: TCEASecondaryWindowPlacement;
  Displays: TCEADisplayInfoArray;
  Selected: TCEADisplayInfo;
  DisplayResult: TCEAResult;
begin
  if FUiLayoutStore = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FUiLayoutStore.LoadPlacement(ASchemaId, Placement);
  if Result.Failed then Exit;

  // Fallback when the remembered display no longer exists (FR-032).
  Displays := nil;
  if FDisplayEnumerator <> nil then
  begin
    DisplayResult := FDisplayEnumerator.EnumerateDisplays(Displays);
    if DisplayResult.Failed then
      SetLength(Displays, 0);
  end;
  if (Length(Displays) > 0) and
     not PlacementIntersectsAnyDisplay(Placement, Displays) then
  begin
    if FindPrimaryDisplay(Displays, Selected) then
    begin
      Placement.DisplayId := Selected.DisplayId;
      Placement.Left := Selected.Left;
      Placement.Top := Selected.Top;
      Result := TCEAResult.Ok('{"schema_id":"' + JsonEscapeText(ASchemaId) +
        '","display_id":"' + JsonEscapeText(Placement.DisplayId) +
        '","left":' + IntToStr(Placement.Left) +
        ',"top":' + IntToStr(Placement.Top) +
        ',"width":' + IntToStr(Placement.Width) +
        ',"height":' + IntToStr(Placement.Height) +
        ',"maximized":' + JsonBool(Placement.Maximized) +
        ',"scale_percent":' + IntToStr(Placement.ScalePercent) +
        ',"fallback_to_primary":true}');
      Exit;
    end;
  end;
  Result := TCEAResult.Ok('{"schema_id":"' + JsonEscapeText(ASchemaId) +
    '","display_id":"' + JsonEscapeText(Placement.DisplayId) +
    '","left":' + IntToStr(Placement.Left) +
    ',"top":' + IntToStr(Placement.Top) +
    ',"width":' + IntToStr(Placement.Width) +
    ',"height":' + IntToStr(Placement.Height) +
    ',"maximized":' + JsonBool(Placement.Maximized) +
    ',"scale_percent":' + IntToStr(Placement.ScalePercent) +
    ',"fallback_to_primary":false}');
end;

function TCEAStandaloneRuntime.ConfigureFieldChangeRule(const AFieldId,
  ACondition: string; const AThreshold: Double;
  const ACooldownMs: Int64): TCEAResult;
var
  Rule: TCEAFieldChangeRule;
  Condition: TCEAChangeCondition;
begin
  if FEventService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if not TryParseChangeCondition(ACondition, Condition) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_condition_unknown', '{}'));
  FillChar(Rule, SizeOf(Rule), 0);
  Rule.FieldId := AFieldId;
  Rule.Condition := Condition;
  Rule.Threshold := AThreshold;
  Rule.CooldownMs := ACooldownMs;
  Rule.Enabled := True;
  Result := FEventService.ConfigureRule(Rule);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","condition":"' + ChangeConditionText(Condition) +
    '","cooldown_ms":' + IntToStr(ACooldownMs) +
    ',"rules":' + IntToStr(FEventService.RuleCount) + '}');
end;

function TCEAStandaloneRuntime.MarkEvent(const ATag: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
begin
  if FEventService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  Result := FEventService.MarkEvent(Identity.Id, Identity.Epoch,
    Int64(GetTickCount64), ATag);
end;

function TCEAStandaloneRuntime.ListEvents: TCEAResult;
var
  Events: TCEAEventPackageArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FEventService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Events := FEventService.GetEvents;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Events) do
    begin
      O := TJSONObject.Create;
      O.Add('event_id', Events[I].EventId);
      O.Add('trigger_kind', EventTriggerKindText(Events[I].TriggerKind));
      O.Add('trigger_source', Events[I].TriggerSource);
      O.Add('start_at_ms', Events[I].StartAtMs);
      O.Add('end_at_ms', Events[I].EndAtMs);
      O.Add('duration_ms', Events[I].DurationMs);
      O.Add('analysis_state',
        EventAnalysisStateText(Events[I].AnalysisState));
      O.Add('field_snapshots_json', Events[I].FieldSnapshotsJson);
      O.Add('recording_refs_json', Events[I].RecordingRefsJson);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"events":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Events)) +
      ',"suppressed":' + IntToStr(FEventService.SuppressedCount) +
      ',"snapshots":' + IntToStr(FEventService.SnapshotCount) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.DeleteEvent(
  const AEventId: string): TCEAResult;
begin
  if FEventService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FEventService.DeleteEvent(AEventId);
end;

function TCEAStandaloneRuntime.ListFieldWriteHistory(const AFieldId: string;
  const ALimit: Integer): TCEAResult;
var
  Recs: TCEAFieldWriteRecordArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FWriteJournal = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FWriteJournal.ListWrites(AFieldId, ALimit, Recs);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Recs) do
    begin
      O := TJSONObject.Create;
      O.Add('record_id', Recs[I].RecordId);
      O.Add('sequence', Recs[I].Sequence);
      O.Add('field_id', Recs[I].FieldId);
      O.Add('display_name', Recs[I].DisplayName);
      O.Add('value_type', Recs[I].ValueType);
      O.Add('original_value', Recs[I].OriginalValue);
      O.Add('target_value', Recs[I].TargetValue);
      O.Add('adapter_id', Recs[I].AdapterId);
      O.Add('address_hex', Recs[I].AddressHex);
      O.Add('process_identity_id', Recs[I].ProcessIdentityId);
      O.Add('pid', Int64(Recs[I].Pid));
      O.Add('epoch', Int64(Recs[I].Epoch));
      O.Add('outcome', Recs[I].Outcome);
      O.Add('stable_code', Recs[I].StableCode);
      O.Add('error_text', Recs[I].ErrorText);
      O.Add('detail', Recs[I].DetailJson);
      O.Add('command_sent', Recs[I].CommandSent);
      O.Add('verified', Recs[I].Verified);
      O.Add('recorded_at', Recs[I].RecordedAt);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"writes":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Recs)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.ListFieldEvidence(const AFieldId: string;
  const ALimit: Cardinal): TCEAResult;
var
  Items: TCEAFieldEvidenceArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FFieldEvidenceService = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FFieldEvidenceService.ListForField(AFieldId, ALimit, Items);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Items) do
    begin
      O := TJSONObject.Create;
      O.Add('evidence_id', Items[I].EvidenceId);
      O.Add('field_id', Items[I].FieldId);
      O.Add('display_name', Items[I].DisplayName);
      O.Add('kind', EvidenceKindText(Items[I].Kind));
      O.Add('address', Items[I].AddressText);
      O.Add('value_type', Items[I].ValueType);
      O.Add('previous_value', Items[I].PreviousValueJson);
      O.Add('observed_value', Items[I].ObservedValueJson);
      O.Add('process_identity_id', Items[I].ProcessIdentityId);
      O.Add('epoch', Int64(Items[I].Epoch));
      O.Add('executable_sha256', Items[I].ExecutableSha256);
      O.Add('module_set_hash', Items[I].ModuleSetHash);
      O.Add('outcome', EvidenceOutcomeText(Items[I].Outcome));
      O.Add('detail', Items[I].DetailJson);
      O.Add('provenance_uri', Items[I].ProvenanceUri);
      O.Add('content_hash', Items[I].ContentHash);
      O.Add('recorded_at', Items[I].RecordedAt);
      // The two gates are reported so a caller cannot mistake a record for a
      // permission: a user statement names a field, it does not prove it writable.
      O.Add('supports_write_claim',
        IsWriteSupportingKind(Items[I].Kind) and
        IsWriteSupportingOutcome(Items[I].Outcome));
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"evidence":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Items)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.RecordFieldUserConfirmation(
  const AFieldId: string): TCEAResult;
var
  Field: TCEAGameField;
  Identity: TCEProcessIdentity;
  Evidence: TCEAFieldEvidence;
  RecordResult: TCEAResult;
begin
  if (FGameModel = nil) or (FFieldEvidenceService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  RecordResult := FFieldEvidenceService.RecordUserConfirmation(AFieldId,
    Field.DisplayName, Field.AddressHex, Field.ValueType,
    '{"source":"operator_declaration"}', Identity, FClock.UtcNowIso8601,
    Evidence);
  if RecordResult.Failed then Exit(RecordResult);
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","evidence_id":"' + JsonEscapeText(Evidence.EvidenceId) +
    '","kind":"user_statement"' +
    ',"supports_write_claim":false' +
    ',"note":"a user statement names the field, it does not prove writability"'
    + '}');
end;

function DiscoveryRoundJson(const ARound: TCEADiscoveryRound): string;
begin
  Result := '{"round_id":"' + JsonEscapeText(ARound.RoundId) +
    '","sequence":' + IntToStr(ARound.Sequence) +
    ',"kind":"' + DiscoveryRoundKindText(ARound.Kind) +
    '","state":"' + DiscoveryRoundStateText(ARound.State) +
    '","purpose":"' + JsonEscapeText(ARound.Purpose) +
    '","operation":"' + JsonEscapeText(ARound.Operation) +
    '","expected_observation":"' + JsonEscapeText(ARound.ExpectedObservation) +
    '","field_id":"' + JsonEscapeText(ARound.FieldId) +
    '","observed_outcome":"' + JsonEscapeText(ARound.ObservedOutcome) +
    '","matched_expectation":' + JsonBool(ARound.MatchedExpectation) +
    ',"created_at":"' + JsonEscapeText(ARound.CreatedAt) +
    '","completed_at":"' + JsonEscapeText(ARound.CompletedAt) + '"}';
end;

function TCEAStandaloneRuntime.PlanDiscoveryRound(const AKind, APurpose,
  AOperation, AExpectedObservation, AFieldId: string): TCEAResult;
var
  Kind: TCEADiscoveryRoundKind;
  Round: TCEADiscoveryRound;
  PlanResult: TCEAResult;
begin
  if FDiscoveryRounds = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if not TryParseDiscoveryRoundKind(Trim(AKind), Kind) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_kind_invalid', '{}'));
  // 分轮验证只在游戏会话里有意义：不知道在跟哪个进程说话时，
  // 「预期看到什么」无从谈起。
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  PlanResult := FDiscoveryRounds.PlanRound(Kind, APurpose, AOperation,
    AExpectedObservation, AFieldId, FClock.UtcNowIso8601, Round);
  if PlanResult.Failed then Exit(PlanResult);
  Result := TCEAResult.Ok('{"round":' + DiscoveryRoundJson(Round) +
    ',"count":' + IntToStr(FDiscoveryRounds.Count) + '}');
end;

function TCEAStandaloneRuntime.CompleteDiscoveryRound(const ARoundId,
  AObservedOutcome: string; const AMatchedExpectation: Boolean): TCEAResult;
var
  Round: TCEADiscoveryRound;
  FinishResult: TCEAResult;
begin
  if FDiscoveryRounds = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  FinishResult := FDiscoveryRounds.CompleteRound(ARoundId, AObservedOutcome,
    AMatchedExpectation, FClock.UtcNowIso8601, Round);
  if FinishResult.Failed then Exit(FinishResult);
  Result := TCEAResult.Ok('{"round":' + DiscoveryRoundJson(Round) + '}');
end;

function TCEAStandaloneRuntime.AbandonDiscoveryRound(const ARoundId,
  AReason: string): TCEAResult;
var
  Round: TCEADiscoveryRound;
  AbandonResult: TCEAResult;
begin
  if FDiscoveryRounds = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  AbandonResult := FDiscoveryRounds.AbandonRound(ARoundId, AReason,
    FClock.UtcNowIso8601, Round);
  if AbandonResult.Failed then Exit(AbandonResult);
  Result := TCEAResult.Ok('{"round":' + DiscoveryRoundJson(Round) + '}');
end;

function TCEAStandaloneRuntime.ListDiscoveryRounds(
  const ALimit: Cardinal): TCEAResult;
var
  Rounds: TCEADiscoveryRoundArray;
  ListResult: TCEAResult;
  I: Integer;
  Body: string;
begin
  if FDiscoveryRounds = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  ListResult := FDiscoveryRounds.ListRounds(ALimit, Rounds);
  if ListResult.Failed then Exit(ListResult);
  Body := '';
  for I := 0 to High(Rounds) do
  begin
    if Body <> '' then Body := Body + ',';
    Body := Body + DiscoveryRoundJson(Rounds[I]);
  end;
  Result := TCEAResult.Ok('{"rounds":[' + Body + '],"count":' +
    IntToStr(Length(Rounds)) + '}');
end;

function TCEAStandaloneRuntime.CurrentDiscoveryRound: TCEAResult;
var
  Round: TCEADiscoveryRound;
begin
  if FDiscoveryRounds = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FDiscoveryRounds.CurrentRound(Round) then
    Result := TCEAResult.Ok('{"has_active_round":true,"round":' +
      DiscoveryRoundJson(Round) + '}')
  else
    Result := TCEAResult.Ok('{"has_active_round":false,"round":null}');
end;

function DiscoveryGoalJson(const AGoal: TCEADiscoveryGoal): string;
begin
  Result := '{"goal_id":"' + JsonEscapeText(AGoal.GoalId) +
    '","sequence":' + IntToStr(AGoal.Sequence) +
    ',"description":"' + JsonEscapeText(AGoal.Description) +
    '","field_id_hint":"' + JsonEscapeText(AGoal.FieldIdHint) +
    '","value_type_hint":"' + JsonEscapeText(AGoal.ValueTypeHint) +
    '","behavior_hint":"' + JsonEscapeText(AGoal.BehaviorHint) +
    '","rationale":"' + JsonEscapeText(AGoal.Rationale) +
    '","source":"' + DiscoveryGoalSourceText(AGoal.Source) +
    '","state":"' + DiscoveryGoalStateText(AGoal.State) +
    '","advisory":' + JsonBool(AGoal.Advisory) +
    ',"created_at":"' + JsonEscapeText(AGoal.CreatedAt) +
    '","decided_at":"' + JsonEscapeText(AGoal.DecidedAt) +
    '","reject_reason":"' + JsonEscapeText(AGoal.RejectReason) + '"}';
end;

function TCEAStandaloneRuntime.ProposeDiscoveryGoal(const ADescription,
  AFieldIdHint, AValueTypeHint, ABehaviorHint: string): TCEAResult;
var
  Goal: TCEADiscoveryGoal;
  ProposeResult: TCEAResult;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // 目标只在本会话里有意义：不知道在跟哪个游戏说话时，「找金币」
  // 这句话不指任何东西。
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  ProposeResult := FDiscoveryGoals.ProposeFromOperator(ADescription, AFieldIdHint,
    AValueTypeHint, ABehaviorHint, FClock.UtcNowIso8601, Goal);
  if ProposeResult.Failed then Exit(ProposeResult);
  Result := TCEAResult.Ok('{"goal":' + DiscoveryGoalJson(Goal) +
    ',"count":' + IntToStr(FDiscoveryGoals.Count) + '}');
end;

function TCEAStandaloneRuntime.ProposeDiscoveryGoalWithModel(
  const ADescription: string; const AMaxOutputTokens: Cardinal): TCEAResult;
var
  Goal: TCEADiscoveryGoal;
  ProposeResult: TCEAResult;
  Tokens: Cardinal;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if FLLMProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  // 外发的是操作者自己写的那句话，不是内存内容；没有数值要同意，
  // 但模型产出的 hint 恒为 advisory。
  Tokens := AMaxOutputTokens;
  if Tokens = 0 then
    Tokens := 512;
  ProposeResult := FDiscoveryGoals.ProposeFromModel(FLLMProvider, ADescription,
    Tokens, FClock.UtcNowIso8601, Goal);
  if ProposeResult.Failed then Exit(ProposeResult);
  Result := TCEAResult.Ok('{"goal":' + DiscoveryGoalJson(Goal) +
    ',"count":' + IntToStr(FDiscoveryGoals.Count) +
    ',"advisory_only":true' +
    ',"note":"model hints are suggestions, they are not evidence"}' );
end;

function TCEAStandaloneRuntime.AcceptDiscoveryGoal(
  const AGoalId: string): TCEAResult;
var
  Goal: TCEADiscoveryGoal;
  AcceptResult: TCEAResult;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  AcceptResult := FDiscoveryGoals.Accept(AGoalId, FClock.UtcNowIso8601, Goal);
  if AcceptResult.Failed then Exit(AcceptResult);
  // 接受目标只表示「我在找这个」，它不授权任何动作：扫描仍要分轮计划
  // 与治理租约，写入仍要 verified_writable 与二次确认。
  Result := TCEAResult.Ok('{"goal":' + DiscoveryGoalJson(Goal) +
    ',"grants_scan":false,"grants_write":false' +
    ',"note":"accepting a goal states intent, it does not authorise an action"}');
end;

function TCEAStandaloneRuntime.RejectDiscoveryGoal(const AGoalId,
  AReason: string): TCEAResult;
var
  Goal: TCEADiscoveryGoal;
  RejectResult: TCEAResult;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  RejectResult := FDiscoveryGoals.Reject(AGoalId, AReason,
    FClock.UtcNowIso8601, Goal);
  if RejectResult.Failed then Exit(RejectResult);
  Result := TCEAResult.Ok('{"goal":' + DiscoveryGoalJson(Goal) + '}');
end;

function TCEAStandaloneRuntime.ListDiscoveryGoals(
  const ALimit: Cardinal): TCEAResult;
var
  Goals: TCEADiscoveryGoalArray;
  ListResult: TCEAResult;
  I: Integer;
  Body: string;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  ListResult := FDiscoveryGoals.ListGoals(ALimit, Goals);
  if ListResult.Failed then Exit(ListResult);
  Body := '';
  for I := 0 to High(Goals) do
  begin
    if Body <> '' then Body := Body + ',';
    Body := Body + DiscoveryGoalJson(Goals[I]);
  end;
  Result := TCEAResult.Ok('{"goals":[' + Body + '],"count":' +
    IntToStr(Length(Goals)) + '}');
end;

function TCEAStandaloneRuntime.CurrentDiscoveryGoal: TCEAResult;
var
  Goal: TCEADiscoveryGoal;
begin
  if FDiscoveryGoals = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FDiscoveryGoals.CurrentGoal(Goal) then
    Result := TCEAResult.Ok('{"has_active_goal":true,"goal":' +
      DiscoveryGoalJson(Goal) + '}')
  else
    Result := TCEAResult.Ok('{"has_active_goal":false,"goal":null}');
end;

function TCEAStandaloneRuntime.EnableWriteAccess(
  const AReason: string): TCEAResult;
var
  Identity: TCEProcessIdentity;
  ReasonResult: TCEAResult;
begin
  // FR-054: the reason is not decoration. "writes enabled" with no stated reason
  // is indistinguishable from a stale toggle left on from an earlier session,
  // and the journal will later show writes nobody can account for.
  ReasonResult := ValidateWriteAccessReason(AReason);
  if ReasonResult.Failed then Exit(ReasonResult);
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  // The unit function shares this method's name, so it must be unit-qualified;
  // an unqualified call would recurse into this method forever.
  FWriteAccess := cea_write_access.EnableWriteAccess(Identity.Id, Identity.Epoch,
    FClock.UtcNowIso8601, Trim(AReason));
  Result := TCEAResult.Ok('{"enabled":true,' +
    '"reason":"' + JsonEscapeText(FWriteAccess.Reason) + '",' +
    '"process_identity_id":"' + JsonEscapeText(Identity.Id) + '",' +
    '"epoch":' + IntToStr(Identity.Epoch) + ',' +
    '"note":"writes are enabled for this process and epoch only; ' +
    'a new attach or a new game revokes the grant"}');
end;

function TCEAStandaloneRuntime.DisableWriteAccess: TCEAResult;
var
  Previous: TCEAWriteAccess;
begin
  // FR-054: disabling forgets the grant entirely rather than keeping a stale
  // identity around; a later enable must look like a new decision, not the
  // continuation of a grant that was already withdrawn.
  Previous := FWriteAccess;
  FWriteAccess := cea_write_access.DisableWriteAccess;
  Result := TCEAResult.Ok('{"enabled":false,' +
    '"previous_process_identity_id":"' +
    JsonEscapeText(Previous.ProcessIdentityId) + '",' +
    '"note":"the write grant is discarded, not suspended"}');
end;

function TCEAStandaloneRuntime.GetWriteAccess: TCEAResult;
begin
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Result := TCEAResult.Ok('{"write_access":' + WriteAccessJson(FWriteAccess) + '}');
end;

function TCEAStandaloneRuntime.RequestFieldWrite(
  const AFieldId: string): TCEAResult;
var
  Field, Updated: TCEAGameField;
  Identity: TCEProcessIdentity;
  Request: TCEAFieldWriteRequest;
  RequestText: string;
begin
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  if Trim(AFieldId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'field_id_required', '{}'));
  if not FGameModel.GetField(AFieldId, Field) then
    Exit(TCEAResult.Error(rcUnknown, 'field_not_found', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;
  // Requesting a write is not the same as being allowed to write: it states
  // intent, so it still requires the session grant. Without this check a caller
  // could walk a field into pending_write and then use the verification path.
  Result := CheckWriteAccess(FWriteAccess, Identity.Id, Identity.Epoch);
  if Result.Failed then Exit;

  Request := ClassifyWriteRequest(Field.Access);
  RequestText := FieldWriteRequestText(Request);
  if Request <> fwrAccepted then
    // Already pending or already proven: report the state without changing it.
    // Re-declaring intent must not silently downgrade a verified field.
    Exit(TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
      '","request":"' + RequestText +
      '","access":"' + FieldAccessText(Field.Access) +
      '","changed":false}'));

  Updated := Field;
  Updated.Access := FieldAccessAfterRequest(Field.Access);
  Updated.LastUpdated := FClock.UtcNowIso8601;
  if not FGameModel.UpdateField(Updated) then
    Exit(TCEAResult.Error(rcInternalError, 'field_update_failed',
      '{"field_id":"' + JsonEscapeText(AFieldId) + '"}'));
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscapeText(AFieldId) +
    '","request":"' + RequestText +
    '","access":"' + FieldAccessText(Updated.Access) +
    '","changed":true,' +
    '"note":"pending_write is intent, not permission; a write still requires ' +
    'verified_writable"}');
end;

function TCEAStandaloneRuntime.AnalyzeEvent(const AEventId,
  AFieldId: string): TCEAResult;
var
  Events: TCEAEventPackageArray;
  Target: TCEAEventPackage;
  Found: Boolean;
  I, J: Integer;
  Analysis: TCEAEventAnalysis;
  Suggestions: TCEAVerificationSuggestionArray;
  Arr: TJSONArray;
  O: TJSONObject;
begin
  if (FEventService = nil) or (FEventAnalysisService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if Trim(AEventId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_id_required', '{}'));

  Events := FEventService.GetEvents;
  Found := False;
  FillChar(Target, SizeOf(Target), 0);
  for I := 0 to High(Events) do
    if Events[I].EventId = AEventId then
    begin
      Target := Events[I];
      Found := True;
      Break;
    end;
  if not Found then
    Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));

  // FR-094：分析过的事件在时间线上要能看出已分析，否则玩家无法区分
  // 「还没看」和「看过了、结论是推断级」。
  if Target.AnalysisState = eaUnanalyzed then
    FEventService.MarkAnalysisState(AEventId, eaAnalyzed);

  Result := FEventAnalysisService.Analyze(Target, Events, AFieldId, Analysis);
  if Result.Failed then
    Exit;

  Arr := TJSONArray.Create;
  try
    Suggestions := Analysis.Suggestions;
    for J := 0 to High(Suggestions) do
    begin
      O := TJSONObject.Create;
      O.Add('suggestion_id', Suggestions[J].SuggestionId);
      O.Add('kind', Suggestions[J].Kind);
      O.Add('field_id', Suggestions[J].FieldId);
      O.Add('text', Suggestions[J].Text);
      // 建议只是建议：UI 不得把它渲染成可执行按钮（FR-093）。
      O.Add('advisory', Suggestions[J].Advisory);
      O.Add('requires_approval', Suggestions[J].RequiresApproval);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"event_id":"' + Analysis.EventId +
      '","grade":"' + EvidenceGradeText(Analysis.Grade) +
      '","grade_reason":"' + Analysis.GradeReason +
      '","write_justifying":' +
      JsonBool(IsWriteJustifyingGrade(Analysis.Grade)) +
      ',"advisory_only":' +
      JsonBool(IsAdvisoryGrade(Analysis.Grade)) +
      ',"has_trend":' + JsonBool(Analysis.HasTrend) +
      ',"trend":' + TrendJson(Analysis.Trend) +
      ',"digest":' + Analysis.DigestJson +
      ',"suggestions":' + Arr.AsJSON +
      ',"suggestion_count":' + IntToStr(Length(Suggestions)) +
      ',"cloud_used":false}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.CorrelateEventField(
  const AFieldId: string): TCEAResult;
var
  Events: TCEAEventPackageArray;
  Trend: TCEAFieldTrend;
begin
  if (FEventService = nil) or (FEventAnalysisService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Events := FEventService.GetEvents;
  Result := FEventAnalysisService.CorrelateField(Events, AFieldId, Trend);
end;

function TCEAStandaloneRuntime.SuggestEventVerification(
  const AEventId: string): TCEAResult;
var
  Events: TCEAEventPackageArray;
  Target: TCEAEventPackage;
  Suggestions: TCEAVerificationSuggestionArray;
  Found: Boolean;
  I, J: Integer;
  Arr: TJSONArray;
  O: TJSONObject;
begin
  if (FEventService = nil) or (FEventAnalysisService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if Trim(AEventId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_id_required', '{}'));
  Events := FEventService.GetEvents;
  Found := False;
  FillChar(Target, SizeOf(Target), 0);
  for I := 0 to High(Events) do
    if Events[I].EventId = AEventId then
    begin
      Target := Events[I];
      Found := True;
      Break;
    end;
  if not Found then
    Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));

  Suggestions := FEventAnalysisService.SuggestVerification(Target, Events);
  Arr := TJSONArray.Create;
  try
    for J := 0 to High(Suggestions) do
    begin
      O := TJSONObject.Create;
      O.Add('suggestion_id', Suggestions[J].SuggestionId);
      O.Add('kind', Suggestions[J].Kind);
      O.Add('field_id', Suggestions[J].FieldId);
      O.Add('text', Suggestions[J].Text);
      O.Add('advisory', Suggestions[J].Advisory);
      O.Add('requires_approval', Suggestions[J].RequiresApproval);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"event_id":"' + AEventId +
      '","suggestions":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Suggestions)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.AnalyzeEventWithProvider(const AEventId,
  AFieldId: string; const AConsentToSendValues: Boolean): TCEAResult;
var
  Events: TCEAEventPackageArray;
  Target: TCEAEventPackage;
  Found: Boolean;
  I: Integer;
  Analysis: TCEAEventAnalysis;
  Content: UnicodeString;
begin
  if (FEventService = nil) or (FEventAnalysisService = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // 外发必须每次显式同意：调用方不传 true 就 fail closed（FR-080）。
  if not AConsentToSendValues then
    Exit(TCEAResult.Error(rcApprovalRequired, 'cloud_consent_required',
      '{"approval_surface":"local_ui_only"}'));
  if FLLMProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));

  Events := FEventService.GetEvents;
  Found := False;
  FillChar(Target, SizeOf(Target), 0);
  for I := 0 to High(Events) do
    if Events[I].EventId = AEventId then
    begin
      Target := Events[I];
      Found := True;
      Break;
    end;
  if not Found then
    Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));

  Result := FEventAnalysisService.Analyze(Target, Events, AFieldId, Analysis);
  if Result.Failed then
    Exit;
  Result := FEventAnalysisService.AskProvider(FLLMProvider, Analysis, True,
    1024, Content);
  if Result.Failed then
    Exit;
  // 模型回答只是推断，显式标注 advisory，永不升级为可写依据（FR-084/091）。
  Result := TCEAResult.Ok('{"event_id":"' + AEventId +
    '","grade":"' + EvidenceGradeText(Analysis.Grade) +
    '","advisory_only":true' +
    ',"content":' + UTF8String(JsonEscapeUnicode(Content)) +
    ',"cloud_used":true' +
    ',"note":"model output is inference, not evidence"}');
end;

function TCEAStandaloneRuntime.StartEventRecording(
  const AStorageDirectory: string; const AFrameIntervalMs: Int64;
  const ACacheDurationMs: Int64; const AMaxDiskBytes: QWord;
  const ARetentionMs: Int64): TCEAResult;
var
  Identity: TCEProcessIdentity;
  WindowHandle: HWND;
  Title, Reason, Dir: string;
  Policy: TCEARecordingPolicy;
  LocateResult: TCEAResult;
  FrameSource: TCEAWin32WindowFrameSource;
  Capture: TCEAWin32RecordingCapture;
  Cache: TCEARecordingService;
  Bridge: TCEAEventRecordingBridge;
begin
  if not FStarted or (FEventService = nil) or (FWindowLocator = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FRecordingBridge <> nil then
    Exit(TCEAResult.Error(rcConflict, 'event_recording_already_active', '{}'));
  Result := CurrentIdentity(Identity);
  if Result.Failed then Exit;

  // 按 PID 找主窗口：录像帧源需要一个 HWND，运行时只知道 PID。
  LocateResult := FWindowLocator.FindMainWindow(Identity.Pid, WindowHandle,
    Title);
  if LocateResult.Failed then Exit(LocateResult);

  if Trim(AStorageDirectory) <> '' then
    Dir := Trim(AStorageDirectory)
  else
    Dir := IncludeTrailingPathDelimiter(ExtractFileDir(FDatabasePath)) +
      CeaRecordingStorageDirectoryName;

  FrameSource := TCEAWin32WindowFrameSource.Create(WindowHandle, False);
  Capture := TCEAWin32RecordingCapture.Create(FrameSource, Dir,
    AFrameIntervalMs);
  if not Capture.ProbeSupport(Reason) then
  begin
    Capture.Free;
    FrameSource.Free;
    Exit(TCEAResult.Error(rcConflict, 'event_recording_unavailable',
      '{"reason":"' + JsonEscapeText(Reason) + '"}'));
  end;

  Policy.CacheDurationMs := ACacheDurationMs;
  Policy.MaxDiskBytes := AMaxDiskBytes;
  Policy.RetentionMs := ARetentionMs;
  if not Policy.IsValid then
  begin
    Capture.Free;
    FrameSource.Free;
    Exit(TCEAResult.Error(rcInvalidArgument, 'recording_policy_invalid', '{}'));
  end;
  Cache := TCEARecordingService.Create(Policy);
  Bridge := TCEAEventRecordingBridge.Create(Capture, Cache);

  // 旧缓存（Start 时建的空缓存）被替换成这次会话的缓存
  FreeAndNil(FRecordingCache);
  FRecordingCache := Cache;
  FRecordingCapture := Capture;
  FFrameSource := FrameSource;
  FRecordingBridge := Bridge;
  FRecordingPid := Identity.Pid;
  FRecordingStorageDir := Dir;
  FEventService.SetRecorder(Bridge);

  Result := TCEAResult.Ok('{"active":true' +
    ',"pid":' + IntToStr(Identity.Pid) +
    ',"window_handle":"0x' + IntToHex(PtrUInt(WindowHandle), 16) + '"' +
    ',"window_title":"' + JsonEscapeText(Title) + '"' +
    ',"storage_directory":"' + JsonEscapeText(Dir) + '"' +
    ',"frame_interval_ms":' + IntToStr(AFrameIntervalMs) + '}');
end;

procedure TCEAStandaloneRuntime.StopEventRecording;
begin
  // 先解除事件服务持有的引用，再释放桥（桥持有捕获器）。
  if FEventService <> nil then
    FEventService.SetRecorder(nil);
  FreeAndNil(FRecordingBridge);
  FreeAndNil(FFrameSource);
  FreeAndNil(FRecordingCapture);
  FRecordingPid := 0;
  FRecordingStorageDir := '';
end;

function TCEAStandaloneRuntime.EventRecordingActive: Boolean;
begin
  Result := (FRecordingBridge <> nil) and (FRecordingCapture <> nil);
end;

function TCEAStandaloneRuntime.EventRecordingEndpoint: string;
begin
  if not EventRecordingActive then
    Exit('');
  Result := FRecordingStorageDir;
end;

function TCEAStandaloneRuntime.ListRecordingSegments: TCEAResult;
var
  Segments: TCEARecordingSegmentArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FRecordingCache = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Segments := FRecordingCache.GetSegments;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Segments) do
    begin
      O := TJSONObject.Create;
      O.Add('segment_id', Segments[I].Id);
      O.Add('started_at_ms', Segments[I].StartedAtMs);
      O.Add('ended_at_ms', Segments[I].EndedAtMs);
      O.Add('duration_ms', Segments[I].DurationMs);
      O.Add('frame_count', Int64(Segments[I].FrameCount));
      O.Add('size_bytes', Int64(Segments[I].SizeBytes));
      O.Add('storage_ref', Segments[I].StorageRef);
      O.Add('locked', Segments[I].Locked);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"segments":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Segments)) +
      ',"total_bytes":' + IntToStr(FRecordingCache.TotalSizeBytes) +
      ',"active":' + JsonBool(EventRecordingActive) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.SetRecordingSegmentLocked(
  const ASegmentId: string; const ALocked: Boolean): TCEAResult;
begin
  if FRecordingCache = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FRecordingCache.SetLocked(ASegmentId, ALocked);
end;

function TCEAStandaloneRuntime.QueueEventForAnalysis(
  const AEventId: string): TCEAResult;
var
  Event: TCEAEventPackage;
begin
  if (FEventService = nil) or (FWakeQueue = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if Trim(AEventId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_id_required', '{}'));
  if not FEventService.GetEvent(AEventId, Event) then
    Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));
  // eaQueued 会在事件服务里生成结构化摘要并送入队列（FR-078/077）。
  Result := FEventService.MarkAnalysisState(AEventId, eaQueued);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"event_id":"' + JsonEscapeText(AEventId) +
    '","analysis_state":"queued","queued":' +
    IntToStr(FWakeQueue.QueueLength) +
    ',"dropped":' + IntToStr(FWakeQueue.DroppedCount) + '}');
end;

function TCEAStandaloneRuntime.PeekAnalysisQueue: TCEAResult;
var
  EventId, ContextJson: string;
  Arr: TJSONArray;
begin
  if FWakeQueue = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // 只读快照：不在这里出队，避免 MCP 调用悄悄消费掉本地待办。
  Arr := TJSONArray.Create;
  try
    if FWakeQueue.Peek(EventId, ContextJson) then
      Arr.Add(EventId);
    Result := TCEAResult.Ok('{"queued":' + IntToStr(FWakeQueue.QueueLength) +
      ',"dropped":' + IntToStr(FWakeQueue.DroppedCount) +
      ',"next_event_id":"' + JsonEscapeText(EventId) +
      '","pending":' + Arr.AsJSON + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.LoadGcmCatalog: TCEAResult;
begin
  if FGcmCatalog = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FGcmCatalog.Reload;
end;

function TCEAStandaloneRuntime.MatchGcmGame(const AProcessName: string;
  const AMinScore: Integer): TCEAResult;
var
  Found: TCEAGameMatchResult;
begin
  if FGcmCatalog = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if not FGcmCatalog.Loaded then
  begin
    Result := FGcmCatalog.Load;
    if Result.Failed then Exit;
  end;
  Result := FGcmCatalog.MatchProcessName(AProcessName, AMinScore, Found);
end;

function TCEAStandaloneRuntime.SearchGcmGames(const AText: string): TCEAResult;
begin
  if FGcmCatalog = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if not FGcmCatalog.Loaded then
  begin
    Result := FGcmCatalog.Load;
    if Result.Failed then Exit;
  end;
  Result := FGcmCatalog.SearchGames(AText, 50);
end;

function TCEAStandaloneRuntime.ScanGcmCheatFiles: TCEAResult;
var
  Candidates: TCEACheatFileCandidateArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FGcmCheatLibrary = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FGcmCheatLibrary.ScanGcmLibrary(Candidates);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Candidates) do
    begin
      O := TJSONObject.Create;
      O.Add('file_path', Candidates[I].FilePath);
      O.Add('file_name', UTF8Encode(Candidates[I].FileName));
      O.Add('game_name', UTF8Encode(Candidates[I].GameName));
      O.Add('origin', UTF8Encode(Candidates[I].Origin));
      O.Add('version', UTF8Encode(Candidates[I].Version));
      O.Add('size_bytes', Int64(Candidates[I].SizeBytes));
      O.Add('source', CheatFileSourceName(Candidates[I].Source));
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"candidates":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Candidates)) +
      ',"trainers_directory":"' + FGcmCheatLibrary.TrainersDirectory + '"}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.ImportCheatFile(const APath: string): TCEAResult;
var
  Candidate: TCEACheatFileCandidate;
begin
  if FGcmCheatLibrary = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FGcmCheatLibrary.ImportFromPath(APath, Candidate);
end;

function TCEAStandaloneRuntime.PublishCheatFile(
  const ASourcePath: string): TCEAResult;
var
  Candidate: TCEACheatFileCandidate;
  Published: TCEACheatFilePublishResult;
  Imported: TCEAResult;
begin
  if (FGcmCheatLibrary = nil) or (FGcmCheatPublisher = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Imported := FGcmCheatLibrary.ImportFromPath(ASourcePath, Candidate);
  if Imported.Failed then Exit(Imported);
  Result := FGcmCheatPublisher.Publish(Candidate, Published);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"published_path":"' + Published.PublishedPath +
    '","sha256":"' + Published.Candidate.ContentHash +
    '","replaced":' + JsonBool(Published.Replaced) + '}');
end;

function TCEAStandaloneRuntime.ListPublishedCheatFiles: TCEAResult;
var
  Candidates: TCEACheatFileCandidateArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if FGcmCheatPublisher = nil then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Result := FGcmCheatPublisher.ListPublished(Candidates);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Candidates) do
    begin
      O := TJSONObject.Create;
      O.Add('file_path', Candidates[I].FilePath);
      O.Add('file_name', UTF8Encode(Candidates[I].FileName));
      O.Add('game_name', UTF8Encode(Candidates[I].GameName));
      O.Add('sha256', Candidates[I].ContentHash);
      O.Add('size_bytes', Int64(Candidates[I].SizeBytes));
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"files":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Candidates)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.TranslateCheatFileDescriptions(
  const APath: string; const ACancellation: ICEACancellationToken): TCEAResult;
var
  Artifact: TCTArtifact;
  Translator: TCEAGcmDescriptionTranslator;
  Batch: TCEADescriptionBatch;
  Parsed: TCEAResult;
  I: Integer;
  Items: TJSONArray;
  O: TJSONObject;
begin
  if not FStarted or (FCTParser = nil) then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  // Translation needs a live provider; without one the caller should get a
  // clear "configure the LLM" answer instead of an empty success.
  if FLLMProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  Parsed := FCTParser.ParseFile(APath, 'file://local/' +
    ExtractFileName(APath), Artifact);
  if Parsed.Failed then Exit(Parsed);
  Translator := TCEAGcmDescriptionTranslator.Create(FLLMProvider);
  try
    Result := Translator.Translate(Artifact, Batch, ACancellation);
    if Result.Failed then Exit;
    Items := TJSONArray.Create;
    try
      for I := 0 to High(Batch.Entries) do
      begin
        O := TJSONObject.Create;
        O.Add('source', UTF8Encode(Batch.Entries[I].SourceText));
        O.Add('target', UTF8Encode(Batch.Entries[I].TranslatedText));
        O.Add('translated', Batch.Entries[I].Translated);
        Items.Add(O);
      end;
      Result := TCEAResult.Ok('{"source_uri":"' + Artifact.SourceUri +
        '","sha256":"' + Batch.ContentHash +
        '","disclaimer":"' + CeaTranslationDisclaimer +
        '","requests":' + IntToStr(Batch.RequestCount) +
        ',"count":' + IntToStr(Batch.Count) +
        ',"translated":' + IntToStr(Batch.TranslatedCount) +
        ',"entries":' + Items.AsJSON + '}');
    finally
      Items.Free;
    end;
  finally
    Translator.Free;
  end;
end;

function TCEAStandaloneRuntime.StartSecondaryScreen(
  const AEnableWrites: Boolean; const APreferredPort, AAttempts: Word): TCEAResult;
var
  SelectedPort: Word;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FSecondaryScreen <> nil then
    Exit(TCEAResult.Error(rcConflict, 'secondary_screen_already_running', '{}'));
  FSecondaryScreen := TCEASecondaryScreenHost.Create(GenerateMCPToken);
  FSecondaryScreen.OnRender := @SecondaryScreenRender;
  // 多页面（FR-033）：副屏可以列页并切页，切页只改呈现、不写目标内存。
  FSecondaryScreen.OnListPages := @SecondaryScreenListPages;
  FSecondaryScreen.OnSelectPage := @SecondaryScreenSelectPage;
  // Writes are opt-in. When disabled the host answers 403 for /api/write,
  // so the page can never become a bypass around the governed write path.
  if AEnableWrites then
    FSecondaryScreen.OnWrite := @SecondaryScreenWrite;
  Result := FSecondaryScreen.Start(APreferredPort, AAttempts, SelectedPort);
  if Result.Failed then
  begin
    FreeAndNil(FSecondaryScreen);
    FSecondaryScreenPort := 0;
    Exit;
  end;
  FSecondaryScreenPort := SelectedPort;
  Result := TCEAResult.Ok('{"endpoint":"' + FSecondaryScreen.Endpoint +
    '","writes_enabled":' + JsonBool(AEnableWrites) +
    ',"port":' + IntToStr(SelectedPort) + '}');
end;

procedure TCEAStandaloneRuntime.StopSecondaryScreen;
begin
  FreeAndNil(FSecondaryScreen);
  FSecondaryScreenPort := 0;
end;

function TCEAStandaloneRuntime.SecondaryScreenEndpoint: string;
begin
  if FSecondaryScreen = nil then Result := ''
  else Result := FSecondaryScreen.Endpoint;
end;

function TCEAStandaloneRuntime.SecondaryScreenRunning: Boolean;
begin
  Result := (FSecondaryScreen <> nil) and (FSecondaryScreenPort <> 0);
end;

function TCEAStandaloneRuntime.SecondaryScreenRender(
  const ALayoutSchemaId: string): TCEAResult;
var
  Page: TCEAUiPage;
  SchemaJson: string;
begin
  // 选中了某个页面就渲染那个页面的 schema（多页面 FR-033 / 回退 FR-026）；
  // 没选中时退回「按状态模型即时生成」的单页视图。
  if (FSecondaryScreenPageId <> '') and (FUiPageStore <> nil) then
  begin
    if not FUiPageStore.GetPage(FSecondaryScreenPageId, Page, SchemaJson).Failed
    then
    begin
      Result := RenderUiSchemaJson(SchemaJson);
      if not Result.Failed then Exit;
    end;
  end;
  Result := BuildUiRenderJson(ALayoutSchemaId);
end;

function TCEAStandaloneRuntime.SecondaryScreenListPages: TCEAResult;
begin
  // 未开会话时也允许列页：页面是本地布局，不依赖进程身份。
  Result := ListUiPages;
end;

function TCEAStandaloneRuntime.SecondaryScreenSelectPage(
  const APageId: string): TCEAResult;
begin
  Result := SetSecondaryScreenPage(APageId);
end;

function TCEAStandaloneRuntime.SecondaryScreenWrite(const AFieldId,
  ATargetValue, AExpectedCurrentValue: string): TCEAResult;
begin
  Result := WriteFieldValue(AFieldId, ATargetValue, AExpectedCurrentValue);
end;

{ ---------------------------------------------------------------------------
  1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025 / FR-026 / FR-033）

  页面存的是「schema JSON」而不是「状态模型快照」：字段的当前值永远来自
  实时状态模型，页面只决定布局与组件。因此回退一个旧版本只会换回旧布局，
  绝不会把旧数值写回游戏。
  --------------------------------------------------------------------------- }

function TCEAStandaloneRuntime.RenderUiSchemaJson(
  const ASchemaJson: string): TCEAResult;
var
  Codec: TCEAUiSchemaCodec;
  Schema: TCEAUiSchema;
  Render, Applied: TCEAUiRenderModel;
  Layout: TCEAUiLayoutState;
  LayoutResult: TCEAResult;
begin
  if (FGameModel = nil) or (FUiRuntime = nil) then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Codec := TCEAUiSchemaCodec.Create;
  try
    Result := Codec.Decode(ASchemaJson, Schema);
  finally
    Codec.Free;
  end;
  if Result.Failed then Exit;

  Result := FUiRuntime.Bind(Schema, FGameModel, Int64(GetTickCount64), Render);
  if Result.Failed then Exit;

  if (FUiLayoutStore <> nil) and (Schema.Id <> '') then
  begin
    LayoutResult := FUiLayoutStore.LoadLayout(Schema.Id, Layout);
    if not LayoutResult.Failed then
      if not FUiRuntime.ApplyLayout(Render, Layout, Applied).Failed then
        Render := Applied;
  end;

  Result := TCEAResult.Ok(FUiRuntime.RenderToJson(Render));
end;

function TCEAStandaloneRuntime.FindProposalIndex(
  const AProposalId: string): Integer;
begin
  Result := FUiProposalIds.IndexOf(AProposalId);
end;

function TCEAStandaloneRuntime.SaveUiPage(const APageId, ATitle, ASchemaId,
  ASchemaJson: string): TCEAResult;
var
  Version: Integer;
  Codec: TCEAUiSchemaCodec;
  Schema: TCEAUiSchema;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  // 存进去之前先按白名单解一遍：页面里的组件类型必须是受控集合，
  // 不能让任意 JSON 直接进渲染器。这里只做静态校验，不要求已开局。
  Codec := TCEAUiSchemaCodec.Create;
  try
    Result := Codec.Decode(ASchemaJson, Schema);
  finally
    Codec.Free;
  end;
  if Result.Failed then Exit;
  Result := FUiPageStore.SavePage(APageId, ATitle, ASchemaId, ASchemaJson,
    FClock.UtcNowIso8601, Version);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"page_id":"' + JsonEscapeText(APageId) +
    '","schema_id":"' + JsonEscapeText(ASchemaId) +
    '","version":' + IntToStr(Version) + '}');
end;

function TCEAStandaloneRuntime.ListUiPages: TCEAResult;
var
  Pages: TCEAUiPageArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.ListPages(Pages);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Pages) do
    begin
      O := TJSONObject.Create;
      O.Add('page_id', Pages[I].PageId);
      O.Add('title', Pages[I].Title);
      O.Add('schema_id', Pages[I].SchemaId);
      O.Add('version', Pages[I].Version);
      O.Add('active', Pages[I].Active);
      O.Add('updated_at', Pages[I].UpdatedAt);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"pages":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Pages)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.GetUiPage(const APageId: string): TCEAResult;
var
  Page: TCEAUiPage;
  SchemaJson: string;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.GetPage(APageId, Page, SchemaJson);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"page_id":"' + JsonEscapeText(Page.PageId) +
    '","title":"' + JsonEscapeText(Page.Title) +
    '","schema_id":"' + JsonEscapeText(Page.SchemaId) +
    '","version":' + IntToStr(Page.Version) +
    ',"active":' + JsonBool(Page.Active) +
    ',"updated_at":"' + JsonEscapeText(Page.UpdatedAt) +
    '","schema_json":"' + JsonEscapeText(SchemaJson) + '"}');
end;

function TCEAStandaloneRuntime.SetActiveUiPage(
  const APageId: string): TCEAResult;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.SetActivePage(APageId);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"page_id":"' + JsonEscapeText(APageId) +
    '","active":true}');
end;

function TCEAStandaloneRuntime.GetActiveUiPage: TCEAResult;
var
  Page: TCEAUiPage;
  SchemaJson: string;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.GetActivePage(Page, SchemaJson);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"page_id":"' + JsonEscapeText(Page.PageId) +
    '","title":"' + JsonEscapeText(Page.Title) +
    '","schema_id":"' + JsonEscapeText(Page.SchemaId) +
    '","version":' + IntToStr(Page.Version) +
    ',"schema_json":"' + JsonEscapeText(SchemaJson) + '"}');
end;

function TCEAStandaloneRuntime.ListUiSchemaVersions(
  const ASchemaId: string): TCEAResult;
var
  Versions: TCEAUiSchemaVersionArray;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.ListVersions(ASchemaId, Versions);
  if Result.Failed then Exit;
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Versions) do
    begin
      O := TJSONObject.Create;
      O.Add('schema_id', Versions[I].SchemaId);
      O.Add('version', Versions[I].Version);
      O.Add('created_at', Versions[I].CreatedAt);
      Arr.Add(O);
    end;
    Result := TCEAResult.Ok('{"schema_id":"' + JsonEscapeText(ASchemaId) +
      '","versions":' + Arr.AsJSON +
      ',"count":' + IntToStr(Length(Versions)) + '}');
  finally
    Arr.Free;
  end;
end;

function TCEAStandaloneRuntime.RestoreUiSchemaVersion(const ASchemaId: string;
  const AVersion: Integer): TCEAResult;
var
  SchemaJson: string;
  Target: TCEAUiPage;
  PageFound: Boolean;
  Pages: TCEAUiPageArray;
  NewVersion: Integer;
  I: Integer;
  PageId, Title: string;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  if AVersion <= 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_version_invalid', '{}'));
  Result := FUiPageStore.LoadVersion(ASchemaId, AVersion, SchemaJson);
  if Result.Failed then Exit;

  // 回退不是「切到旧版本」，而是「把旧 JSON 存成一个新版本」（append-only）。
  // 这样历史永不丢，操作者可以再往前走。
  PageFound := False;
  Result := FUiPageStore.ListPages(Pages);
  if Result.Failed then Exit;
  for I := 0 to High(Pages) do
    if Pages[I].SchemaId = ASchemaId then
    begin
      Target := Pages[I];
      PageFound := True;
      Break;
    end;
  if PageFound then
  begin
    PageId := Target.PageId;
    Title := Target.Title;
  end
  else
  begin
    // 还没有任何页面引用这个 schema：用 schema id 作页面 id，标题留空由
    // 调用方后续改名。
    PageId := ASchemaId;
    Title := ASchemaId;
  end;

  Result := FUiPageStore.SavePage(PageId, Title, ASchemaId, SchemaJson,
    FClock.UtcNowIso8601, NewVersion);
  if Result.Failed then Exit;
  Result := TCEAResult.Ok('{"schema_id":"' + JsonEscapeText(ASchemaId) +
    '","page_id":"' + JsonEscapeText(PageId) +
    '","restored_from":' + IntToStr(AVersion) +
    ',"version":' + IntToStr(NewVersion) + '}');
end;

function TCEAStandaloneRuntime.SetSecondaryScreenPage(
  const APageId: string): TCEAResult;
var
  Page: TCEAUiPage;
  SchemaJson: string;
  Codec: TCEAUiSchemaCodec;
  Schema: TCEAUiSchema;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Result := FUiPageStore.GetPage(APageId, Page, SchemaJson);
  if Result.Failed then Exit;
  // 先按白名单解码一次再切换，避免把一个渲染不了的面板推给副屏。
  Codec := TCEAUiSchemaCodec.Create;
  try
    Result := Codec.Decode(SchemaJson, Schema);
  finally
    Codec.Free;
  end;
  if Result.Failed then Exit;
  FSecondaryScreenPageId := APageId;
  Result := TCEAResult.Ok('{"page_id":"' + JsonEscapeText(APageId) +
    '","schema_id":"' + JsonEscapeText(Page.SchemaId) +
    '","version":' + IntToStr(Page.Version) + '}');
end;

function TCEAStandaloneRuntime.ProposeUiCustomization(
  const AInstruction: string): TCEAResult;
var
  Proposal: TCEAUiSchemaProposal;
  Index: Integer;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiCustomizationService = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'ui_customization_unavailable', '{}'));
  if FGameModel = nil then
    Exit(TCEAResult.Error(rcConflict, 'game_session_not_started', '{}'));
  Result := FUiCustomizationService.ProposeFromInstruction(FGameModel,
    AInstruction, FClock.UtcNowIso8601, Proposal);
  if Result.Failed then Exit;
  // 提案只活在内存里：未确认的模型产物永不落盘（FR-025 / PRD 7.6）。
  Index := FindProposalIndex(Proposal.ProposalId);
  if Index >= 0 then
  begin
    FUiProposalSchemas[Index] := Proposal.SchemaJson;
  end
  else
  begin
    FUiProposalIds.Add(Proposal.ProposalId);
    FUiProposalSchemas.Add(Proposal.SchemaJson);
  end;
  Result := TCEAResult.Ok('{"proposal_id":"' +
    JsonEscapeText(Proposal.ProposalId) +
    '","state":"proposed","requires_confirmation":true' +
    ',"dropped":' + IntToStr(Proposal.DroppedComponents) +
    ',"downgraded":' + IntToStr(Proposal.DowngradedComponents) + '}');
end;

function TCEAStandaloneRuntime.ConfirmUiCustomization(const AProposalId,
  APageId, ATitle: string): TCEAResult;
var
  Index, Version: Integer;
  SchemaJson: string;
  PageId, PageTitle: string;
  Codec: TCEAUiSchemaCodec;
  Schema: TCEAUiSchema;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  if FUiPageStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ui_page_store_unavailable', '{}'));
  Index := FindProposalIndex(AProposalId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'ui_proposal_not_found', '{}'));
  SchemaJson := FUiProposalSchemas[Index];
  if Trim(SchemaJson) = '' then
    Exit(TCEAResult.Error(rcUnknown, 'ui_proposal_not_found', '{}'));
  Codec := TCEAUiSchemaCodec.Create;
  try
    Result := Codec.Decode(SchemaJson, Schema);
  finally
    Codec.Free;
  end;
  if Result.Failed then Exit;

  PageId := Trim(APageId);
  if PageId = '' then PageId := AProposalId;
  PageTitle := Trim(ATitle);
  if PageTitle = '' then PageTitle := PageId;
  Result := FUiPageStore.SavePage(PageId, PageTitle, PageId, SchemaJson,
    FClock.UtcNowIso8601, Version);
  if Result.Failed then Exit;
  // 确认后提案即失效：同一个提案不能被重复确认成第二个页面。
  FUiProposalIds.Delete(Index);
  FUiProposalSchemas.Delete(Index);
  Result := TCEAResult.Ok('{"proposal_id":"' +
    JsonEscapeText(AProposalId) +
    '","page_id":"' + JsonEscapeText(PageId) +
    '","version":' + IntToStr(Version) + ',"state":"confirmed"}');
end;

function TCEAStandaloneRuntime.RejectUiCustomization(
  const AProposalId: string): TCEAResult;
var
  Index: Integer;
begin
  if not FStarted then
    Exit(TCEAResult.Error(rcConflict, 'runtime_not_started', '{}'));
  Index := FindProposalIndex(AProposalId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'ui_proposal_not_found', '{}'));
  FUiProposalIds.Delete(Index);
  FUiProposalSchemas.Delete(Index);
  Result := TCEAResult.Ok('{"proposal_id":"' +
    JsonEscapeText(AProposalId) + '","state":"rejected"}');
end;

end.

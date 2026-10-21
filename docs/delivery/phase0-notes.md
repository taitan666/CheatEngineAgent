# Phase 0 技术验证笔记

**日期：** 2026-10-19
**目标：** 证明「独立引擎 → 状态采集 → 语义字段 → 受控写入 → 重读验证」端到端闭环可行
**状态：** 闭环已打通（自进程 mock 目标）；真实游戏验证待后续

---

## 1. 已完成（本轮）

### 1.1 仓库瘦身（P0-1）

- 删除根目录 CE 相关：`Cheat Engine/`、`DBKKernel/`、`dbvm/`、`DBVM UEFI/`、`lua/`、`scripts/`、`.gitmodules`
- 删除 `integration/cheat-engine/`、`references/upstream/`
- 删除 9 个空壳单元（4 个 `domain/ce/*_adapter` + `cea_mcp_dispatcher` + `cea_ct_search` + `cea_tool_dispatcher` + `cea_structured_log` + `cea_ui_projection`）
- 8 个 `cea_ce_*` 单元改名去前缀（`cea_ce_scan_capability` → `cea_scan_capability` 等）
- 3 个 `ce_agent_*` 引擎单元迁移为新名（`cea_win32_engine_runtime` / `cea_win32_engine_bootstrap` / `cea_engine_mcp_dispatcher`）
- `cea_runtime.pas` 的遗留 `TCEAgentRuntime` 改名为 `TCEAKernelRuntime`（消除与引擎装配器的同名歧义）
- sqlite3.dll 归档到 `vendor/sqlite3/`，构建脚本改指向新位置
- 更新 `unit-manifest.txt`、`.lpi` 搜索路径、`compile-smoke.ps1`、`run-test-program.ps1`、`verify-scaffold.ps1`

### 1.2 语义字段模型（P0-2）

- `src/domain/state-model/cea_field_model.pas`：`TCEAGameField`（`field_id/display_name/value_type/value_json/source/confidence/access/validation_status/last_updated/constraints_json/evidence_refs_json/address_hex`）+ `TCEAFieldAccess`（read_only/pending_write/verified_writable/invalid）+ `TCEAValidationStatus`（observed/hypothesis/user_confirmed/verified）
- `src/domain/state-model/cea_game_state_model.pas`：`TCEAGameStateModel`（字段集合 + 版本指纹 `ExecutableSha256/ModuleSetHash` + `MatchesVersion` 兼容性检测）
- `schemas/state-model/{field,game-state}.schema.json` + manifest 接入
- 注意：Pascal 保留字 `Label` 冲突 → 字段名用 `DisplayName`

### 1.3 首条写入闭环（P0-3/P0-4）

- `src/core/command/cea_command_types.pas`：`TCEAFieldWriteCommand`（field_id/value_type/target_value/expected_current_value/profile_id/address_hex）+ `TCEACommandOutcome`（submitted/verified/rejected/sent_not_applied/overwritten/version_mismatch）
- `src/core/command/cea_command_bus.pas`：`TCEAFieldCommandBus.ExecuteWrite`，复用 `EncodeExactValue`（值类型→字节）+ `CompareWriteReadback`（原子写入）+ `ReadCurrentHex`（独立重读验证）
- `src/core/capture/cea_state_capture_service.pas`：`TCEAStateCaptureService.CaptureField`，读字段字节 + 变化检测（单调序列号）
- 测试 `test_field_command_flow.pas` 通过：采集→写入→重读→状态冲突拒绝→只读拒绝

---

## 2. 验证结果

| 检查 | 结果 |
| --- | --- |
| `compile-smoke.ps1`（FPC 全量编译） | PASS（16160 行） |
| `verify-scaffold.ps1`（15 文件 + 52 schema + 写内存安全） | PASS |
| `check-schemas.ps1`（54 schemas） | PASS |
| `test_field_model.pas` | PASS（FIELD_MODEL） |
| `test_field_command_flow.pas` | PASS（FIELD_COMMAND_FLOW） |
| `lazbuild` 完整构建 `dist/CheatEngineAgent.exe` | ⚠️ 未跑通（沙箱无法写 `AppData\Local\lazarus` 配置目录，非代码问题） |

---

## 3. 技术限制与待办

### 3.1 已确认的限制

1. **`lazbuild` 需要写 `AppData\Local\lazarus` 配置目录**，当前 DSH 沙箱 workspace-write 模式拒绝。需在 Full Access 模式或本机手动跑 `build-standalone-app.ps1` 才能产出 `dist/CheatEngineAgent.exe`。
2. **采集服务的字节→文本解码未实现**：`CaptureField` 返回 hex 字节，未解码成整数/float 文本值。Phase 0 目标是证明闭环，值解码留到有真实字段语义时。
3. **字段地址 `AddressHex` 是简化设计**：真实场景地址来自指针链/Profile 定位信息，Phase 0 用直接地址。真实游戏需基址+多级指针链。

### 3.2 真实游戏验证（未做，待 Phase 0 后续）

- 《Stardew Valley》类独立 RPG 的真实内存特征尚未验证：金钱/HP 地址是否稳定，是否需基址+指针链，.NET GC 是否影响。
- 按计划，若地址不稳定，切换「基址+多级指针链」或改选 C++ 原生游戏（《空洞骑士》）。

### 3.3 尚未接入主程序

- `cea_field_model` / `cea_command_bus` / `cea_state_capture_service` 目前只被测试引用，**尚未接入 `cea_application_runtime.pas` 和主 UI**。这是 Phase 1（1B/1E）的工作。

---

## 4. Phase 0 退出条件评估

PRD 12 Phase 0 退出条件：
- ✅ 只读展示闭环稳定（采集 → 字段 → 读值）
- ✅ 至少一条可验证修改路径（采集 → 写入 → 重读验证，`coVerified`）
- ⚠️ 但为**自进程 mock 目标**，非真实游戏；真实游戏验证后置（符合「以模拟适配器验证命令流程并明确标注限制」的降级路径）

**结论：Phase 0 的技术可行性已证明，真实游戏闭环是 Phase 0 剩余的待办（需真实游戏环境 + 授权样本）。**

---

## 5. 真实游戏验证（《Stardew Valley》，2026-10-19 补充）

### 5.1 已完成的验证（真实游戏进程 PID 4340）

| 能力 | 结果 |
| --- | --- |
| 附加真实游戏进程 | ✅ PASS（`VERIFY_SDV_ATTACH=PASS`，身份签名 + Epoch + 分类 single_player_offline） |
| 枚举模块 | ✅ PASS（识别 .NET 运行时 coreclr.dll/clrjit.dll + 游戏程序集 Stardew Valley.dll） |
| 读取内存 | ✅ PASS（读到 Stardew Valley.dll 的 PE 头 `4D 5A` 魔数） |
| 枚举内存区域 | ⚠️ 240+ 个 private 区域，超出扫描引擎 128-region 上限 |
| 定位体力字段 | ❌ 受阻（见 5.2） |

### 5.2 发现的真实游戏兼容性问题

1. **128-region 硬限制对现代游戏不足**（已修复）：Stardew Valley（.NET 6）240+ 区域、Hollow Knight（Unity IL2CPP）405 区域，均超过 `ValidateRanges` 的 128 上限。已实现双层修复：`MergeAdjacentRegions`（合并相邻同类区域）+ `ValidateRanges` 加 `AMaxRanges` 参数（进程级扫描放宽到 4096，显式范围仍 128）+ 后端 `ExecuteFirstScan` 的 128 硬限制改为 `MaxRegions` 参数。
2. **512MB 字节预算对现代游戏不足**：.NET/Unity 游戏 private 内存 > 512MB，扫描出现 `byte_limit` 提前截断。
3. **字段级定位对 Unity IL2CPP / .NET 托管对象不可靠**（核心发现）：Geo 金币（Hollow Knight，int 21→23）和体力（Stardew Valley，float）都是托管对象字段，纯值扫描命中海量假阳性（小整数在内存中极其普遍），复筛无法有效收敛。定位这类字段需要：指针链、AOB 特征、或托管堆结构分析（类型句柄、对象偏移），这是现有「值扫描」引擎的能力边界。

### 5.3 结论与后续

- **真实游戏的「读取」闭环已通**（附加 + 枚举 + 读内存都 PASS），这是 Phase 0 真实游戏验证的核心成果。
- **「写入」闭环受阻于「字段级定位」能力缺失**：现代引擎游戏（Unity IL2CPP / .NET）的数值字段无法靠纯值扫描可靠定位，需要指针链/结构分析能力（Phase 1+）。
- 后续方向（Phase 1+）：
  - 实现指针链扫描（`cea_ct_draft` 已支持 pointer_chain 类型，但运行时定位需完善）
  - 实现 AOB 特征定位（对 IL2CPP 的 Geo 字段，可用「变化前后」的 AOB 特征）
  - 或接入社区已知的字段偏移（Hollow Knight 的 Geo 偏移是社区充分研究的）
  - 或改用「更易定位」的字段（如 Geo 的上限/特殊值，而非小整数）

### 5.4 新增代码（本轮）

- `tests/pascal/verify_sdv_attach.pas` — 真实游戏附加验证
- `tests/pascal/scan_sdv_stamina.pas` — 体力值扫描
- `tests/pascal/diag_sdv_regions.pas` — 内存区域诊断
- `tests/pascal/read_sdv_heap.pas` — 内存读取验证
- `src/platform/windows/cea_win32_memory_regions.pas` — 新增 `MergeAdjacentRegions` 合并相邻同类区域
- `src/platform/windows/cea_win32_readonly_backend.pas` — `PlanReadableRegions` 调用合并

> 注意：以上临时验证程序（verify_sdv_attach/scan_sdv_stamina/diag_sdv_regions/read_sdv_heap）是 Phase 0 诊断用的临时脚本，非正式测试套件，后续可清理或转为正式集成测试。

---

## 6. Phase 1 实现笔记（2026-10-19 补充）

### 6.1 已完成的 Phase 1 模块

| 模块 | 文件 | 测试 |
|---|---|---|
| Game Profile 类型 | `src/domain/profile/cea_profile_types.pas` | — |
| Profile 端口 | `src/domain/profile/cea_profile_ports.pas` | — |
| Profile 存储 | `src/infrastructure/cea_profile_store.pas` | — |
| Profile 服务 | `src/core/profile/cea_profile_service.pas` | `PROFILE_SERVICE=PASS` |
| UI Schema 类型 | `src/domain/ui-schema/cea_ui_schema_types.pas` | `UI_SCHEMA=PASS` |
| UI Schema Codec | `src/domain/ui-schema/cea_ui_schema_codec.pas` | `UI_SCHEMA_CODEC=PASS` |
| UI Schema Builder | `src/domain/ui-schema/cea_ui_schema_builder.pas` | `UI_SCHEMA_BUILDER=PASS` |
| 端到端集成 | （跨模块） | `PHASE1_E2E=PASS` |
| 字段映射服务（1C） | `src/core/mapping/cea_mapping_service.pas` | `MAPPING_SERVICE=PASS` |
| 事件录像证据层（1G） | `src/core/events/cea_event_types.pas` | `EVENT_SERVICE=PASS` |
| 事件服务（1G） | `src/core/events/cea_event_service.pas` | `EVENT_SERVICE=PASS` |
| 录像缓存策略（1G） | `src/core/events/cea_recording_service.pas` | `EVENT_SERVICE=PASS` |
| GDI 帧源/关键帧捕获（1G） | `src/platform/windows/cea_win32_recording.pas` | `EVENT_SERVICE=PASS` |

### 6.3 回归修复（2026-10-20）

- **发现 Phase 0 迁移引入的回归**：`RegisterEngine` 重复注册时返回 `rcInternalError`，但行为契约（`test_ce_agent_registration.pas`）期望 `rcConflict`。根因是迁移 `RegisterCheatEngineAgent`→`RegisterEngine` 时把「已注册」（冲突）和「缺依赖」（内部错误）两种情况合并成了一个返回码。
- **修复**：拆分两种情况——`EngineRegistered` 返回 `rcConflict`，`ABackend=nil`/`AHasher=nil` 返回 `rcInternalError`。
- **验证**：`test_ce_agent_registration.pas`、`test_ce_win32_bootstrap.pas`、`test_ce_mcp_runtime_dispatcher.pas`、`test_governed_memory_effect.pas` 全部 PASS。

### 6.4 Profile 接入主程序 + 测试基建修复（2026-10-20）

- **Profile 服务接入 `cea_application_runtime`**：`Runtime.Start` 现在初始化 `TCEAProfileStore`（独立数据库 `profiles.sqlite3`，与治理库 `governance.sqlite3` 同级）+ `TCEAProfileService`，`Runtime.Stop` 释放。Profile 能力成为应用运行时的一部分，不再只是测试引用。
- **修复测试基建 cwd 缺陷**：`run-test-program.ps1` 原先运行测试 exe 时不切 cwd，导致依赖相对路径 fixture 的测试（如 `test_standalone_app_runtime.pas` 的 `tests\fixtures\ct\minimal-valid.ct`）失败。已改为 `Push-Location $ProjectRoot` 后运行，测试从此从项目根解析相对路径。
- **验证**：`STANDALONE_APP_RUNTIME=PASS`（此前因 cwd 失败），回归确认 `PHASE1_E2E`、`PROFILE_SERVICE`、`FIELD_COMMAND_FLOW`、`cea_win32_engine_runtime` 全部 PASS。

### 6.5 LLM 结构化输出（1C 地基，2026-10-20）

- **契约扩展**：`TCEALLMChatRequest` 增加 `ResponseFormat`（空=文本，`json_object`=JSON 模式）和 `OutputJsonSchema`（可选 JSON Schema 约束，先记录待用）。向后兼容——两个 provider 用 `FillChar` 初始化，新字段默认空，不影响现有文本调用。
- **OpenAI body 构建**：当 `ResponseFormat='json_object'` 时，添加 OpenAI 的 `response_format:{"type":"json_object"}`。
- **验证**：`test_openai_compatible`、`test_anthropic_compatible`、`test_llm_streaming` 全 PASS（向后兼容）。
- **目的**：为「AI 生成字段映射/UI Schema JSON」（PRD 6.3/6.9）提供结构化输出地基。

### 6.6 事件录像证据层（1G，2026-10-20）

对应 PRD 6.8 节 FR-070～FR-084，按 `docs/transformation-plan.md:157-159` 实现。

**分层**
- `src/core/events/cea_event_types.pas`：事件/片段/快照/规则/帧数据类型 + 4 个端口（`ICEARecordingCapture`、`ICEAFrameSource`、`ICEAEventStore`、`ICEAEventWakePort`）+ 文本往返与分类函数（`IsLocalDeterministicTrigger`、`IsAdvisoryOnlyTrigger`）。
- `src/core/events/cea_event_service.pas`：内存快照环形缓存、事件包组装、字段变化规则评估、冷却抑制、事件窗口合并、按需唤醒 AI。
- `src/core/events/cea_recording_service.pas`：循环录像缓存与保留策略（时长/磁盘/保留期淘汰，锁定片段豁免）。
- `src/platform/windows/cea_win32_recording.pas`：GDI BitBlt 窗口帧源 + 关键帧捕获落盘（Phase 1 原型）。

**已落地的 PRD 语义**
- FR-070 循环缓存：快照环形覆盖（`SnapshotCapacity`）；录像片段超时长从最旧未锁定片段淘汰，锁定片段不被覆盖。
- FR-071 手动标记：`MarkEvent` 写入 `etUserMark` 事件包并记录用户标签。
- FR-072 本地确定性触发：字段变化规则（任意变化/上升/下降/超阈值/低于阈值）由本地代码评估，**不调用 AI**。
- FR-074 事件前后片段 + 合并：`PreRollMs`/`PostRollMs` 定义窗口；触发时间落在既有事件窗口内则合并延长并重算快照，避免重复保存大量视频。
- FR-075 统一时间线：事件包记录 `CaptureLatencyMs`/`ClockErrorMs`，快照与录像共用毫秒时间基准。
- FR-076 事件包：EventId/触发来源/时间范围/进程标识+Epoch/字段快照/录像引用/分析状态/用户标签。
- FR-077 按需唤醒 AI：规则过滤 + 冷却（`CooldownMs`，抑制计数 `SuppressedCount`）+ `eaQueued` 时经 `ICEAEventWakePort` 入队。
- FR-078 证据选择：入队上下文为结构化摘要（trigger_kind/duration_ms/field_snapshots），不含原始视频。
- FR-079 保留策略：缓存时长、最大磁盘字节、保留期限、锁定永久保留。
- FR-083 删除：`DeleteEvent` 连同录像引用移除。
- FR-080 隐私：录像默认落本地存储目录；Phase 1 无任何云端上传路径。
- FR-084 视觉事件候选：`etAiSuggested` 标记为 `IsAdvisoryOnlyTrigger`，仅作参考，不作为内存写入依据。

**关键设计决策**
- **捕获 API 选 GDI BitBlt**（而非 Desktop Duplication / Media Foundation）：随 Windows 提供、无额外依赖，且可对指定窗口抓帧；Desktop Duplication 更适合全屏高帧率，留待后续阶段评估。编码与持久化格式（当前为逐帧 `.bgr` + `.index.json`）标注为待定，符合 PRD 第 19 节「技术决策状态」。
- **`ICEAFrameSource` 端口解耦**：core 层只依赖端口，平台捕获实现可替换，测试可用假帧源驱动，无需真实窗口。
- **`FEventSequence` 与 `FSequence` 分离**：修复了实现中发现的真实 bug——原实现共用计数器，导致快照写入会推进事件 ID 序号、事件 ID 跳号且测试断言 `event-00000001` 失败。

**验证**：`tests/pascal/test_event_service.pas` → `EVENT_SERVICE=PASS`（14 组断言，覆盖上述 FR 语义 + 录像缓存淘汰 + 锁定豁免 + 保留清理 + 磁盘预算 + GDI 捕获落盘）；`PASCAL_COMPILE_SMOKE=PASS`；`SCHEMA_CHECK=PASS schemas=58 units=93`；`SCAFFOLD_ACCEPTANCE=PASS`。

**尚未实现（后续阶段）**：FR-073 外部事件源（P1）、FR-081 事件浏览器（P1）、FR-082 证据关联（P1）、实时视频编码与压缩、事件包持久化到 SQLite（`ICEAEventStore` 端口已定义但无实现）。

### 6.7 Phase 1 模块接入运行时 + 桌面主窗口重组（1H，2026-10-20）

**问题**：1A/1B/1C/1D/1E/1F/1G 的模块此前只被测试引用（除 Profile 外），`cea_application_runtime.pas` 对 `cea_mapping_service`/`cea_event_service`/`cea_ui_schema_runtime`/`cea_command_bus`/`cea_state_capture_service` 零引用——即「代码已写、产品未通电」。

**接入方式（`src/app/cea_application_runtime.pas`）**
- 新增私有字段：`FGameModel: TCEAGameStateModel`、`FMappingService: TCEAMappingService`、`FCommandBus: TCEAFieldCommandBus`、`FCaptureService: TCEAStateCaptureService`、`FEventService: TCEAEventService`、`FUiRuntime: TCEAUiSchemaRuntime`、`FUiLayoutStore: TCEAUiLayoutStore`、`FDisplayEnumerator: TCEAWin32DisplayEnumerator`、`FCommandBusPid`、`FCommandBusSha256`、`FGameName`、`FGameVersion`、`FGameSessionActive`。
- 新增公开玩家级 API（全部 fail-closed，未开会话时返回 `game_session_not_started`）：
  - 会话：`StartGameSession(const AGameName, AGameVersion: string)`（要求已附加进程，从 `EngineRuntime.Processes.Current` 取 `ExecutableSha256`/`ModuleSetHash` 建模型与 Command Bus；**显式重置为只读起步**）、`EndGameSession`、`GameSessionActive: Boolean`。
  - 字段：`DeclareField`（经 `TCEAMappingService.ProposeUserDeclared` → `MaterializeField`，**物化后 Access 恒为 `faReadOnly`**）、`CaptureFieldValue`（`TCEAStateCaptureService.CaptureField`，同时按规则 `ObserveField` 喂事件服务）、`ConfirmFieldWritable`（唯一提升路径：先写目标值 → 重读一致 → 才升 `faVerifiedWritable`；失败则置 `faInvalid`）、`WriteFieldValue`（`TCEAFieldCommandBus.ExecuteWrite`，`verified` 才算成功）、`ListGameFields`。
  - 副屏：`BuildUiRenderJson(const ALayoutSchemaId: string)`（`TCEAUiSchemaBuilder.BuildFromModel` → `TCEAUiSchemaRuntime.Bind` → `ApplyLayout` → `RenderToJson`；无布局记忆时按模型顺序渲染）。
  - 布局/窗口：`EnumerateDisplays`、`SaveWindowPlacement`、`LoadWindowPlacement`。
  - 事件：`MarkEvent(const ATag)`、`ListEvents`。
- **`ConfirmFieldWritable` 的安全语义（本次接入最关键的设计）**：字段一旦被 `DeclareField` 物化就是 `faReadOnly`，而 `TCEAFieldCommandBus` 只接受 `faVerifiedWritable`——形成死锁。解法是引入「验证性写入」作为唯一的晋升通道：以 `faVerifiedWritable` 临时视图驱动 Command Bus，写入→独立重读→一致才写回真实 `faVerifiedWritable`，不一致则 `faInvalid`。这既解开死锁，又保证「可写」永远建立在实证之上（符合 PRD 9 条原则之「修改必须可验证」）。
- **`Start`/`Stop` 装配**：`Start` 在 Profile 块之后建 `FUiLayoutStore`（`ui-layouts.sqlite3`，与治理库同级）→ `FMappingService` → `FEventService`（`PreRollMs=3000`/`PostRollMs=5000`/`SnapshotCapacity=512`/`DefaultCooldownMs=1000`）→ `FUiRuntime` → `FDisplayEnumerator`；`Stop` 逆序释放并 `FreeAndNil(FGameModel)`、`FCommandBus := nil`。

**桌面主窗口重组（1H，`app/lazarus/cea_main_form.pas`）**
- 原有 7 个诊断页签（治理与安全 / 进程与内存 / CT RAG / 存档工作台 / LLM 工作台 / MCP / 关于与安全）**全部保留但降为次级**，新增 `PlayerTab`（「玩家工作台」，位于首位并设为默认激活页）。
- 玩家工作台为三栏（PRD 7.5 线框）：左栏 `FPlayerNav: TListBox`（游戏概览 / 游戏字段 / 写入验证 / 事件时间线 / 副屏 / 设置），中栏 `FPlayerCenterPanel`（按导航切换 6 个 section 面板），右栏 `FPlayerDetailPanel`（字段语义详情 + 操作反馈）。
- 字段状态用「颜色 + 文字」双重信号：`UpdatePlayerDetail` 明确列出 `read_only`（只读，不提供写入入口）/`pending_write`（待验证）/`verified_writable`（可写）/`invalid`（失效）四态及其含义。
- **两级反馈（FR-044/AC-007）**：`WriteSelectedField` 区分 `verified`（「写入已发送并验证一致」）与其它 outcome（「命令已发送，但尚未验证为修改成功」），绝不含糊。
- `VerifySelectedFieldWritable` 在写入前弹确认框，明确说明「这是把字段从只读提升为可写的唯一途径」并要求授权确认。

**验证基建新增 `tests/pascal/compile-app.ps1`**
- 用 ppcx64 直接编译 `app/lazarus/cheat_engine_agent.lpr`（含 LCL），绕过 lazbuild（lazbuild 需写 `%LOCALAPPDATA%\lazarus`，被 DSH 沙箱拒绝）。
- 关键参数：`-Fu<lcl units>` + `-Fu<lcl units>\win32`（`Interfaces` 单元在 `win32` 子目录，不在 LCL 根）+ `-Fu<components\lazutils\lib\x86_64-win64>`。
- 结果：**`PASCAL_APP_COMPILE=PASS compiler=3.2.2`**，21715 行，2 warning 1 note（均为既有告警）。

**验证结果**：`PASCAL_APP_COMPILE=PASS`（1H 编译通过）；`PASCAL_COMPILE_SMOKE=PASS`（21507 行）；`SCAFFOLD_ACCEPTANCE=PASS files=15 json=58`；`SCHEMA_CHECK=PASS schemas=58 ids=58 manifest=57 units=97`；Phase 1 测试全绿（`STANDALONE_APP_RUNTIME`/`MCP_PROTOCOL`/`PHASE1_E2E`/`MAPPING_SERVICE`/`EVENT_SERVICE`/`FIELD_COMMAND_FLOW`/`PROFILE_SERVICE`/`UI_SCHEMA`/`UI_SCHEMA_CODEC`/`UI_SCHEMA_BUILDER`/`UI_SCHEMA_RUNTIME`/`FIELD_MODEL` 全部 PASS）。

**顺带修复**
- `src/mcp/cea_mcp_dispatcher.pas`：`TMCPFoundationDispatcher` 原先没有 `Create`，而 `test_mcp_protocol.pas:53` 调用 `Create(nil)`（FPC 默认 `TObject.Create` 无参 → 编译错误）。已补 `constructor Create(const AOwner: TObject = nil)`。
- `tests/pascal/run-test-program.ps1`：`-Program` 相对路径原先按调用者 cwd 解析，导致从项目根调用时 `PathNotFound`。已改为先按 cwd 试、失败再按项目根解析。

**尚未实现（Phase 1 之后）**：副屏 WebView2/本地容器宿主本身（当前只产出渲染 JSON，未起窗口）；1D 的 FR-025/026/033/034（自然语言定制、页面版本回退、多页面、浮动小组件）；1G 的 `ICEAEventStore` 持久化。

### 6.8 存档写入闭环修复：ReplaceFileW → MoveFileExW（2026-10-20）

**症状**：`test_save_edit`、`test_save_recovery`、`test_save_backup` 三个测试此前记录为失败；重新运行后 `ApproveAndExecute` 对存档编辑 effect 返回 `rcUnknownOutcome` / `save_edit_replace_uncertain`（code=19）。

**诊断过程（逐层隔离，全部用 `tests/pascal/run-test-program.ps1` 运行独立诊断程序）**
1. `tests/pascal/diag_save_edit.pas`：完整走一遍存档编辑链路（Inspect → Propose → RequestBackup → Approve → PlanEdit → Approve），定位到失败点**恰好在 `ApproveAndExecute(edit)`**，即 `TCEAWin32SaveEffectPort.ExecuteEdit` 内。
2. `tests/pascal/diag_replace.pas`：单独复现 `CreateFileW` + `ReplaceFileW`，得 **`ReplaceFileW ok=FALSE err=5`（ERROR_ACCESS_DENIED）**；且 `err=5` 与是否持有锁句柄无关。
3. `tests/pascal/diag_replace2.pas`：对比 `ReplaceFileW` vs `MoveFileExW`，覆盖临时目录/工作区目录、`FILE_FLAG_WRITE_THROUGH`、`REPLACEFILE_WRITE_THROUGH` 四种组合 → **`ReplaceFileW` 在全部组合下均 `err=5`，`MoveFileExW` 在全部组合下均 `ok=TRUE`**。
4. 用 PowerShell 的 .NET `[System.IO.File]::Replace()` 交叉验证（它内部即调用 `ReplaceFileW`）→ 同样失败（「对路径的访问被拒绝。」/「路径的形式不合法。」）。**证明这是宿主环境（DSH 沙箱）对 `ReplaceFileW` 的限制，不是 FPC 声明错误或代码缺陷。**
5. `tests/pascal/diag_replace4.pas`：测试锁句柄与替换的关系 → **锁关闭后再 `MoveFileExW` 成功（`ok=TRUE`），锁持有期间失败（`err=5`）**，且与 `GENERIC_READ`/`DELETE` 访问位、share 模式（`0x05`/`0x07`/`0x00`）均无关。

**根因（两个独立缺陷叠加）**
- **缺陷 A（代码）**：`ExecuteEdit`/`ExecuteRestore` 在持有目标文件读锁句柄的 `try...finally` 块**内部**调用替换 API。Windows 不允许对仍被打开的文件做重命名替换，故必然失败。
- **缺陷 B（环境）**：`ReplaceFileW` 在本宿主环境全局返回 `ERROR_ACCESS_DENIED`（沙箱限制），即使无锁也失败。另外 FPC 的 `windows` 单元**不声明** `ReplaceFileW`，原代码是自行 `external 'kernel32.dll'` 声明的。

**修复（`src/platform/windows/cea_win32_save_effect_port.pas`）**
- 删除自声明的 `ReplaceFileW`，改为自声明 `MoveFileExW`（`external 'kernel32.dll' name 'MoveFileExW'`）+ 常量 `MoveFileReplaceExisting = $00000001`。
- `ExecuteEdit` 与 `ExecuteRestore` 两处均改为：**在 `finally` 中先 `CloseHandle(LockHandle)` 释放锁**，再在 `try...finally` **之外**调用 `MoveFileExW(CandidatePath, TargetPath, MoveFileReplaceExisting)`。锁内仍保留 `GetFileInformationByHandle` 身份校验与 `ReadVerified` 预读（这两步需要锁来防止 TOCTOU）。
- 锁句柄的 share 模式放宽为 `FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE`。
- **安全性论证（关键）**：替换 API 的返回码不再作为正确性依据；**权威保证来自替换后的 `FReader.Inspect` 回读校验**——比较目标文件 `Sha256` 与候选哈希、`ByteCount` 与编码长度，不一致即 `rcUnknownOutcome`/`save_edit_readback_failed`。因此换用 `MoveFileExW` 不削弱「写入必须可验证」的治理约束。

**验证结果**：`test_save_edit`、`test_save_recovery`、`test_save_backup` 三个测试**全部 `PASCAL_TEST=PASS`**；`diag_save_edit.pas` 端到端链路 `ApproveAndExecute(edit)` 返回 `code=0`，含 `before_sha256`/`after_sha256`。

**遗留观察（未修复，需在真实环境复核）**：`MoveFileExW` 在持有目标句柄时同样返回 `err=5`，因此「先释放锁再替换」不是可选优化而是必需步骤；若后续要恢复 `ReplaceFileW` 语义（原子替换 + 保留 ACL/属性 + 可选备份），需在不受此沙箱限制的环境验证。

### 6.2 关键编码发现（重要，后续开发必读）
**结论（2026-10-21 探针实验修订，取代本节最初的说法）：决定中文字面量如何解码的不是「有没有 BOM」，而是编译时的 `DefaultSystemCodePage`，而它取决于是否加载 LCL。**

- **纯 RTL 控制台程序**（本项目所有 `tests\pascal\test_*.pas`）：`DefaultSystemCodePage = 936`。无 BOM 时 FPC 把 UTF-8 字节按 GBK 逐字节解码 → 赋给 `UnicodeString` 的中文字面量变乱码（探针实测 `'事件录像'` 得 `00E4 00BA 008B ...` 而非 `4E8B 4EF6 ...`）。
- **LCL 主程序**（`app\lazarus\cea_main_form.pas`）：LCL 初始化把 `DefaultSystemCodePage` 改成 **65001**。此时无 BOM 的 UTF-8 字面量**本来就被正确解码**（探针实测 `TButton.Caption` + `GetWindowTextW` 读到 `4E8B 4EF6 5F55 50CF`，正确）。**给这类文件加 BOM 反而有害**：FPC 会把 `string` 字面量标成 `UnicodeString`，每次 `string`↔`UnicodeString` 交互都产生一条隐式转换警告 —— 实测 `cea_main_form.pas` 由 22 条警告涨到 383 条。故该文件**保持无 BOM**。
- **正确修法（推荐）**：给需要中文字面量的源文件加**文件级指令 `{$codepage utf8}`**（放在 `{$mode objfpc}{$H+}` 之后）。它只影响本文件，不会像 `-FcUTF8` 那样波及 LCL 主程序；实测在 `default_cp=936` 下即可让 `UnicodeString` 字面量正确（`4E8B 4EF6 5F55 50CF`）。
- **不要用命令行 `-FcUTF8`**：实测给三个构建脚本加该参数后，应用编译警告 22 → 383，且 `test_phase1_e2e.pas` 的 `ui schema persisted` 断言失败。已全部回滚。
- **BOM 与 `{$codepage utf8}` 二选一**：BOM 是全文件级别的隐式声明，副作用是让 `string` 字面量变 `UnicodeString`；指令同样声明源码编码但语义更明确。含中文的 `.pas` 只要二者有其一来保证解码正确即可，但**不要给 LCL 主程序加**。
- **当前覆盖面**：`src`/`app`/`tests` 中含非 ASCII 的 `.pas` 共 63 个，其中 8 个已有 `{$codepage utf8}`。剩余风险文件（`test_field_model.pas`/`test_field_command_flow.pas`/`test_ui_schema.pas`）已于本轮补上指令。经核查这些文件的字段本身是 `string`（`TCEAGameField.DisplayName`、`TCEAUiComponent.Title`），字面量与比较对象同为 `string`，字节一致，此前并不存在真实 bug，只是「日后被赋给 `UnicodeString` 就会静默乱码」的隐患。
- **工具坑**：`[System.IO.File]::ReadAllBytes('相对路径')` 解析到 session workspace 根而非 `cd` 目录，处理源文件必须用绝对路径。

### 6.9 全量测试扫描基线 + 沙箱对跨进程测试的限制（2026-10-20）
**新增 `tests/pascal/run-all-tests.ps1`**：遍历 `tests\pascal\test_*.pas` 逐个经 `run-test-program.ps1` 运行，输出 `SUMMARY pass=N fail=M skip=K total=T` 与 `FAILED_LIST=...`。

**参数化测试归类**：`test_win32_child_process.pas` 需要外部启动的目标进程与 4 个命令行参数（pid/地址/范围大小/模块标记文件），单独运行必然在参数断言处失败，并非代码回归。脚本现将其登记在 `$parameterized` 映射中输出 `SKIP`，由 `tests\integration\test-win32-child-process.ps1` 负责驱动。该集成脚本已实测通过：`WIN32_CHILD_PROCESS=PASS` + `WIN32_CHILD_PROCESS_INTEGRATION=PASS`。

**重要环境限制（不是代码缺陷）**：DSH 沙箱（workspace-write）下，`CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, <其他进程 pid>)` 返回 `INVALID_HANDLE_VALUE` 且 `GetLastError = 5`（ERROR_ACCESS_DENIED）。实测：同一可执行文件对**自身 pid** 可取模块快照（16 个模块），对进程列表中任意**其他 pid** 一律 `err=5`。因此 `test_win32_child_process` 在默认沙箱下会在 `Processes.Attach` 处返回 `win32_module_snapshot_failed`。用 `danger-full-access` 重跑同一集成脚本即 PASS，确认是沙箱令牌限制而非实现缺陷。**结论：跨进程模块枚举类测试必须在 Full Access 下运行；默认沙箱下应视为环境限制，不要据此改动生产代码。**

**当前基线**：`SUMMARY pass=57 fail=0 skip=1 total=58`（默认沙箱），跨进程集成另计。

**临时诊断文件清理**：`tests/pascal/diag_child_attach*.pas`、`diag-child-attach.ps1`、`diag_ct_fixture*.pas` 已删除（仅用于本次定位，结论已归档于本节与 6.8 节）。`diag_replace*.pas`、`diag_save_edit.pas`、`diag_sdv_regions.pas` 因在 6.8/第 5 节有明确记录而保留。

### 6.10 事件证据持久化（1G 补齐，2026-10-20）
**问题**：`ICEAEventStore` 此前只有接口声明（`src/core/events/cea_event_types.pas`），`TCEAEventService` 的事件全在内存数组 `FEvents` 中，应用退出即全部丢失。FR-076（事件包）与 FR-083（删除后不得留下可恢复隐私副本）都要求落盘。

**新增 `src/infrastructure/cea_event_repository.pas`**
- `TCEAEventRepository = class(TObject, ICEAEventStore)`，仿 `cea_profile_store.pas` 的 SQLite 模式（`TSQLite3Connection` + `TSQLTransaction`，`EnsureConnected`，`INSERT OR REPLACE` upsert，`Q.Free` 放在 except 之后）。
- 表 `event_packages(event_id TEXT PRIMARY KEY, process_identity_id TEXT NOT NULL, created_at_ms INTEGER NOT NULL, payload_json TEXT NOT NULL)` + 索引 `idx_events_process`。
- 除接口四方法（`SaveEvent`/`LoadEvent`/`ListEvents`/`DeleteEvent`）外，增加 `Initialize` 与 `ListEventsForProcess(const AProcessIdentityId: string; out AEvents)`。
- **FR-083 实现细节**：`DeleteEvent` 在事务提交后执行 `VACUUM`（VACUUM 不能在事务内），使被删行不再残留于 SQLite 空闲页；VACUUM 失败被吞掉，不影响删除语义。
- 错误码：`event_database_path_required`/`event_database_open_failed`/`event_store_initialize_failed`/`event_invalid`/`event_save_failed`/`event_id_required`/`event_not_found`（rcUnknown）/`event_payload_invalid`/`event_load_failed`/`event_process_identity_required`/`event_list_failed`/`event_delete_failed`。

**改造 `src/core/events/cea_event_service.pas`**
- 新增 `FEventStore: ICEAEventStore`、`SetEventStore`、`ReloadFromStore`、私有 `PersistEvent(const AIndex: Integer)`（未装配存储时 no-op）。
- `AssembleEvent` 末参数由 `const AFieldId, AValueJson: string` 改为 `const AUserTagsJson: string`：标签在**建事件之前**确定，`MarkEvent` 的标签才能真正落盘（原实现先建事件再改 `UserTagsJson`，落盘会丢标签）。合并分支与新建分支末尾各调 `PersistEvent`。
- `ObserveField` 触发时传 `'["field:' + JsonEscape(AFieldId) + '"]'`；`MarkEvent` 先算 `TagsJson` 再传入。
- `DeleteEvent` 在内存移除后同步调 `FEventStore.DeleteEvent`；`MarkAnalysisState` 返回前 `PersistEvent`。
- **`ReloadFromStore` 恢复事件序号**：事件 ID 形如 `event-00000001`，重启后从已载入的最大序号继续，否则新事件会复用旧 ID 覆盖历史。返回 `{"count":N,"next_sequence":M}`。

**接入主程序 `src/app/cea_application_runtime.pas`**
- 新增私有字段 `FEventStore: TCEAEventRepository`。
- `Start` 中（`FDisplayEnumerator` 之后）：`events.sqlite3`（与 `governance.sqlite3`/`profiles.sqlite3`/`ui-layout.sqlite3` 同目录）→ `Initialize` → `FEventService.SetEventStore(FEventStore)` → `ReloadFromStore`；任一失败即 `raise`。
- `Stop` 中 `FreeAndNil(FEventService)` 之后 `FreeAndNil(FEventStore)`。

**验证**
- 新增 `tests/pascal/test_event_repository.pas`（7 组断言）：落盘与 14 字段往返、缺失事件 `event_not_found`、列表与按进程过滤、服务装配后 `MarkEvent`/`ObserveField` 自动落盘、`DeleteEvent` 同步清除、**重启后 `ReloadFromStore` 续号到 `event-00000003` 不覆盖历史**、清空后重复删除返回 `rcUnknown`。→ `EVENT_REPOSITORY=PASS`。
- `PASCAL_COMPILE_SMOKE=PASS`（21955 行）；`STANDALONE_APP_RUNTIME=PASS`（接入未破坏既有行为）。
- 已登记 `build/unit-manifest.txt` 与 `tests/pascal/compile_smoke.pas`。

### 6.11 副屏宿主：本地回环 HTTP（1D 补齐，2026-10-20）
**问题**：1D 此前只到 `BuildUiRenderJson`（产出渲染 JSON），没有真正可打开的页面。PRD FR-023 要求「通过本地 WebView 或本地服务，不要求把实时游戏数据上传云端」。

**选型决策**：用**本地回环 HTTP 服务**，不嵌 WebView2。理由：LCL 无内建 WebView2 组件，自建 COM 宿主需要额外运行时与注册表依赖，且在 DSH 沙箱下无法验证窗口；本地服务方案只用 FPC 自带的 `fphttpserver`，零新增依赖，且天然满足 FR-023「本地运行」。浏览器作为渲染容器，桌面端负责起停与打开。

**新增 `src/ui/cea_secondary_screen_host.pas`**
- `TCEASecondaryHttpServer = class(TFPHttpServer)`：仅把 protected 的 `Address` 重新 public，用于绑定 `127.0.0.1`。
- `TCEASecondaryScreenHost`：`Create(const AToken)`、`Start(const APreferredPort, AAttempts: Word; out ASelectedPort: Word)`、`Stop`、`RevokeToken`、`Endpoint`。
- 回调类型：`TCEARenderCallback = function(const ALayoutSchemaId: string): TCEAResult of object`；`TCEAWriteCallback = function(const AFieldId, ATargetValue, AExpectedCurrentValue: string): TCEAResult of object`。
- 路由：`GET /` 或 `/index.html` 返回内联页面（**需同时接受空 PathInfo 与 `/`**，不同 FPC 版本对根路径的解析不同）；`GET /api/render?token=..&schema_id=..`；`POST /api/write?token=..`；其余 404。
- **鉴权**：所有路由（含首页）都要求 `token` 查询参数，缺失或错误一律 401；`RevokeToken` 后旧令牌立即失效。
- **fail-closed 三态**：未装配 `OnRender` → 503；未装配 `OnWrite` → **403 + `write_not_enabled`**；回调返回失败 → 200 但原样回传稳定码，绝不伪装成功。
- 回调用 `TCriticalSection` 串行化，避免并发触碰非线程安全的运行时状态。
- `Stop` 先 `FServer.Active := False` 再打一次 `/__stop__` 唤醒监听线程，确保关闭能被观察到。

**接入主程序 `src/app/cea_application_runtime.pas`**
- 新增字段 `FSecondaryScreen: TCEASecondaryScreenHost`、`FSecondaryScreenPort: Word`。
- 公开 API：`StartSecondaryScreen(const AEnableWrites: Boolean; const APreferredPort, AAttempts: Word)`、`StopSecondaryScreen`、`SecondaryScreenEndpoint`、`SecondaryScreenRunning`。
- **写入默认关闭**：`StartSecondaryScreen` 只在 `AEnableWrites = True` 时装配 `OnWrite`；装配后也只转发到 `WriteFieldValue`（即 `TCEAFieldCommandBus` 的受治理路径：`faVerifiedWritable` + compare-write-readback + 写后独立重读），副屏因此不可能绕过治理直接写内存。
- `Stop` 中在 `FCaptureService` 之后释放 `FSecondaryScreen` 并清零端口。

**接入主窗体 `app/lazarus/cea_main_form.pas`（副屏页签）**
- 新增 `FSecondaryStatusLabel`、`FSecondaryStartButton`（「启动副屏宿主（只读）」）、`FSecondaryOpenButton`（「在浏览器打开」）、`FSecondaryStopButton`。
- 新增方法 `StartSecondaryScreen` / `StopSecondaryScreen` / `OpenSecondaryScreen`（用 `LCLIntf.OpenURL` 调系统默认浏览器）/ `UpdateSecondaryStatus`（按运行状态刷新标签与按钮可用性）。
- `Destroy` 中在 `FreeAndNil(FRuntime)` 之前调 `FRuntime.StopSecondaryScreen`，避免进程退出时端口悬挂。

**验证**
- 新增 `tests/pascal/test_secondary_screen_host.pas`（12 组断言）：回环绑定与 endpoint 形状、无/错令牌 401、未装配渲染 503、带令牌渲染成功且 `schema_id` 正确转交、渲染失败原样回传 `model_empty`、未装配写入 403 `write_not_enabled`、装配后写入参数逐个转交、拒绝写入时不出现 `"verified":true`、不完整/非法 JSON 400、未知路由 404、`Stop` 后连接失败。→ `SECONDARY_SCREEN_HOST=PASS`。
- `PASCAL_COMPILE_SMOKE=PASS`（22558 行）；`PASCAL_APP_COMPILE=PASS`（22848 行）；`run-all-tests.ps1` → **`SUMMARY pass=59 fail=0 skip=1 total=60`**。
- 已登记 `build/unit-manifest.txt` 与 `tests/pascal/compile_smoke.pas`。

### 6.12 CE 下载 Phase A：GCM 目录加载（2026-10-20）

**新增 `src/domain/gcm/cea_gcm_types.pas` + `src/core/gcm/cea_gcm_catalog.pas`**

- 数据类型：`TCEACheatTableEntry`（`GameName`/`Origin`/`OfficialUrl`/`GcmUrl`/`Version`）、`TCEAGameTranslation`（`EnUs`/`ZhCn`/`SteamId`）、`TCEAGameMatch`（`Matched`/`EnName`/`ZhName`/`MatchScore`/`SteamId`/`Entries`）。
- 文本字段刻意用 `UnicodeString`：源 JSON 是 UTF-8，而本项目多数单元未声明 `{$codepage utf8}`。
- `TCEAGcmCatalog.Load` 读 `%APPDATA%\GameCheatsManager\`（或构造参数覆盖）下的 `cheat_table.json` 与 `translations.json`，`SetCodePage(AContent, CP_UTF8, False)` 后交给 `GetJSON`。实测：目录 537245 字节、翻译 380135 字节/**3533 条**。
- 匹配：`MatchProcessName` 归一化（小写、去扩展名、`_`/`-`/空格折叠）后与游戏名算相似度，`AMinScore` 由调用方定；`SearchGames` 按 40 分阈值过滤并去重，最多 200 条。
- 翻译：先按紧凑名键精确匹配 `en_US`，再回退到 `steam_id` 匹配。
- 永不联网：本阶段纯本地读取，不触碰 `gcm_url`。

**关键编码修复（本轮真实缺陷）**

1. `JsonEscapeUnicode` 原本输出 `\uXXXX`，但 FPC 3.2.2 的 `fpjson` 解码器 `UnescapeJSONUnicode` **无法还原任何 U+007F 以上的 `\uXXXX`**：`\u661f` 解成两个 `?`，`\u661f\u9732` 解成合法 UTF-8 + `?`。所有内部消费方（`GetJSON(R.DataJson)`）都读不回来。改为输出**原始 UTF-8**，返回类型改 `UTF8String`。
2. 只改返回类型仍不够：`TCEAResult.DataJson` 是 `string`（本机 cp936），把 `UTF8String` 拼进去会被**转码成 GBK**（实测 `E7 A9 BA…` → `BF D5 B6 B4…`）。新增 `Utf8JsonText(const AValue: UTF8String): string`，内部 `SetCodePage(Tmp, CP_UTF8, False)` 只改标签不转码；`MatchProcessName`/`SearchGames` 的 JSON 组装全部改用 `UTF8String` 拼接再经该函数产出。
3. `SearchGames` 原先把各字段经 `UnicodeString` 中转再 `string(Json)` 转回，同样会转码；一并改为全程 `UTF8String`。

**验证**：新增 `tests/pascal/test_gcm_catalog.pas`（含中文名断言改为「解码后值相等」而非「字面量匹配 `\uXXXX`」）。→ `GCM_CATALOG=PASS`；全量 `SUMMARY pass=60 fail=0 skip=1 total=61`；`PASCAL_COMPILE_SMOKE=PASS`（23347 行）。已登记 `build/unit-manifest.txt` 与 `tests/pascal/compile_smoke.pas`。

### 6.13 CE 下载 Phase B：本地复用 + 手动导入（2026-10-20）

**来源决策（方案 C）**：不做网络下载，只复用 GCM 已下载目录 + 操作者显式路径。理由见 `docs/ce-download-feature-design.md` §7.1：`gcm_url` 是 S3 filePath，真实下载需 `SIGNED_URL_DOWNLOAD_ENDPOINT` + `CLIENT_API_KEY` 签名，复用等于内嵌他人私有凭据。

**新增三个单元**

- `src/domain/gcm/cea_gcm_cheat_file.pas`：`TCEACheatFileSource`（`cfsGcmLibrary`/`cfsUserImport`）、`TCEACheatFileCandidate`（`Source`/`FilePath`/`FileName`/`GameName`/`Origin`/`Version`/`SizeBytes`/`ContentHash`）、`TCEACheatFilePublishResult`；常量 `CeaCheatFileMaxBytes = 16 * 1024 * 1024`、`CeaCheatFileLibraryDirectoryName = 'cheat-tables'`；`NormalizeCheatFilePath` 做路径穿越防护（规范化后必须仍在允许根目录内）。
- `src/core/gcm/cea_gcm_cheat_library.pas`：`TCEAGcmCheatLibrary`。`ScanGcmLibrary` 递归发现 `*.ct` 并读同级 `gcm_info.json`（`game_name`/`origin`/`version`）；`ImportFromPath` 校验存在性、扩展名、大小上限。`DefaultGcmTrainersDirectory` 返回 `%APPDATA%\GCM Trainers`。
- `src/core/gcm/cea_gcm_cheat_publisher.pas`：`TCEAGcmCheatPublisher`。流程 = 计算 SHA-256 → 写临时文件 → **原子发布** → 写 `.meta.json` 元数据 → `ListPublished` 扫描。

**五个真实缺陷（测试驱动发现）**

1. `RenameFile` 是 `MoveFileW`，目标已存在时失败 → 重发布永远失败。改用自声明 `MoveFileExW(..., MoveFileReplaceExisting)`。**不能 `uses Windows`**：该单元的 `BOOL`/`DWORD` 会与本地声明冲突（`Incompatible type for arg no. 1`）。
2. `FindFirst` 的 `TSearchRec` 与本地声明类型不匹配（`Got "TRawbyteSearchRec", expected "QWord"`）→ 改用 `FindFirstUTF8`/`FindNextUTF8`/`FindCloseUTF8` 或显式 `TSearchRec` 传递。
3. 递归扫描需要跳过 `.`/`..` 并对目录递归、对文件过滤扩展名（大小写不敏感）。
4. `gcm_info.json` 缺失时不能让整个扫描失败：游戏名/来源/版本留空，候选仍然可用。
5. 源文件在发现后、发布前被删除 → 必须返回稳定码（测试断言 `vanished source rejected` + 稳定码），不能在临时文件阶段才炸。

**验证**：`tests/pascal/test_gcm_cheat_library.pas` → `GCM_CHEAT_LIBRARY=PASS`（21 条断言，含缺失文件/错误扩展名/空路径/源文件消失/重发布替换）。全量 `SUMMARY pass=61 fail=0 skip=1 total=62`；`PASCAL_COMPILE_SMOKE=PASS`（24057 行）；`PASCAL_APP_COMPILE=PASS`（24490 行）。

**运行时接入**：`src/app/cea_application_runtime.pas` 装配 `FGcmCatalog`/`FGcmCheatLibrary`/`FGcmCheatPublisher`，公开 7 个 API：`LoadGcmCatalog`/`MatchGcmGame`/`SearchGcmGames`/`ScanGcmCheatFiles`/`ImportCheatFile`/`PublishCheatFile`/`ListPublishedCheatFiles`。`Stop` 中逆序释放。全部本地读取，不联网、不执行下载内容。

**schema**：`schemas/gcm/cheat-table-file.schema.json`（`source`/`file_path`/`file_name`/`game_name`/`origin`/`version`/`size_bytes`/`sha256`），已登记 `schemas/manifest.json`。→ `SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=104`。

**编码注意**：`TCEACheatFileCandidate` 的文本字段用 `UnicodeString`（同 6.12 理由）；JSON 输出前统一 `UTF8Encode`，否则中文游戏名会被转成 GBK 乱码。

### 6.14 CE 下载 Phase C：描述翻译 + Phase D UI 入口（2026-10-20）

**新增单元** `src/core/gcm/cea_gcm_description_translator.pas`：`TCEADescriptionTranslation`（`SourceText`/`TranslatedText`/`Translated`）、`TCEADescriptionBatch`（`SourceUri`/`ContentHash`/`Entries`/`RequestCount` + `Count`/`TranslatedCount`）、`TCEAGcmDescriptionTranslator`（`CollectDescriptions`/`Translate`），常量 `CeaTranslationDisclaimer = '机器翻译，仅供参考'`。

**安全边界（关键）**

- **只外发 `<Description>` 文本**：`CollectDescriptions` 只读 `TCTEntry.Description`，Auto Assembler（`AutoAssemblerText`）与 Lua（`LuaText`）永不进入 prompt。测试用 `Prompts` 断言实际外发内容。
- **结果仅作参考**：`TranslatedText` 与 `SourceText` 并存，不参与字段物化、地址解析或写入命令。
- **整批原子校验**：`ApplyTranslations` 先校验再提交。第一版逐条写入，`test_gcm_description_translator` 的 `unknown source` 用例立即暴露「半翻译泄漏」（第一条已写入，第二条才判定为编造）。改为 `Pending` 数组两趟：全部 source 精确匹配且条数一致后才一次性提交。错误码：`translation_response_invalid` / `translation_source_unknown` / `translation_entry_duplicated` / `translation_entry_count_mismatch`。

**编码链路（重要，复用 fpjson 时的固定套路）**

1. `Chat()` 返回信封 `{"provider_id":...,"content":"..."}`，模型输出是 `content` 里的**嵌套 JSON 字符串**，必须二次解析（`ExtractProviderContent`）。
2. 取 `content` 必须用 `TJSONObject.Get('content', UnicodeString(''))`。用 `string` 重载会把 UTF-8 字节按 cp936 打标签，后续 `GetJSON` 直接失败。
3. 解析出的 `UnicodeString` 再 `Utf8JsonText(UTF8Encode(...))` 打回 CP_UTF8 标签才能塞进 `TCEAResult.DataJson`。
4. `TCTEntry.Description` 由 `cea_ct_parser` 以原始 UTF-8 字节存入 AnsiString（带默认 cp936 标签），读取时必须 `UnicodeString(UTF8Decode(...))`，直接类型转换会得到 GBK 乱码。

**测试** `tests/pascal/test_gcm_description_translator.pas` → `GCM_DESCRIPTION_TRANSLATOR=PASS`（10 个用例，含去重、正常翻译、未知 source、缺条、provider 失败传播、空表零请求、按 `MaxEntriesPerRequest=2` 分三批、畸形 JSON、取消后不再调用 provider、无 provider、免责文案字面量编码校验）。

**运行时接入**：`TCEAStandaloneRuntime.TranslateCheatFileDescriptions(APath, ACancellation)`；未启动→`runtime_not_started`，未配置模型→`llm_not_configured`（不静默成功）。输出 JSON 含 `source_uri`/`sha256`/`disclaimer`/`requests`/`count`/`translated`/`entries[]`。

**Phase D UI 入口**：`app/lazarus/cea_main_form.pas` 的「CT RAG」页签加「翻译描述（机器）」按钮（`CTTools` 高度 82→118），点击先 `MessageDlg` 二次确认，明确告知只外发描述文本、脚本/地址/AOB 不外发。

**验证**：全量 `SUMMARY pass=62 fail=0 skip=1 total=63`；`PASCAL_COMPILE_SMOKE=PASS`；`PASCAL_APP_COMPILE=PASS`（24917 行）；`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=105`。

### 6.15 玩家级能力暴露为 MCP 工具（2026-10-20）

**背景**：Phase 1 的玩家级能力（字段模型、映射、采集、写入、UI 渲染、事件、GCM 目录）此前只能由本机 UI 调用，MCP 客户端看不到。本次把它们注册进 `TMCPToolRegistry`，同时保持「MCP 永不是审批面」这条硬约束。

**注册工具（23 个，registry 从 27 → 50）**

- 会话：`cea.start_game_session`、`cea.end_game_session`
- 字段读：`cea.list_game_fields`、`cea.capture_field_value`、`cea.list_field_mappings`
- 字段提案（仅提案）：`cea.declare_field`、`cea.propose_ai_field_mapping`、`cea.confirm_field_mapping`、`cea.reject_field_mapping`
- 字段写（仅申请）：`cea.confirm_field_writable`、`cea.write_field_value`
- 渲染/布局：`cea.build_ui_render_json`、`cea.enumerate_displays`
- 事件：`cea.mark_event`、`cea.list_events`、`cea.delete_event`
- GCM：`cea.match_gcm_game`、`cea.search_gcm_games`、`cea.scan_gcm_cheat_files`、`cea.list_published_cheat_files`
- CE 文件库（仅申请）：`cea.import_cheat_file`、`cea.publish_cheat_file`、`cea.translate_cheat_descriptions`

**关键设计（fail-closed，与 `cea.request_memory_write` 同构）**

- **所有变更类玩家操作一律返回 `rcApprovalRequired`**，稳定码 `local_operator_approval_required`，`DataJson` 带 `{"approval_surface":"local_ui_only","surface":"<declare_field|field_write|field_mapping_review|propose_ai_field_mapping>"}`。新增辅助函数 `ApprovalRequiredWithSurface`（`cea_application_runtime.pas` implementation 段）。
- **MCP 无法触达治理写入路径**：`cea.write_field_value` 不调用 `WriteFieldValue`，因此 `TCEAFieldCommandBus` 对 MCP 不可达；测试用 `Value[0] = $10` 断言目标内存未被修改。
- **只读工具真正执行**：`list_game_fields`/`capture_field_value`/`list_field_mappings`/`build_ui_render_json`/`enumerate_displays`/`list_events`/`match_gcm_game`/`search_gcm_games`/`scan_gcm_cheat_files`/`list_published_cheat_files` 直接转发到对应运行时 API。
- **CE 文件库的写面全在 MCP 之外**：`import_cheat_file`/`publish_cheat_file`/`translate_cheat_descriptions` 只返回 `rcApprovalRequired`。理由分别是：导入会改变本地知识库、发布会改变不可变库内容、翻译会把 CT 文本发往设备外（三者都不是「读」）。
- **会话生命周期由 MCP 可管**：`start_game_session`/`end_game_session` 是状态管理而非目标写入，允许 MCP 调用；会话结束后所有玩家级读取回到 `game_session_not_started`。
- 新增 `TCEAStandaloneRuntime.EndGameSession`（`procedure`）与 `GameSessionActive: Boolean`（读 `FGameModel <> nil`）。

**测试断言写法（重要教训）**：`TMCPProtocol` 会把 `DataJson` 用 fpjson 重新序列化成带空格的形式（`"game_name" : "Self Test Game"`），因此**不能用 `Pos('"key":"value"', Response)` 匹配 MCP 响应**。正确做法是 `GetJSON(Response)` 后用 `FindPath('result.structuredContent.data.<field>')` 取值比较。`registry` 层的 `CallTool` 返回值才是紧凑 JSON。

**测试**：`tests/pascal/test_standalone_app_runtime.pas` 新增 17 条断言（会话启动/字段列出/只读访问状态/MCP 不能声明/写入仅申请且内存未变/采集字节精确/渲染模型/事件标记/事件列出/事件删除/会话结束/结束后的 fail-closed/CE 文件库列出/导入发布翻译三者仅申请）。`tests/pascal/test_mcp_protocol.pas` 的 `Tools.Count` 断言 27 → 50，并新增 5 条「玩家级工具已列出」断言。

**计数教训**：工具数先后写成 46、51 都被 `test_mcp_protocol.pas:157` 断言挡下，实测为 50。新增工具时必须先跑该测试再定数字，不要凭清单口算。

**验证**：`SUMMARY pass=62 fail=0 skip=1 total=63`；`MCP_PROTOCOL=PASS`；`STANDALONE_APP_RUNTIME=PASS`；`PASCAL_COMPILE_SMOKE=PASS`；`PASCAL_APP_COMPILE=PASS`；`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=105`；`SCAFFOLD_ACCEPTANCE=PASS files=15 json=59`。

### 6.16 1D 增强：多页面 / 版本回退 / 自然语言定制（2026-10-20）

**背景**：PRD 的 FR-025（自然语言定制）、FR-026（页面版本回退）、FR-033（多页面）此前只有测试级单元，未接入运行时，副屏也只能渲染单页。

**三个单元（先有测试，后接入）**

- `src/domain/ui-schema/cea_ui_page_types.pas`（98 行）：`TCEAUiPage`（`PageId`/`Title`/`SchemaId`/`Version`/`Active`/`UpdatedAt`）、`TCEAUiSchemaVersion`、接口 `ICEAUiPageStore`（8 方法）。语义：**版本历史 append-only，回退 = 把旧 JSON 存成新版本，永不销毁版本**。
- `src/infrastructure/cea_ui_page_store.pas`（419 行）：SQLite 两表 `ui_schema_versions(schema_id,version,...)`（PK 复合）与 `ui_pages(page_id PRIMARY KEY,...,active)`；`NextVersion` 用 `COALESCE(MAX(version),0)+1`。错误码 `ui_page_not_found`/`ui_schema_version_not_found`/`ui_page_none_active`（rcUnknown）、`ui_page_fields_required`/`ui_page_schema_required`/`ui_page_id_required`/`ui_schema_id_required`/`ui_schema_version_required`（rcInvalidArgument）。
- `src/core/ui/cea_ui_customization_service.pas`（364 行）：`TCEAUiCustomizationService.ProposeFromInstruction` 让模型出整页 schema，`Sanitize` 做三件事——模型虚构的字段直接丢弃（PRD 7.6 禁止伪造字段）、把非 `faVerifiedWritable` 的 `uaEditable` 降为 `uaReadOnly`、全空则 `ui_proposal_no_usable_component`。`BuildPrompt` 只外发 `field_id`/`name`/`type`/`writable`，**永不外发值、地址、进程名**。

**运行时接入（`src/app/cea_application_runtime.pas`，现 3571 行）**

- 第 5 个 SQLite 库 `ui-pages.sqlite3`（与 `governance.sqlite3`/`profiles.sqlite3`/`ui-layout.sqlite3`/`events.sqlite3` 并列，同在数据目录）。
- 11 个公开 API：`SaveUiPage`/`ListUiPages`/`GetUiPage`/`SetActiveUiPage`/`GetActiveUiPage`/`ListUiSchemaVersions`/`RestoreUiSchemaVersion`/`SetSecondaryScreenPage`/`ProposeUiCustomization`/`ConfirmUiCustomization`/`RejectUiCustomization`。
- **`ConfirmUiCustomization` 只收 `proposal_id` + 目标 `page_id` + `title`，schema 从内存提案表取**：调用方无法伪造已确认的页面内容。未确认提案只存在内存（`FUiProposalIds`/`FUiProposalSchemas` 两个 `TStringList`），**永不落盘**。
- `TCEAUiCustomizationService.Provider` 改为 `read/write`：服务在 `Start` 里就要建好，但 provider 要到 `ConfigureLLM` 之后才存在，故 `ConfigureLLM` 成功后注入 `FLLMProvider`。
- `SecondaryScreenRender` 改为按 `schema_id` 参数当 `page_id` 去 `FUiPageStore.GetPage` 取已保存 schema 渲染；找不到就回退到 `BuildUiRenderJson` 自动生成，**副屏不会因为页面被删而白屏**。
- MCP 新增 11 个工具（registry 50 → 61）：读类 `cea.list_ui_pages`/`cea.get_ui_page`/`cea.get_active_ui_page`/`cea.list_ui_schema_versions` 真正执行；变更类 `cea.save_ui_page`/`cea.set_active_ui_page`/`cea.restore_ui_schema_version`/`cea.set_secondary_screen_page`/`cea.propose_ui_customization`/`cea.confirm_ui_customization`/`cea.reject_ui_customization` 一律 `rcApprovalRequired` + `local_ui_only`。

**两个真实缺陷（测试驱动发现）**

1. **`Exit` 丢返回值**：`ProposeFromInstruction` 里有 4 处 `if Response.Failed then Exit;`，裸 `Exit` 会丢掉 `Result`，表现为返回 `rcOk` 但 `StableCode=''`。必须写 `Exit(Response)`。
2. **`BuildPrompt` 的 `Raw` 必须是 `UTF8String`**：把 `JsonEscapeUnicode(...): UTF8String` 拼进 `string` 会被编译器按 `DefaultSystemCodePage=936` 转码，中文指令变成 GBK 字节（`把金币` → `B0 D1 BD F0`），模型收到乱码。

**测试隔离教训**：`TCEAStandaloneRuntime` 从数据库目录派生兄弟库（`ui-pages.sqlite3` 等），因此测试必须每次用**独立临时目录**（`cea-app-runtime-<pid>-<tick>`），否则上一轮的 `ui-pages.sqlite3` 会让版本号从 2 起，`version=1` 的断言失败。

**副屏页内切页（FR-033 落地到浏览器侧）**

- `TCEASecondaryScreenHost` 新增两个回调端口：`OnListPages`（只读列页）、`OnSelectPage`（切页）。新增两条路由：`GET /api/pages`、`POST /api/page`。**两者都要令牌**（缺失/错误 401），与首页一致。
- `GET /api/pages` 在未装配回调时返回 `{"pages":[],"count":0}` 而不是错误——切页控件因此可以总是存在，不会因宿主未接而报错。
- `POST /api/page` 未装配回调 → 403 `page_selection_not_enabled`；请求体 > 8KB → 413；非 JSON → 400 `page_body_invalid`；缺 `page_id` → 400 `page_request_incomplete`；页面不存在 → 200 + `{"error":"ui_page_not_found"}`（与 `/api/render` 的错误传递方式一致）。
- **切页不需要写开关**：它只改变呈现、不触碰目标内存。测试用「`WriteCalls` 计数在切页前后不变」断言这条不变量，而不是只断言返回码。
- 页面头部新增 `<select id="pageSel">`（含「Auto (current state)」空值项），每 10 秒轮询 `/api/pages` 刷新选项，切换时 POST `/api/page`。`select` 也给了 `min-height:44px` 与 `:focus-visible` 描边，符合 44px 触控与键盘可达性要求。

**桌面端入口（`app/lazarus/cea_main_form.pas`，现 3197 行）**

副屏页签新增 8 个控件与 8 个处理函数：保存当前页面（把当前渲染结果存为具名页面）、列出页面、让副屏渲染该页、列出历史版本、回退到该版本、生成改版提案、确认并保存、丢弃提案。`FPageIds: TStringList` 与 `FPageCombo` 的索引对齐，`Destroy` 里 `FreeAndNil(FPageIds)`。

**验证**：`UI_PAGE_STORE=PASS`；`UI_CUSTOMIZATION_SERVICE=PASS`；`STANDALONE_APP_RUNTIME=PASS`；`SECONDARY_SCREEN_HOST=PASS`；`MCP_PROTOCOL=PASS`；`SUMMARY pass=64 fail=0 skip=1 total=65`；`PASCAL_APP_COMPILE=PASS`；`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=108`；`SCAFFOLD_ACCEPTANCE=PASS files=15 json=59`。

### 6.17 指针链与模块偏移：跨进程重启的真实游戏定位（2026-10-20）

**背景**：真实游戏验证（Stardew Valley / Hollow Knight）暴露出根本缺口——`TCEAGameField.AddressHex` 只能存绝对地址，而 Unity IL2CPP 与 .NET 游戏每次重启都会重新分配托管堆，绝对地址必然失效。CE 的解法是「模块基址 + 偏移 + 多级指针」，本项目此前**完全没有**这套能力：`TCEACandidateKind` 里有 `ckPointerChain` 这个枚举值，但没有任何求值实现。

**求值语义（与 CE 的 `getAddress` 一致，已写入单元注释）**

```
address := moduleBase + baseOffset
for i := 0 to High(Offsets) do
  address := ReadPointer(address) + Offsets[i]
```

读取次数 = `offsets` 个数；最后一个偏移只相加、不再解引用；零偏移的链是纯模块相对地址，零次读取。深度上限 `CeaPointerChainMaxDepth = 8`。

**两个新单元**

- `src/domain/reverse/cea_pointer_chain.pas`：`TCEAPointerChainSpec`（`ModuleName`/`ModuleBaseOffset`/`Offsets`/`AddressWidthBits`，`IsValid` 要求宽度 ∈ [32,64] 且深度 ≤ 8 且模块名非空）、端口 `ICEAPointerMemoryReader`（只有 `ReadPointerBytes`，故求值器**在类型层面就不可能写入**）、`TCEAPointerChainResolver.Resolve(AModuleBase, ASpec, out AAddress)`、`ParsePointerChainSpec(AOffsetsJson, AModuleName, AModuleBaseOffset, AAddressWidthBits, out ASpec)`、`TryParseHexOffset`。
- `src/platform/windows/cea_win32_pointer_reader.pas`：`TCEAWin32PointerReader` 实现 `ICEAPointerMemoryReader`，另有 `ModuleBaseAddress(AModuleName, out ABaseAddress)`（走 `CreateToolhelp32Snapshot`）。**必须 uses `JwaTlHelp32`**——`Windows` 单元没有 `CreateToolhelp32Snapshot`/`Module32FirstW`，与 `cea_win32_readonly_backend.pas` 的做法一致。

**三个安全决策**

1. **每次读取都 `OpenProcess` + `CloseHandle`，不长期持句柄**：指针链只在声明/显式重解析/写入前求值，长持句柄只会拉长 stale-handle 窗口。
2. **只请求 `PROCESS_QUERY_INFORMATION or PROCESS_VM_READ`**：该单元永远不可能写目标。验收脚本把这条变成了硬断言（见下）。
3. **短读一律失败且 `Bytes := nil`**，绝不返回部分字节——否则会用缺失字节拼出假指针，写到错误地址。

**字段与映射层改造**

- `TCEAGameField` 新增 `ModuleName` / `PointerOffsetsJson` / `AddressWidthBits` 与 `HasPointerChain`（= `(ModuleName <> '') and (PointerOffsetsJson <> '') and (AddressWidthBits in [32,64])`）。`IsValid` 不变——链字段是可选的，不强制。
- `TCEAFieldMapping` 新增 `AddressWidthBits`；`TCEAMappingService` 新增 `ProposePointerChain`，`MaterializeField` 现在会把 `ModuleName`/`PointerOffsetsJson`/`AddressWidthBits` 一并物化到字段（否则链信息在物化那一步就丢了）。

**运行时接入（`src/app/cea_application_runtime.pas`）**

- 私有 `ResolvePointerFieldAddress(AFieldId, var AField)`：取 `CurrentIdentity` → `TCEAWin32PointerReader.Create(Pid, 64)` → `ModuleBaseAddress` → `ParsePointerChainSpec` → `Resolve`，成功后把解析出的绝对地址写回 `Field.AddressHex`。
- 公开 `DeclarePointerField(AFieldId, ADisplayName, AValueType, AModuleName, AOffsetsJson, AAddressWidthBits)`：声明即解析一次，让调用方立刻知道链是否成立；**解析失败仍保留字段**（链可能只是需要游戏进到主菜单），但返回失败结果 + `"resolved":false`。
- 公开 `ResolveFieldAddress(AFieldId)`：显式重解析。
- **`ConfirmFieldWritable` / `CaptureFieldValue` / `WriteFieldValue` 三个路径都在动作前重解析**。这是关键：写到一个陈旧地址不只是失败，而会破坏无关数值。
- `ListGameFields` 输出 `module_name`/`pointer_offsets_json`/`address_width_bits`/`has_pointer_chain`，客户端因此能区分「绝对快照」与「可重解析位置」。
- MCP 新增 2 个工具（registry 61 → 63）：`cea.resolve_field_address` 只读执行；`cea.declare_pointer_field` 走 `rcApprovalRequired` + `local_ui_only`（声明字段是改变模型的动作）。

**一个真实的 JSON 缺陷（测试驱动发现）**

`BoolToStr(Value, True)` 输出的是 Pascal 大小写 `True`/`False`，**不是合法 JSON**。这个缺陷此前藏在 `WriteFieldValue`、`CaptureFieldValue`、`SaveWindowPlacement`、`PublishCheatFile`、`StartSecondaryScreen`、`SaveUiPage` 六个返回体里——因为测试都用 `Pos('"verified":true', ...)` 匹配子串，而实际输出是 `"verified":True`，断言从来没有真正命中过布尔值。引入 `JsonBool(const AValue: Boolean): string` 统一出口后，测试改用 `GetJSON` + `FindPath` 真正解析返回体，缺陷才暴露并被修掉。

**教训**：子串断言会放过格式错误的 JSON。凡是要断言返回体里的字段值，都应 `GetJSON` 后取值比较——这也顺带验证了返回体是合法 JSON。

**同类的第二个 JSON 缺陷**：`ResolvePointerFieldAddress` 的成功返回体里 `'","depth":' + IntToStr(Spec.Depth) + '","access":"'` 多了一个引号，拼出 `"depth":1","access":...` —— 不是合法 JSON。直接调用方 `GetJSON` 失败会退化成空对象，MCP 层同样 `GetJSON` 失败后塞入空 `TJSONObject`，于是 `FindPath('...data.address')` 返回 nil，`.AsString` 触发 `EAccessViolation` 而不是断言失败。**教训**：这类缺陷的报错信号是访问违例而非断言失败，看到 AV 且栈在 `FindPath` 上，先怀疑上游返回体不是合法 JSON。

**测试自身的一处修正**：`test_standalone_app_runtime.pas` 在「死链探测」之后把 `ChainSlot` 重新指回 `ChainValueA`（777），但随后的 `ConfirmFieldWritable('test.chain', '1234', '4242')` 仍按旧 pointee 的 4242 做期望值，于是 `memory_effect_original_changed`。链字段的期望当前值必须来自**重解析后的当前 pointee**，这正是「写前重解析」生效的证据。

**验收脚本的两处收紧**

- `tests/acceptance/verify-scaffold.ps1` 与 `tools/schema-check/check-schemas.ps1` 原来只允许两个文件出现 `OpenProcess`/`ReadProcessMemory`。新增指针读取器后，改为显式白名单三个文件，并**额外断言指针读取器文本中不得出现 `WriteProcessMemory`/`PROCESS_VM_WRITE`/`PROCESS_VM_OPERATION`/`PROCESS_ALL_ACCESS`**——白名单是放宽，写权限断言是收紧，两者配套。

**验证**：`POINTER_CHAIN=PASS`；`WIN32_POINTER_READER=PASS`；`STANDALONE_APP_RUNTIME=PASS`；`MCP_PROTOCOL=PASS`；`SUMMARY pass=66 fail=0 skip=1 total=67`；`PASCAL_COMPILE_SMOKE=PASS`（27678 行）；`PASCAL_APP_COMPILE=PASS`；`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=110`；`SCAFFOLD_ACCEPTANCE=PASS files=15 json=59`。

### 6.18 CE 文件库页面：关闭 Phase D 的最后一项外观工作（2026-10-21）

**背景**：`docs/transformation-plan.md` 的「尚未完成」表里，「CE 下载独立页面」是唯一纯外观遗留项——Phase A/B/C 的模块、schema 与运行时 API 全部就绪，只缺 UI 入口。此前的入口只有「CT RAG」页签上的「翻译描述（机器）」按钮。

**主窗口改动（`app/lazarus/cea_main_form.pas`）**

- 玩家工作台左栏导航由 6 项变 7 项，新增第 6 项「CE 文件库」，原「设置与诊断」顺延为第 7 项（`SelectPlayerSection` 的索引映射同步从 0–5 改为 0–6）。
- 新增 section `FSecGcm: TPanel` 与三个字段 `FGcmQueryEdit`/`FGcmProcessEdit`/`FGcmMemo`，以及 6 个处理方法：`SearchGcmGames`/`MatchGcmProcess`/`ScanGcmCheatFiles`/`ListPublishedCheatFiles`/`ImportCheatFileIntoLibrary`/`PublishCheatFileToLibrary`。
- 控件布局：搜索行（游戏名 + 「搜索 GCM 目录」）、匹配行（进程名 + 「匹配游戏」）、操作行（扫描本地 `.CT` / 列出已发布 / 导入 `.CT` / 发布到文件库）、下方只读 `FGcmMemo` 显示返回 JSON。全部按钮 `min-height` 由 LCL 默认高度保证，与既有面板一致。

**四个交互决策**

1. **发布是唯一不可逆动作，单独二次确认**：`PublishCheatFileToLibrary` 先 `MessageDlg` 说明「写入受管文件库并记录 SHA-256、不执行脚本、不联网」，确认后才调用 `PublishCheatFile`。导入（`ImportCheatFileIntoLibrary`）只校验扩展名/存在/大小上限，不改动原文件，因此不弹确认，只在结果里提示「未执行、未修改原文件」。
2. **匹配阈值固定 60**：`MatchGcmGame(ProcessName, 60)`。`ScoreNormalizedNameMatch` 的分档是 100/95/80/70/token 命中率，60 以下基本是噪声匹配。
3. **空目录不当错误**：`ScanGcmCheatFiles` 成功但 `count:0` 时给的是信息提示「未发现本地 .CT 文件，可继续用导入」，而不是错误框——本机实测 `%APPDATA%\GCM Trainers` 下只有 4 个 `.ct`，空结果是常态。
4. **GCM 目录缺失时给可执行建议**：`SearchGcmGames` 失败时提示「若未安装 GCM，请改用扫描本地已有 .CT」，因为 `cheat_table.json` 来自 GCM 的设置库，未安装 GCM 的机器必然拿不到。

**一次编辑事故（已修）**：用 `edit` 替换 `ShowPlayerEvents` 时只匹配了函数头、把函数体删掉，文件短暂存在「有 `procedure` 头无 `begin`」的形态。随后立即用完整替换补回函数体并追加新方法。**教训**：替换整个过程时应把 `var`/`begin`/`end;` 一起写进 `old_string`，只匹配签名会留下半截过程。

**验证**：`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（27937 行，2713456 bytes code）；`SUMMARY pass=66 fail=0 skip=1 total=67`（默认沙箱，跳过的仍是参数化的 `test_win32_child_process.pas`）。文档同步：`docs/ce-download-feature-design.md` 的 Phase D 补 D3 条目，`docs/transformation-plan.md` 把「CE 下载独立页面」从「尚未完成」移到已完成表并改名为「CE 文件库页面」。

### 6.19 AOB 签名扫描的桌面入口（2026-10-21）

**背景**：AOB 能力在运行时层早已存在（`StartAobScan` / `GetAobScanUniqueness` / 无状态的 `JudgeAobUniqueness`），MCP 也暴露了 `aob_scan` 与唯一性判定，但桌面端只有数值扫描入口——玩家无法在 UI 里用签名定位，而签名唯一性是「真实写入验证」的前提。

**主窗口改动（`app/lazarus/cea_main_form.pas`）**

- 「进程与内存」页签的 `ScanTools` 面板由 176 增高到 204，新增第三行：`FScanModuleEdit`（模块名）、`FScanAobEdit`（签名，宽 320）、「扫描签名并判定唯一性」按钮、「重新判定唯一性」按钮（初始禁用）、`FScanAobLabel`（三态结果）。
- 新增 4 个字段：`FScanModuleEdit` / `FScanAobEdit` / `FScanAobJudgeButton` / `FScanAobLabel`，以及会话标记 `FScanIsAob: Boolean`。
- 新增 2 个处理方法：`StartAobSignatureScan` / `JudgeAobUniqueness`（后者与运行时同名方法重名，编译器按 `Self` 方法解析，无冲突）。

**五个交互决策**

1. **扫描前二次确认，文案写清「唯一才能当锚点」**：确认框列出 PID/epoch/模块/签名/预算，并明说「多命中会被判为歧义」与「只读扫描，不写入游戏」。
2. **扫描范围由模块基址自动钉死**：UI 不接受用户填地址，`StartAobScan` 内部用 `TCEAWin32PointerReader.ModuleBaseAddress` 取基址与 `size`，`max_regions=1`。这样签名扫描天然可重放（重启后模块基址变化但偏移不变）。
3. **预算上限沿用现有输入**：模块大小若超过「字节数」输入则截断到预算（`complete=false`），不另开一套输入框——与数值扫描的语义一致，减少玩家困惑。
4. **三态文案区分「签名不存在」与「签名歧义」**：`not_found` 提示「可能版本不同或签名错误」，`ambiguous` 提示「命中 N 处，不能作为写入锚点」。零命中不能与「进程里没有这个值」混为一谈。
5. **数值扫描与签名扫描互斥**：进入任一会话时清空另一类的标记（`FScanIsAob := False` / 禁用对方的按钮），结束会话时全部复位。签名会话期间模块名与签名输入框锁定，避免中途改签名导致判定对象与扫描对象不一致。

**验证**：`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（28382 行，2724368 bytes code）；`SUMMARY pass=66 fail=0 skip=1 total=67`。

### 6.20 指针链字段的桌面入口 + CT 基址偏移缺陷（2026-10-21）

**背景**：指针链能力（`DeclarePointerField` / `ResolveFieldAddress` / 写前重解析）已在运行时和 MCP 就绪，但玩家在 UI 里只能看到「游戏字段」列表，无法**声明**一个链字段，也无法把 CT 里的链搬进来——而链字段是「跨进程重启后仍能定位同一个数值」的唯一手段。

**主窗口改动（`app/lazarus/cea_main_form.pas`，28646 行）**

- 「游戏字段」section 在既有「读取当前值（采集）」按钮之后（`Top := 228` 起）新增一块「指针链」区域，复用上方已有的字段 ID / 字段名 / 值类型输入（`FFieldIdEdit` / `FFieldNameEdit` / `FFieldTypeBox`），新增 4 个控件：
  - `FFieldChainModuleEdit`（模块名，`TextHint='模块名，如 game.exe'`）
  - `FFieldChainOffsetsEdit`（链定义，`TextHint='{"base":"0x20","offsets":["10","8"]}'`）
  - `FFieldChainEntryEdit`（CT 条目键，`TextHint='CT entry_key'`）+ `FFieldChainButton`（「从 CT 条目填入」）
  - 下方「声明指针链字段」按钮（`Caption := '声明指针链字段'`）
- 新增 2 个处理方法：`DeclareChainFromCT`（校验链形态 → 二次确认 → `FRuntime.DeclarePointerField`）与 `LoadChainFromSelectedCTEntry`（`FRuntime.GetCTEntry` → 解析 → 回填两个输入框）。
- 没有单独的「重解析地址」按钮：`ResolveFieldAddress` 已在 `CaptureFieldValue` / `ConfirmFieldWritable` / `WriteFieldValue` 三条路径内部自动重解析，再开一个手动按钮只会制造「手动解析过的陈旧地址」这一额外状态。

**四个交互决策**

1. **声明前二次确认，且文案点明「初始只读」**：确认框列出字段 ID / 模块 / 基址偏移 / 解引用层数 / 地址表达式，并写明「声明后字段初始为只读；必须再走「验证字段可写」才能写入」。声明改变的是字段模型与写入目标，属于需要操作者知情的动作。
2. **声明成功但解析失败仍保留字段**：链字段的常见失败原因是「游戏还没进到能读该指针的界面」，此时地址无效但字段定义是对的。`DeclarePointerField` 返回失败体里带 `resolved:false` 与 `detail`，UI 据此提示「字段已声明，但当前无法解析该链」并列出「模块名拼写、游戏还没进入存档、基址偏移失效」三种常见原因，然后照常刷新字段列表。
3. **提交前先用纯函数校验链形态**：`DeclareChainFromCT` 先调 `ParsePointerChainSpec(OffsetsJson, ModuleName, 0, 64, Spec)`，格式错就直接提示期望形态。否则明显写错的链会被运行时物化成字段后才在解析阶段失败，错误更难懂。
4. **按 CT 条目填充只搬数据、不自动声明**：填充后玩家可以先核对链定义再决定声明。CT 是外部来源，直接声明等于让外部文件决定写到哪个地址。CT 条目缺模块名或地址是绝对地址时明确拒绝（见下）。

**本轮发现的真实缺陷：CT 基址偏移丢失**

CE 把模块相对条目的基址偏移写在**地址表达式**里（`<Address>SampleOfflineGame.exe+0020</Address>`），`<Offsets>` 只存解引用之后的各级偏移（`10`、`8`）。最初的 `LoadChainFromSelectedCTEntry` 只搬 `<Offsets>`，于是 `base` 恒为 0——整条链从模块基址 0 开始解析，算出的是错误地址，且因为是「合法数字」而不会报错。

修复：在域层新增 `ParseCTAddressExpression(AAddressExpression, out AModuleName, out ABaseOffset): TCEAResult`（`src/domain/reverse/cea_pointer_chain.pas`），把「地址表达式 → 模块名 + 基址偏移」这一条 CE 语义收敛到唯一实现，UI 与任何未来的导入路径共用。拒绝三类输入：无 `+`（绝对地址，`ct_address_expression_not_module_relative`）、`+` 后为空或非十六进制（`ct_address_expression_offset_invalid`）、模块名为空（`ct_address_expression_module_missing`）。UI 再校验解析出的模块名与条目的 `module` 字段是否一致，不一致以条目字段为准并提示。

**测试**：`tests/pascal/test_pointer_chain.pas` 新增 7 组断言（共 10 条）覆盖上述语义：`SampleOfflineGame.exe+0020` 拆出模块名与 `0x20`、`game.exe + 0x1A8` 带空格形态、`game.exe+` 被拒、`0x1234` 被拒而非误读、`+20` 缺模块名被拒、`game.exe+zz` 被拒、空白表达式被拒。`POINTER_CHAIN=PASS`。

**验证**：`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（28646 行，2732624 bytes code）；`SUMMARY pass=66 fail=0 skip=1 total=67`。

**教训**：外部格式（CE 的 `.CT`）的语义必须落到有测试的域层函数上。埋进 UI 事件处理器的解析逻辑既不会被测试覆盖，也最容易「少搬一个字段」——而这次少的那个字段恰好是整条链的起点。

### 6.21 PRD 6.9 事件分析与证据关联（FR-090~094，2026-10-21）

PRD 第 6.9 节（`ceagent.md:297-307`）定义了五条 P0/P1 需求，但改造计划与代码里此前**完全没有对应条目**——这是本轮发现的唯一一处「需求层面真空」，而非实现缺口。五条需求分别是：事件摘要（FR-090）、证据分级（FR-091）、多轮关联（FR-092）、验证建议（FR-093）、事件驱动的 UI 更新（FR-094）。

#### 设计取舍

- **证据分级是硬约束，不是展示字段。** 五级 `TCEAEvidenceGrade`：`egDirectObservation` / `egRepeatedVerification` / `egUserConfirmed` / `egAiHypothesis` / `egVisualInference`。只有前三级算「可写入理由」（`IsWriteJustifyingGrade`），后两级恒为「仅建议」（`IsAdvisoryGrade`）。AI 触发的事件（`etAiSuggested`）即使观测到了确定的值变化，也只能降到 `egVisualInference`——推断永远不能反过来变成证据，否则「AI 说这个字段可写」就绕过了整条治理链。
- **建议是建议，不能变成按钮。** `TCEAVerificationSuggestion` 的 `Advisory` 与 `RequiresApproval` 恒为 True，序列化后由 UI 渲染成纯文本。FR-093 要求「执行扫描、写入和高成本任务仍须确定性规则及用户授权」，所以建议里绝不能带可直接执行的地址或参数。
- **外发模型要当场同意，且同意粒度到单次调用。** `AnalyzeEventWithProvider(EventId, FieldId, ConsentToSendValues)` 的 `ConsentToSendValues` 是必填参数，运行时不缓存、不记忆；未同意时走纯本地分析。MCP 侧的 `cea.analyze_event_with_model` 则固定返回 `rcApprovalRequired` + `local_ui_only`——与所有变更类工具一致，模型永远无法自己批准外发。
- **只读推导可以完全在本地做。** 摘要、分级、趋势关联都不需要模型，因此 `cea.analyze_event` / `cea.get_field_trend` 对 MCP 开放（`readOnly=true`）。这符合「本地确定性优先」：能用规则算出来的，就不要问模型。

#### 一个真实缺陷（本轮修掉）

`BoolToStr(Value, True)` 输出的是 Pascal 大小写的 `True`/`False`，不是合法 JSON。事件分析服务的第一版在摘要与趋势里用了它，导致下游 `GetJSON` 解析失败——而失败发生在 MCP 分发层的 `BuildToolCall` 里，表现为**访问违例而不是断言失败**（与此前指针链那次同一个陷阱）。修法：服务内新增局部 `JsonBool`，运行时侧复用既有的 `JsonBool`，测试断言也从 `"changed":True` 改为 `"changed":true`。

顺带发现测试自己写错了断言（`Pos('"changed":True', Digest)`）——它实际上在断言一个 bug。**测试断言了错误的行为时，绿灯比红灯更危险。**

#### 接入与验证

- 运行时新增 4 个 API：`AnalyzeEvent` / `CorrelateEventField` / `SuggestEventVerification` / `AnalyzeEventWithProvider`；`AnalyzeEvent` 成功后把事件的 `AnalysisState` 从 `eaUnanalyzed` 推进到 `eaAnalyzed`（FR-094：时间线上要能区分「还没看」和「看过了、结论是推断级」）。
- MCP：新增 `cea.analyze_event`、`cea.get_field_trend`、`cea.analyze_event_with_model` 三个工具，registry 64 → 67；`test_mcp_protocol.pas:157` 的 `Tools.Count` 断言同步改为 67。
- 桌面端：「事件时间线」section 新增事件列表（点击即填入事件 ID，避免手抄 16 位 ID）+「分析证据强度」+「关联该字段变化」+「交给模型解读（会外发数值）」。模型解读单独二次确认，文案明确写出「发送后无法撤回」。
- 验证：`EVENT_ANALYSIS=PASS`（新增 `tests/pascal/test_event_analysis.pas`，259 行，覆盖摘要/分级/关联/建议/模型同意五个面）、`MCP_PROTOCOL=PASS`、`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（29904 行）、`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=111`、全量 `SUMMARY pass=67 fail=0 skip=1 total=68`。

#### 教训

**先核对需求清单，再核对代码。** 这一轮之前的所有工作都是「已实现的东西怎么改得更好」，而 FR-090~094 是「需求里写了、计划里没有、代码里也没有」——只读代码永远发现不了这种空洞，必须拿 PRD 的 FR 编号去对照改造计划。后续每完成一个阶段，都应该反向扫一遍 PRD 的 FR 编号，确认没有第二个这样的洞。
### 6.22 PRD 6.7 Game Profile 接通：从「有测试的死代码」到真实调用链（2026-10-21）

#### 空洞的发现方式

上一节（6.21）的教训是「拿 PRD 的 FR 编号反向扫改造计划」。照着做之后，第一个被扫出来的不是缺失的 FR，而是一个**存在但没接线的模块**：Phase 1F 的 Game Profile 在 `src/app/cea_application_runtime.pas` 里只有创建与释放（`FProfileStore`/`FProfileService`），**没有任何调用方**。它的单元测试 `test_profile_service.pas` 一直是绿的，因为测试直接构造了 service；但应用层从来没调用过它，玩家点不到任何入口。

这和 FR-090~094 的空洞性质不同，却同样只读代码看不出来：代码都在、测试都绿、计划表里也打了勾。**「有测试」不等于「被使用」。**

#### 两个真实缺陷

1. **指针链配方没有落盘。** `SaveFromModel` 只序列化了 8 个字段（field_id / display_name / value_type / source / access / validation_status / address_hex），**没有 `module_name` / `pointer_offsets_json` / `address_width_bits`**。也就是说存下来的 Profile 只有一次性的绝对地址快照；游戏一重启，Profile 里全是读不出来的旧地址——而 Profile 的全部价值恰恰是跨会话复用。已补全 6 个字段（含 confidence / constraints_json / evidence_refs_json）。

2. **`BoolToStr(X, True)` 又一次产出非法 JSON。** `LoadForGame` 的成功体用了它，输出 Pascal 风格的 `True`。这是本项目第三次踩同一个坑（指针链、事件分析、这里）。修法：`cea_profile_service.pas` 内加局部 `BoolToJson`。

#### 设计决定：Profile 不携带可写性

新增 `RestoreInto` 把 Profile 的字段集合还原进状态模型，三条硬约束：

- **一律 `faReadOnly`**，不还原 `access`。上一轮的 `verified_writable` 是「那个进程、那个地址」的证明，对新进程无效。
- **一律 `vsObserved`**，不还原 `validation_status`。否则一次存档就能把任意字段洗成 `vsVerified`。
- **不还原 `value_json`**，置空。那是上一轮进程里的瞬时值，当成当前值展示会直接误导玩家。

运行时侧 `RestoreGameProfile` 在版本不匹配（`Match.Compatible=False`）时，再把所有 `source='win32_memory'` 的字段降级为 `faInvalid` 并计入 `downgraded`——对应 FR-062「版本变化后 Profile 降级而不是静默失效」。

#### 接入与验证

- 运行时新增 `SaveGameProfile` / `RestoreGameProfile(AGameName)`；`SaveGameProfile` 会把当前激活的 UI 页面 schema 一起存进 Profile（`has_ui_schema` 标记），没页面也能存。
- MCP 新增 `cea.save_game_profile` / `cea.restore_game_profile`，两者都返回 `rcApprovalRequired` + `local_ui_only`（写持久配置、改活模型都属 FR-094 要求本地确认的范畴），registry 67 → **69**；`test_mcp_protocol.pas:157` 断言同步。
- 桌面端：「游戏字段」页新增 Game Profile 区块（保存当前 Profile / 游戏名输入 / 还原 Profile），还原前二次确认，还原后按 `compatible` 分两种文案。
- 测试：`test_profile_service.pas` 补指针链落盘与 `RestoreInto` 三条约束断言；`test_standalone_app_runtime.pas` 补端到端「保存 → 还原 → 字段退回只读 / 定位配方存活 / 不带旧值」与两条 MCP 负例。
- 验证：`PROFILE_SERVICE=PASS`、`STANDALONE_APP_RUNTIME=PASS`、`MCP_PROTOCOL=PASS`、`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（30254 行）、全量 `SUMMARY pass=67 fail=0 skip=1 total=68`。

#### 教训

**计划表上的勾不等于接线。** 后续每个标为「已完成」的模块，都要能回答一个问题：**应用层谁调用它、玩家从哪里点到它？** 回答不了的就是死代码，无论测试多绿。

### 6.23 FR-046 操作历史：写入账本从「只有治理层」到「玩家可见」（2026-10-21）

#### 空洞的性质

FR-046（P0）要求「记录时间、字段、原值、目标值、适配器、结果及错误信息」。这条需求在 Phase 0 里被**误判为已完成**：`docs/transformation-plan.md` 曾把 `src/infrastructure/cea_structured_log.pas` 标注为「空壳，PRD 需要真实操作历史日志」，随后 Phase 0 任务 1.3 把这个空壳删掉了 —— 但真实的操作历史**从未被重新实现**。

删掉空壳本身是对的，问题在于删完之后没人回头看这条需求。这和 6.21（FR-090~094 完全缺失）的区别是：那次连一行代码都没有，这次有一段被删掉的占位符，看起来像是「处理过了」。

#### 为什么治理账本不够

治理层 治理层有完整的 `Effect → Approval → Receipt → Proof` 链路，也有 SQLite ledger。但**玩家级写入根本不走那条链路**：

- `WriteFieldValue` 走 `TCEAFieldCommandBus`（`CompareWriteReadback` + 独立重读），产生的是 `TCEAFieldWriteResult`，只有 `Outcome`/`StableCode`/`DetailJson`，**没有 Receipt 也没有 Proof**。
- `ConfirmFieldWritable` 更彻底，它**绕过 CommandBus**，直接调 `FEffectBackend.CompareWriteReadback`，自己判一致性。

也就是说：治理层的账本记的是「治理层 授权的 effect」，玩家改游戏数值这件事在治理账本里**没有任何痕迹**。而后者才是这个产品真正会改变玩家游戏的动作。

#### 新单元

- `src/core/command/cea_write_journal_types.pas`：`TCEAFieldWriteRecord`（RecordId / Sequence / FieldId / DisplayName / ValueType / OriginalValue / TargetValue / AdapterId / AddressHex / ProcessIdentityId / Pid / Epoch / Outcome / StableCode / ErrorText / DetailJson / CommandSent / Verified / RecordedAt）+ `ICEAWriteJournalStore`。两个适配器常量把「哪条代码路径写的」变成可查询的事实：`CeaWriteAdapterCommandBus = 'command_bus/win32_compare_write_readback'`、`CeaWriteAdapterDirectVerify = 'direct_verify/win32_compare_write_readback'`。
- `src/core/command/cea_write_journal.pas`：`TCEAWriteJournal`，表 `field_writes`，`sequence INTEGER PRIMARY KEY AUTOINCREMENT` 保证顺序，`record_id TEXT NOT NULL UNIQUE` 保证幂等，两个索引（`field_id, sequence DESC` 与 `recorded_at`）。第六个独立 SQLite 库 `write-journal.sqlite3`。

#### 三个设计决定

1. **日志失败不得把写入结果翻成「没写」。** `JournalWrite` 在 `FWriteJournal=nil` 或 `AppendWrite` 失败时返回 `Ok('{}')` 并置 `ARecorded=False`，调用方把这个布尔作为 `journal_recorded` 字段返回。理由：写入已经落到目标进程了，账本写失败是**账本的问题**，不是写入的问题；如果因为记账失败就返回 `rcInternalError`，玩家会以为数值没改，而实际上已经改了。
2. **失败与成功的写入都要记。** `ConfirmFieldWritable` 有四个出口（`CompareWriteReadback` 失败 / 独立重读失败 / 重读不一致 / 成功），四处都记账。被拒的写入同样有审计价值：`outcome='rejected'` 能回答「为什么我按了按钮却没变」。
3. **账本只记「发生过的写入」，不记「尝试过的动作」。** 死链探测（`pointer_chain_null_pointer`）在写之前就退出了，不产生记录。端到端测试把这个语义钉死：`test.chain` 有 3 次真实写入、1 次死链探测，断言 `count = 3`。

#### 接入与验证

- 运行时：`ListFieldWriteHistory(AFieldId, ALimit)`，`ALimit<=0` 用默认 50、超 500 钳到 500；返回 `{"writes":[...],"count":N}`。`WriteFieldValue` 与 `ConfirmFieldWritable` 的成功体新增 `journal_recorded` 布尔。
- MCP：`cea.list_field_write_history`（readOnly=True, destructive=False, idempotent=True, capability `write_history`），registry 69 → **70**；`test_mcp_protocol.pas:157` 断言同步。**没有、也不会有对应的写工具** —— MCP 能读账本，但不能写入字段。
- 桌面端：「写入验证」section 新增「刷新操作历史」+ 列表（时间 / 字段 / 原值→目标值 / 结果 / 适配器），点一条把完整记录 JSON 放进右下输出区。列表项只用可读摘要，明细靠点击 —— 把一整行 JSON 塞进列表会立刻不可读。
- 验证：`WRITE_JOURNAL=PASS`（新增 `tests/pascal/test_write_journal.pas`，8 组断言含重开库持久性）、`STANDALONE_APP_RUNTIME=PASS`（新增端到端：3 条记录、最新在前、原值/目标值/适配器正确、`command_sent` 是 JSON 布尔、MCP 读到同样的 3 条）、`MCP_PROTOCOL=PASS`、`PASCAL_APP_COMPILE=PASS compiler=3.2.2`（30854 行 / 2791216 bytes code）、全量 `SUMMARY pass=68 fail=0 skip=1 total=69`。

#### 教训

**「删除空壳」和「实现需求」是两件事。** Phase 0 删掉 `cea_structured_log.pas` 时，计划表把它标成了「已处理」，但需求的满足状态并没有变化。凡是「因为它是空壳所以删掉」的条目，删完必须回到 PRD 看这条需求由谁承接 —— 否则空壳会变成一个更隐蔽的空洞：连占位符都没有了，搜索代码时连线索都找不到。

**字段声明与 FPC 的顺序约束。** 本轮两次撞到 `Error: Fields cannot appear after a method or property definition`：FPC 的 `private` 段里字段必须连续，方法声明不能夹在字段中间。加字段时如果顺手把方法声明写在字段后面，编译立刻失败。

### 6.24 事件录像与按需唤醒（FR-070/074/077/079，2026-10-21）
**问题**：事件证据链的三个环节此前全部「有代码、没人调」：
- `TCEAEventService.SetRecorder` 全项目零调用 → 每个事件包的 `recording_refs_json` 恒为 `[]`，FR-074（事件前后片段）名存实亡。
- `ICEAEventWakePort` 只有接口声明、无任何实现类 → `SetWakePort` 零调用，FR-077（按需唤醒）完全没有落点。
- `TCEAWin32RecordingCapture`、`TCEARecordingService` 只被测试引用，运行时零装配。

**三个新增单元**
- `src/platform/windows/cea_win32_window_locator.pas`：`TCEAWin32WindowLocator.FindMainWindow(APid, out AWindowHandle, out ATitle)`。此前全项目无 `EnumWindows`/`GetWindowThreadProcessId` 使用，而帧源必须拿到 `HWND` —— 这是整条链的起点缺口。选 `EnumWindows` 按 pid 过滤、优先可见且有标题的窗口，成功体带 `candidates` 计数便于诊断「多个候选窗口」的情形。
- `src/core/events/cea_event_recording_bridge.pas`：把 `ICEARecordingCapture`（抓帧）与 `TCEARecordingService`（缓存/淘汰/锁定）桥成同一个 `ICEARecordingCapture`，捕获成功才登记进缓存。**失败不登记**：否则缓存里会出现磁盘上并不存在的片段。
- `src/core/events/cea_event_wake_queue.pas`：`TCEAEventWakeQueue` 实现 `ICEAEventWakePort`，有界 FIFO（默认容量 8）。同一 event id 重复入队不占新位（返回 `duplicate:true`），满队丢弃最旧并累计 `DroppedCount`。**丢最旧而不是拒新的**：分析队列的价值在「最近发生了什么」，丢弃最旧的语义与人类注意力一致。

**运行时装配**（`src/app/cea_application_runtime.pas`）
- `Start` 中 `FEventService` 之后建 `FEventWakeQueue` 并 `SetWakePort`；`SetRecorder` 延迟到 `StartEventRecording`（因为需要窗口句柄）。
- 新增公开 API：`StartEventRecording(ADirectory, AFrameIntervalMs, ACacheDurationMs, AMaxDiskBytes, ARetentionMs)`、`StopEventRecording`（procedure）、`EventRecordingActive`、`EventRecordingEndpoint`、`ListRecordingSegments`、`SetRecordingSegmentLocked`、`QueueEventForAnalysis`、`PeekAnalysisQueue`。
- `StartEventRecording` 用 `TCEAWin32WindowLocator` 定位当前 pid 的主窗口，再 `TCEAWin32WindowFrameSource.Create(HWND, False)`（不含窗口边框）+ `TCEAWin32RecordingCapture` + `TCEAEventRecordingBridge`。
- **`FFrameSource` 的类型必须是类而不是接口**（`TCEAWin32WindowFrameSource` 而非 `ICEAFrameSource`）：CORBA 接口不参与引用计数，用接口字段保存会让帧源对象永远没人释放。这是本轮修掉的一个真实泄漏。

**MCP（70 → 76）**
`cea.start_event_recording` / `cea.stop_event_recording` / `cea.list_recording_segments` / `cea.lock_recording_segment` / `cea.queue_event_for_analysis` / `cea.peek_analysis_queue`。前三个变更类工具一律 `ApprovalRequiredWithSurface` —— 录像会持续读取游戏画面，属 FR-080 隐私范畴，不能由模型自行开启。

**验证**
- 新增 `tests/pascal/test_event_recording_bridge.pas`（7 组）与 `tests/pascal/test_event_wake_queue.pas`（7 组），全部 PASS。
- `test_standalone_app_runtime.pas` 新增端到端断言，其中 `StartEventRecording` **按结果分支**：测试进程没有游戏窗口，成功（`window_not_found` 之外的路径）与失败（`window_not_found`）都算正确，**不允许的是静默失败**。
- `PASCAL_APP_COMPILE=PASS`（31938 行 / 2810688 bytes code / 22 warning）、`MCP_PROTOCOL=PASS`、全量 `SUMMARY pass=71 fail=0 skip=1 total=72`。

**教训**
- **「有实现类」不等于「有装配点」。** 录像三件套与唤醒端口的代码都是完整的、也都有单元测试，但 `SetRecorder`/`SetWakePort` 从未被调用，等于整层不存在。检查一个能力是否真的生效，要 grep 它的**装配函数**有没有调用方，而不是看它的类有没有测试。
- **同一个 record 变量不能既作查询键又作 `out` 接收者。** `Cache.GetSegment(Segment.Id, Segment)` 中 `out` 形参在求值参数时就把 `Segment` 整体清零，`Segment.Id` 已是空串。改用字面量作键。
- **BOM 的取舍取决于是否加载 LCL**（详见 6.2 节修订）：`cea_main_form.pas` 保持无 BOM，测试文件用 `{$codepage utf8}`。
### 6.25 FR-052 证据记录：让「凭什么这么判断」变成可查的数据（2026-10-21）

#### 空洞的性质
PRD `FR-052（P0）证据记录：保存候选地址、数据类型、观察到的变化、适用进程/版本和验证结果`（`ceagent.md:266`）在改造计划里同样没有承接条目。代码侧看起来「有东西」：`src/core/reverse/cea_evidence_service.pas` 提供 `Add`/`Find`/`FindForTarget`/`Count`。但它是**内存数组**、**只被单元测试引用**、运行时 uses 里根本没有它。这和 6.22 的 Game Profile 是同一类问题：**有类、有测试、没有调用方**。

#### 与 FR-046 的分工（设计决定）
- FR-046 写入账本回答「我做过什么」：一次写入的字段、原值、目标值、适配器、结果。它的记录单位是**动作**。
- FR-052 证据记录回答「凭什么这么判断」：一次采集或一次验证的字段、地址、类型、观察值、进程身份、版本指纹、结论。它的记录单位是**判断依据**。
两者不能合并：同一次写入既产生动作（FR-046）又产生证据（FR-052），而采集只产生证据、不产生动作。

#### 新单元
- `src/core/reverse/cea_field_evidence.pas`：`TCEAFieldEvidence`（`EvidenceId`/`FieldId`/`DisplayName`/`Kind`/`AddressText`/`ValueType`/`PreviousValueJson`/`ObservedValueJson`/`ProcessIdentityId`/`Epoch`/`ExecutableSha256`/`ModuleSetHash`/`Outcome`/`DetailJson`/`ProvenanceUri`/`ContentHash`/`RecordedAt`）+ `TCEAFieldEvidenceService`（`RecordCapture`/`RecordVerification`/`RecordUserConfirmation`/`ListForField`/`Count`/`ToReference`）。复用既有 `TCEAEvidenceKind`/`TCEAVerificationOutcome`/`TCEAEvidenceReference`，不另造枚举。
- `src/infrastructure/cea_field_evidence_store.pas`：`TCEAFieldEvidenceStore`（表 `field_evidence`，索引 `idx_field_evidence_field(field_id, sequence DESC)`）+ `TCEAReverseEvidenceStore`（把同一张表适配成既有 `ICEAEvidenceStore`，供逆向编排复用）。
- 第七个独立 SQLite 库 `field-evidence.sqlite3`，与 `agentos`/`profiles`/`ui-layout`/`events`/`ui-pages`/`write-journal` 平级。

#### 三条硬规则（安全边界）
1. **`supports_write_claim` 只有 `ekMemoryObservation`/`ekVerification` 且 `voPass`/`voInconclusive` 才为真。** `ekUserStatement`（操作者说「这就是金币」）只命名字段，不证明可写；`ekCTArtifact`/`ekDisassembly` 是别的进程/别的版本的证据。`voFail`/`voUnknown` 是反证，更不能支撑。
2. **采集证据的 `Outcome` 恒为 `voPending`，验证证据必须显式给结论**（传 `voPending` 直接 `evidence_outcome_required`）。否则「我读过一次」会被误读成「我验证过」。
3. **内容哈希的种子必须含序号**（`FieldId + Observed + Previous + IdentityId + Epoch + RecordedAt + EvidenceId`）。同一字段连续两次读到同一个值是完全正常的（血量没变），若哈希只含值，仓储的去重逻辑会把第二次采集吞掉，时间线上就会出现「明明采集了却查不到」。

#### 接入与验证
- `CaptureFieldValue`：算出 `ValueText` 后、更新模型前调 `RecordCapture`，返回体追加 `evidence_id`/`evidence_recorded`。**先记录再改模型**，记录里保留真正读到的值。
- `ConfirmFieldWritable`：成功分支 `JournalWrite` 之后调 `RecordVerification(..., voPass, ...)`。
- `ListFieldEvidence`（新 API）+ `RecordFieldUserConfirmation`（新 API，返回体明写 `"note":"a user statement names the field, it does not prove writability"`）。
- MCP：`cea.list_field_evidence`（只读，可直接执行）与 `cea.record_field_confirmation`（`approval_required` + `local_ui_only`，MCP 不能自己造证据）。registry **76 → 78**。
- 桌面端「写入验证」页新增证据列表（摘要进列表、完整 JSON 点击查看）与「我确认这个字段就是它（留证据）」按钮。
- `FIELD_EVIDENCE=PASS`、`STANDALONE_APP_RUNTIME=PASS`、`MCP_PROTOCOL=PASS`、`PASCAL_APP_COMPILE=PASS`、全量 `SUMMARY pass=72 fail=0 skip=1 total=73`。

#### 教训
- **`FindPath` 找不到键时返回 `nil`，对 `nil` 调 `.AsBoolean` 是访问违例，不是断言失败。** 本次测试写成 `FindPath('...data.approval_required').AsBoolean`，而审批结果体里根本没有 `approval_required` 键（它是 `stable_code` + `approval_surface` + `surface`），于是得到 `EAccessViolation` 而不是「断言失败：MCP 不能自己造证据」。**写 MCP 断言前必须先看返回体的真实键名**；`approval_required` 只是文案里出现的子串，从来不是字段。
- **`FillChar(Record, SizeOf(Record), 0)` 会抹掉托管字段**（string/动态数组），并让编译器报 `function result variable of a managed type does not seem to be initialized`。record 清零一律用 `X := Default(TRec)`。
- **record 的方法体不能只写在 `interface` 段**，必须在 `implementation` 里给出实现，且单元头需要 `{$modeswitch advancedrecords}`，否则报 `Syntax error, "END" expected but "FUNCTION" found`。
- **绕过 `run-test-program.ps1` 直接跑编译产物会得到 `ct_database_open_failed`**：该脚本运行前把 `vendor\sqlite3` 加进 `PATH`，手工直编必须自己把 `sqlite3.dll` 放到位。调试期用 `-gl` 编到临时目录后，**收尾必须删掉该目录**，否则脚本的泄漏检查会阻断。
### 6.26 FR-051 分轮验证：把「预期」固定在动手之前（2026-10-21）

#### 空洞的性质
PRD `C:\Users\taitan666\Downloads\ceagent.md:265` 的 FR-051（P0）要求：每轮扫描或修改前，显示目的、操作和预期观察结果。全项目 grep `Purpose|ExpectedObservation|分轮` 只命中 4 处无关注释——**这条需求从来没被任何单元承接**。它与 FR-046（我做过什么）、FR-052（凭什么这么判断）构成三件套：FR-051 记的是「动手之前我以为会发生什么」。

#### 三条设计决定
1. **轮次是会话内计划，不落盘。** 持久事实已经在证据表（FR-052）与写入账本（FR-046）里；把旧意图也存下来，只会让下一轮误以为「还有人没交代」。
2. **同一时刻只允许一个未收尾轮次。** 允许并行规划等于允许「先扫了再补理由」——预期一旦可以事后追加，就永远可编。
3. **`MatchedExpectation` 必须操作者显式给出，不从数值推断。** 替操作者判断「这算符合预期」，等于伪造验收结论。

#### 一个真实缺陷：DataJson 的码页标签
`TCEAResult.DataJson` 由「字符串字面量 + 拼接」生成时，FPC 把结果标成 `DefaultSystemCodePage=936`，而字节其实是正确 UTF-8。`GetJSON` 的参数类型是 `TJSONStringType = UTF8String`，收到标签 936 的字符串会**再按 936 转码一次**：`找血量` 的末字节 `0x8F` 在 GBK 里是合法双字节前导，于是它把后面的闭合引号 `0x22` 当成尾字节吞掉，JSON 缺引号。

- 之前一直没暴露，是因为断言全用 `Pos(...)` 子串匹配，从不解 JSON；FR-051 是第一次对含中文的 payload 调 `GetJSON`。
- 修法不是逐个拼装点补，而是在契约源头打一次标签：`src/contracts/cea_results.pas` 新增 `Utf8JsonText`（`SetCodePage(Raw, CP_UTF8, False)`，不转码），`TCEAResult.Ok` 与 `TCEAResult.Error` 各过一遍；`src/mcp/cea_mcp_protocol.pas` 的 `RequestData`/`Data` 与 `src/mcp/cea_mcp_registry.pas` 的 `Arguments` 在 `GetJSON` 前也过一遍。
- `tests/pascal/test_contracts.pas` 故意**不加** `{$codepage utf8}` 以复现运行时状态，断言改用字节十六进制（`E689BEE8A180E9878F`）而不是字符串相等——因为期望值字面量在同一文件里也会被标成 936，字符串比较时自己就被转码了。撤掉 `Utf8JsonText` 后该测试精确复现 `EJSONParser: Error at line 1, Pos 36 ... got token "operation"`。

#### 接入与验证
- 新单元 `src/core/discovery/cea_discovery_round.pas`：`TCEADiscoveryRound`（RoundId/Sequence/Kind/Purpose/Operation/ExpectedObservation/FieldId/State/ObservedOutcome/MatchedExpectation/CreatedAt/CompletedAt）+ `TCEADiscoveryRoundService`（PlanRound/CompleteRound/AbandonRound/CurrentRound/GetRound/ListRounds/Count/Reset）；轮次 ID 形如 `round-00000001`。
- 测试 `tests/pascal/test_discovery_round.pas` → `DISCOVERY_ROUND=PASS`（12 组断言：必填门禁 / 活跃轮次冲突 / 状态机单向 / 放弃必须有理由且不可再收尾 / 长度上限 / limit 钳制 / 文本契约往返 / Reset 重置序号）。
- 运行时 5 个 API：`PlanDiscoveryRound`/`CompleteDiscoveryRound`/`AbandonDiscoveryRound`/`ListDiscoveryRounds`/`CurrentDiscoveryRound`；`EndGameSession` 时 `Reset`，因为轮次属于某一局。
- MCP 5 个工具（registry 78 → 83）：`cea.plan_discovery_round`/`cea.complete_discovery_round`/`cea.abandon_discovery_round` 一律 `ApprovalRequiredWithSurface('discovery_round', '{}')`；`cea.list_discovery_rounds`/`cea.get_current_discovery_round` 可读。**理由：替操作者声明「我预期看到 X」等于伪造验收标准，MCP 只能读不能规划。**
- 桌面端新增第 5 个导航项「分轮计划」：kind 下拉 + 目的/操作/预期/字段四个输入 + 规划（二次确认列出三项原文）+ 轮次 ID/实际观察 + 符合预期勾选 + 收尾/放弃 + 轮次列表。收尾与放弃都是二次确认；`FDiscoveryRoundIds` 保存原始轮次 ID，列表行只放给人看的摘要（不能从摘要里切 ID）。

#### 教训
- **「有测试」不等于「被使用」，此前已在 Game Profile 上吃过一次；这次的空洞更隐蔽——连代码都没有，只有 PRD 里一行字。** 只读代码永远发现不了「需求写了、计划没有、代码也没有」，必须拿 PRD 的 FR 编号反向扫改造计划。
- **同一族编码缺陷第三次出现（指针链、事件分析、此处），但每次表现形式不同。** 前两次是 `BoolToStr(X, True)` 产出 `True/False` 非法 JSON，这次是码页标签导致 `GetJSON` 二次转码。共同点是：**FPC 的字符串标签是隐式传播的，字节正确不代表标签正确。**
- **断言错误行为时绿灯比红灯更危险。** 本轮测试一度断言 `"changed":True`（大写），实际上那是在断言 bug。
- **FPC 匿名函数不可用**（`Illegal expression`），别照搬其它语言的写法。
### 6.27 FR-050 目标描述：让操作者用自己的话说想找什么（2026-10-21）

#### 空洞的性质
PRD `C:\Users\taitan666\Downloads\ceagent.md:264` 的 FR-050（P0）要求：用户可以用自然语言描述希望发现的字段。全项目 grep `TargetDescription|NaturalLanguage|自然语言|GoalStatement|DiscoveryGoal` 只命中 1D 的「自然语言改版 UI」（FR-025）——那是改界面，不是描述目标。**这条需求从来没被任何单元承接**，与 FR-046、FR-051、FR-052 同一族：需求写了、计划没有、代码也没有。

#### 三条设计决定
1. **目标只是意图，不是证据。** `TCEADiscoveryGoal.Advisory` 仅在模型提案时为真；任何目标都不产生地址、不产生可写性、不进入 `Game State Model`。模型给的 `field_id_hint`/`value_type_hint`/`behavior_hint` 全是提示。
2. **接受目标不授权任何动作。** `AcceptDiscoveryGoal` 的返回体恒带 `grants_scan:false` 与 `grants_write:false`，并附一句 `accepting a goal states intent, it does not authorise an action`。扫描仍要走分轮计划 + 治理租约，写入仍要字段先被验证为可写。**这一条是刻意的冗余：让调用方每次都被提醒一遍。**
3. **目标不落盘，且换游戏即 `Reset`。** 没有证据的目标是悬空意图；落盘会让下一次会话把旧愿望当成还没做完的义务。`EndGameSession` 里与分轮计划一起清空——换了游戏，「我在找金币」这句话不再指任何东西。

#### 一个真实设计缺口（测试逼出来的）
`TCEADiscoveryGoalService.Reject` 原先只接受 `dgoProposed`，于是「接受之后发现搞错了」无法否决（报 `discovery_goal_not_proposed`）。这不是测试写错，是设计缺口：人会先接受再改主意。改为——已 `rejected` 返回 `discovery_goal_already_rejected`；已 `superseded` 返回 `discovery_goal_not_proposed`；**`accepted` 允许被否决**，否决只是结束其活跃状态，已决定的事实不变。

#### 接入与验证
- 新单元 `src/core/discovery/cea_discovery_goal.pas`：`TCEADiscoveryGoal`（GoalId/Sequence/Description/FieldIdHint/ValueTypeHint/BehaviorHint/Rationale/Source/State/Advisory/CreatedAt/DecidedAt/RejectReason）+ `TCEADiscoveryGoalService`（ProposeFromOperator/ProposeFromModel/Accept/Reject/Current/GetGoal/ListGoals/Count/Reset）；目标 ID 形如 `goal-00000001`。
- 测试 `tests/pascal/test_discovery_goal.pas` → `DISCOVERY_GOAL=PASS`。调试中修掉三个真实问题：`StringToJSONString` 只转义不加引号（`"content":{\"...` 是裸对象而非字符串，服务端解析失败）；测试把时间戳传进了 `ABehaviorHint` 位置；列表断言拿被后续调用覆盖的变量做比较。
- 运行时 6 个 API：`ProposeDiscoveryGoal`/`ProposeDiscoveryGoalWithModel`/`AcceptDiscoveryGoal`/`RejectDiscoveryGoal`/`ListDiscoveryGoals`/`CurrentDiscoveryGoal`；`ProposeDiscoveryGoalWithModel` 在 `FLLMProvider=nil` 时返回 `llm_not_configured`，`AMaxOutputTokens=0` 回落 512。
- MCP 6 个工具（registry 83 → 89）：`cea.propose_discovery_goal`/`cea.propose_discovery_goal_with_model`/`cea.accept_discovery_goal`/`cea.reject_discovery_goal` 一律 `ApprovalRequiredWithSurface`；`cea.list_discovery_goals`/`cea.get_current_discovery_goal` 可读。**理由：意图只能由人给出，MCP 不能替操作者声明或接受目标。**
- 桌面端「分轮计划」页新增目标区块：描述输入 + 类型/变化两个下拉 + 字段提示 + 「记下这个目标」/「接受为当前目标」/「否决目标」+ 否决理由 + 当前目标状态行 + 目标 ID + 目标列表（点一条把 ID 填进来）。接受前二次确认，文案明写「不授权扫描、不授权写入」。下拉的「（类型不限）」项传空串给运行时——那一项是给人看的，传下去会被当成不存在的值类型整体拒绝。

#### 教训
- **FPC 的 `Text` 是 `TForm` 的既有属性名，和 `Active` 一样会撞 `Duplicate identifier`。** 这是本项目第二次在同一文件里踩 LCL 属性重名。
- **`FindPath(...).AsString` 会把 UTF-8 转成本地码页**，中文比较结果取决于编译期码页标签而非内容。断言中文一律用 `Pos('"key":"值"', DataJson) > 0`，因为 `DataJson` 已被 `Utf8JsonText` 打过 CP_UTF8 标签。
- **`StringToJSONString` 是转义器不是序列化器**：它把 `"` 变成 `\"`，但不加外层引号。拿它拼 JSON 字符串值必须自己补两端引号。

### 6.28 FR-042/FR-045 命令预览：把「即将覆盖什么」摆到确认框之前（2026-10-21）

#### 空洞的性质
PRD `ceagent.md:254` 的 FR-042（P0）要求「提交前展示字段、原值、目标值和目标适配器」，`ceagent.md:257` 的 FR-045（P0）要求「如果原值在编辑期间已经变化，提示用户刷新或重新确认」。这两条在代码里都没有对应实现：`Select-String 'Preview|preview'` 在 `src/app/cea_application_runtime.pas`、`src/core/command/*.pas`、`src/mcp/cea_mcp_registry.pas` 全部零命中。`WriteSelectedField` 当时的确认框只写「将把 <字段> 写入目标值」，既不显示原值，也不显示适配器，更不知道原值有没有变过——玩家是在看不见自己要覆盖什么的情况下按下「是」的。

#### 三条设计决定
- **原值必须实时读，不能复用 Game State Model 缓存。** 缓存里的是上一次采集时的值，可能是几分钟前的，进程重启后甚至已经被清空。展示一个不是「即将被覆盖的那个值」的原值，比不展示更危险。所以 `PreviewFieldWrite` 在有指针链时先重解析地址（解析失败只记 `live_read_stable_code` 不提前退出），再调 `FEffectBackend.ReadCurrentHex` 真读一次。
- **冲突比较字节，不比文本。** `1.5` 与 `1.50` 是同一个浮点数，按文本比会把它们判成冲突；`EncodeExactValue` 编码后比 hex 才是「同一个值」。
- **冲突不是错误结果。** 预览成功了，只是载荷里 `can_execute=false` + `blocking_reason`。返回 `rcInvalidArgument` 之类的错误会让 UI 没东西可显示，而恰恰是这时候玩家最需要看到「原值现在是多少、目标值是多少」。所以 `BlockingReason` 是分级字段而不是错误码：`field_not_verified_writable` → `original_value_unavailable`（读失败）→ `expected_value_changed`（冲突）。

#### 一个真实缺陷（本轮修掉）
`ToJson` 里布尔项前的分隔符被写成了 `'","live_read_failed":'`，产出 `..."blocking_reason":"","live_read_failed":false","live_read_stable_code":""}`——`false` 后面多了一个引号，JSON 缺闭合引号。测试只报 `EJSONParser: Error at line 1, Pos 477`，看不出是哪个键；写了个探针 `tmp-probe/probe.pas` 直调 `BuildWritePreview` 打印 `R.DataJson` 才定位到。规则：**布尔项前用 `',"key":'`（无前导引号），字符串项前用 `'","key":"'`。** 这是本项目第 N 次同类 JSON 拼接缺陷。

另一个同类陷阱：`TJSONObject.Get(AName)` 返回 `TJSONVariant`，对它调 `.AsBoolean` 会抛 `EVariantInvalidOpError: Invalid variant operation`（测试里 30 条 note 提示 `operator :=(Boolean):Variant`）。JSON 布尔一律用 `O.Get('key', False)` 这个重载。

#### 接入与验证
- 新单元 `src/core/command/cea_write_preview.pas`：`TCEAWritePreview`（FieldId/DisplayName/ValueType/AddressHex/AccessText/AdapterId/OriginalValue/OriginalBytesHex/ExpectedCurrentValue/TargetValue/TargetBytesHex/HasPointerChain/Conflict/WritableNow/RequiresConfirmation/BlockingReason/LiveReadFailed/LiveReadStableCode）+ `BuildWritePreview`；`CanExecute = WritableNow and not Conflict and not LiveReadFailed`。
- 测试 `tests/pascal/test_write_preview.pas` → `WRITE_PREVIEW=PASS`（11 组断言，含「float 格式不误判冲突」与「读失败时 blocking_reason=original_value_unavailable」）。
- 运行时 `PreviewFieldWrite(AFieldId, ATargetValue, AExpectedCurrentValue)`：实时读原值 → `BuildWritePreview` → 返回 `Preview.ToJson`。**预览永不写入、永不改模型，所以可以安全暴露给 MCP；写本身仍走 `cea.write_field_value` 的本地审批路径。**
- MCP 注册 `cea.preview_field_write`（readOnly=True、destructive=False、idempotent=True、capability `field_preview`），dispatch 直接执行 → registry 89 → **90**，`tests/pascal/test_mcp_protocol.pas:157` 断言改为 `Tools.Count = 90`。
- 桌面端 `WriteSelectedField` 改为「先预览 → 按 `can_execute` 分流 → 确认框里列出字段/原值/目标值/适配器 → 才写入」。冲突时弹「原值已变化，写入被阻止」并显示两个值，让玩家刷新后重新确认；读失败时弹「无法读取当前原值，写入被阻止」并给出稳定码。
- 端到端断言（`tests/pascal/test_standalone_app_runtime.pas`）：干净预览 `can_execute=true`/`requires_confirmation=true`；旧原值预览 `conflict=true` + `blocking_reason=expected_value_changed` + `can_execute=false`；**预览跑两次后 `ChainSlot^` 仍是 1234，证明预览没有写**；MCP 路径同一判定。
- 门禁：`PASCAL_APP_COMPILE=PASS`（22 warning）、`WRITE_PREVIEW=PASS`、`STANDALONE_APP_RUNTIME=PASS`、`MCP_PROTOCOL=PASS`、全量 `SUMMARY pass=75 fail=0 skip=1 total=76`、`SCHEMA_CHECK=PASS schemas=59 ids=59 manifest=58 units=121`、`SCAFFOLD_ACCEPTANCE=PASS files=15 json=59`。

#### 教训
- **确认框里没写出来的东西，玩家就是不知道。** FR-043 的「二次确认」只有在框里摆出真实事实时才有意义；只写「将写入 X」的确认框只是让玩家多点一次鼠标，不构成知情同意。
- **「预览」和「校验」要能分开看。** 预览是给人看的，所以它必须在被挡住的时候也成功返回内容；把「不能执行」表达成错误码，等于在最需要信息的时候把信息丢掉。
- **临时探针是定位 JSON 拼接缺陷的唯一有效手段。** 测试只报字符偏移，看不出是哪个键写坏了；直调构造函数打印 `DataJson` 一眼就能看见多出来的引号。用完必须删掉 `tmp-probe\`，否则 `compile-smoke.ps1` 的 `Build artifacts leaked into the project tree` 会阻断冒烟。
### 6.29 FR-041 输入校验：把「这个字段能接受什么值」变成数据（2026-10-21）

#### 空洞的性质
`TCEAGameField.ConstraintsJson` 从 Phase 1 起就存在于字段模型里，`schemas/state-model/field.schema.json` 也为它留了位置，但它在整个代码库里只有四处出现：定义（`src/domain/state-model/cea_field_model.pas:38`）、Profile 序列化（`src/core/profile/cea_profile_service.pas:103`）、Profile 还原（同文件 `:240`）、以及 UI builder 里一句注释「Phase 1 简化：暂不解析 ConstraintsJson 到组件 options」。**运行时从来没有读过它，更没有校验过任何写入值。**

这不是「功能不完整」，而是**比不完整更糟**：字段上明明写着约束，schema 也允许写，但约束从不生效。操作者以为声明了「金币上限 99999」，写入 99999999 依然成功。

同一轮扫描还发现第二个缺口：`EncodeExactValue` 只认 byte/word/dword/single/qword/double 六种，而字段模型与写命令 schema 都允许 `integer` 和 `bool`。于是任何 integer/bool 字段的写入、验证、预览都会报 `invalid_scan_value` —— 类型声明得出来，写不进去。

#### 六条设计规则（写在单元头注释里）
新单元 `src/core/command/cea_field_constraints.pas` 的每条规则都对应一种「静默失效」的可能：
1. **空 `ConstraintsJson` = 无约束，不是无效。** 否则所有历史字段都会一夜之间变成不可写。
2. **畸形约束是错误，不能静默跳过。** 跳过意味着「检查过且允许」与「从未检查」无法区分 —— 正是这次要修的那个 bug 的形态。
3. **未知键拒绝。** `{"maximun":100}` 拼错一个字母就会让上限静默消失。
4. **数值边界按数值比较，不按文本。** 文本比较会说 `"9" > "100"`。
5. **`allowed_values` 按编码字节比较。** 这样 `1.5` 与 `1.50` 是同一个值。
6. **只接受定宽数值类型。** bool/enum/string 在写入路径上没有编码能力，承诺校验它们就是承诺写入路径做不到的保证。

#### 两个真实缺陷
- **`Obj.Get('min', '')` 是字符串重载。** JSON 里 `"min":100` 是 jtNumber，该重载对非字符串返回默认值 `''`，于是每次解析都命中 `field_constraints_invalid`，min/max 全线失效，`ToJson` 输出 `{"has_min":true,"min":""}` —— 看起来解析成功了，其实边界是空的。修法是新增 `ReadBound`：`Find(AName)` 后按 `JSONType` 分别取 `jtNumber → Item.AsJSON`、`jtString → Item.AsString`。首轮测试 15 处失败里 13 处是这一个根因的下游表现。
- **`IsWritableValueType` 漏写了 `(AValueType = 'bool')`。** 布尔表达式里列了 byte/word/dword/integer/qword/single/double，唯独漏了刚加进来的 bool。

#### 三个设计决定
- **约束问题在预览里是 `blocking_reason`，不是错误结果。** 与 FR-045 的「冲突不是错误」同理：预览成功完成了预览，操作者需要看到载荷才知道要改什么。真正写入路径仍然硬拒。
- **加约束不需要二次确认，清约束必须确认。** 加约束只会让写入更难；清约束会放宽范围，而放宽是不可见的 —— 字段看上去没变，但下一次写入就通过了。
- **MCP 可以读约束，不能设约束。** `cea.set_field_constraints` 一律 `approval_required` + `local_ui_only`：约束决定一次写入能携带哪些值，放宽它是治理决定，不是读取。

#### 接入与验证
- 新单元 `src/core/command/cea_field_constraints.pas`：`TCEAFieldConstraints`（HasMin/HasMax/MinValue/MaxValue/AllowedValues）+ `ParseFieldConstraints`/`IsWritableValueType`/`ValidateFieldValue`；九个稳定错误码（`field_constraints_invalid`/`field_constraints_unknown_key`/`field_value_below_min`/`field_value_above_max`/`field_value_not_allowed` 等）。
- `src/domain/ce/cea_value_scan_types.pas` 的 `EncodeExactValue` 把 `integer`/`bool` 并入 4 字节分支，bool 接受 `true`/`false`/`1`/`0`。
- `src/core/command/cea_write_preview.pas` 加 `ConstraintsJson`/`ConstraintsSatisfied`/`ConstraintStableCode`，`CanExecute` 追加约束条件，`BlockingReason` 优先级变为 `field_not_verified_writable` → `constraints_not_satisfied` → `original_value_unavailable` → `expected_value_changed`。
- 运行时三处写路径全部前置校验：`ConfirmFieldWritable`、`WriteFieldValue`、`PreviewFieldWrite`；新增 `SetFieldConstraints(AFieldId, AConstraintsJson)`（空串清除；解析在声明期完成，避免「约束存进去了但每次写入都失败」）。
- 桌面「写入验证」页加约束输入框与保存/清除按钮；保存失败若含 `field_constraints_unknown_key` 会专门解释「拼错的键会被静默忽略，从而让上限形同虚设」并列出可用键。
- 端到端断言：声明 `{"min":100,"max":500}` 后预览 9999 → `constraints_satisfied=false` + `blocking_reason=constraints_not_satisfied`；`WriteFieldValue(9999)` 必须失败且**目标内存仍是 1234**；范围内写入 300 成功；清空约束后 9999 又可执行；`{"maximun":500}` 在声明期被拒。**被约束拒绝的写入不进操作历史** —— 它从未到达适配器，日志记的是「发生了什么」而不是「尝试了什么」。
- 门禁：`FIELD_CONSTRAINTS=PASS`、`WRITE_PREVIEW=PASS`、`STANDALONE_APP_RUNTIME=PASS`、`MCP_PROTOCOL=PASS`、`PASCAL_APP_COMPILE=PASS`（22 warning）、全量 `SUMMARY pass=76 fail=0 skip=1 total=77`、`SCHEMA_CHECK=PASS units=122`。

#### 教训
- **schema 里允许的字段不等于代码里读的字段。** `ConstraintsJson` 在 schema、模型、Profile、UI builder 里都出现过，四处都是「存在」，唯独没有一处是「使用」。要判断一个字段是不是死的，不能 grep 它出现几次，要看它有没有被**读取并据此做决定**。
- **类型声明与编码能力必须对齐。** `integer`/`bool` 在字段模型与写命令 schema 里是合法类型，在 `EncodeExactValue` 里却不存在 —— 这类缺口不会在声明处报错，只会在玩家点写入的那一刻报 `invalid_scan_value`。
- **JSON 数字不能用字符串重载读。** `Obj.Get(name, '')` 对 jtNumber 返回默认值而不是报错，这是最隐蔽的一类「解析成功但值为空」。
- **改注释时不要用 PowerShell 按索引切片。** 本次两次吞掉声明行（一次吃掉 `unit cea_field_constraints;`，一次把 `function` 头粘到注释末行）。含 JSON 花括号的说明要写成 `//` 行注释，且改动优先用编辑工具。
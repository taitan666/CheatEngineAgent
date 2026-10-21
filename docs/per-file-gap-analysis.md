# CheatEngineAgent 逐文件差距分析（复用 / 改造 / 删除）

**基于：** PRD V1.2（`ceagent.md` / `ceagentPRD_V1.2.docx`）+ 现有 `cheat-engine-agnet/` 全源码逐文件审读
**日期：** 2026-10-19
**配套：** 本文是 [transformation-plan.md](transformation-plan.md) 的逐文件细化，聚焦「每个现有文件：复用 / 改造 / 删除」的精确判断与理由。

---

## 0. 读法说明

每个文件标注三种处置之一：

| 标记 | 含义 |
|---|---|
| ✅ **复用** | 作为 PRD 产品层的底座直接保留，几乎不改（可能仅新增少量方法） |
| 🔧 **改造** | 保留主体，但需扩展/重构以承载 PRD 语义模型、Command Bus、Profile 等新概念 |
| ❌ **删除/替换** | 是 scaffold 空壳、被替代实现取代、或与 PRD 路线 A 冲突，应移除或重写 |

同时标注「现状」为 **真实实现** / **薄壳** / **空壳(stub)** 三档，避免把空壳误当成品。

---

## 1. 治理与执行内核（安全底座，PRD 可复用率最高）

### `src/core/governance/`

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `cea_policy_model.pas` | 真实（82 行） | ✅ **复用** | 硬否认清单 + 离线目标要求，是 PRD 9.1「默认只读/禁反作弊/禁多人」的现成实现。需在 `RequiresOfflineTarget` 里**新增** `write_field`、`save_profile_entry`、`recording_*` 等未来 capability id |
| `cea_lease_service.pas` | 真实（79 行） | ✅ **复用** | Lease+Epoch 校验是 PRD「进程切换/版本失效即拒绝旧命令」AC-008/013/016 的直接机制 |
| `cea_effect_service.pas` | 真实（225 行） | ✅ **复用** | Effect→Approval→Receipt→Proof 闭环，直接对应 PRD 8.5.5 写入链路与 AC-007/015 的两级反馈 |
| `cea_governance_gateway.pas` | 真实（151 行） | 🔧 **改造** | `InvokeRead`/`RequestEffect`/`ExecuteApprovedEffect` 即 PRD「Command Bus 校验 + Write Adapter 调度」的雏形。改造点：新增**字段级**命令协议（field_id/target_value/expected_current/profile_id）入口，而非裸 capability+json |
| `cea_freeze_service.pas` | 真实（324 行） | ✅ **复用** | 有界冻结（绑定 target/address/value 三元组、遇第三值停止、写次/时长预算、不自动恢复）已满足 PRD「瞬时写入 vs 被覆盖」的核心关切 |

### `src/core/state/` 与 `src/core/execution/`

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `cea_state_kernel.pas` | 空壳（48 行，`RecordEnvelope` 返回 `NotImplementedResult`） | ❌ **删除/替换** | 声明了 State Kernel 但未实现；真正的状态持久化在 `cea_sqlite_store.pas`。PRD 需要的是「Game State Model 存储」，应由新的 `src/core/state-model/` 服务接管，本文件要么实现要么移除 |
| `cea_event_store.pas` | 薄壳（43 行，仅包装 validator+store） | 🔧 **改造** | 逻辑正确但只是 `AppendEvent` 转发。若 PRD 事件证据层（5.5/6.8）落地，需在此扩展「事件包 + 时间线」持久化 |
| `cea_execution_kernel.pas` | 真实但薄（57 行，仅校验+转发 Attach/WriteMemory） | 🔧 **改造** | 是「唯一权威执行器」的占位；PRD Command Bus 应建立在它之上，把 `WriteMemory` 泛化为字段级命令 |
| `cea_runtime.pas` | 薄壳（67 行，组装三内核） | 🔧 **改造** | 组装逻辑正确但被 `cea_application_runtime.pas` 旁路（后者才是真正装配点）。需决定「保留双装配」还是「合并」 |

---

## 2. 应用装配层（当前真正的实现核心，但过度集中）

### `src/app/cea_application_runtime.pas`（2004 行）

| 判断 | 处置 |
|---|---|
| 真实且庞大（2004 行，单一 God object） | 🔧 **改造（重点重构）** |

**现状：** 这是**真正的产品装配点**，`TCEAStandaloneRuntime` 手动装配了 SQLite store、policy、lease/effect/freeze、win32 后端、CT catalog、LLM、save、MCP server 等全部依赖，并暴露 60+ 方法（Attach/Scan/PlanWrite/Freeze/Save/CT/LLM/MCP/Health）。

**问题：** 它把「应用装配 + 领域逻辑 + MCP 分发」混在一个类里，PRD 要新增的 Game State Model、Command Bus、UI Schema Runtime、Profile、事件录像都会继续膨胀它。

**改造建议：**
1. 拆分出 `TCEAApplicationCompositionRoot`（纯装配）与 `TCEAApplicationFacade`（对外 API）。
2. 把 MCP 工具分发从 runtime 抽出（现有 `TCEAStandaloneMCPDispatcher` 只是薄转发）。
3. 新增 `CommandBus`、`StateCapture`、`ProfileService` 作为**独立服务**注入，而非继续堆方法。

---

## 3. Win32 / CE 平台层（PRD 的内存读写引擎底座，复用率最高）

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/platform/windows/cea_win32_readonly_backend.pas` | 真实（990 行） | ✅ **复用** | 进程枚举/只读附加/读内存/区域枚举/AOB+精确值扫描/复筛，是 PRD「CE 引擎」的**本地等价实现**。关键：它是 PRD 路线 A 之外的第二条可行路径——即使不接外部 CE 进程，本后端已能闭环 |
| `src/platform/windows/cea_win32_memory_regions.pas` | 真实（232 行） | ✅ **复用** | VirtualQueryEx 区域枚举 + private/image/mapped 分类 + 预算 |
| `src/platform/windows/cea_win32_effect_backend.pas` | 真实（168 行） | ✅ **复用** | compare-write-readback 写原语，正是 PRD「修改必须可验证」的实现 |
| `src/platform/windows/cea_win32_governed_capability_port.pas` | 真实（145 行） | ✅ **复用** | 受治理写入的 custody 链（approval+offline+identity 校验），即 PRD Write Adapter 的核心 |
| `src/platform/ce/cea_ce_process_capability.pas` | 真实（187 行） | ✅ **复用** | 身份签名 + Epoch 递增，即 PRD「版本/结构特征指纹」的进程级实现 |
| `src/platform/ce/cea_ce_scan_capability.pas` | 真实（501 行） | ✅ **复用** | 受治理扫描 scope 授权（≤128 有序非重叠区间），对应 PRD 6.6 金手指扫描 |
| `src/platform/ce/cea_ce_memory_read_capability.pas` | 真实（74 行） | ✅ **复用** | 读适配器 |
| `src/platform/ce/cea_ce_command_queue.pas` | 真实（241 行） | ✅ **复用** | owner-thread FIFO，保证 CE 上下文单线程执行（PRD 8.5.2「合适的 CE 执行上下文」） |
| `src/platform/ce/cea_ce_disassembly_capability.pas` | 真实但极简（74 行） | 🔧 **改造** | 底层 `Disassemble` 只认 nop/ret/int3，其余 dump `db`。PRD 反汇编属「后续工具」，短期可复用，长期需接真反汇编 |
| `src/platform/ce/cea_ce_runtime_ports.pas` | 真实（42 行，接口） | ✅ **复用** | `ICEAReadOnlyRuntimeBackend` 是「连接器抽象」的现成雏形——PRD `ICEGameConnector` 可直接从它泛化 |
| `src/platform/ce/cea_ce_effect_ports.pas` | 真实（22 行，接口） | ✅ **复用** | `ICEAMemoryEffectBackend` = Write Adapter 端口 |

> **关键洞察：** PRD 8.5 说「先 CE 引擎 + Lua Bridge」。但现有 `cea_win32_readonly_backend.pas` + `cea_win32_effect_backend.pas` **已经提供了不依赖外部 CE 进程的等价能力**。因此 Phase 0 有两条等价路径可选：**(a)** 外挂真实 CE 进程走 Lua Bridge（PRD 原文路线）；**(b)** 直接用现有 Win32 后端作为第一 Connector 打通闭环，CE Lua Bridge 作为第二 Connector 并行推进。方案 (b) 风险更低、可先出可验证 demo。

---

## 4. CE 集成层（PRD 路线 A 的桥接边界）

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `integration/cheat-engine/ce_agent_registration.pas` | 真实（315 行） | 🔧 **改造** | 组合 `TCEAgentRuntime`（进程/内存/模块/扫描/反汇编 capability）。这是「连接器组合边界」，PRD 路线 A 的 Lua Bridge Connector 应在此注册为新的 capability 集 |
| `integration/cheat-engine/ce_agent_mcp_runtime_dispatcher.pas` | 真实（84 行） | 🔧 **改造** | MCP tool→capability 映射 + owner-thread 队列。需新增 Lua Bridge 工具映射 |
| `integration/cheat-engine/ce_agent_win32_bootstrap.pas` | 真实（59 行） | ✅ **复用** | 装配 win32 后端 + SHA256 的启动器 |
| `integration/cheat-engine/ce-unit-map.yaml` | 参考 | ✅ **保留（参考）** | 只读参考，不并入构建 |
| `integration/game-cheats-manager/catalog-contract.md` | 参考 | ✅ **保留（参考）** | GCM catalog 契约，PRD 后续「官方 API/Mod」连接器可借鉴 |

> **注意：** `integration/cheat-engine/` 里的文件名为「cheat engine 集成」，但实际它桥接的是**本仓库自带的 `cea_win32_*` 后端**，并非真正调用外部 `Cheat Engine/` 目录里的 CE 程序。PRD 路线 A 的「真·CE Lua Bridge」目前**尚不存在**，是 Phase 0 需从零新增的（见 `lua-bridge/`）。

---

## 5. CE 域适配器（⚠️ 全部是空壳，误导性命名）

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/domain/ce/cea_ce_process_adapter.pas` | 空壳（28 行） | ❌ **删除/替换** | 所有方法返回 `NotImplementedResult('CE process ...')`。真正的进程能力在 `platform/ce/cea_ce_process_capability.pas` |
| `src/domain/ce/cea_ce_memory_adapter.pas` | 空壳（31 行） | ❌ **删除/替换** | 同上，真实现是 `cea_ce_scan_capability.pas` + win32 后端 |
| `src/domain/ce/cea_ce_debug_adapter.pas` | 空壳（22 行） | ❌ **删除/替换** | debug 能力尚未实现 |
| `src/domain/ce/cea_ce_script_adapter.pas` | 空壳（23 行） | ❌ **删除/替换** | 脚本执行尚未实现（且 PRD 要求 script 必须静态分析 + 审批） |
| `src/domain/ce/cea_value_scan_types.pas` | 真实（120 行） | ✅ **复用** | 精确值编码 + 对齐，扫描基础 |

**结论：** `domain/ce/*_adapter.pas` 是最初「把 CE 当应用宿主」时代的遗留空壳，与「独立应用 + win32 后端」的现行架构脱节，属于**应清理的技术债**。PRD 路线 A 进一步确认「不把 CE 当宿主」，因此这些空壳无保留价值。

---

## 6. 底层候选定位与验证模块（内部目录名 `reverse-domain`）

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/domain/reverse/cea_reverse_types.pas` | 真实（212 行） | ✅ **复用** | Experiment/Hypothesis/Evidence/Candidate/Recipe/Verification 全类型 + 状态机，是 PRD 6.6 金手指工作流 + 6.9 证据分级的**现成领域模型** |
| `src/domain/reverse/cea_reverse_ports.pas` | 真实（66 行，接口） | 🔧 **改造** | `ICEAReversePlanner`/`ICEAReverseCapabilityPort`/`ICEARecipeVerifier` 声明了但未实现——PRD 金手指的「AI 分轮验证」正好需要实现 planner |
| `src/core/reverse/cea_experiment_service.pas` | 真实（196 行） | ✅ **复用** | 有界实验状态机 + 治理网关委托，对应 PRD 场景 C「分轮验证」 |
| `src/core/reverse/cea_hypothesis_service.pas` | 薄壳（48 行，仅内存数组） | 🔧 **改造** | 类型+校验有，无持久化无生成。PRD 需要「AI 生成假设 → 待确认态 → 持久化」，需接 store + AI |
| `src/core/reverse/cea_evidence_service.pas` | 薄壳（79 行，仅内存） | 🔧 **改造** | 同上，需接 `cea_reverse_repository` |
| `src/core/reverse/cea_verification_service.pas` | 真实（110 行） | ✅ **复用** | AOB 唯一性 + 读回验证 + 重试策略，**完全实现** PRD「修改必须可验证」的核心语义 |
| `src/core/reverse/cea_recipe_service.pas` | 薄壳（40 行） | 🔧 **改造** | publish 门禁正确，但无持久化/版本化。PRD Recipe≈Game Profile 条目，需接 store |
| `src/core/reverse/cea_ct_evidence_bridge.pas` | 真实（42 行） | ✅ **复用** | CT 工件 → 证据的桥，PRD「CT catalog-evidence 桥接」现成 |

> **关键洞察：** 底层候选定位与验证模块的类型层（`cea_reverse_types.pas`）已经非常接近 PRD 的「Game State Model + 证据分级」。差距在于：它表达的是**「地址候选/证据/配方」**，而 PRD 8.4 需要的是**「命名字段 field_id/label/type/value/confidence/access」**。二者是「定位层」与「语义层」的关系，需要在中间新增 `src/domain/state-model/` 把候选映射为语义字段。

---

## 7. CT 知识 / RAG 层

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/knowledge/ct/cea_ct_model.pas` | 真实（41 行，纯类型） | 🔧 **改造** | `TCTEntry` 无「语义/显示名/UI 元数据」字段。PRD 语义映射需要扩展或在其上建新模型 |
| `src/knowledge/ct/cea_ct_parser.pas` | 真实（352 行） | ✅ **复用** | XXE 防护 + 预算 + 风险标志（检测 Lua/AA 里的进程/网络/文件访问），即 PRD FR-053「脚本审查」的静态分析基础 |
| `src/knowledge/ct/cea_ct_catalog.pas` | 真实（687 行，1 个 stub 方法） | ✅ **复用** | SQLite 存储 + 拼音模糊检索（32 词硬编码词表）+ RAG envelope（`authority:none`）。对应 PRD「CT 检索 + RAG」 |
| `src/knowledge/ct/cea_ct_search.pas` | 空壳（21 行） | ❌ **删除/替换** | `TCTHybridSearch` 返回 `NotImplementedResult`；真检索在 `cea_ct_catalog.SearchText`。 |
| `src/knowledge/ct/cea_ct_rag.pas` | 真实（72 行，薄适配） | ✅ **复用** | `ICTKnowledgePort` 实现 |

> **限制（重要）：** 拼音词表仅 32 个常见作弊词（无/限/生/命/金/钱/币…），**不能**对任意中文游戏字段名做拼音转写。PRD「AI 字段语义映射」不能依赖此拼音路径，需走 LLM 结构化输出（见 §9）。

---

## 8. 存档工作台层

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/core/save/cea_save_service.pas` | 真实（514 行） | ✅ **复用** | 存档编辑闭环（probe→字段→提议→备份→编辑→恢复→验证），即 PRD「存档解析作为独立适配器」的完整实现 |
| `src/core/save/cea_save_discovery_service.pas` | 真实（151 行） | ✅ **复用** | 有界目录发现 + 取消/撤销，对应 PRD 6.8 事件采集的「不自动全盘搜索」原则 |
| `src/domain/save/cea_save_types.pas` | 真实（54 行） | ✅ **复用** | 快照/格式描述符/字段观察/编辑提议 |
| `src/domain/save/cea_save_ports.pas` | 真实（35 行，接口） | ✅ **复用** | `ICEASaveCodec` = PRD「按游戏格式决定是否支持的存档 Codec」 |
| `src/domain/save/cea_save_discovery_types.pas` | 真实（38 行） | ✅ **复用** | 预算/作用域/候选 |
| `src/platform/save-fixtures/cea_fixture_save_codec.pas` | 真实（184 行） | ✅ **复用（fixture 保留）** | `CEA-SAVE-1` 测试格式；**明确标注非真实游戏兼容**，PRD 6.5 也要求「以模拟适配器验证命令流程并标注限制」 |
| `src/platform/windows/cea_win32_save_reader.pas` | 真实（206 行） | ✅ **复用** | 反 TOCTOU 的有界读 + SHA256 |
| `src/platform/windows/cea_win32_save_effect_port.pas` | 真实（558 行） | ✅ **复用** | 备份/恢复/编辑（ReplaceFileW 原子替换 + 读回），PRD 存档写入安全基座 |
| `src/platform/windows/cea_win32_save_discovery.pas` | 真实（268 行） | ✅ **复用** | 递归发现 + reparse/云占位符防护 |

---

## 9. LLM 层（⚠️ 关键差距：无结构化输出）

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/llm/cea_llm_provider.pas` | 真实（85 行，契约） | 🔧 **改造** | `TCEALLMChatRequest` 只有 `UserPrompt + RagContextJson`，**无 response_format/json_object/工具调用字段**。PRD 6.3/6.9 的「AI 生成 UI Schema、字段映射」需要结构化 JSON 输出，必须扩展请求契约 |
| `src/llm/cea_llm_streaming.pas` | 真实（205 行） | 🔧 **改造** | SSE 解析只提取文本 delta（content/text），**不解析 tool_use/function_call 结构化块**。若走工具调用路径需扩展 |
| `src/llm/cea_openai_compatible.pas` | 真实（251 行，1 个 stub 方法） | 🔧 **改造** | `Chat()` 完整，但 `Invoke()` 是 stub；且无 `response_format`/tools。需新增 JSON 模式或工具调用 |
| `src/llm/cea_anthropic_compatible.pas` | 真实（207 行） | 🔧 **改造** | 同上，无 tool_use 解析 |
| `src/llm/cea_tool_dispatcher.pas` | 空壳（27 行） | ❌ **删除/替换** | `SubmitProposal` 返回 `NotImplementedResult`；这是「受治理工具提案」的应有入口，PRD AI 金手指/UI Schema 提案正需要它，须重写 |

> **结论：** LLM 层当前是**文本进文本出**，无法直接产出受 schema 约束的字段映射/UI Schema JSON。改造方向（PRD 6.9 依赖）：
> 1. 给 `TCEALLMChatRequest` 增加 `response_format`/`json_schema` 或 `tools`/`tool_choice` 字段。
> 2. 在 OpenAI/Anthropic 两个 provider 的 body 构建 + 流式/非流式解析里加入结构化输出处理。
> 3. 实现 `cea_tool_dispatcher`，让「AI 提案」经治理网关（现有 governance gateway）进入「待确认」态。
> 或者 Phase 0 先「文本里让模型吐 JSON + 下游 schema 校验」的降级路径（现有 `cea_schema_validator` 可校验），但需明确这是降级、非最终方案。

---

## 10. 基础设施层

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/infrastructure/cea_sqlite_store.pas` | 真实（1136 行） | ✅ **复用** | 8 表（events/leases/approvals/effects/receipts/proofs/idempotency/save_recovery_cases）。PRD Profile 可新增表或复用 |
| `src/infrastructure/cea_schema_validator.pas` | 真实（312 行） | 🔧 **改造** | 手写**子集** JSON Schema 校验器（仅 2 个硬编码正则），非完整 Draft 2020-12。PRD「UI Schema 受控组件」需要更强的 schema 校验，需扩展或换库 |
| `src/infrastructure/cea_secret_store.pas` | 真实（163 行） | ✅ **复用** | Windows Credential Manager，PRD 隐私要求（密钥不进配置/日志）现成 |
| `src/infrastructure/cea_ct_xml_exporter.pas` | 真实（133 行） | ✅ **复用** | CT 草稿 → CE XML（含 provenance 注释）。对应 PRD「生成/配置修改脚本」的受控产物 |
| `src/infrastructure/cea_reverse_repository.pas` | 真实（353 行） | ✅ **复用** | 5 表候选定位与验证工件存储（target/candidate/evidence/recipe/verification） |
| `src/infrastructure/cea_policy_engine.pas` | 薄壳（31 行，委托 policy_model） | ✅ **复用（不必动）** | 「Inert」是设计意图，真逻辑在 policy_model |
| `src/infrastructure/cea_structured_log.pas` | 空壳（22 行） | ❌ **删除/替换** | `RecordEvent` 返回 `NotImplementedResult`。PRD 6.5 FR-046「操作历史」+ 6.8 时间线需要真实日志，须重写或并入 `cea_event_store` |
| `src/infrastructure/windows/cea_release_identity.pas` | 真实（169 行） | ✅ **复用** | EXE 哈希 + Authenticode + 安全提示分类 |
| `src/infrastructure/windows/cea_system_clock.pas` | 真实 | ✅ **复用** | UTC ISO8601 时钟 |
| `src/infrastructure/windows/cea_windows_sha256.pas` | 真实 | ✅ **复用** | SHA256 |
| `src/infrastructure/windows/cea_winhttp_transport.pas` | 真实 | ✅ **复用** | WinHTTP 传输（LLM 用） |

---

## 11. MCP 层

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/mcp/cea_mcp_http_server.pas` | 真实（224 行） | ✅ **复用** | loopback 127.0.0.1 + Bearer token + POST /mcp，PRD「本机受限 IPC，不监听公网」现成 |
| `src/mcp/cea_mcp_protocol.pas` | 真实（232 行） | ✅ **复用** | JSON-RPC 2.0 + tools/list + tools/call |
| `src/mcp/cea_mcp_registry.pas` | 真实（314 行） | 🔧 **改造** | 已注册 26 个工具。PRD 需新增 `connect`/`read_field`/`write_field`/`get_profile`/`generate_ui_schema` 等**字段级**工具 |
| `src/mcp/cea_mcp_dispatcher.pas` | 近空壳（44 行） | ❌ **删除/替换** | 只实现 `cea.health` + `cea.get_runtime_state`（硬编码 `mcp_enabled:false`），其余 `not_implemented`，且 gateway 从未使用。真正的分发在 `integration/.../ce_agent_mcp_runtime_dispatcher.pas` |

---

## 12. UI 层

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/ui/cea_local_approval_port.pas` | 真实 | ✅ **复用** | 本地审批端口，PRD「MCP 不能批准自己的 Effect」的机制 |
| `src/ui/cea_ui_projection.pas` | 空壳（33 行） | ❌ **删除/替换** | `ProjectTask` 返回「No runtime action implemented by this scaffold」。PRD 需要真正的玩家级投影，须重写 |
| `src/ui/cea_value_scan_ui_model.pas` | 真实（131 行） | ✅ **复用** | 扫描 UI 输入校验 |
| `app/lazarus/cea_main_form.pas` | 真实（约 2000+ 行） | 🔧 **改造（重点）** | 现有 7 Tab 是「操作者诊断面板」。PRD 7.5 要重组为玩家级三栏（游戏概览/副屏/字段/金手指实验室/Profile/操作历史/事件时间线/设置），并新增副屏网页宿主 |
| `app/lazarus/cheat_engine_agent.lpr` | 真实（33 行） | ✅ **复用** | 入口 + `--self-test` |

---

## 13. CT 草稿生成（ct-draft）模块

| 文件 | 现状 | 处置 | 理由 |
|---|---|---|---|
| `src/domain/ct-draft/cea_ct_draft_types.pas` | 真实（344 行） | ✅ **复用** | 草稿/条目/提案/导出请求，含风险标志（非可移植/版本绑定/AOB-only） |
| `src/domain/ct-draft/cea_ct_draft_ports.pas` | 真实（42 行，接口） | ✅ **复用** | 仓库/源解析/XML 导出/文件端口 |
| `src/core/ct-draft/cea_ct_draft_service.pas` | 真实（233 行） | ✅ **复用** | 草稿构建/重验证/废弃，含源证据哈希绑定 + 兼容性哈希 |
| `src/core/ct-draft/cea_ct_draft_canonical.pas` | 真实 | ✅ **复用** | 规范化 JSON |
| `src/core/ct-draft/cea_ct_draft_source_resolver.pas` | 真实 | ✅ **复用** | 从逆向工件 bundle 解析草稿源 |

> **对应 PRD：** ct-draft 模块正是 PRD 6.6 FR-055「验证过的字段保存为 Profile 条目」+ FR-053「生成受控脚本」的**最接近实现**——它已经能把「验证过的候选地址 + 证据」编译成带 provenance 的 .CT 草稿。这是连接「金手指实验室」与「可复用 Profile」的关键复用资产。

---

## 14. 汇总：处置统计

| 处置 | 数量 | 代表文件 |
|---|---|---|
| ✅ 复用 | ~45 | 治理内核、win32/CE 平台、存档、逆向类型、CT catalog、基础设施存储/secret/hash |
| 🔧 改造 | ~18 | `cea_application_runtime`、LLM 三件套、`cea_main_form`、schema_validator、mcp_registry、state/event store、reverse 薄壳服务 |
| ❌ 删除/替换 | ~12 | `domain/ce/*_adapter`（4 个空壳）、`cea_state_kernel`、`cea_structured_log`、`cea_mcp_dispatcher`、`cea_ct_search`、`cea_tool_dispatcher`、`cea_ui_projection` |

**技术债清单（改造前应先清理）：**
1. 4 个 `domain/ce/*_adapter.pas` 空壳（误导性命名，真实现已在他处）。
2. `cea_mcp_dispatcher.pas` 与 `ce_agent_mcp_runtime_dispatcher.pas` 职责重叠，前者近空壳。
3. `cea_state_kernel.pas` 声明未实现，`cea_runtime.pas` 被 `cea_application_runtime` 旁路。
4. `cea_structured_log.pas` 全空壳，无日志。

---

## 15. 与 PRD 的三大关键缺口（改造的主攻点）

1. **无语义字段模型（Game State Model）**：现有最接近的是逆向域「候选地址」和 ct-draft「条目」，但都没有 `field_id/label/type/value/confidence/access/validation_status` 的玩家语义层。→ 新增 `src/domain/state-model/`（transformation-plan.md §1A）。

2. **LLM 无结构化输出**：文本进文本出，无法受约束地产出字段映射/UI Schema JSON。→ 改造 `cea_llm_provider` + 两个 provider + `cea_tool_dispatcher`（transformation-plan.md §1C）。

3. **无副屏 UI Runtime + Command Bus + Game Profile**：这三者是 PRD 产品的「最后一公里」，现有代码完全空白。→ 新增 `src/core/command/`、`src/ui/cea_ui_schema_runtime.pas`、`src/core/profile/`（transformation-plan.md §1D/1E/1F）。

**而安全底座（治理内核 + 平台后端 + 存档 + CT + 基础设施）已基本就绪，可直接作为改造的地基。**

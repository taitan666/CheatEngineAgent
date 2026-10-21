# AgentOS 1.18-draft 符合性改造计划

**规范依据：** `C:\Users\taitan666\Downloads\AGENTOS_CORE_RELEASE\AGENTOS_UNIVERSAL_SPEC.md`
（`spec_version = 1.18-draft`，16,259 行；**该文件实测 `sha256:938829d234dea443c91ed4364264370aba44fdc6875151a98f93a5e711411540`**）
**机器契约包：** 同目录 `AGENTOS_CORE_RELEASE`（`release_id = agentos-core-contracts-1.13`，`release_scope = core_structural_and_control_flow`，`runtime_conformance = false`）
**⚠ 发布包完整性不一致（实测，P0）**：`ReleaseManifest.json` 的 `canonical_spec_hash` 是 `sha256:bff1f943547abfda89dc76e94ecd2fde332fa40f32c23777cdecab4b8b93c59e`，**与 `AGENTOS_UNIVERSAL_SPEC.md` 的实际哈希不符**。10 个 `file_hashes` 全部匹配（0 处不符），10 个 `<!-- CORE_*_BEGIN -->` 嵌入标记各出现 1 次，说明只有规范正文文件在打包后被改动过（或清单未随正文一起重生成）。因此 `check_release.py` 会在 `Canonical spec snapshot hash mismatch` 处失败。**本计划的所有引用行号以此实际文件为准；符合性索引绑定的是上方的实测哈希，不是清单里的哈希。** 需要向规范发布者确认以哪一份为准。
**目标代码库：** `cheat-engine-agnet/`
**日期：** 2026-10-21
**测量基线：** 全量 Pascal 回归 `SUMMARY pass=77 fail=0 skip=1 total=78`；123 个单元；58 个 schema；95 个 MCP 工具；7 个运行时 SQLite 库

---

## 0. 一句话结论

**项目当前不能声明任何一层 AgentOS 符合性。**

- **结构层**：本地 14 个 `schemas/agentos/*` 只覆盖 129 个 Core 定义的 **10.9%**，且其中 **12/14 与规范同名定义的字段集不一致**（`reqEq=False`）——它们不是同一套契约。
- **协议层**：三个 Kernel 是空壳。`TCEAStateKernel.RecordEnvelope` 直接返回 `NotImplementedResult('state envelope commit')`；`TCEAGovernanceKernel` 只有 `EvaluateCapability`；`TCEAExecutionKernel` 只有 `Attach` / `WriteMemory`。全项目 `tenant_id` / `Outbox` / `TypedDelta` / `ErrorCodeRegistry` / `aggregate_version` / `CommitVerifier` grep 命中数**均为 0**。
- **运行层**：无部署绑定、无证据解析器、无出口清单。`dist/internal-release-manifest.json` 自身写着 `publishable: false`、`evidence` 四项全 `not-recorded`。

本计划的定位是**把「符合性」拆成三层分别建设、分别声明，并且只声明真正验证过的层级**——而不是把 129 个 schema 抄一遍然后写一份「符合 AgentOS」的报告。规范 §0 与 §17.1 都明确禁止后者。

---

## 1. 为什么不能直接「全面对齐」

规范自身给这条路径设了三道闸门，任何一道都足以否决「全面对齐」的做法：

1. **§0 规范与项目边界**：「本文固定对象语义、适用条件、不变量、证据接口和最低验收形状。具体存储事务、宿主 API、出口拦截、故障注入设施、独立 verifier、数据集、样本量、阈值、预算和部署证明由实际软件项目选择并提供。文中的研究对照、示例数值、伪代码及测试草图可指导项目设计，**不能成为通用默认实现，也不能替代项目证据**。条件能力未启用时保留 `not_applicable` 的依据；能力已启用但未运行验证时记录 `not_run`。」
2. **§17.1**：「项目可以仅声明已完成的层级。」「`undetermined`、缺失本层必需引用、仅自报输出、无法解析的证据、版本不匹配**均不得计入 pass**。」
3. **§17 三层符合性**：结构符合 ≠ 协议符合 ≠ 运行符合；「结构检查和文档静态检查不能替代协议故障注入及部署运行演练；**未执行的验证不得报告为通过**。」

同时，发布包自己就声明了深度上限：`ContractCoverage.json` 的 129 条 `level` **全部是 `field_shape`**，README 原文「当前深度为 `field_shape`，**不把对象结构校验冒充跨引用、权限、故障恢复或运行符合**」。也就是说，即使把 129 个 schema 全部对齐，能得到的也只是**结构层**的一个子结论，协议与运行层仍需独立建设。

本项目是一个 **lite profile、单执行者、单机、单人单机游戏**的 Windows 桌面工具。把 129 个定义（含多 Agent 移交、世界模型、学习演化、复制拓扑、AGI 阶段门槛）全部实现在工程上不成立，在语义上也不诚实——因为 FeatureSet 明确不允许这些能力。正确做法是**先做适用性裁剪，再对适用集建契约**。

---

## 2. 事实基线（实测，非估计）

### 2.1 规范侧

| 项 | 值 |
|---|---|
| 规范版本 / 行数 | `1.18-draft` / 16,259 |
| AO 不变量 | **67 条**（AO-001~AO-067） |
| Core 定义 | **129 个**（`$defs`） |
| 场景 ID | **88 个**（RT-01~12、AT-01~28、ST-01~13、DS-01~05、MI-01~04、FS-01~04、EP-01~05、WM-01~05、COL-01~05、IT-01、CF-01~06） |
| 发布包 `required_scenario_ids` | **87**（= 81 catalog + 6 CF） |
| 三层符合性 | 结构 / 协议 / 运行，必须分开声明 |
| 规范自身结构深度 | `field_shape`（129/129） |
| `runtime_conformance` | `false` |

### 2.2 项目侧

| 项 | 实测值 | 规范要求 | 差距 |
|---|---|---|---|
| AO 编号在项目内出现 | **4/67**（AO-001、AO-051、AO-052、AO-059，且全在 docs，代码零引用） | 67 条须逐条建索引 | 63 条零引用 |
| Core 定义落地为项目契约 | **14/129**（10.9%） | 129（按适用性裁剪后 ≥50） | ≥36 个缺口 |
| 本地 agentos schema 与规范同名定义字段一致 | **2/14** | 全部一致或显式声明偏差 | 12 个不是同一契约 |
| `schemas/agentos/approval.schema.json` | **0 个 properties**（只有 required） | 规范 7 个字段 | 空壳 |
| Kernel API 逻辑表面 | 约 6/≈55 个方法 | §16 列出的逻辑表面 | 其余未实现 |
| `TCEAStateKernel.RecordEnvelope` | `NotImplementedResult('state envelope commit')` | `append_observation` / `propose_delta` / `commit` | 整层缺失 |
| `tenant_id` | 0 处 | AO-006 要求所有写入携带 | 缺失 |
| `Outbox` | 0 处 | AO-009 / §8.2 步骤 2 | 缺失 |
| `TypedDelta` / `aggregate_version` | 0 / 0 处 | §4.3 / AO-010 | 缺失 |
| `ErrorCodeRegistry` | 0 处 | §16（37 个 code + 版本 + 摘要进 ReleaseManifest） | 缺失 |
| `CommitVerifier` | 0 处 | AO-001 / AO-015 | 缺失 |
| `IStateStore` 能力 | 只有 `Initialize` + `AppendEvent` | Envelope 八字段 + 租户 + schema_version + TypedDelta | 不足 |
| ExecutionHold / control_version | 0 处 | AO-036~AO-039（本项目 FeatureSet 已声明 `execution_hold` 启用） | **声明了但零实现** |
| WorkLedger / WorkCheckpoint / RequirementTrace | 0 处 | AO-025 / AO-045（本项目已声明 `durable_work_ledger` 启用） | **声明了但零实现** |
| FeatureSet 覆盖的规范具名能力 | **9/28** | ≥28 | 19 个未表态 |
| 符合性索引（§17.1 九字段） | 无（`tests/acceptance/requirements-traceability.md` 是 13 行 markdown，无 `requirement_id`/`spec_version`/`applicability`/`verification_level`/`verdict`） | 机器可读索引 | 缺失 |
| ImplementationPlan / StatusLedger / VerificationLedger / RemainingBoundary | 全部为人肉 markdown，`remaining-boundary.md` 内容已过时 | 四件套持久化并互相引用 | 缺失 |
| `jsonschema`（Python 模块） | **未安装**，`pip install` 无网络 | `check_release.py` 依赖 | 检查器不可运行 |
| 全量回归 | `pass=77 fail=0 skip=1 total=78` | 不得退化 | 基线 |

**最高优先级的发现（比「缺功能」更严重）**：`bootstrap/feature-set-lite.yaml` 声明 `execution_hold` 与 `durable_work_ledger` 为 **enabled**，但两者在代码里**零实现**。规范 §11 原文：「**不能以空壳接口冒充效果保证**」；§17.1 原文：能力已启用但未运行验证时记录 `not_run`。当前状态是「声明为已启用、实际不存在」——这是三层声明里最不可接受的一种，必须在任何其他工作之前处理。

---

## 3. 符合性声明策略（先定规则，再谈实现）

### 3.1 三层分开声明，禁止跨层推断

| 层 | 定义（§17） | 本计划能否声称 | 依据 |
|---|---|---|---|
| **结构符合** | 对应 JSON Schema 与正反例检查通过 | 可在 Phase B 后声明（仅适用子集） | 项目自建检查器 + 正反例 |
| **协议符合** | 真实实现通过故障注入与安全检查 | 可在 Phase H 后声明 `provisional_match`；**不能声明 pass** | 规范明文：adapter 输出只是 provisional |
| **运行符合** | 在声明部署拓扑上完成隔离、备份恢复、预算与运维演练 | **不声明**，记 `not_run` | DSH 沙箱限制（见 §9） |

### 3.2 版本与失效绑定

索引每一行都必须绑定 `spec_version = 1.18-draft` 与 `canonical_spec_hash`。规范升级、Schema 变更、场景变更、实现摘要变更、部署拓扑变更、证据解析器变更 → **受影响行立即失效重判**（§17.1）。禁止保留无条件 `pass`。

### 3.3 适用性判定规则（本项目采用）

1. 能力在 FeatureSet 中 `denied` → 对应 AO 记 `not_applicable`，`applicability_reason` 必须引用该 denied 项与实际出口清单。
2. 能力 `enabled` 且已有验证 → 可判 `pass`。
3. 能力 `enabled` 但未验证 → `not_run`。
4. 能力既未 enabled 也未 denied → 记 `undetermined`，**先补 FeatureSet，不允许长期悬空**（规范禁止 `undetermined` 计入 pass）。

---

## 4. FeatureSet 收敛（Phase A 的前置决定）

规范 §11 要求 FeatureSet 至少覆盖 **28 个具名能力**。当前 `bootstrap/feature-set-lite.yaml` 只表态 **9/28**，且混用了 5 个项目自造名（`ct_rag`、`real_process_access`、`model_training`、`anti_cheat_bypass`、`multiplayer_targeting`）——这些可以作为项目自有的 `FeatureDefinition` 保留，但**不能顶替**规范具名能力。

**建议的 28 项最终表态**（7 enabled / 21 denied，0 undetermined）：

| 能力 | 表态 | 理由 |
|---|---|---|
| `external_writes` | **enabled** | 内存写 / 存档编辑已实现（CommandBus + compare-write-readback） |
| `durable_work_ledger` | **enabled** | 已声明；本计划 Phase B 补实现 |
| `execution_hold` | **enabled** | 已声明；本计划 Phase E 补实现 |
| `context_retrieval` | **enabled** | CT RAG `SearchText` / `BuildRagContext` 已实现；CF-05 需要交付期重验 |
| `prompt_assembly` | **enabled** | 所有 LLM 调用点存在；AO-059 需补齐记录 |
| `guardrails` | **enabled** | 「AI 永不产出可执行物」+ MCP 审批门已是事实上的 guardrail，需落成 GuardrailRun |
| `data_ingestion` | **enabled** | CT XML 解析、GCM 目录导入已实现；AO-031/058 需补覆盖率记录 |
| `multi_agent` / `agent_handoff` / `concurrent_workers` / `automatic_recovery` | **denied** | 单执行者架构；AO-041~044/046/057 `not_applicable` |
| `learning` / `world_model` / `simulation` / `capability_evolution` | **denied** | 项目永久边界（no-model-training） |
| `distributed_replication` | **denied** | 单机；AO-050 `not_applicable` |
| `derived_context_views` | **denied** | 无派生索引；AO-053 `not_applicable` |
| `automatic_memory_formation` | **denied** | 无 Memory Core；AO-051/054 `not_applicable` |
| `sandbox_attestation` | **denied** | 单进程本地执行，无隔离边界；AO-062 `not_applicable` |
| `interactive_environment` | **denied** | 副屏是输出端，不做 GUI 自动化；AO-063 `not_applicable` |
| `telemetry` | **denied** | 无遥测管道（审计账本 ≠ 遥测）；AO-060 `not_applicable` |
| `evaluation` | **denied** | 无 EvalRun；AO-064 `not_applicable` |
| `independent_review` | **denied** | 无多 LLM 互检；AO-046 `not_applicable` |
| `adaptive_harness_generation` / `topology_optimization` / `context_cache_optimization` / `long_horizon_diagnostics` / `combinatorial_safety_testing` | **denied** | 超出本项目范围 |

**同时必须修**：`schemas/agentos/feature-set.schema.json` 目前 `additionalProperties = false` 且没有 `degradation_policy`，而 `feature-set-lite.yaml` 带 `degradation_policy` —— 该 YAML 与本地 schema **不兼容**。规范侧 `FeatureSet` 有 6 个字段（含 `agentos_release_ref`、`content_hash`、`created_at`、`enabled_features`），本地只有 5 个。

---

## 5. 分阶段改造路线

工作量等级：**S** ≈ 1~2 天，**M** ≈ 3~5 天，**L** ≈ 1~2 周，**XL** ≈ 2~4 周（单人）。

### Phase A — 符合性骨架与适用性基线（M）

**目标**：把「声明」变成机器可验证的东西，且不写一行运行时逻辑。这是唯一能立刻消除「虚假声明」的阶段。

| 任务 | 产出 |
|---|---|
| A1 | `conformance/agentos/applicability.json`：67 个 AO + 129 个定义 + 88 个场景的逐条索引，字段严格按 §17.1 九字段（`requirement_id` / `spec_version` / `applicability` / `applicability_reason` / `schema_refs` / `scenario_refs` / `implementation_binding_refs` / `evidence_refs` / `verification_level` / `verdict`）。初始 `verdict` 全部如实填写（当前绝大多数为 `not_run` 或 `not_applicable`）。 |
| A2 | 重写 `bootstrap/feature-set-lite.yaml` 到 §4 的 28 项表态；同步扩 `schemas/agentos/feature-set.schema.json` 到规范 6 字段并放行 `degradation_policy`。 |
| A3 | `conformance/agentos/error-code-registry.json`：§16 全部 37 个 code + `default_handling` + `retryable` + `result_code_map`（映射到现有 `TCEAResultCode`）。 |
| A4 | `conformance/agentos/remaining-boundary.json` 取代 `docs/delivery/remaining-boundary.md`（后者内容已过时：仍写「SQLite persistence / JSON Schema runtime validation 未实现」，实际早已实现）。 |
| A5 | 清理陈旧项：`bootstrap/application-descriptor.yaml` 移除 `adapters: cheat_engine_7_5`（与「不桥接 CE」决策冲突），补 `validators` / `acceptance_suite`。 |
| A6 | `tools/conformance/check-index.ps1`：校验字段完整性、枚举合法性、引用可解析、`not_applicable` 必须有理由、按层统计 pass/fail/inconclusive/not_run 与分母。 |

**退出条件**：`check-index.ps1` PASS；67/129/88 三张表行数齐全；无 `undetermined`；任一 `pass` 行都能解析出证据。

### Phase B — 工作账本与需求追踪（L）

**目标**：落实已声明为 enabled 的 `durable_work_ledger`（AO-025 / AO-045 / §18.1）。

| 任务 | 文件 |
|---|---|
| B1 | `src/domain/work/cea_work_types.pas`：`WorkLedger`（20 字段）、`WorkCheckpoint`、`RequirementTrace`、`ImplementationPlan`、`ImplementationStatusLedger`、`VerificationLedger`、`RemainingBoundary` |
| B2 | `src/core/work/cea_work_ledger_service.pas`：单调 `work_state_version`、`expected_work_state_version` 条件写（版本冲突 → `rcConflict`） |
| B3 | `src/core/work/cea_work_checkpoint.pas`：`verify_all_refs_hashes_and_shared_work_version`，失败即 `recovering` + `checkpoint_inconclusive` |
| B4 | `src/core/work/cea_requirement_trace.pas`：直接访问原始请求（不只读执行者整理的摘要）、`explicit`/`inferred`/`required`、`coverage_result` |
| B5 | `src/infrastructure/cea_work_store.pas`（第 8 个库 `work.sqlite3`） |
| B6 | `resume_work` 六步；**对未结算 Effect 只 reconcile，不重放** |

**退出条件**：CF-02 正负例可被项目内测试驱动；`WORK_LEDGER=PASS`。

### Phase C — Task / Envelope / Commit 语义闭合（XL）

**目标**：把 State Kernel 从空壳变成有语义的最小实现，这是 AO-001/009/010/011 的落点，也是后续所有阶段的公共地基。

| 任务 | 文件 |
|---|---|
| C1 | `src/domain/agentos/cea_envelope_types.pas`：Envelope 13 字段（含 `parent_id`/`session_id`）、9 值 `type` enum、`causation_id`/`correlation_id`、聚合身份+版本+**日志顺序号**（时间戳不能代替顺序号） |
| C2 | `src/domain/agentos/cea_task_types.pas` + `src/core/task/cea_task_service.pas`：9 个 `execution_status` + `outcome` + `wait_reason` + `resume_status`，**转换表逐条硬校验**（非法转换返回 `rcConflict` + `task_transition_invalid`） |
| C3 | `src/domain/agentos/cea_typed_delta.pas`：`set`/`unset`、字段路径、前提引用；请求摘要规范化（UTF-8、键排序、无空白、禁 NaN/Infinity、`sha256:`+64 位小写十六进制） |
| C4 | 重写 `src/core/state/cea_state_kernel.pas`：`AppendObservation` / `ProposeDelta` / `Commit`；Commit 幂等键 `(tenant_id, aggregate_id, idempotency_key)`；`expected_base_version` 前提检查；同键同摘要返回原结果（即使 base version 已变）、同键异请求 `IDEMPOTENCY_CONFLICT`、版本不符 `COMMIT_CONFLICT` |
| C5 | `src/infrastructure/cea_aggregate_store.pas`（`aggregates.sqlite3`）：aggregates + commits + observations + idempotency，四张表**同一事务**写入 |
| C6 | `src/contracts/cea_error_codes.pas`：37 个 §16 code ↔ `TCEAResultCode` 双向映射 + Registry 版本与摘要（进 ReleaseManifest） |
| C7 | 单租户决定：本项目 `tenant_id` 恒为 `cea.local.default`，由进程内受信边界派生，**不接受调用方自填**（AO-006 的「服务端执行」在单机语境下即此） |

**退出条件**：AO-001/006/009/010/011 各有正例 + 负例 + 精确故障点；`STATE_KERNEL=PASS`。

### Phase D — 出口拦截、Outbox 与 Effect 恢复（L）

| 任务 | 内容 |
|---|---|
| D1 | `src/core/execution/cea_outbox.pas`：Outbox 表 + 原子领取（`attempt`/`epoch`/请求摘要），发送前再查权限 |
| D2 | 改造 `src/core/governance/cea_effect_service.pas`：`Plan` 时**同事务**写 Effect + Outbox + 预算预留（AO-009 的「不得动作已交付但没有持久计划」） |
| D3 | 幂等作用域从当前 `idempotency_key UNIQUE` 扩为 `(tenant_id, adapter_id, target_scope, idempotency_key)`（AO-017） |
| D4 | `reconcile_effect` + 扩展 `save_recovery_cases` 为通用 `recovery_cases`（AO-019 的 owner/deadline/next_reconcile_at/恢复预算/人工渠道）；**禁止把 unknown 改成 failed 或 applied** |
| D5 | `conformance/agentos/egress-inventory.json`：逐条列出真实出口 + 拦截点 + 代码位置（AO-008 的证据形态） |

**退出条件**：CF-01 正负例；§8.4 崩溃窗口六行表**每行**都有对应测试。

### Phase E — ExecutionHold（L）

| 任务 | 内容 |
|---|---|
| E1 | `src/domain/hold/cea_hold_types.pas` + `src/core/hold/cea_hold_service.pas`：`Acquire` 原子推进 `control_version`；`active_holds_covering(scope)`；`Release` 必须绑定全部待释放 hold + `expected_control_version` + 当前 `task_contract_version` + 有效 Proof；`release_only` 后**仍检查 `remaining`** |
| E2 | 表并入 `agentos.sqlite3`（`execution_holds` + `control_versions`）——**必须与 Effect 同库同事务**，否则无法证明 hold 与 permit 的共同可排序边界（§17.2） |
| E3 | 出口前置 `CheckActiveHold(scope, control_version)`：写入 / 冻结 / 存档编辑 / CT 发布 / Profile 保存 / 成功报告 |
| E4 | ImpactIndex 最小实现（AO-048）：资源读写集 + 发布集合 + 已知因果边 |

**退出条件**：CF-03 正负例；hold 跨进程重启仍有效；「先 hold 后放行」被拒、「hold 前已发出」记 Receipt 并对账。

### Phase F — Profile / Manifest / Guardrail / PromptAssembly（L）

| 任务 | 内容 |
|---|---|
| F1 | `src/core/profile/cea_resolved_manifest.pas`：解析 FeatureSet 依赖闭包，缺失依赖/被撤销 Feature/Profile 不足/未声明降级 → **Admission 拒绝**（AO-021，不能接受任务后静默退化） |
| F2 | `src/core/llm/cea_prompt_assembly.pas`：记录片段稳定引用/版本/authority/`trust_class`/顺序/include-exclude-compact（AO-059），接入全部 LLM 调用点；失配返回 `PROMPT_ASSEMBLY_MISMATCH` |
| F3 | `src/core/guardrail/cea_guardrail_service.pas`：`GuardrailPlan` + `GuardrailRun`；Secret 物化/授权/Effect 前置只能用 `blocking`（AO-061/AO-040）；`inconclusive` 不得按 pass |
| F4 | `cea_discovery_goal.pas` 补 AO-066 字段：提案触发、仅可建议的条件、自动激活范围与上限、需人类决定的变化、升级与停止条件 |
| F5 | Secret 走 AO-056：`cea_secret_store` 的解析只在调用出口，任何 read/search/RAG/导出表面只返回 `secret_ref` 占位符 |

**退出条件**：FS-03/FS-04 场景有 adapter 输出；PromptAssembly 失配可复现。

### Phase G — 交付完整性与如实告知（M）

| 任务 | 内容 |
|---|---|
| G1 | `src/core/delivery/cea_delivery_manifest.pas`（AO-027）+ `cea_completion_report.pas`（AO-028）+ `cea_notification_obligation.pas`（AO-029） |
| G2 | `tools/conformance/build-delivery-manifest.ps1`：**读回实际产物**生成/校验清单，不核对内部目录代替（AO-027 明文） |
| G3 | `docs/delivery/verification-report.md` 改为由 VerificationLedger 生成；`tests/acceptance/requirements-traceability.md` 迁入 `conformance/agentos/requirements-index.json` 后删除 |
| G4 | `ChangeContract`（AO-026）覆盖三条写路径：存档编辑、CT 发布、Profile 保存 |

**退出条件**：CF-04 正负例；发布清单与读回产物逐项一致。

### Phase H — 协议符合适配器与三层报告（L）

| 任务 | 内容 |
|---|---|
| H1 | `tools/conformance/cea-conformance-adapter.lpr`（Pascal 控制台）：stdin 读一 case、stdout 返回 `case_id` + `decision`/`verdict` + `deployment_binding` + `authoritative_state` + `audit_ref`，负例附 `fault_timeline` |
| H2 | 覆盖 CF-01~06；`not_applicable` 场景显式返回并附依据，**不伪造 pass** |
| H3 | `python run_conformance.py --adapter <path>` → `protocol_result`；`runtime_conformance` **保持 `inconclusive`**（规范明文：adapter 输出只是 provisional） |
| H4 | `docs/delivery/agentos-conformance-report.md`：三层分别统计 pass/fail/inconclusive/not_run 与分母，列出不适用项与依据，保留失败与未知案例 |

**退出条件**：结构层 pass 有据可查；协议层如实输出（`provisional_match` 或 `fail`）；运行层 `not_run` 并写明原因。

---

## 6. 依赖顺序与并行度

```
A ──► B ──► C ──► D ──► E ──► F ──► G ──► H
      │           │
      └───────────┴──► (D 与 E 可在 C3/C4 完成后并行，因共用 aggregates/agentos 库事务边界)
```

- A 必须先做：它把「虚假声明」清零，且不依赖任何代码改动。
- B 与 C 无强耦合，可并行（B 只动新库与纯逻辑）。
- D、E 都改写入路径，串行更安全；E2 决定数据库归属后 D2 才好定事务边界。
- H 必须最后，因为它要引用前面所有阶段的真实能力。

---

## 7. 67 条 AO 适用性映射表

`A` = applicable，`N` = not_applicable（理由见 §4 的 denied 项），阶段列为落点。

| AO | 主题 | 适用 | 阶段 | 当前 |
|---|---|---|---|---|
| AO-001 | 记录与成功分离 | A | C | 部分（Receipt/Proof 有，Commit 无） |
| AO-002 | 执行前检查身份/权限/范围/预算/Lease | A | C | 部分（无预算） |
| AO-003 | 旧 Epoch 不得提交/发起 | A | C | 部分 |
| AO-004 | Effect 幂等唯一、同键异参拒绝 | A | C/D | 部分（作用域过窄） |
| AO-005 | Proof/审批绑定版本与内容 | A | C | 部分 |
| AO-006 | 写入携带身份/租户/版本/因果链 | A | C | 租户缺失 |
| AO-007 | 未知与冲突不静默成功 | A | C | 部分 |
| AO-008 | 出口实际拦截 | A | D | 无清单 |
| AO-009 | Plan/Outbox/预算预留同事务 | A | C/D | 无 Outbox |
| AO-010 | Commit 幂等键作用域 | A | C | 无 Commit |
| AO-011 | Task 状态机与 outcome | A | C | 无 Task |
| AO-012 | 部分成功只能提交已验证子结果 | A | C | 无 |
| AO-013 | 取消先记录再中断、在途移交 | A | C | 无 |
| AO-014 | 不可信内容不得转为用户指令 | A | F | 部分（缺 trust_class） |
| AO-015 | 执行者自报 pass 不足 | A | C | 部分 |
| AO-016 | 审批有效 ≠ 必然允许 | A | C | 部分 |
| AO-017 | Effect 幂等作用域四元组 | A | D | 作用域过窄 |
| AO-018 | applied 后 Domain Commit 冲突 | A | D | 无 Commit |
| AO-019 | RecoveryCase 字段与不可篡改 | A | D | 仅存档域 |
| AO-020 | 出口与 Commit Verifier 检查 Epoch | A | C | 部分 |
| AO-021 | Profile 与特性不互相替代、Admission 拒绝 | A | F | 无 manifest |
| AO-022 | 审批方式 deny/policy_auto/human_required | A | F | 部分 |
| AO-023 | 显式区分运行模式 | A | C | 仅 live，需声明 |
| AO-024 | 预算预留/结算/幂等 | A | F | 无 |
| AO-025 | RequirementTrace | A | B | 无 |
| AO-026 | ChangeContract | A | G | 无 |
| AO-027 | DeliveryManifest | A | G | 无 |
| AO-028 | CompletionReport | A | G | 无 |
| AO-029 | NotificationObligation | A | G | 无 |
| AO-030 | 写入/Commit/验收/发布绑定契约版本 | A | B/C | 无 |
| AO-031 | acquisition/inspection 覆盖率 | A | F | 无 |
| AO-032 | 运行绑定 EffectiveContract | A | F | 无 |
| AO-033 | Requirement→Artifact→Delivery→Report | A | G | 无 |
| AO-034 | 验收需真实 fixture/负例/故障点 | A | 全阶段 | 部分 |
| AO-035 | ErrorSignal | A | F | 无 |
| AO-036 | ExecutionHold 持久化 + control_version | A | E | **零实现** |
| AO-037 | Hold 是覆盖层不改结果枚举 | A | E | 零实现 |
| AO-038 | 仅 Core 原子应用 ResumeDecision | A | E | 零实现 |
| AO-039 | Hold 跨崩溃/Resume/切换有效 | A | E | 零实现 |
| AO-040 | Guardrail blocking/parallel 语义 | A | F | 无 |
| AO-041 | ReviewPlan 先于审查 | N | — | `independent_review` denied |
| AO-042 | ReviewFinding 绑定 | N | — | 同上 |
| AO-043 | 审查缺席策略 | N | — | 同上 |
| AO-044 | 暂停/互检真实验证 | N | — | 同上 |
| AO-045 | WorkLedger/Checkpoint/版本竞争 | A | B | **零实现** |
| AO-046 | EvidenceIndependenceAssessment | N | — | `independent_review` denied |
| AO-047 | ErrorSignal 去重键由 Core 计算 | A | F | 无 |
| AO-048 | 影响索引与 hold 传播 | A | E | 无 |
| AO-049 | 正文/Schema/场景/检查器/摘要同步 | A | G | 部分（文档已脱节） |
| AO-050 | 复制与跨设备边界 | N | — | `distributed_replication` denied |
| AO-051 | Memory 绑定 | N | — | 无 Memory Core |
| AO-052 | 检索与交付同授权语义 | A | F | 部分（CT RAG） |
| AO-053 | 派生索引声明 | N | — | `derived_context_views` denied |
| AO-054 | MemoryFormationRun | N | — | `automatic_memory_formation` denied |
| AO-055 | QueueStatusSnapshot | N | — | 无权威队列 |
| AO-056 | Secret 只返回占位符 | A | F | 部分 |
| AO-057 | AgentMessage/Handoff | N | — | `agent_handoff` denied |
| AO-058 | IngestionRun 三类覆盖率 | A | F | 无 |
| AO-059 | PromptAssembly 记录 | A | F | 无 |
| AO-060 | SpanRecord | N | — | `telemetry` denied |
| AO-061 | GuardrailRun 绑定与 blocking | A | F | 无 |
| AO-062 | Sandbox 与 RuntimeAttestation | N | — | `sandbox_attestation` denied |
| AO-063 | 交互动作重新解析目标 | N | — | `interactive_environment` denied |
| AO-064 | EvalRun 分离标记 | N | — | `evaluation` denied |
| AO-065 | AGIArchitecturePlan | N | — | 不声明 AGI 方向 |
| AO-066 | 自主目标策略 | A | F | 部分（discovery goal 已有） |
| AO-067 | 六类连续性与阶段门槛 | N | — | 同上 |

**合计：applicable 50 / not_applicable 17 / undetermined 0。**

---

## 8. 129 个 Core 定义的处置策略

**不手抄 129 个 schema。** 手抄会产生两份会漂移的事实源，且规范自身已声明 `additionalProperties: true`（结构定义不得闭合）。

采用**双层 + 机械导出**：

1. `schemas/agentos-core/` = 发布包 `$defs` 的**机械导出**（每个定义一个文件，`$id` 前缀 `https://schemas.cheatengineagent.local/agentos-core/`，保留 `additionalProperties: true`），由 `tools/conformance/export-core-schemas.ps1` 生成并校验摘要。**该目录禁止手工编辑。**
2. `schemas/agentos/`（本地运行时契约，14 个）改名语义为**项目投影**，每个文件加两个扩展键：
   - `x-agentos-definition: "<规范定义名>"` —— 必须命中 129 名单；
   - `x-agentos-contract-status: "project-projection" | "canonical-subset" | "canonical-extended"`。
3. `conformance/agentos/schema-mapping.json`：逐字段标注 `same` / `project_extension` / `core_missing`，`core_missing` 必须给 `applicability_reason`。
4. 检查器（Phase B 的 `check-index.ps1` 扩展）校验：
   - 每个 `x-agentos-definition` 可解析；
   - 每个 `canonical-subset` 的 `required` ⊆ 规范 `required`；
   - `schemas/agentos-core/` 的 129 个文件哈希与发布包一致；
   - 结构定义不得闭合（`additionalProperties` 必须为真）——照 `check_release.py` 第 ⑨ 条。

**关键设计决定与理由**：本地 14 个 agentos schema 正被运行时使用（`cea_sqlite_store` 按本地字段建表、`TCEAEffect`/`TCEALease`/`TCEAApprovalDecision` 等 record 直接序列化）。**直接把它们改成规范字段形状会破坏 42KB 的 SQLite 存储层与 78 个测试**，且不会带来任何语义收益——规范自己只到 `field_shape`。双层投影让「结构符合」可被机器验证，同时不动运行时契约。

**expected 的 `core_missing`（首批）**：`task` 缺 `current_epoch`/`policy_snapshot_id`/`required_capabilities`/`resume_status`/`task_contract_version`/`tenant_id`/`unsettled_effect_refs`/`wait_condition`/`wait_deadline`；`task-contract` 缺 `acceptance_criteria`/`objective`/`requirements_hash`/`source_request_refs`/`source_snapshot_hash`/`status`；`effect` 字段集几乎不重叠；`approval` 是空壳（0 properties）；`proof` 缺 `composition`/`child_proof_refs`/`threshold`/`type`；`work-ledger`/`verification-ledger`/`remaining-boundary` 各缺 4~8 个版本绑定字段。

---

## 9. 风险、限制与「不做」清单

### 9.1 环境限制（不可绕过）

- **`jsonschema` 未安装且无网络** → 发布包的 `check_release.py` 本机不可运行。项目侧检查器只能实现其中不依赖 Draft 2020-12 校验器的 14 项（哈希、集合相等、嵌入块、场景目录、`additionalProperties` 为真、字段数一致、正反例存在性），Draft 校验单列 `not_run`，并在报告中写明原因。**不得把「检查器跑过了」写成「结构符合 pass」。**
- **DSH 沙箱**：跨进程 `CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, <其他 pid>)` 返回 `GetLastError=5`；无法写 `%LOCALAPPDATA%\lazarus` 做完整 dist 构建。**运行层因此只能记 `not_run`。**
- 规范是 **1.18-draft**，可能变更。索引必须绑定 `spec_version` + 实测文件哈希，变更即失效重判。
- **发布包 `canonical_spec_hash` 与实际正文哈希不一致**（见文档头）。在向发布者确认前，索引绑定实测哈希，并在报告中披露该不一致；不能因为「清单写了某个哈希」就把它当作已核验的规范摘要。

### 9.2 技术风险

| 风险 | 缓解 |
|---|---|
| 双层 schema 漂移 | `schema-mapping.json` + 检查器强制；`agentos-core/` 禁止手改 |
| 数据库从 7 个增至 9~10 个，事务边界模糊 | 明确归属：Hold/control_version 必须进 `agentos.sqlite3`（与 Effect 同库）；aggregates 独立；work 独立。每个库在 `conformance/agentos/egress-inventory.json` 之外另附「权威范围」说明 |
| 为通过 CF 向量而造假 | AO-034 明文禁止「只拒绝所有操作」；CF-01 必须走真实 `WriteFieldValue`，CF-03 必须走真实 hold 表 |
| Pascal 同名解析陷阱（`faReadOnly` 与 SysUtils 文件属性常量冲突，序数 0 vs 1） | 新代码一律带单元限定：`cea_field_model.faReadOnly` |
| JSON 拼接产生非法 JSON（布尔/引号/编码） | 布尔一律 `JsonBool`；数组项前 `,"key":`、字符串项前 `,"key":"`；`DataJson` 一律经 `Utf8JsonText`；断言用 `GetJSON` + `FindPath`，不用 `Pos` 子串 |
| 中文源码编码 | 含非 ASCII 的 `.pas` 必须 `{$codepage utf8}`；**LCL 主程序不要加 BOM**（实测警告 22→383） |

### 9.3 明确不做

- 不实现多 Agent / Handoff / 并发 Worker / 多 LLM 互检（FeatureSet denied）。
- 不实现 Memory Core / Ingestion 管道 / 世界模型 / 学习演化 / 复制拓扑。
- 不实现沙箱隔离与交互式环境动作（本机单进程，无隔离边界）。
- 不实现 AGIArchitecturePlan 与 S0~S3 阶段门槛（不声明 AGI 方向）。
- **不声明运行符合**，直到有独立 verifier 与真实部署证据。
- 不为了「凑 129」而给 not_applicable 的定义建空 schema。

---

## 10. 验收命令

全部在 `cheat-engine-agnet/` 下执行（本机无 `pwsh`，必须用 Windows PowerShell 5.1 显式绕过执行策略）：

```powershell
# 符合性索引（Phase A 起）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\conformance\check-index.ps1

# 结构层（现有 58 schema + 单元清单）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\schema-check\check-schemas.ps1

# 编译
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\pascal\compile-smoke.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\pascal\compile-app.ps1

# 全量回归（基线不得退化）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\pascal\run-all-tests.ps1

# 发布包结构自检（需 jsonschema；当前记 not_run）
python check_release.py --spec C:\Users\taitan666\Downloads\AGENTOS_CORE_RELEASE\AGENTOS_UNIVERSAL_SPEC.md

# 协议符合（Phase H；无 adapter 时输出 not_run）
python run_conformance.py --adapter <adapter 路径>
```

**基线守护**：任何阶段结束时 `run-all-tests.ps1` 必须满足 `fail=0`，且 `pass` 数不低于上一阶段（当前 77）。

---

## 11. 与既有文档的关系

| 文档 | 关系 |
|---|---|
| `docs/transformation-plan.md` | **产品层计划**（PRD V1.2 → 玩家副屏闭环）。本文件是**符合性层计划**，两者并行不冲突；共享同一 ImplementationStatusLedger（Phase B 产出） |
| `docs/per-file-gap-analysis.md` | 产品层逐文件复用/改造/删除，不涉及 AgentOS 语义 |
| `docs/delivery/agentos-v1.4-digital-life-gap-assessment.md` | 依据 **v1.4-draft**，结论「不能宣称符合 AgentOS v1.4」在 1.18-draft 下仍成立但已过时；本文件**取代**其路线部分，原文件标记 `superseded_by: docs/agentos-conformance-transformation-plan.md` |
| `docs/delivery/remaining-boundary.md` | Phase A 迁移为 `conformance/agentos/remaining-boundary.json` 后删除（内容已过时） |
| `tests/acceptance/requirements-traceability.md` | Phase G 迁移为 `conformance/agentos/requirements-index.json` 后删除（缺 §17.1 必需字段） |
| `docs/ui-ux-design-spec.md` | UI 层规范，与本计划正交 |

---

## 12. 第一周的最小可验证产出

如果只做一件事，做 Phase A：

1. `conformance/agentos/applicability.json`（67 + 129 + 88 三张表）；
2. `bootstrap/feature-set-lite.yaml` 的 28 项表态 + 对应 schema 修复；
3. `conformance/agentos/error-code-registry.json`（37 code）；
4. `tools/conformance/check-index.ps1`。

完成后的状态是：**项目第一次能如实说清「哪些要求适用、哪些不适用、适用的那些现在是什么状态」**——而不是像现在这样，`requirements-traceability.md` 里写着「interface only」而代码里早已实现，`remaining-boundary.md` 里写着「SQLite 未实现」而实际有 7 个库正在用。这本身就是规范 §18.4「如实告知」要求的第一项能力。

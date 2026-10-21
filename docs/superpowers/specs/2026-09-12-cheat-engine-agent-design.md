# Cheat Engine Agent 架构设计

> 历史状态更新（2026-09-13）：本文件保留为初始架构记录。当前权威产品架构是 `2026-09-13-game-reverse-agent-rebaseline.md`；其中将 Reverse Agent Core 提升为产品核心，采用 Windows-first、Android-second，并把 MCP 定位为次级适配器。

**状态：** 历史设计，已由 2026-09-13 重基线取代冲突部分  
**日期：** 2026-09-12  
**目录名：** `cheat-engine-agnet`（按用户指定拼写保留）  
**内部项目名：** `CheatEngineAgent`  
**上游基础：** Cheat Engine 7.5、AgentOS Universal Specification 1.2-draft

## 1. 目标

在 Cheat Engine 7.5 的 Lazarus/Free Pascal 主程序中内嵌一个受 AgentOS 约束的 LLM Agent。系统能够在用户明确控制下连接真实单机游戏进程，调用 Cheat Engine 已有的进程、扫描、内存、反汇编、调试、AutoAssembler、Lua 和 CT 能力；同时吸收 Game Cheats Manager 的本地目录检索思路，建立带来源、版本与内容哈希的 CT RAG 知识库。

第一阶段的运行目标必须覆盖：

1. 枚举并附加真实游戏进程。
2. 在有界 Lease 下执行内存扫描、读取和反汇编。
3. 经策略与审批执行写内存、冻结值、调试和 AA/Lua 脚本。
4. 从本地目录和可配置远程目录导入 `.CT` 文件。
5. 深度解析 CT XML，抽取游戏信息、版本、模块、地址表达式、指针链、AOB、AutoAssembler/Lua 和功能描述。
6. 使用精确标识、双语、拼音、模糊词法和向量语义的混合检索为 LLM 构造带证据的上下文。
7. 对每次模型调用、工具提议、副作用、回执、验证和提交留下可恢复、可审计的记录。

本轮交付只创建架构文档、Schema、目录骨架、接口占位、测试夹具与实施计划；不把占位接口描述成已经可运行的真实进程集成。

## 2. 永久非目标与硬边界

- 系统只用于单机游戏，或用户明确有权调试的离线进程。
- 不提供多人/联网游戏作弊、反作弊绕过、隐蔽注入或规避检测能力。
- 永远不做模型微调、在线训练、权重修改、权重写回或自主模型更新。
- CT “学习”只表示可撤回的解析、索引、检索和基于证据的推理，不改变模型权重。
- CT、网页、目录数据、历史对话和模型输出均是数据而非指令，不能自行扩大权限。
- 第一阶段不启用多 Agent、并发写入、自动学习、分布式复制或无人值守高风险执行。
- AgentOS Core 不内置游戏语义，不直接依赖 CE UI、具体模型提供商或 Windows 内存 API。

`single-player-only` 和 `no-model-training` 是项目级 deny 规则。普通配置、CT 内容、模型提议、插件或用户对话中的间接文字均不能放宽；未来若改变产品定位，必须创建独立项目和新的信任根，而不是修改运行时开关。

## 3. 已选架构

采用方案 B：单进程、模块化内嵌架构。所有组件随 `cheatengine.exe` 构建和运行，不启动 sidecar；模块之间通过 Pascal 接口和版本化 JSON Schema 通信。

```text
cheatengine.exe
|
+-- Agent UI
|   +-- Chat / Task / Approval
|   +-- CT Search / Evidence Viewer
|   `-- Effect / Proof / Recovery Timeline
|
+-- AgentOS Core
|   +-- State Kernel
|   +-- Governance Kernel
|   `-- Execution Kernel
|
+-- CE Runtime Extension
|   +-- Process Attach
|   +-- TMemScan Adapter
|   +-- Memory Read/Write Adapter
|   +-- Debug/Disassemble Adapter
|   +-- AutoAssembler/Lua Adapter
|   `-- CT Load/Save Adapter
|
+-- CT Knowledge Extension
|   +-- Catalog Sync / Local Import
|   +-- CT XML Parser and Extractors
|   +-- Bilingual/Pinyin/Fuzzy Search
|   +-- Lexical/Vector Hybrid Retriever
|   `-- Provenance/Hash/Compatibility Validator
|
+-- LLM Runtime
|   +-- Provider-neutral Client
|   +-- OpenAI-compatible Adapter
|   +-- Tool Dispatcher
|   `-- RAG Context / Disclosure Controller
|
`-- Infrastructure
    +-- SQLite Ledger and Knowledge Store
    +-- JSON Schema Validator
    +-- Windows Secret Store Adapter
    `-- Structured Logging
```

### 3.1 依赖方向

- `core/*` 只能依赖 `contracts/*` 和通用基础类型。
- `domain/ce/*` 实现 Core 定义的 Capability Port，并可依赖 CE 现有单元。
- `knowledge/ct/*` 通过 Artifact、Observation、Fact 和 Proof 契约向 Core 提交结果。
- `llm/*` 只能提交结构化提议，不能直接调用 CE 适配器。
- `ui/*` 是 UserFacingProjection，只发送 Command 和展示权威状态，不保存第二份任务真相。
- `infrastructure/*` 实现持久化、验证、密钥和日志 Port。

## 4. AgentOS 配置

首个可运行版本采用 Lite Profile 和单执行者，但启用以下条件能力：

- `external_writes`
- `durable_work_ledger`
- `execution_hold`
- `ct_rag`
- `real_process_access`

下列能力必须由 Feature Admission 明确拒绝：

- `multi_agent`
- `concurrent_workers`
- `automatic_recovery`（仅允许显式恢复与对账）
- `learning`
- `model_training`
- `world_model`
- `distributed_replication`
- `anti_cheat_bypass`
- `multiplayer_targeting`

虽然使用 Lite Profile，真实内存写入一经启用就必须满足外部 Effect 的 Policy、Authority、Lease、幂等、Receipt、Proof、Commit 和 unknown 对账契约，不能以 Profile 名称豁免。

## 5. 核心组件

### 5.1 State Kernel

负责 TaskContract 版本、Task 生命周期、Observation、Fact、Artifact、Proof、Commit、事件日志和读模型。SQLite 中的 Canonical State 与 Operational Ledger 是唯一权威状态。聊天、Prompt、UI 选中项和 LLM 上下文只属于 Context。

### 5.2 Governance Kernel

负责身份、目标进程范围、单机策略、Capability 权限、风险级别、审批、Lease、预算、数据披露和硬 deny。模型只能提出 `ToolProposal`，不能签发 Lease、批准自己或修改策略。

### 5.3 Execution Kernel

负责任务领取、Epoch、工具调度、Effect/Outbox、取消、超时、回执、读回验证、显式恢复和对账。第一阶段只有一个权威执行者；CE 或目标进程重启会提升 Epoch 并拒绝旧执行结果。

### 5.4 CE Runtime Extension

将 CE 已有实现包装为窄接口：进程枚举与附加、`TMemScan` 扫描、地址解析、内存读取/写入、反汇编、调试、AutoAssembler、Lua 和 CT 加载/保存。Core 不直接引用 `MainForm`、`TMemScan` 或全局 ProcessHandle。

每次附加生成 `ProcessIdentity`，至少包含 PID、进程启动时间、EXE 规范路径、文件 SHA-256、位数、模块清单摘要和 Agent Epoch。任何字段发生不可解释的变化都使旧 Lease 失效。

### 5.5 CT Knowledge Extension

负责源注册、目录同步、本地导入、Artifact 固化、CT XML 解析、搜索文档生成、嵌入生成、混合检索、兼容性过滤和引用返回。原始 CT 字节不可变保存或以内容寻址方式引用；解析器升级产生新解析版本，不覆盖旧证据。

### 5.6 LLM Runtime

提供 `ILLMProvider`、OpenAI-compatible 实现、结构化输出校验、Tool Calling、RAG 上下文构造、数据披露控制、Token/费用预算和 Provider unknown 对账。Provider、模型实际标识、适配器版本和输入输出摘要必须进入 ModelInvocation。

## 6. Game Cheats Manager 搜索机制与接入方式

对 GCM 官方源码的检查表明，其 CT 搜索不是对运行进程扫描，也不是对 CT 内容做语义理解。主要流程是：

1. 启动或更新时把多个来源的数据同步到本地 JSON。
2. CT 搜索读取 `cheat_table.json`。
3. 查询词通过翻译索引扩展中英文等价词。
4. 对 `game_name` 执行规范化、整词/缩写、子串、拼音和 RapidFuzz 模糊匹配。
5. 命中项返回来源、作者、版本和下载 URL，随后排序与去重。

本项目兼容这一“本地数据集 + 双语模糊检索”体验，但不复制 Python/PyQt 实现，也不假定未公开服务端 API 是稳定契约。接入通过 `ICheatCatalogSource`，支持：

- GCM 风格 JSON 目录导入。
- 用户选择的本地 CT 文件夹。
- 用户显式配置、许可证允许的远程目录源。
- 下载后的哈希、大小、媒体类型、来源 URI、抓取时间和许可证元数据记录。

检索在 GCM 方案上增加 CT 内容解析和兼容性约束。排序优先级是：

1. 精确游戏 ID、EXE 名和 EXE/模块哈希。
2. 架构、版本、模块集合与 AOB 兼容性。
3. 规范化标题、别名、中英文、拼音、缩写和模糊词法分数。
4. 功能描述、脚本语义和结构字段的向量相似度。
5. 来源可信度、验证新鲜度和用户明确偏好。

向量分数不能覆盖硬兼容过滤。版本或模块身份未知时结果必须标为 `inconclusive`，只能用于解释或人工检查。

参考来源：

- [Game Cheats Manager 官方仓库](https://github.com/dyang886/Game-Cheats-Manager)
- [GCM `search_index.py`](https://github.com/dyang886/Game-Cheats-Manager/blob/main/src/scripts/search_index.py)
- [GCM `download_display_thread.py`](https://github.com/dyang886/Game-Cheats-Manager/blob/main/src/scripts/threads/download_display_thread.py)

## 7. CT 解析与 RAG 数据流

```text
Catalog / Local CT / User URL
        |
        v
Artifact: raw bytes + provenance + license + sha256
        |
        v
CT Parser -> Observation (unverified)
        |
        +-- GameIdentity / Compatibility
        +-- CheatEntry tree
        +-- AddressSpec / PointerChain
        +-- AobSignature
        `-- ScriptArtifact (untrusted text)
        |
        v
Validator -> Fact / SearchDocument / Proof
        |
        v
Hybrid Retrieval -> RagContextManifest
        |
        v
LLM -> ToolProposal
        |
        v
Policy + Authority + Lease + Approval
        |
        v
CE Capability -> Receipt -> Proof -> Commit
```

`CheatTableArtifact` 绑定原始内容哈希、解析器版本与来源；`CheatEntry` 保留原始 XML 路径和父子关系；`AddressSpec` 使用判别联合表示静态地址、模块偏移和指针链；`AobSignature` 保存模块、模式、通配符、预期匹配数和验证状态；`ScriptArtifact` 保存 AA/Lua 文本摘要、声明能力与静态检查结果。

RAG 上下文必须列出每段内容的 Artifact/Observation/Fact/Proof 引用、兼容性状态、检索分数和截断方式。LLM 不得收到未由 DisclosurePolicy 允许的本地路径、密钥、无关进程数据或完整内存转储。

## 8. 真实进程能力与风险分级

### 8.1 默认允许的受限只读能力

- 枚举用户会话中的候选进程。
- 读取已附加进程的模块与内存映射。
- 在明确范围、类型和预算下扫描内存。
- 读取指定地址并反汇编指定范围。
- 验证 AOB 的零个、一个或多个匹配。

这些能力仍需身份、范围、Lease 和预算检查；“只读”不等于无成本或无数据披露。

### 8.2 必须形成 Effect 的能力

- 写内存或冻结值。
- 设置/移除断点与改变调试状态。
- 执行 AutoAssembler 或 Lua。
- 加载可能自动执行脚本的 CT。
- 下载远程 CT、写入本地库或导出文件。

Effect 状态固定为 `planned -> executing -> applied | rejected | unknown`。审批必须绑定目标进程身份、对象内容哈希、参数摘要、策略快照、次数和到期时间。

### 8.3 第一阶段拒绝的能力

- DBK/内核驱动操作。
- 反作弊规避、隐蔽注入和进程保护绕过。
- 面向多人或联网游戏的修改。
- CT 脚本中的任意网络、文件系统、子进程或持久化操作。
- 无人值守或后台自动写入。

## 9. 异常、取消与恢复

- PID 复用或进程重启：ProcessIdentity 不匹配，撤销旧 Lease，丢弃旧地址候选。
- AOB 零匹配或多匹配：Proof 为 fail/inconclusive，停止写入。
- 写内存：执行前保存原始字节和值，执行后读回；读回不一致为 failed，无法判断为 unknown。
- AA/Lua：先静态检查声明能力；未知 API 或超范围访问直接拒绝。
- CT 同步：下载到临时文件，校验哈希和 Schema 后原子发布新索引版本。
- 模型超时：记录 provider request ID；不得因为超时而重复已产生副作用的调用。
- 紧急停止：先阻止新 Effect、撤销业务 Lease、持久化在途状态，再取消 Session。
- 恢复：重新检查 TaskContract、Epoch、Policy、预算、ProcessIdentity 与未结算 Effect；不盲目重发 unknown 操作。

## 10. 主要 Schema

### 10.1 AgentOS Core

`Envelope`、`TaskContract`、`Task`、`FeatureDefinition`、`FeatureSet`、`ResolvedExecutionManifest`、`Lease`、`ApprovalRequest`、`ApprovalDecision`、`Effect`、`Receipt`、`Proof`、`TypedDelta`、`CommitRequest`、`ModelInvocation`、`WorkLedger`、`VerificationLedger`、`RemainingBoundary`。

### 10.2 CE Domain

`ProcessIdentity`、`ModuleIdentity`、`MemoryRange`、`ScanRequest`、`ScanResult`、`MemoryReadRequest`、`MemoryReadResult`、`MemoryWriteRequest`、`MemoryWriteResult`、`DisassembleRequest`、`DebugRequest`、`ScriptExecutionRequest`。

### 10.3 CT/RAG

`CheatCatalogSource`、`CheatTableArtifact`、`GameIdentity`、`CompatibilityProfile`、`CheatEntry`、`AddressSpec`、`PointerChain`、`AobSignature`、`ScriptArtifact`、`SearchDocument`、`RetrievalQuery`、`RetrievalResult`、`RagContextManifest`。

### 10.4 LLM

`ModelInvocationRequest`、`ModelInvocationResult`、`ToolProposal`、`ToolResultEnvelope`、`DisclosureManifest`、`ProviderConfiguration`。

Schema 使用 JSON Schema 2020-12。所有业务对象包含 `schema_version`；摘要使用 `sha256:` 加 64 位小写十六进制。示例配置不得包含真实 API 密钥。

## 11. 目录结构

```text
cheat-engine-agnet/
+-- README.md
+-- LICENSE-NOTICE.md
+-- docs/
|   +-- architecture/
|   +-- decisions/
|   +-- plans/
|   +-- source-analysis/
|   `-- superpowers/
|       +-- specs/
|       `-- plans/
+-- bootstrap/
+-- schemas/
|   +-- agentos/
|   +-- ce-domain/
|   +-- ct-knowledge/
|   `-- llm/
+-- src/
|   +-- contracts/
|   +-- core/state/
|   +-- core/governance/
|   +-- core/execution/
|   +-- domain/ce/
|   +-- knowledge/ct/
|   +-- llm/
|   +-- infrastructure/
|   `-- ui/
+-- integration/
|   +-- cheat-engine/
|   `-- game-cheats-manager/
+-- config/
|   +-- policies/
|   `-- providers/
+-- tests/
|   +-- contracts/
|   +-- fixtures/ct/
|   +-- policies/
|   `-- acceptance/
`-- tools/schema-check/
```

## 12. 测试与验收

### 12.1 架构交付验收

- 所有 Schema 可由检查器加载，正例通过、反例被拒绝。
- Pascal 单元依赖满足 Core 不引用 CE UI 或具体 Provider。
- 文档、Schema 和 Pascal 接口名称一致。
- ProjectBootstrap、ApplicationDescriptor 和 FeatureSet 可解析。
- 需求追踪覆盖真实进程、GCM 风格搜索、CT 深度解析、RAG、审批、读回和恢复。
- `single-player-only` 与 `no-model-training` deny 场景有不可绕过的验收用例。

### 12.2 第一阶段运行验收

- PID 复用和目标重启使旧 Lease/Epoch 失效。
- 扫描可取消且不会把旧结果应用到新进程。
- 写后读回失败不会产生成功 Commit。
- AOB 零匹配、多匹配和模块哈希不符均停止执行。
- 危险 AA/Lua API 被静态策略拒绝。
- CT 下载损坏、索引竞争和解析器升级保留旧证据。
- LLM 超时、格式错误、预算超限和 unknown 状态不会重复写入。
- 多人/联网目标和任何模型训练 Capability 在 Admission 阶段被拒绝。

## 13. 实施顺序

1. 固定 ProjectBootstrap、ApplicationDescriptor、FeatureSet 与项目硬策略。
2. 建立核心及领域 Schema、示例与 Schema 检查器。
3. 建立 Pascal Contract/Port 和 Core 空实现，验证依赖方向。
4. 建立 CT 解析、目录源、搜索与 RAG 接口占位及夹具。
5. 建立 CE Runtime Port、危险能力分类和注册入口占位。
6. 建立 Provider-neutral LLM 接口与 OpenAI-compatible 配置占位。
7. 建立 UI Projection 接口、状态机文档和端到端验收场景。
8. 后续按 TDD 实现第一阶段真实进程与 CT RAG，不在本轮脚手架中虚报完成。

## 14. 假设、限制与待验证事项

- 当前工作区是 Cheat Engine 7.5 源码快照，但根目录不是 Git 仓库；无法在本轮提交设计文档。
- GCM 的远程目录和签名 URL 属于外部、可能变化的服务；架构只依赖可替换的 Source Contract。
- GCM 及其数据源的许可证、再分发权限和条目来源必须在实际同步前逐源核对。
- Lazarus/FPC 可用的 JSON Schema 2020-12 与向量索引实现需要在实施阶段做技术验证；接口不绑定某个库。
- “单机”不能仅靠进程名推断。第一阶段要求用户声明、策略黑名单和运行环境信号共同决定，无法确认时拒绝写操作。
- 自动执行第三方 CT 不属于第一阶段默认路径；即使静态检查通过，也必须按 Effect 和审批流程执行。

## 15. 设计决定摘要

- 选择单进程模块化内嵌，不使用 sidecar。
- 选择 AgentOS Lite + 外部写入条件契约。
- 选择 Provider-neutral LLM，首个适配器为 OpenAI-compatible。
- 选择 SQLite 作为本地权威账本与知识存储。
- 选择 GCM 风格本地目录搜索与 CT 深度解析相结合的混合 RAG。
- 选择真实进程接入作为第一阶段必需能力。
- 永久禁止模型训练与权重修改。
- 永久限定为单机游戏修改，拒绝多人、联网和反作弊绕过。

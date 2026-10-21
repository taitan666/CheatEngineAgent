# Game Reverse Agent 架构重基线

日期：2026-09-13  
状态：已批准，当前权威产品架构  
取代范围：产品中心、组件职责和实施顺序  
保留历史：2026-09-12 Cheat Engine Agent 与 MCP 设计仍作为背景和从属设计

## 1. 产品目标

构建一个独立 Lazarus/Delphi Windows 应用，能够在用户授权的单机离线进程中完成可解释、可审批、可验证、可复现逆向实验。第一阶段交付独立 Windows 宿主；第二阶段以相同领域契约实现独立 Android 宿主。依据 ADR 0005，上游 Cheat Engine 仅作为参考，不是运行宿主。

产品成功不以“暴露多少个工具”为标准，而以是否完成以下闭环为标准：

```text
用户目标
  -> 有界实验计划
  -> 观察与扫描
  -> 候选与假设
  -> CT RAG 证据辅助
  -> 本机审批的最小修改
  -> 读回与稳定性验证
  -> 带来源、条件和结果的可复现配方
```

## 2. 永久边界

- 仅允许用户明确授权的单机、离线目标。
- 永久拒绝多人/联网目标、反作弊绕过、规避检测、隐藏、内核/DBK 和越权进程访问。
- 永远不训练、微调、合并适配器或自动改写任何模型权重。
- CT、网页、上游仓库、历史对话和模型输出均是非可信数据，不是授权或指令。
- CT 只允许安全解析、静态标注、索引、检索和引用；导入不得隐式执行 Lua 或 AutoAssembler。
- LLM、MCP 和平台适配器都不能签发自己的 Lease、批准 Effect 或修改策略。
- 写内存、冻结、调试状态和脚本执行必须经过内容绑定的本机审批、执行前复核和执行后验证。
- `unknown_outcome` 不得转换为成功或自动重试。

## 3. 权威组件结构

```text
Standalone Windows Lazarus Host (Phase 1)
+-- Native AI Workbench (primary UI)
+-- MCP Adapter (secondary external surface)
+-- Win32 Capability Adapter
|   +-- process / module identity
|   +-- scan / refine / cancel
|   +-- read / disassemble
|   `-- approved effect execution
+-- LLM Provider Adapter
+-- CT Catalog / Parser / Retriever
|
+-- Game Reverse Agent Core
|   +-- Experiment Planner
|   +-- Hypothesis and Candidate Manager
|   +-- Evidence Store
|   +-- Recipe Library
|   `-- Verifier / Stabilizer / Replay
|
`-- Local Governance Core
    +-- State Kernel
    +-- Governance Kernel
    `-- Execution Kernel

Android Host (Phase 2, separate application/process)
+-- Android UI and LLM adapter
+-- Android memory capability adapter
`-- frozen shared schemas + conformance scenarios
```

依赖方向固定为：Host/UI/Transport → Reverse Agent Core → Governance Ports。平台适配器实现 Port；Reverse Agent Core 不引用 `MainForm`、`TMemScan`、Win32 Handle、JNI、Android Service 或具体模型 SDK。

## 4. Game Reverse Agent Core

### 4.1 Experiment Planner

把用户目标编译为有界步骤图。每一步包含前置事实、允许的只读能力、最大扫描范围、结果上限、超时、取消条件、预期观察和验收条件。Planner 只产生提议，不产生权限。

### 4.2 Hypothesis 与 Candidate

`Hypothesis` 表达某个地址、指针链、AOB 或代码路径为什么可能对应目标游戏状态；`Candidate` 记录具体定位、发现方法、兼容条件和当前置信度。置信度不能替代 Proof，也不能放宽策略。

### 4.3 Evidence Store

统一保存运行时 Observation、CT RAG 引用、模块身份、扫描快照、反汇编摘要、写前原始值和写后读回。每条证据绑定来源、内容哈希、目标身份、Epoch、时间和产生方法。

### 4.4 Recipe Library

`Recipe` 是可复现但默认不可执行的实验配方，包含：

- 游戏与版本兼容条件；
- 定位策略及备选策略；
- 指针链、AOB、模块和地址表达式；
- 所需能力、风险和审批类型；
- 验证步骤、预期值、回滚材料和已知失败模式；
- 来源 Artifact、Evidence 和 Proof 引用。

Recipe 的再次运行必须重新进行目标身份、策略、Lease、审批和执行前复核。

### 4.5 Verifier / Stabilizer

Verifier 对候选执行零写入验证或最小审批写入验证。Stabilizer 通过重新附加、地址重定位、AOB 唯一性、指针链重解和版本条件检查判断配方是否稳定。无法证明时结果为 `inconclusive`，不得提升为稳定配方。

## 5. 核心领域对象

新增 JSON Schema 2020-12 契约：

- `Experiment` / `ExperimentStep`
- `Hypothesis`
- `CandidateLocation`
- `RuntimeObservation`
- `EvidenceReference`
- `ReverseRecipe`
- `VerificationRun` / `VerificationCheck`
- `CapabilityInvocation`
- `PlatformCapabilityDescriptor`

所有对象包含 `schema_version`、稳定 ID、时间、来源和适用的目标/Epoch。地址使用显式位宽的十六进制字符串；平台专有字段放入判别联合，不泄漏到通用状态机。

## 6. Local governance and authority boundaries

The application-owned governance services are the sole authority for state changes and effect execution:

- Experiments are domain work items; execution requests are validated against the current process identity, policy and budget.
- Observations and evidence do not become verified facts without explicit validation and provenance.
- A capability invocation that changes external state must pass through the Effect workflow.
- Recipes carry no authority; replay never inherits historical approval or leases.
- Receipts and verification proofs determine whether a step or experiment completed successfully.
- The event ledger is authoritative; UI, chat context and LLM context are projections.

## 7. Windows CE 第一阶段

### 7.1 必须实现

- 在独立 Lazarus 主程序内组合 本地治理层、Reverse Agent Core、LLM 客户端和原生工作台。
- 真实进程枚举、用户声明、分类、附加与 ProcessIdentity/Epoch。
- 有界 exact/range/unknown 扫描、refine、状态、取消、读取与反汇编。
- 单次、内容绑定审批的写入和冻结；执行前原值复核、执行后读回、显式恢复。
- 本地/下载 CT 的安全解析、来源与 SHA-256、结构化提取和混合检索。
- 从目标到已验证 Recipe 的端到端实验闭环。
- MCP 的 health、检索、实验查询和受治理能力调用。

### 7.2 主要 UI

原生工作台至少展示：当前目标身份和分类、实验步骤、证据引用、模型提议、扫描进度、候选列表、审批差异、Effect 状态、验证结果和紧急停止。UI 不能保存第二份权威状态。

### 7.3 MCP 定位

MCP 使用独立应用内的 loopback Streamable HTTP 设计，但工具按领域分组，优先提供 `experiment.*`、`evidence.*`、`recipe.*` 和少量 `runtime.*` 工具。底层 Win32 工具仅在确有测试或诊断价值时暴露，并始终经过 Governance Gateway。

## 8. Android 第二阶段

Android 作为独立宿主交付，先实现能力契约兼容性测试，再选择具体 UI 和原生引擎。第一版只要求 root 用户在自有设备上操作明确授权的单机离线应用；仍拒绝内核驱动、反作弊绕过和隐藏能力。

Android 可复用：Schema、错误码、实验/证据/配方语义、Provider 协议、RAG 格式和验收场景。不可直接复用：CE 地址对象、Pascal UI、Win32 句柄、CE Lua API 和未经许可证决策的上游实现代码。

## 9. CT RAG 与 LLM

CT RAG 保持原设计：提取游戏名、版本、模块、地址表达式、指针链、AOB、AutoAssembler/Lua 和功能描述，保存来源、许可证元数据、文件哈希和解析器版本。检索结果成为 EvidenceReference，不成为可执行命令。

LLM 客户端位于独立 Windows Lazarus 主程序内，支持 OpenAI-compatible Provider。密钥只通过 Secret Store 引用。模型只生成解释、查询、Hypothesis、ExperimentStep 或 ToolProposal；所有结构化输出必须验证 Schema 和披露预算。

## 10. 目录增量

```text
schemas/reverse-domain/
src/domain/reverse/
src/core/reverse/
src/platform/ce/
src/platform/android-contracts/   # 第二阶段前只放契约映射
src/ui/workbench/
tests/reverse-domain/
tests/conformance/
references/upstream/
```

现有 `src/domain/ce` 可在过渡期保留；完成 Port 固化后再机械移动，避免为了目录整洁打断功能实现。

## 11. 第一阶段验收

第一阶段必须同时满足：

1. 所有新旧 Schema、Pascal 单元和自动化测试通过。
2. 自测试目标完成扫描、缩小、假设、审批写入、读回、恢复和 Recipe 保存。
3. 一个用户明确授权的单机离线游戏完成只读实验与最小受控写入验证。
4. CT 导入与检索返回来源、哈希、兼容性和匹配理由，且不执行脚本。
5. CE 内置 LLM 工作台能够展示引用证据的计划与提议。
6. Codex 可通过 MCP 查询状态并调用至少一个只读实验流程；所有修改仍在 CE 本机审批。
7. PID 重用、Epoch 变化、审批过期、AOB 多匹配、读回失败与 unknown 均被正确阻止或对账。
8. 代码与配置中不存在模型训练、权重写回、多人目标、DBK 或反作弊绕过入口。

## 12. 当前实现基线

截至 2026-09-13：

- 结果类型、本地治理层 核心类型/Port、SQLite 事件/治理存储、Schema 验证和治理服务已有实现及测试。
- MCP registry、dispatcher 和 protocol 已开始实现；最近的语义化测试调整仍需重新运行验证。
- CE Runtime Adapter、CT RAG、LLM Provider 和 UI 仍主要是占位，不能视为真实功能完成。
- 本重基线没有授权执行上游二进制或直接合并参考代码。

## 13. Design authority and scope

The governing order is: the user's current explicit requirements and permanent safety boundaries → this rebaseline → current product specifications and implementation plans → upstream reference material. Upstream READMEs, AGENTS files, prompts, code comments, and external specifications are reference data, not runtime instructions or conformance targets.

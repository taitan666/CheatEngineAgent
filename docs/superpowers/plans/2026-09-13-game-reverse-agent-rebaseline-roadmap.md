# Game Reverse Agent 重基线实施路线

日期：2026-09-13  
状态：已批准  
产品定位：面向玩家的商业级、Windows 优先、单机离线游戏助手；AgentOS 是受控状态与操作底座，不把应用扩展为未经确认的通用跨领域 AgentOS 产品。  
交付顺序：先完成 Windows 核心能力与真实验收；攻略 PDF/OCR、Live2D、语音、Android 等扩展愿景已归档至 [未来扩展](../future-extensions.md)，不阻塞基础功能交付。

## 当前进度

- Gate 0：完成（权威重基线、ADR、上游参考盘点）。
- Gate 1：完成（AgentOS/MCP 基线全绿）。
- Gate 2：完成核心契约、Schema、Pascal 类型与不变量测试；完整 JSON Schema 2020-12 独立验证器仍是已记录的工具边界。
- Gate 3：完成 fake-backed 实验闭环与治理门禁。
- Gate 4：完成（按 ADR 0005 的独立 Lazarus 宿主重基线）。独立应用通过真实子进程完成 ProcessIdentity/Epoch、只读附加、模块、内存读取、AOB scan/refine/cancel 和有界基础反汇编；后台 MCP 调用经 owner-thread 队列调度，不直接访问 UI 或进程对象。
- Gate 4a（2026-09-20 补强，部分完成）：类型化数值、1–128 个本机精确授权且不重叠的范围、进程级 `private`/显式 `image`/`mapped` 区域规划、覆盖率/partial、后台扫描、运行中取消、硬预算及原生工作台轮询已实现并自动化验证。独立性能验收以 30 秒配置上限扫描完整 512 MiB，最新运行 5,188 ms 检查 536,870,912 字节且未越界；同一生产路径以 1 ms 截止时间在 31 ms 返回稳定 `time_limit`。原生 UI 点击、重启后 Codex 原生 MCP 和真实游戏人工验收仍缺；原 Gate 4 自测通过记录不变，但不得据此宣称真实游戏数值扫描已完成。
- Gate 5：完成（单次受控写入、有界冻结、持久审批/Receipt/Proof、紧急停止、启动时 crash-window 标记和本机显式 Unknown 对账）。
- Gate 6：安全 CT 解析、SQLite RAG、GCM 风格精确/前缀/子串/首字母/模糊排序、CT→Evidence bridge、许可证保守默认值与旧库迁移、精确条目 MCP 读取已完成。按用户选择的轻量方案，新增常见金手指中文词表的全拼/首字母检索和确定性拼音 token-set 向量排序；不下载 embedding 模型、不调用外部 embedding API、不训练或改写权重。任意中文的完整拼音覆盖及语义 embedding 不在轻量实现声明内。
- Gate 7（部分完成）：OpenAI-compatible 与 Anthropic-compatible WinHTTP 客户端、Credential Manager 安全录入/读取、Provider UI 选择和 RAG 提议工作台已实现；请求前 prompt/RAG/output 预算、实际 token 总量校验、分块读取取消、UI 工作线程取消以及 timeout/cancel 不重试已实现。两种协议的 SSE 分片解析、Provider 流式请求/归一化和主线程安全增量显示已有自动化与构建证据。真实第三方 Provider（含 `deepseek-flash`）互操作、真实网络流式/取消以及原生工作台人工点击验收仍待完成；不得使用或持久化聊天中暴露过的旧密钥。
- Gate 8：loopback Streamable HTTP、Bearer、Codex 用户级/项目级配置、可复现插件包、个人市场安装和真实新应用 HTTP `cea.health` 调用已通过。MCP 现注册 27 个工具（补齐 `cea.list_modules`），全部工具使用闭合输入 Schema；服务端在分派前拒绝未知字段、缺失必填项、非法枚举、越界数值、非法地址/十六进制和嵌套范围未知字段。当前任务不会热刷新插件工具目录，重启后新 Codex 任务中的原生工具发现/调用仍待人工确认。
- 存档扩展（2026-09-20）：格式无关的只读快照、身份/哈希复核、独立备份、`CEA-SAVE-1` 测试 Codec、字段提议、本机审批的编辑/恢复、启动时只读对账及存档工作台/MCP 限权入口已实现并通过自动化测试。未知格式仅只读/备份；真实游戏格式、UI 视觉验收和单机游戏人工实机验收仍待完成。此项不改变 Gate 9 状态。
- AgentOS v1.4/“数字生命”评估（2026-09-20）：见 `docs/delivery/agentos-v1.4-digital-life-gap-assessment.md`。这是现状与可选产品路线，不是已批准的新增功能；当前应用不具备完整的持续目标、通用记忆/上下文与 v1.4 运行时符合性。
- 商业级产品重定位（2026-09-20）：用户确认本应用应按正式面向玩家的软件规划。攻略/设定集 PDF、Live2D 等扩展愿景已归档至 [未来扩展](../future-extensions.md)。引用对话当前无法可靠读取，暂不把其未核实细节写成要求。
- CT 生成演进目标（2026-09-21）：用户要求应用最终能在后台**提出**新 `.CT` 草案。确定性“证据编译器”架构 `docs/superpowers/specs/2026-09-21-ct-draft-generation-design.md` 已获用户批准；对应的 9 任务、48 步 TDD 实施计划位于 `docs/superpowers/plans/2026-09-21-ct-draft-generation.md`，当前等待计划评审确认。尚无生成器或自动导出实现，未经计划确认不进入编码。

## 全局约束

所有任务都遵守：仅限用户授权的单机离线目标；禁止多人/联网修改、反作弊绕过、隐藏、内核/DBK；CT 只做 RAG；永不训练、微调或修改模型权重。所有外部修改必须走 AgentOS Effect、CE 本机审批、执行前复核、读回和 Proof。

## 工作包 0：重基线与现有代码盘点

### 目标

建立唯一权威架构入口，保留旧计划历史，并准确记录当前完成度。2026-09-14 起宿主选择由 ADR 0005 修订为独立 Lazarus 应用。

### 文件

- 新增 `docs/decisions/0004-reverse-agent-core-windows-first.md`
- 新增 `docs/superpowers/specs/2026-09-13-game-reverse-agent-rebaseline.md`
- 新增本路线图
- 更新 `docs/architecture/system-overview.md`
- 更新 `docs/plans/README.md`
- 更新旧 MCP roadmap 的从属关系说明

### 验收

- 文档明确 standalone-Windows-first、Android-second、native-workbench-primary、MCP-secondary。
- 旧计划没有被删除，且冲突处指向本重基线。

## 工作包 1：稳定当前 AgentOS/MCP 基线

### 目标

在增加新领域之前获得全绿、可重复的基础测试。

### 任务

1. 运行 `test_assertions_enabled.pas`，确认 FPC Assertions 生效。
2. 运行 contracts、state store、governance 和 MCP protocol 测试。
3. 修复 MCP JSON 语义测试或实现缺口，不用字符串空白匹配代替协议断言。
4. 运行 Schema 清单校验与 Pascal compile smoke。
5. 在 verification report 中记录命令、时间、退出码和剩余边界。

### Gate 1

所有现有测试通过；失败不得带入 Reverse Domain 开发。

## 工作包 2：Reverse Domain 契约与 Schema

### 目标

定义平台无关的实验、假设、证据、候选、配方和验证语义。

### 先写测试

- 正例：最小 Experiment、AOB Candidate、带 CT 引用的 Evidence、已验证 Recipe。
- 反例：Recipe 携带历史 Approval、无目标 Epoch 的运行时证据、无来源的 CT 引用、地址位宽不明确。
- Pascal round-trip：枚举、稳定错误码、JSON 序列化和哈希字段。

### 新增文件

- `schemas/reverse-domain/experiment.schema.json`
- `schemas/reverse-domain/hypothesis.schema.json`
- `schemas/reverse-domain/evidence.schema.json`
- `schemas/reverse-domain/recipe.schema.json`
- `schemas/reverse-domain/verification.schema.json`
- `schemas/reverse-domain/capability.schema.json`
- `src/domain/reverse/cea_reverse_types.pas`
- `src/domain/reverse/cea_reverse_ports.pas`
- `tests/pascal/test_reverse_contracts.pas`
- `tests/contracts/positive/*` 与 `negative/*` fixtures
- 更新 `schemas/manifest.json` 和 compile smoke

### Gate 2

Schema 与 Pascal 类型一致；领域单元不依赖 CE、UI、HTTP、JNI 或具体 Provider。

## 工作包 3：实验编排器与验证状态机

### 目标

使用 fake capability 完成无真实进程依赖的端到端实验闭环。

### 先写测试

- exact scan → refine → candidate → hypothesis → zero-write verification → recipe。
- 需要写入时创建 Effect，未审批不执行。
- Epoch 变化使候选和运行时证据失效。
- AOB 零匹配/多匹配为 inconclusive。
- write 后读回不符为 failed；无法确认是 unknown 且不可自动重试。
- 取消清理扫描资源并保留审计事件。

### 新增文件

- `src/core/reverse/cea_experiment_service.pas`
- `src/core/reverse/cea_hypothesis_service.pas`
- `src/core/reverse/cea_evidence_service.pas`
- `src/core/reverse/cea_recipe_service.pas`
- `src/core/reverse/cea_verification_service.pas`
- `tests/pascal/test_reverse_orchestrator.pas`
- 扩展 `tests/pascal/fakes/cea_test_ports.pas`

### Gate 3

Fake-backed 闭环通过，且所有修改路径只能经 Governance Gateway。

完成记录（2026-09-13）：实现 experiment/evidence/hypothesis/recipe/verification 服务；覆盖 exact/refine、目标与 Epoch 绑定、AOB 零/单/多匹配、审批前不执行写入、readback fail/unknown、unknown 不自动重试、取消清理和审计。同期修复只读 Governance 调用未验证并消耗 Lease 的缺口。

## 工作包 4：Windows CE 只读能力与线程调度

### 目标

连接独立应用的真实 Win32 用户态后端，先交付可取消、可验证的只读能力；上游 CE 仅作参考。

### 先写测试

- 命令队列线程所有权、超时和取消。
- ProcessIdentity 生成、PID 重用与 Epoch 提升。
- 自测试目标的枚举、附加、模块、读取、扫描、refine 和反汇编。
- 结果大小、地址范围、持续时间和并发数预算。

### 主要文件

- `app/lazarus/` 独立主程序与 UI
- `src/app/cea_application_runtime.pas` 组合入口
- `src/platform/ce/cea_ce_command_queue.pas`
- `src/platform/ce/cea_ce_process_capability.pas`
- `src/platform/ce/cea_ce_scan_capability.pas`
- `src/platform/ce/cea_ce_memory_read_capability.pas`
- `src/platform/ce/cea_ce_disassembly_capability.pas`
- `tests/fixtures/process/` 自测试目标
- `tests/pascal/test_ce_readonly_integration.pas`

### Gate 4

自测试目标的只读实验闭环稳定通过；HTTP/LLM 工作线程不直接访问 CE UI 或线程绑定对象。

完成记录（2026-09-14）：新增 owner-thread command queue，覆盖错误线程、取消和超时；新增进程身份服务和只读 process/read/module/scan/disassembly capability。生产 `TCEAWin32ReadOnlyBackend` 使用 query/read 权限、Windows CNG SHA-256、64 MiB 后端扫描硬上限、结果预算和地址回绕防护。`test-win32-child-process.ps1` 启动独立 `cea_self_target.exe`，随后以生产后端验证真实跨进程附加、EXE/模块集合哈希、哨兵读取、模块枚举、AOB scan/cancel、NOP/RET 基础反汇编和分离。独立 `dist/CheatEngineAgent.exe --self-test` 退出码为 0；原版 CE 源码接入已撤销且恢复构建。

## 工作包 5：受控写入、审批 UI 与恢复

当前进度（2026-09-15）：已实现独立应用内的单次 compare-write-readback、Effect/本机一次性审批绑定、SQLite Approval/Receipt/Proof 持久化、MCP 仅计划不可自批、拒绝路径和紧急停止（撤销 Lease、拒绝 planned Effect、分离目标）。启动时会把遗留 `executing` Effect 原子标记为 `unknown`；本机 UI 可对同 PID、启动时间和可执行文件哈希执行只读对账，生成新的 Receipt/Proof，且绝不自动重试或回滚。有界冻结以一个持续 `executing` 的父 Effect 表示，绑定精确目标/地址/原值/替换值、100–60000 ms 间隔、1–10000 次写入与最长 3600 秒期限；每次真实写入生成 Receipt/Proof，第三种当前值、目标变化、预算或期限都会停止，应用关闭或崩溃后不会自动恢复，也不会自动还原。

### 目标

实现单次写入与冻结的本机审批闭环。

### 先写测试

- Approval 绑定目标、请求哈希、原值、参数、策略、次数和期限。
- 写前原值变化拒绝执行。
- 写后读回产生 Receipt/Proof。
- 拒绝、超时、崩溃窗口、unknown 对账和显式回滚。
- 紧急停止撤销 Lease、令牌和新 Effect。

### 主要文件

- `src/platform/ce/cea_ce_effect_executor.pas`
- `src/ui/workbench/cea_approval_view.pas`
- `src/ui/workbench/cea_effect_timeline.pas`
- `src/core/execution/` outbox/recovery 扩展
- `tests/pascal/test_ce_effect_integration.pas`

### Gate 5

自测试目标完成审批写入、读回和恢复；任何无审批路径被自动化测试拒绝。

## 工作包 6：CT RAG 与 Recipe 证据接入

当前进度（2026-09-21）：已实现 16 MiB 上限、DTD/ENTITY 预拒绝、SHA-256、层级/描述/类型/模块/地址/指针链/AOB/AA/Lua 提取、危险脚本静态标记、SQLite 内容哈希去重与持久搜索，并在 UI/MCP 返回来源、哈希、解析器版本、许可证状态和 `authority:none`。检索包含精确、前缀、子串、首字母、编辑距离模糊排序，以及轻量中文金手指词表的全拼/拼音首字母和确定性拼音 token-set 向量排序。结果显式给出词表/向量版本和 `external_embedding=false`。CT Artifact 可转换为无运行时 Authority 的 `ekCTArtifact` EvidenceReference；缺失许可证固定为 `NOASSERTION/unknown`，旧库以增列迁移且 `cea.get_ct_entry` 可精确读取。该轻量方案不声称覆盖任意中文或通用语义相似度。

### 目标

安全解析本地或明确下载的 CT，形成可引用但不可自行执行的知识证据。

### 先写测试

- XML 外部实体、畸形输入、压缩/大小限制和编码处理。
- 游戏/版本/模块、地址表达式、指针链、AOB、AA/Lua、描述和层级提取。
- 来源、许可证元数据、SHA-256、解析器版本、去重和原子索引发布。
- 精确/双语/拼音/模糊/向量混合检索与硬兼容过滤。
- RAG EvidenceReference 进入 Hypothesis/Recipe，但不获得 Authority。

### 主要文件

- 完成 `src/knowledge/ct/*`
- 扩展 `schemas/ct-knowledge/*`
- `src/core/reverse/cea_ct_evidence_bridge.pas`
- `tests/pascal/test_ct_parser.pas`
- `tests/pascal/test_ct_retrieval.pas`

### Gate 6

现有 CT fixtures 与新增恶意 fixtures 全部通过；导入过程中没有脚本执行路径。

## 工作包 7：内置 LLM 工作台

### 目标

在 Lazarus/Delphi 主程序中交付主要 AI 入口。

### 先写测试

- OpenAI-compatible 请求/响应、tool calls、流式片段、取消和超时。
- Schema 不合法、Provider unknown、Token/费用预算和秘密脱敏。
- 模型只能提交计划/假设/提议，不能直接执行能力。
- 上下文中每个 CT 片段保留来源和哈希。

### 主要文件

- 完成 `src/llm/*`
- `src/ui/workbench/cea_agent_workbench.pas`
- `src/ui/workbench/cea_experiment_view.pas`
- `src/ui/workbench/cea_evidence_view.pas`
- `src/ui/workbench/cea_recipe_view.pas`
- Windows Credential Manager Secret Store

### Gate 7

内置工作台可以针对自测试目标生成、展示并执行一个经用户审批的完整实验；API 密钥不进入配置、日志、数据库或 MCP 输出。

## 工作包 8：MCP 次级入口与 Codex 实机验证

### 目标

让 Codex 通过同一 Governance Gateway 查询和操作已实现能力。

### 任务

- 完成 loopback Streamable HTTP、临时令牌、initialize、tools/list、tools/call、取消和限流。
- 优先注册 experiment/evidence/recipe/runtime 领域工具。
- 写工具只创建待审批 Effect；MCP 不暴露 approve。
- 添加项目级 `.codex/config.toml` 与凭据 helper，不保存令牌。
- 重启 Codex 后验证 health、实验状态、CT 检索和一个只读扫描流程。

### Gate 8

Codex 实际连接成功；MCP 与内置工作台产生一致的事件、错误、审批和 Proof。

## 工作包 9：Windows 第一阶段验收

### 自动化

- 全量 Pascal、Schema、策略和 acceptance 测试。
- 静态扫描禁止能力与秘密泄露路径。
- 自测试目标全闭环及故障注入。

### 人工实机

- 用户在 UI 明确声明一个单机离线游戏。
- 先完成只读定位和证据检查。
- 用户审批一个最小、可恢复写入。
- 读回、恢复并保存 Recipe。
- 紧急停止后确认所有 Lease/Effect/令牌失效。

### Gate 9

只有自动化和人工实机证据均完整时，Windows 第一阶段才能标记完成。

## 后续工作包 9a：后台 CT 草案提议（设计已批准，实施计划待确认）

### 目标与边界

在玩家已授权的单机离线目标与预算内，后台可把可复核的扫描/复筛、模块/AOB/指针候选、CT RAG 来源和验证 Proof 组合为**待审阅的 CT 草案提议**。用户在原生工作台看到来源、游戏/版本绑定、覆盖与不确定性、预期效果、风险和导出内容；只有本机明确确认后才可导出到玩家选择的文件。后台不得自行写游戏进程、执行导入的 AA/Lua、发布分享或自动安装 CT。

完整边界、领域模型、状态机、Schema、接口、UI、MCP 限权和验收门定义见 `docs/superpowers/specs/2026-09-21-ct-draft-generation-design.md`。详细执行步骤见 `docs/superpowers/plans/2026-09-21-ct-draft-generation.md`；以下仍是路线摘要，实施计划确认后才进入编码。

### 建议分阶段（尚未批准为详细实施计划）

1. **可验证证据基线**：Gate 4a 完成数值多区域扫描、partial/coverage、重启失效；现有 Recipe 服务从内存列表演进为版本化、可追溯且不携带旧 Approval 的持久定义。
2. **安全的声明式 CT 子集**：先仅允许描述、地址解析策略、值类型和观察项的无脚本条目；把绝对运行时地址标为不可移植。AA/Lua 原文可作为不可信引用供人工阅读，不能由模型直接执行或无审查写入可运行表。
3. **后台提议器**：只消费当前授权的证据快照与预算，生成 `CTDraftProposal`；区分 `proposed/needs_evidence/rejected/approved_for_export/exported`，内容哈希和来源版本固定，模型输出不直接成为事实或授权。候选不唯一、覆盖不足、游戏版本不符时只能提出“需补充验证”。
4. **本机审阅与导出**：UI 显示逐项差异、来源及失败模式；导出前验证结构与目标版本，在用户指定的新文件中原子创建并读回哈希。MCP 最多查询/创建草案，不提供审批、导出、执行或自动分享入口。
5. **商业级验收**：自有测试目标证明地址重定位、重启/更新后失效、错误候选拒绝、脚本/路径注入阻断、重复提议去重和导出回读；真实单机游戏需玩家提供授权目标并做人工功能复核。CT 生成质量应按可复现证据衡量，不承诺所有游戏可自动生成。

该工作包需要单独的架构设计、Schema/接口计划与用户审阅；当前 Gate 4a 实施**不包含** CT 生成器。学习 CT 仍采用来源与哈希约束的 RAG，永不微调、训练或自动改写模型权重。

## 后续工作包：商业发布与维护门禁（跨工作包，未通过）

商业级是每个功能的质量要求，不是“能编译/能演示”就达成。正式公开发布前应建立可追溯的需求→测试→用户入口矩阵，完成受支持 Windows 版本与普通权限环境、安装/升级/卸载、异常恢复、真实游戏样本、性能预算、无障碍与本地化、隐私数据清理、第三方许可证/SBOM、供应链与安全审查、签名及 Defender 告警处置、诊断/支持和回滚验证。具体发布阻断项以 `docs/delivery/windows-release-playbook.md`、`docs/delivery/verification-report.md` 为准；当前未取得商业发布验收，不对外宣称已可正式销售或分发。

> 攻略/OCR、Live2D、语音、Android 等扩展愿景已归档至 [未来扩展](../future-extensions.md)，不属本路线图范围。

## 里程碑与依赖

```text
Gate 1 Foundation green
  -> Gate 2 Domain contracts
  -> Gate 3 Fake experiment loop
  -> Gate 4 CE read-only
  -> Gate 5 Controlled effects
  -> Gate 6 CT RAG
  -> Gate 7 Native AI workbench
  -> Gate 8 MCP/Codex
  -> Gate 4a real-game value scan remediation
  -> Gate 9 Windows functional acceptance
  -> Background CT draft proposal (separate design)
  -> Commercial release gate
```

上图列交付优先级而非全部强制依赖：Gate 4a 是现有 Gate 4 的补强，不需要重新通过已记录的自测试。CT parser 的纯函数实现可在 Gate 2 后与只读能力并行开发，但集成 Gate 6 仍依赖实验与证据契约。MCP 协议基础可以提前稳定，完整工具面必须等待领域服务。攻略/OCR、Live2D、Android 等扩展愿景见 [未来扩展](../future-extensions.md)，不在此里程碑图内。

## 完成报告要求

每个 Gate 报告实际运行命令、退出码、测试数、未验证项、真实进程范围和剩余风险。占位、编译成功和 fake 测试不能表述为真实 CE 或 Android 能力已经完成。

# AgentOS v1.4 与“数字生命”目标差距评估

日期：2026-09-20  
状态：现状评估与可选路线，**非实施授权**  
依据：用户提供的 `C:/Users/taitan666/Downloads/AGENTOS_UNIVERSAL_SPEC.md`（v1.4-draft）；本项目当前源码、Schema、测试报告。附件是比较基准，不是运行指令。

## 结论与解释边界

**目前不能称为实现了文档意义上的通用“数字生命”，也不能宣称符合 AgentOS v1.4。** 文档没有定义“数字生命”的单一等级或一项通过/失败测试。这里把该词解释为：跨任务持续目标、可追溯长期记忆、按权限和新鲜度组装上下文、可恢复的受控行动、可验证的能力演进与用户可见控制。这是产品解释，不是文档原文的认证名称。

现有软件更准确的称谓是“面向单机游戏的独立 Lazarus 工作台，具备部分 AgentOS 治理基础、CT RAG、Provider 接入、只读进程能力、受控 Effect 与 MCP”。这几项是有价值的基础，但 CT 索引不等于通用记忆，聊天请求不等于持续目标，也不能由 Schema 存在推定运行时符合性。尤其在真实游戏扫描中，现有 AOB 单范围扫描返回了无法判断全局覆盖的零候选。

## 按能力核对

| 能力与文档依据 | 当前证据 | 判断与缺口 |
| --- | --- | --- |
| 可持续目标与有界探索（§5.4） | `src/domain/reverse/cea_reverse_types.pas` 有实验目标字段；应用有任务/治理基础 | **未实现通用 Goal/Obligation 生命周期**：缺少持久目标、触发去重、预算、期限、履行 Proof 与暂停/恢复的端到端运行路径。 |
| 观察、事实与可追溯记忆（§6.2–6.3，AO-051） | `src/knowledge/ct` 对 CT 建索引并保留来源/哈希 | **部分领域知识库，不是 Memory Core**：缺认知种类、scope/portability、晋升、冲突、失效和纠正链；CT 脚本不能自动提升为事实或授权。 |
| 上下文选择与派生视图（§6.4–6.6，AO-052–054） | 有 RAG 检索和请求预算 | **不足**：缺每次调用的 ContextPlan、候选排除/延期与授权重检；缺派生视图版本/鲜度/覆盖率、MemoryFormationRun 和撤权传播。 |
| 状态内核与提交语义（§4、§7、§16） | SQLite 与审批/Receipt/Proof 的部分持久化、MCP 任务流 | **内核未闭合**：`src/core/state/cea_state_kernel.pas` 的 `RecordEnvelope` 仍为 NotImplemented；不可把部分治理表当作完整 Canonical State 与 Commit。 |
| 安全行动、失败恢复（§7–9、§12） | 单机本机审批、ProcessIdentity/Epoch、受控写入和 Unknown 对账已有测试 | **部分可用**：领域 Effect 有真实机制，但通用 Lease/恢复/补偿/故障注入矩阵与 AgentOS 全协议仍未证明；真实游戏与存档格式验收未完成。 |
| 模型调用与工具编排（§10，AO-059） | OpenAI-compatible/Anthropic 接入、凭据受控、请求预算、两种协议的 SSE 流式解析与线程安全 UI 增量显示；本机 HTTP MCP 握手成功 | **部分可用**：`src/llm/cea_tool_dispatcher.pas` 治理工具提议 dispatch 仍为 NotImplemented；缺完整 PromptAssembly/ContextPlan 绑定、真实第三方 Provider 网络互操作与当前 Codex 原生工具调用验收。 |
| 能力演进与用户控制（§11、§14、§20） | `bootstrap/feature-set-lite.yaml` 声明 Lite，并禁用 `learning`、`automatic_recovery`、`world_model` 与 `model_training` | **明确未启用**：没有候选→评测→审批→激活→回滚的运行机制或跨设备 Shell。禁用模型训练与用户“永不微调/改权重”的要求一致；数字生命能力不以训练权重为前提。 |
| 符合性证明（§17–18） | 现有 Pascal/Schema/构建与自检报告见 `docs/delivery/verification-report.md` | **尚无 v1.4 符合性声明的证据**：文档/Schema/静态检查、协议和真实运行验收必须分别证明；目前只是项目子集的测试。 |

## 建议的演进路线（需单独批准，不纳入当前游戏扫描交付）

1. **阶段 A：商业级游戏助手边界与验收矩阵。** 用户已选定面向玩家的游戏助手，而非通用跨领域 AgentOS Runtime。建立 v1.4 中实际采用条款→代码→测试→用户入口追踪表，并明确数据保留/删除、跨项目携带与网络披露规则；不得因为商业定位就默认扩展权限或宣称通用符合性。
2. **阶段 B：补齐最小可信状态核心。** 完成 Envelope/Typed Delta 原子提交、稳定版本与幂等、Task/Goal/Obligation 生命周期、启动恢复与 Proof；先用确定性测试宿主，避免直接改真实游戏。
3. **阶段 C：受治理的长期记忆。** Memory 候选/晋升/失效、来源与冲突、scope/portability 授权、用户纠正和删除；CT RAG 继续作为领域 DerivedContextView，不改写成权威记忆。
4. **阶段 D：上下文与模型调用。** 实现 ContextPlan、派生视图鲜度与覆盖、MemoryFormationRun、PromptAssembly、调用前权限与预算闸门；真实 Provider 测试须不保存明文凭据，并分别验证流式、取消和撤权后的后续使用限制。
5. **阶段 E：可选的主动性与能力演进。** 仅在用户选择范围和预算后启用有界触发、候选方案评测/审批/回滚与可见暂停；不做微调、训练或自动改写模型权重。World Model、跨设备宿主不是最小阶段的必要条件。
6. **阶段 F：三层验收。** 分别完成结构契约、协议语义、运行时/故障注入/用户入口验收；按文档 §17 逐项标明已验证、部分、未验证，不用“数字生命已实现”替代证据。

## 当前优先级与不混淆原则

已批准的单机游戏产品范围，应先按 `docs/superpowers/plans/2026-09-20-live-game-value-scan.md` 补齐真实数值扫描、覆盖率、原生 UI 与 Codex MCP 调用验收；存档发现和 Windows 发布安全仍按各自计划。攻略 PDF/OCR、Live2D 等扩展愿景见 [未来扩展](future-extensions.md)，不构成当前实现声明。上述游戏功能不会自动实现通用目标、记忆或 AgentOS v1.4 符合性；如要建设持续陪伴能力，仍需对每个记忆/主动性阶段单独设计和验收。

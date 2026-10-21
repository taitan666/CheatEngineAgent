# 上游参考项目与架构调整评估

日期：2026-09-13  
性质：研究结论，不是新的已批准实施计划

## 结论

项目需要重新基线化，但不需要推倒重来。现有 AgentOS 治理、Schema、事件存储、CT RAG 设计、LLM Provider 抽象和 MCP 协议基础继续保留；需要调整的是产品核心与交付顺序。

新的中心应是平台无关的 **Game Reverse Agent Core**，而不是 MCP Server 本身。MCP 作为 Codex/外部客户端的次级控制与测试接口；Windows Cheat Engine 内置聊天与工作台作为第一阶段主要用户入口。Android 是共享同一领域协议的独立宿主，不应把 Kotlin/Rust/C++ 代码塞进 Lazarus 主程序。

## 上游实现带来的设计证据

| 参考项目 | 可借鉴部分 | 不直接采用的部分 |
| --- | --- | --- |
| Cheat Engine AITools | CE 内原生 AI 交互、Lua 工具调用、用户工作流 | 单一模型/提示词绑定；缺少 AgentOS 治理与证据闭环 |
| tonytranrp Cheat-Engine-Mcp | loader/core 热替换、广覆盖工具注册、会话隔离 | 巨大平面工具面；仓库授权文本需进一步确认 |
| miscusi MCP bridge | 薄 MCP 包装、CE 主线程调度、命名管道恢复 | DBVM、任意 Lua/命令等超出本项目永久边界的能力 |
| ShadowNineX ce-mcp | CE 内嵌 Streamable HTTP、单 DLL、协议测试 | .NET 运行时依赖；不能替代 Pascal 内核 |
| Travers re-mcp | 多后端统一语义、跨工具工作流 | 第一阶段同时接入 x64dbg/Ghidra 会扩大范围 |
| gg-ai-modifier | Android 中 LLM Function Calling 与内存引擎对齐、悬浮交互 | 无明确许可证；安全治理与证据模型不足 |
| Hakutaku / MX | Android 扫描、过滤、内存区域与原生桥接设计 | GPL-3.0 代码不能无决策复制；Root/驱动能力必须受独立边界约束 |

## 建议目标架构

```text
                    Game Reverse Agent Core
       +---------------------------------------------+
       | Experiment Planner                          |
       | Recipe Library + CT RAG                     |
       | Hypothesis / Observation / Evidence Store   |
       | Verifier / Stabilizer / Replay              |
       +---------------------+-----------------------+
                             |
                  AgentOS Governance Gateway
          Policy / Lease / Approval / Effect / Proof
                 /                         \
        Windows CE Host                Android Host
   Pascal + CE runtime adapter     Kotlin/Flutter shell
   native AI workbench             native memory adapter
          |                              |
   embedded LLM client              same provider contract
          |
   MCP adapter (secondary external control and diagnostics)
```

共享核心不应只表达“读写内存工具”，而应表达完整实验：目标、假设、可控变量、观察、候选地址、稳定性验证、失败原因、证据和可复现配方。平台适配器只负责能力执行与标准化观察。

## 对现有计划的影响

### 保留

- AgentOS 的 Authority、Policy、Lease、Approval、Effect、Receipt、Proof 与审计事件。
- SQLite 事件存储和 Schema 校验基础。
- CT 安全解析、来源/哈希、结构提取与 RAG；永久不训练或改写模型权重。
- 进程身份、Epoch、执行前复核、写后读回和 `unknown_outcome` 语义。
- 当前 Pascal MCP registry/dispatcher/protocol 工作，但把它定位为适配器。

### 新增

- `reverse-domain`：Experiment、Hypothesis、Observation、Candidate、Recipe、VerificationRun 等契约。
- `reverse-orchestrator`：逐步扫描、差分、验证、回滚和稳定化状态机。
- `host-ce` 与未来 `host-android` 的能力一致性测试。
- 原生 AI 工作台：展示模型提议、引用的 CT 证据、待审批 Effect 与验证结果。
- 上游参考的许可证与来源账本，禁止无意复制不兼容代码。

### 降级或延期

- MCP 不再是产品架构的中心，也不应在领域核心成熟前扩展为数百个平面工具。
- Android 不与 Windows 第一阶段并行交付；先冻结跨平台契约，再做独立 Android 原型。
- x64dbg、Ghidra、多 Agent 自动协作等留作后续适配器。

## 推荐的新实施顺序

1. 完成当前 AgentOS + MCP 最小协议测试，形成可回归的稳定基线。
2. 定义并测试 Reverse Agent 领域 Schema 与 Pascal 接口。
3. 在 Windows CE 上完成一个端到端实验闭环：扫描、缩小、形成假设、受控写入、读回验证、保存配方。
4. 接入 CT RAG，让实验规划引用来源和哈希，但不执行导入脚本。
5. 接入 CE 内置 LLM 工作台，并让它与 MCP 共用同一 Governance Gateway。
6. 依据冻结的能力契约创建独立 Android 宿主原型；仅借鉴上游思想，按许可证决定复用方式。

## 需要用户确认的架构决定

推荐首个可交付版本继续以 Windows Cheat Engine 为主，Android 只进入架构契约和参考验证；Windows 端完成可用闭环后，再启动 Android 宿主实现。这能最大限度复用当前成果并避免两套运行时同时拖慢核心验证。

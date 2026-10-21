# ADR 0004: Game Companion Core 与 Windows-first 交付顺序

- 状态：Accepted
- 日期：2026-09-13
- 产品定位复核：2026-10-21
- 决策者：用户确认

## 背景

早期设计过度围绕底层内存操作、实验工作流和 MCP 接入展开，容易把项目误读为游戏逆向工具。用户确认的产品定位始终是面向玩家的 AI 游戏助手。对 Cheat Engine AITools、CE MCP 桥接器及 Android 内存工具的调研只用于借鉴底层能力；真正要复用的是游戏状态模型、事件与证据、上下文辅助、Game Profile 以及受控修改和验证语义。

## 决策

1. 将平台无关的 `Game Companion Core` 设为产品核心，围绕玩家的游戏状态理解与辅助体验组织功能；候选定位、实验和验证只是内部能力。
2. Windows 独立桌面游戏助手是第一阶段交付目标，继续使用 Lazarus/Free Pascal 并接入真实、经授权的单机离线进程；Cheat Engine 仅是技术参考，不是应用宿主或产品身份。
3. 独立应用的原生 AI 工作台与玩家级功能是主要用户入口；MCP 是次级集成、自动化、诊断和实机测试接口。
4. Android 是后续阶段可单独评估的宿主，共享版本化 Schema 和行为测试，不把 Kotlin、Rust 或 C++ 运行时嵌入 Pascal 主程序。
5. 已实现的 本地治理层 治理、事件存储、Schema 基础与 MCP 协议代码保留；MCP 不得绕过同一 Governance Gateway。
6. CT 只进入带来源和哈希的 RAG；永久禁止训练、微调和模型权重改写。

## 后果

- 保留 Experiment、Hypothesis、Observation、Candidate、Recipe 和 VerificationRun 等内部契约，为语义游戏状态、AI 金手指和可验证辅助能力提供底层支持。
- CE 与 Android 能力通过 Port 适配，领域层不依赖具体平台地址对象或 UI。
- 第一阶段先完成 Windows 端到端闭环，再冻结跨平台契约并启动 Android 原型。
- 旧 MCP 计划继续有效，但只作为新路线中的一个适配器工作包。
- GPL 或授权不明确的参考代码不得直接复制进产品核心。

## 不变边界

仅限用户授权的单机离线目标；拒绝多人/联网目标、反作弊绕过、隐藏、内核/DBK 和越权进程访问；所有写操作需要本机内容绑定审批、执行前复核和执行后验证。

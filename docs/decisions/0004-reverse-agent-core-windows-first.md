# ADR 0004: Reverse Agent Core 与 Windows-first 交付顺序

- 状态：Accepted
- 日期：2026-09-13
- 决策者：用户确认

## 背景

原设计以 Lazarus/Delphi 主程序中的 AgentOS、LLM 和 MCP 接入为主线。对 Cheat Engine AITools、多种 CE MCP 桥接器以及 Android 内存修改器的源码调研表明，MCP 是有用的接入面，但不是能够沉淀跨平台能力的产品核心。真正需要复用的是实验规划、证据、配方和验证语义。

## 决策

1. 将平台无关的 `Game Reverse Agent Core` 设为产品核心。
2. Windows Cheat Engine 宿主是第一阶段唯一交付目标，继续使用 Lazarus/Free Pascal 并接入真实、经授权的单机离线进程。
3. CE 内置 AI 工作台是主要用户入口；MCP 是次级外部控制、诊断和实机测试接口。
4. Android 是第二阶段的独立宿主，共享版本化 Schema 和行为测试，不把 Kotlin、Rust 或 C++ 运行时嵌入 Pascal 主程序。
5. 已实现的 AgentOS 治理、事件存储、Schema 基础与 MCP 协议代码保留；MCP 不得绕过同一 Governance Gateway。
6. CT 只进入带来源和哈希的 RAG；永久禁止训练、微调和模型权重改写。

## 后果

- 新增 Experiment、Hypothesis、Observation、Candidate、Recipe 和 VerificationRun 领域契约。
- CE 与 Android 能力通过 Port 适配，领域层不依赖具体平台地址对象或 UI。
- 第一阶段先完成 Windows 端到端闭环，再冻结跨平台契约并启动 Android 原型。
- 旧 MCP 计划继续有效，但只作为新路线中的一个适配器工作包。
- GPL 或授权不明确的参考代码不得直接复制进产品核心。

## 不变边界

仅限用户授权的单机离线目标；拒绝多人/联网目标、反作弊绕过、隐藏、内核/DBK 和越权进程访问；所有写操作需要本机内容绑定审批、执行前复核和执行后验证。

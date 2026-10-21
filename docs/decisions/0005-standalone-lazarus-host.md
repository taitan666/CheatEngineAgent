# ADR 0005: 独立 Lazarus 宿主

- 状态：Accepted
- 日期：2026-09-14
- 决策者：用户明确纠正
- 取代：ADR 0004 中“嵌入 Cheat Engine 主程序”的宿主选择；其 Windows-first、领域核心与安全边界继续有效

## 决策

CheatEngineAgent 作为独立 Windows Lazarus/Free Pascal 应用交付，不修改、不注入也不启动上游 `cheatengine.exe`。应用拥有自己的主窗口、应用组合根、LLM 客户端、CT RAG、MCP 回环服务和 Win32 用户态进程能力后端。

Cheat Engine 7.5 仅作为架构与行为参考。可复用代码必须先完成许可证和依赖边界审查；产品运行时不依赖 CE 主窗口、全局 ProcessHandle、DBK、内核驱动或 CE 首次启动配置。

## 后果

- 权威入口为 `app/lazarus/cheat_engine_agent.lpr`。
- 构建产物为 `dist/CheatEngineAgent.exe`。
- Windows 能力实现位于 `src/platform/windows/`；核心和契约不依赖 CE 源码。
- 所有实机测试启动独立应用或受控 self-target，不启动原版 CE。
- 原来关于 CE 主程序组合、`TMemScan` 直接绑定和 CE 内嵌工作台的完成条件作废。

## 不变边界

仅限用户授权的单机离线目标；永久拒绝多人/联网修改、反作弊绕过、隐藏和内核/DBK；CT 仅用于带来源的 RAG；永不训练、微调或修改模型权重；写入仍须 受治理 Effect、本机审批、写前比较、读回与 Proof。

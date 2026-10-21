# Cheat Engine Agent MCP 接入设计

> 状态更新（2026-09-13）：本设计继续作为 MCP 适配器规范，但不再定义产品中心或总体实施顺序；这些由 `2026-09-13-game-reverse-agent-rebaseline.md` 管理。

日期：2026-09-12  
状态：已批准的从属 MCP 适配器设计  
适用范围：`cheat-engine-agnet` 第一阶段

## 1. 目标

在 Lazarus/Delphi Cheat Engine 主程序中内嵌 应用运行时与 Streamable HTTP MCP 服务，使本机 Codex 能在用户明确授权的单机游戏进程中调用进程枚举、附加、扫描、读取、反汇编、CT 知识检索以及经本机审批的受控修改能力。

本设计不依赖 Codex 插件。Codex 桌面端、CLI 或 IDE 扩展通过项目级 MCP 配置连接本机服务。插件仅作为未来可选的分发包装。

## 2. 永久边界

- 仅允许用户明确授权的单机、离线目标。
- 永久拒绝多人或联网目标、反作弊绕过、隐藏或规避检测、内核/DBK 能力、持久化以及越权进程访问。
- CT 内容只进入带来源与哈希的 RAG 知识库；永远不进行模型微调、训练或权重改写。
- 模型和 MCP 客户端只能提出操作请求，不能签发 Lease、批准自己的 Effect 或修改策略。
- 内存写入、冻结、调试状态变化、AutoAssembler 和 Lua 执行必须经过本机 UI 审批、执行前复核和执行后读回。
- `unknown` 执行结果不得转换为成功，不得盲目重试。

## 3. 接入方式

采用内嵌 Streamable HTTP MCP：

- 监听地址固定为 `127.0.0.1`，默认端口 `32176`。
- 不监听 `0.0.0.0`、局域网地址或公网地址。
- 每次主程序启动生成新的高熵会话令牌。
- 令牌保存在当前用户可读的运行时凭据文件中，不写入仓库或日志。
- Codex 使用 `http_headers_helper` 获取临时 `Authorization` 请求头。
- MCP 默认关闭，由用户在 Cheat Engine 设置中显式启用。
- 停止服务或紧急停止时撤销令牌并拒绝新请求。

Codex 官方支持本地 STDIO 与 Streamable HTTP MCP，并支持 bearer token、header helper、工具 allow/deny 和写工具审批模式：<https://developers.openai.com/codex/mcp/>。

## 4. 组件结构

```text
Codex
  | Streamable HTTP MCP / temporary bearer token
  v
MCP Transport
  v
Tool Registry + JSON Schema validation
  v
local governance gateway
  +-- Policy / Authority / Lease / Approval
  +-- Effect / Receipt / Proof
  `-- Audit Ledger
  v
Capability Dispatcher
  +-- CE Process Adapter
  +-- CE Memory and Scan Adapter
  +-- CT Parser + SQLite RAG
  `-- LLM Client
  v
Cheat Engine main thread and bounded workers
```

### 4.1 MCP Transport

负责 HTTP 生命周期、MCP initialize、instructions、工具枚举、工具调用、令牌验证、请求大小限制、超时、取消和 JSON-RPC 错误映射。它不拥有业务权限，也不得直接调用 Cheat Engine 全局对象。

服务器 `instructions` 的前 512 个字符必须完整声明：仅限授权的单机离线目标、写操作需要本机审批、客户端不能自批、禁止内核/DBK/反作弊绕过以及 CT 仅用于 RAG。

### 4.2 Tool Registry

为每个工具保存：

- 稳定工具 ID 与版本；
- 输入、输出 JSON Schema；
- `readOnlyHint`、`destructiveHint` 和幂等属性；
- 所需 Capability、风险等级、预算种类和超时；
- 对应的 application dispatcher 入口。

所有入参与出参均经过 Schema 校验。未知字段默认拒绝，地址使用无符号十六进制字符串，字节数组使用偶数长度十六进制字符串。

### 4.3 Governance Gateway

MCP 和内置聊天界面共用同一入口。网关完成目标分类、ProcessIdentity、PolicySnapshot、Lease、审批、预算、Epoch、幂等键和审计检查。任何适配器都不能从 MCP Transport 直接获得执行请求。

### 4.4 CE 调度

HTTP 工作线程不得直接访问 Lazarus 控件、`ProcessHandlerUnit`、`TMemScan`、符号处理器或调试器。请求进入线程安全命令队列，由 CE 主线程或明确拥有对象的受控工作线程执行，并通过 Future/事件对象返回结果。

长扫描必须异步运行并支持状态查询与取消。每个扫描任务绑定 Task、ProcessIdentity、Epoch、范围预算和最大结果数。

## 5. 第一阶段 MCP 工具

### 5.1 只读或无外部修改

- `cea.health`
- `cea.get_runtime_state`
- `cea.list_processes`
- `cea.attach_process`
- `cea.detach_process`
- `cea.read_memory`
- `cea.start_scan`
- `cea.refine_scan`
- `cea.get_scan_status`
- `cea.cancel_scan`
- `cea.disassemble`
- `cea.import_ct`
- `cea.search_ct`
- `cea.get_ct_entry`
- `cea.build_rag_context`
- `cea.get_effect_status`

附加进程虽然不写目标内存，仍要求用户授权声明、目标分类和有效 Lease。导入 CT 会修改本地知识库，但不会执行 CT 中的代码。

### 5.2 受控 Effect 请求

- `cea.request_memory_write`
- `cea.request_freeze`
- `cea.request_debug_action`
- `cea.request_script_execution`
- `cea.emergency_stop`

MCP 不暴露 `approve` 工具。Effect 只能由本机 Cheat Engine UI 产生内容绑定的批准决定。批准必须绑定目标身份、请求哈希、参数摘要、原始字节、策略快照、最大执行次数和过期时间。

### 5.3 玩家级能力（Phase 1 追加，2026-10-20）

Phase 1 的语义字段层同样只把「读」和「提案」交给 MCP；任何会改变目标内存或改变字段权威状态的动作仍然只能由本机操作者完成。共 23 个工具，registry 由 27 增至 50。

**只读执行**（真正落到运行时 API）

- `cea.list_game_fields` — 列出当前会话的语义字段及其 `access` / `validation_status`
- `cea.capture_field_value` — 从目标内存重读一个字段，返回精确 `bytes_hex`
- `cea.list_field_mappings` — 列出映射提案及其确认状态
- `cea.build_ui_render_json` — 生成副屏渲染模型
- `cea.enumerate_displays` — 枚举本机显示器
- `cea.list_events` — 列出事件时间线
- `cea.match_gcm_game` / `cea.search_gcm_games` — 查询本地 GCM 目录
- `cea.scan_gcm_cheat_files` — 列出 GCM 已下载的 CT
- `cea.list_published_cheat_files` — 列出已发布进不可变文件库的 CT

**会话生命周期**（状态管理，不写目标）

- `cea.start_game_session` — 绑定当前已附加进程身份
- `cea.end_game_session` — 结束会话，之后所有玩家级读取回到 `game_session_not_started`

**只提案 / 只申请**（一律返回 `rcApprovalRequired`，稳定码 `local_operator_approval_required`，`approval_surface: local_ui_only`）

- `cea.declare_field`、`cea.propose_ai_field_mapping`
- `cea.confirm_field_mapping`、`cea.reject_field_mapping`
- `cea.confirm_field_writable`、`cea.write_field_value`
- `cea.import_cheat_file`、`cea.publish_cheat_file`、`cea.translate_cheat_descriptions`

**不变量**：`cea.write_field_value` 不转发到 `TCEAStandaloneRuntime.WriteFieldValue`，因此 `TCEAFieldCommandBus`（唯一写适配器）对 MCP 完全不可达。测试以「目标内存字节未改变」断言此不变量，而不是只断言返回码。

### 5.4 多页面与自然语言定制（FR-025 / FR-026 / FR-033，2026-10-20）

1D 增强把页面从「即时生成」扩展为「可存、可切、可回退」，registry 由 50 增至 61。

**只读执行**

- `cea.list_ui_pages` — 列出已保存页面
- `cea.get_ui_page` — 取单个页面及其 schema JSON
- `cea.get_active_ui_page` — 取当前活动页
- `cea.list_ui_schema_versions` — 列某个 schema 的全部历史版本

**只申请**（一律 `rcApprovalRequired` + `local_ui_only`）

- `cea.save_ui_page`、`cea.set_active_ui_page`、`cea.restore_ui_schema_version`
- `cea.set_secondary_screen_page`（改变副屏呈现）
- `cea.propose_ui_customization`（会把字段清单发往模型）
- `cea.confirm_ui_customization`、`cea.reject_ui_customization`（确认即落盘）

**两条不变量**：

1. **版本回退只换布局，不换数值**：页面存的是 schema JSON 而非状态模型快照，字段值永远来自实时状态模型，回退旧版本绝不会把旧数值写回游戏。
2. **模型产物必须本地确认才落盘**：`ProposeUiCustomization` 只把提案放在内存（`FUiProposalIds`/`FUiProposalSchemas`），`ConfirmUiCustomization` 只接受 `proposal_id` + 目标 `page_id` + `title`，schema 由运行时从内存提案表取——调用方无法伪造已确认内容。

### 5.5 指针链字段（真实游戏定位，2026-10-20）

Unity IL2CPP 与 .NET 游戏每次重启都会重新分配托管堆，绝对地址必然失效。CE 的解法是「模块基址 + 偏移 + 多级指针」，registry 由 61 增至 63。

**只读执行**

- `cea.resolve_field_address` — 对已声明的链字段重新求值，返回当前绝对地址

**只申请**（`rcApprovalRequired` + `local_ui_only`）

- `cea.declare_pointer_field` — 声明一个链字段（改变状态模型）

**三条不变量**：

1. **求值器在类型层面就不可能写入**：`ICEAPointerMemoryReader` 只有 `ReadPointerBytes` 一个方法；`TCEAWin32PointerReader` 只请求 `PROCESS_QUERY_INFORMATION or PROCESS_VM_READ`，且每次读完立即 `CloseHandle`。验收脚本（`tests/acceptance/verify-scaffold.ps1`、`tools/schema-check/check-schemas.ps1`）对此有硬断言：指针读取器文本中不得出现任何写权限常量。
2. **写前与采前一律重解析**：`ConfirmFieldWritable` / `CaptureFieldValue` / `WriteFieldValue` 三个路径都先调 `ResolvePointerFieldAddress`。写到一个陈旧地址不只是失败，而会破坏无关数值。
3. **链解析失败即失败，不降级**：短读、空指针、读取失败一律返回 `rcVerificationFailed`，绝不返回部分字节或用旧地址顶替——否则会用缺失字节拼出假指针。

## 6. 写操作状态流

```text
MCP request
  -> authenticate and validate schema
  -> resolve exact ProcessIdentity and PolicySnapshot
  -> create planned Effect
  -> display full change in Cheat Engine UI
  -> local user approves or rejects
  -> revalidate Epoch, identity, Lease and original bytes
  -> mark executing and persist outbox record
  -> execute once
  -> read back target state
  -> record Receipt and Proof
  -> applied | rejected | unknown
```

批准不是对工具类别的永久授权。默认批准只允许一次精确操作；冻结等持续操作使用短期、可撤销、范围受限的 Lease。

## 7. 进程身份与目标准入

`ProcessIdentity` 至少绑定：

- PID；
- 进程启动时间；
- 规范化可执行路径摘要；
- 可执行文件 SHA-256；
- 体系结构；
- 模块集合摘要；
- 当前 CE Epoch；
- 目标分类。

每次外部调用都复核身份。PID 重用、程序重启、模块集合发生策略相关变化或 CE 重新附加时提升 Epoch，并拒绝旧 Lease、扫描任务和 Effect。

单机离线分类不能仅依赖进程名称。第一阶段要求用户在本机 UI 中明确选择并声明目标，策略还会拒绝已知反作弊组件、网络多人客户端和系统敏感进程。

## 8. CT RAG

CT 导入流程：

1. 读取本地文件或已下载的受信任临时制品；
2. 计算 SHA-256、记录来源 URI、文件时间、大小和许可证元数据；
3. 安全解析 XML，禁止外部实体和隐式代码执行；
4. 提取游戏名、版本、模块、地址表达式、指针链、AOB、AutoAssembler、Lua、层级和功能描述；
5. 对脚本进行静态能力标注，不执行脚本；
6. 按内容哈希去重并原子发布 SQLite 索引版本；
7. 混合检索返回内容片段、结构字段、来源、哈希和匹配理由；
8. RAG 上下文只作为证据，不获得执行权限。

## 9. LLM 客户端

LLM 客户端位于 Lazarus/Delphi 主程序内，使用 OpenAI-compatible provider 接口。密钥只通过 Windows Credential Manager 等 Secret Store 引用解析，不写入配置、日志、MCP 输出或 CT 索引。

模型输入经过披露清单和预算检查；模型输出必须满足结构化 Schema。模型仅生成解释、检索查询和 `ToolProposal`。系统永久不实现训练、微调、梯度更新、LoRA 合并或任何模型权重写入路径。

## 10. 稳定错误模型

工具结果使用稳定错误代码，并提供可审计但不泄露秘密的详情：

- `invalid_argument`
- `unauthenticated`
- `unauthorized`
- `approval_required`
- `policy_denied`
- `target_not_offline`
- `stale_process_identity`
- `lease_expired`
- `budget_exceeded`
- `scan_running`
- `ambiguous_match`
- `verification_failed`
- `cancelled`
- `timeout`
- `unknown_outcome`
- `internal_error`

协议错误与业务拒绝分开：无效 JSON-RPC/MCP 请求返回协议错误；合法调用的策略拒绝返回结构化工具结果。

## 11. Codex 项目配置

项目级 `.codex/config.toml` 使用受信任项目配置：

```toml
[mcp_servers.cheat_engine_agent]
url = "http://127.0.0.1:32176/mcp"
http_headers_helper = "<absolute-path-to-credential-helper>"
default_tools_approval_mode = "writes"
startup_timeout_sec = 10
tool_timeout_sec = 60
enabled = true
```

配置不包含令牌。凭据辅助程序只读取当前用户、当前 CE 实例的短期令牌，并输出请求头 JSON。首次添加或修改 MCP 服务后需重启 Codex 桌面端；通过 `/mcp` 检查连接。

## 12. 实机验证

### 12.1 重启前验证

1. 编译全部 Pascal 单元和主程序集成点。
2. 对 MCP initialize、tools/list、tools/call、鉴权、限流、取消和 Schema 进行协议测试。
3. 使用仅操作自身分配缓冲区的测试目标进程，验证枚举、附加、扫描、读取、审批、写入和读回。
4. 使用无害 CT fixture 验证解析、去重、来源记录、静态脚本标注和检索。
5. 验证无审批写入、错误令牌、过期 Lease、PID 重用和禁止目标全部被拒绝。

### 12.2 Codex 重启后验证

1. 启动启用了 MCP 的 Cheat Engine。
2. 安装项目级配置并重启 Codex 桌面端。
3. 通过 MCP 调用 `cea.health` 和只读工具完成连接测试。
4. 由用户在 Cheat Engine 中选择并声明一个明确授权的单机离线进程。
5. 先执行只读扫描，再创建一个最小受控写 Effect。
6. 用户在本机 UI 审批后执行一次写入并验证读回与审计记录。
7. 执行紧急停止，确认新 Effect、Lease 和令牌均被撤销。

## 13. 非目标

- 不提供远程网络控制或多用户服务。
- 不提供无界任意地址批量写入。
- 不自动批准 CT、Lua、AutoAssembler 或模型建议。
- 不在第一阶段实现插件市场分发。
- 不实现在线多人游戏修改、反作弊规避、内核驱动控制或隐藏行为。
- 不实现模型训练、微调或权重改写。

## 14. 完成定义

第一阶段完成需要同时满足：

- 内嵌 MCP 服务通过协议与鉴权测试；
- 本地治理流程不能被 MCP 或 UI 绕过；
- CT RAG 可导入、检索并返回来源与哈希；
- 自测试目标完成读、扫描、审批写和读回；
- Codex 重启后能实际调用只读工具；
- 用户明确授权的单机进程完成一次受控实机验证；
- 所有禁止路径和失败恢复场景均有自动化测试；
- 项目中不存在模型训练或权重修改入口。

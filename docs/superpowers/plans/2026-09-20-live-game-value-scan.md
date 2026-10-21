# 单机游戏数值扫描补强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在玩家明确授权的单机离线进程中，完成有界、多区域、按类型与对齐规则执行的只读数值扫描和复筛；部分覆盖绝不报告为“未找到”。

**Architecture:** 现有 `process_attach` 和 ProcessIdentity/Epoch 门禁保持不变。新增值编码与区域规划两个独立单元；Win32 扫描后端按已授权 `ScanScope` 对已提交、可读区域分段执行，扫描会话持有候选、覆盖率和取消状态。原生 UI 建立作用域并展示覆盖缺口；MCP 只能在已建立的作用域内启动或复筛，不能扩大范围、赋予写权限或直接批准 Effect。

**Tech Stack:** Free Pascal 3.2.2、Lazarus Win64、`VirtualQueryEx`/`ReadProcessMemory`、现有 SQLite/local governance services 与 loopback MCP。

**Spec:** `docs/superpowers/specs/2026-09-13-game-companion-rebaseline.md` §4.1、§7、§9；`schemas/ce-domain/scan.schema.json`。扫描范围、预算、取消与验证要求由本项目自身的安全边界定义。

## 已观察的失败与成功边界

- `Probably Stolen Demo` 的只读 MCP 附加/断开成功，游戏未被写入。
- 767 的四字节 AOB 在一个 64 MiB 范围内碰到 2,000 结果上限；返回值没有覆盖率/截断字段。按 758 复筛为 0。另一个 48 MiB 范围内 758 有 44 个候选，按 880 复筛也为 0。这些只证明所扫描的候选未跟随数值变化，不能证明整个进程没有信用点地址。
- 生产后端只接受 `scan_kind=aob`，虽然 Schema 声明 `scan_kind=value`；运行时要求恰好一个调用者指定的范围。原生工作台没有数值扫描控件；当前 Codex 任务未加载原生 `cheat_engine_agent` 工具，尽管本机 HTTP MCP 直接调用正常。

## Global Constraints

- 仅限玩家授权的单机离线进程；本计划只改只读扫描，不触碰真实游戏写入、AA/Lua、反作弊、多人与内核能力。
- 不在启动、模型请求或 MCP 连接时自动全进程扫描；区域类别、总字节、时长和结果数由本机玩家确认，MCP 不创建或扩大范围。
- 默认只扫描 `MEM_COMMIT`、可读、非 `PAGE_GUARD` 的私有区域；`MEM_IMAGE`/`MEM_MAPPED` 需单独显示并选择。不可读/变化的区域记为遗漏，不能以零结果冒充完全覆盖。
- 任一结果绑定 PID、进程启动时间、可执行文件哈希、ProcessIdentity、Epoch、值类型、字节序、对齐、范围计划与观察时间。地址不是可复用配方，候选不授予写权限。
- 总扫描预算上限初版为 512 MiB、30 秒、10,000 个候选、4,096 个区域；每次 Win32 读取不超过 1 MiB。达到任何上限即返回 `complete=false` 与稳定原因码。运行时可进一步降低预算，不能隐式提高。
- 原有 AOB 调用保持兼容；`scan_kind=value` 只公布已实现且通过测试的类型。任何未知类型、NaN/Infinity 或超出范围的值必须拒绝。
- 本项目目录不是 Git 仓库；记录测试与偏差于 `docs/delivery/verification-report.md`，不虚构 commit。

## Review Focus

1. 结果数达到上限时返回 `result_limit` 和未覆盖字节数，不能返回完整成功；Task 2/3 测试。
2. 跨不可读页、保护变化、进程退出或 Epoch 改变时保留已观察候选但标记 partial/stale，复筛不得混入新进程；Task 2/3 测试。
3. 对齐的 `dword` 扫描找出 767→758→880 的同一哨兵，而不把非对齐字节序列当作整数；Task 1/3 测试。
4. MCP 不能创建扫描作用域、提高预算或把候选升级为写 Effect；Task 4 测试。
5. 取消必须在分段边界及时生效，不阻塞 UI 30 秒，也不把未扫描区域显示为“零匹配”；Task 3/4 测试。

## 文件职责图

- `src/domain/ce/cea_value_scan_types.pas`：`value` 编码、对齐和 `TCEAScanCoverage`，不引用 Win32。
- `src/platform/windows/cea_win32_memory_regions.pas`：只读 `VirtualQueryEx` 区域快照和确定性排序。
- `src/platform/windows/cea_win32_readonly_backend.pas`：按计划分段扫描与复筛，不承担授权决策。
- `src/platform/ce/cea_ce_scan_capability.pas`：ProcessIdentity/Epoch、作用域、预算、取消和状态门禁。
- `integration/cheat-engine/ce_agent_registration.pas`：解析多区域的类型化请求，不信任模型自报覆盖率。
- `src/app/cea_application_runtime.pas`：本机作用域创建/撤销与 MCP 只读查询组合。
- `app/lazarus/cea_main_form.pas`：可见的数值扫描控件、覆盖状态和取消入口。
- `schemas/ce-domain/scan.schema.json`、`src/mcp/cea_mcp_registry.pas`：与真实支持的调用参数和返回投影一致。
- `tests/pascal/test_value_scan.pas`、`test_win32_memory_regions.pas`、`test_ce_scan_capability.pas`、`tests/integration/test-live-mcp-app.ps1`：能力与失败路径验收。

### Task 1: 类型化整数扫描契约与对齐

**Files:** Create `src/domain/ce/cea_value_scan_types.pas`, `tests/pascal/test_value_scan.pas`; modify `schemas/ce-domain/scan.schema.json`, `build/unit-manifest.txt`, `tests/pascal/compile_smoke.pas`.

**Interfaces:** `EncodeExactValue(const AValueType, AText: string; out ABytes: TBytes; out AAlignment: Cardinal): TCEAResult`；`TCEAScanCoverage` 包含 `RequestedBytes`、`InspectedBytes`、`SkippedBytes`、`Complete`、`PartialReason`。第一批支持 `byte/word/dword/qword/single/double`；`aob` 仍按原始字节逐地址匹配。

- [x] **Step 1: 写失败测试。** `dword 767` 必须编码为 `FF 02 00 00` 且对齐 4；`758` 为 `F6 02 00 00`，`880` 为 `70 03 00 00`；负数、边界值、浮点端序、无效格式和溢出分别断言。`IsValueAligned` 单测区分对齐整数与逐字节 AOB；实际扫描过滤留在 Task 3。
- [x] **Step 2: 跑 RED。** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_value_scan.pas`；先因缺少新单元失败，新增对齐测试时又因缺少函数失败。
- [x] **Step 3: 最小实现。** 使用 `TryStrToInt64`/`TryStrToQWord` 与显式小端编码；浮点仅接受有限值并按位复制 IEEE-754；`AAlignment` 与类型宽度一致。Schema 删除尚未实现的字符串/bytes 类型声明，不把数值直接拼入 AOB 字符串。
- [x] **Step 4: 跑 GREEN。** 新测试、`test_ce_scan_capability.pas`、Schema 检查和 compile smoke 均通过；旧 AOB 自测向后兼容。全量回归另有 4 个存档测试因独立应用固定 MCP 端口被当前运行实例占用而失败，见交付报告；Task 1 局部通过不代表全量通过。

### Task 2: 只读区域快照与授权扫描作用域

**2026-09-21 进度：部分实现。** 已有 `VirtualQueryEx` 私有/映像/映射可读区域元数据过滤、不可读/Guard 页测试、精确范围或最多 128 个升序不重叠范围、身份/Epoch 绑定的本机会话 scope，以及无 scope 的 MCP 拒绝；活动扫描不能被新 scope 覆盖。原生工作台的进程级选择默认仅 `private`，`image`/`mapped` 必须显式选择，字节/区域截断保留 partial 原因。真实子进程 fixture 现在可在保持同一 PID、启动时间和 EXE 的情况下加载测试 DLL；生产模块集哈希变化会推进 Epoch，并使旧身份读取被 `rcStaleProcessIdentity` 拒绝。真实游戏退出/重启仍需人工验收；以下步骤不标记为全部完成。

**Files:** Create `src/platform/windows/cea_win32_memory_regions.pas`, `tests/pascal/test_win32_memory_regions.pas`; modify `src/platform/ce/cea_ce_scan_capability.pas`, `tests/pascal/test_ce_scan_capability.pas`.

**Interfaces:** `EnumerateReadableRegions(const APid: Cardinal; const AIdentity: TCEProcessIdentity; const AMaxRegions: Cardinal; out ARegions: TCEAMemoryRegionArray; out ACoverage: TCEAScanCoverage): TCEAResult`；应用运行时暴露仅本机 UI 可达的 `AuthorizeScanScope(const AIdentity: TCEProcessIdentity; const ARegionKinds: TCEAMemoryRegionKinds; const ABudget: TCEAScanBudget; out AScopeId: string): TCEAResult`。作用域绑定精确身份/Epoch，可撤销；MCP `start_scan` 仅引用作用域 ID，不能调用授权方法。

- [ ] **Step 1: 写失败测试。** 自进程构造已提交可读页、`PAGE_NOACCESS`、`PAGE_GUARD` 和跨页区域；验证确定性地址排序、遗漏原因、区域上限、PID 重启/模块哈希变化与旧 Epoch 拒绝。没有本机作用域时 MCP 请求必须拒绝。
- [ ] **Step 2: 跑 RED。** 运行 `test_win32_memory_regions.pas` 与 `test_ce_scan_capability.pas`；预期缺少区域端口/作用域门禁。
- [ ] **Step 3: 最小实现。** 对已附加的查询权限句柄调用 `VirtualQueryEx`，只产出元数据，不读正文；取区域交集前检查地址回绕与累计预算。作用域仅存在当前会话，撤销后拒绝新 scan/refine，清除候选；已发生的读取按真实结果记账。
- [ ] **Step 4: 跑 GREEN。** 通过两个聚焦测试与现有跨进程自测试；无越界读取、无 MCP 自动建作用域。

### Task 3: 有界多区域扫描、覆盖率与异步取消

**2026-09-21 进度：部分实现。** 一个本机确认的范围内可跨多个可读区域执行后台数值扫描/复筛，并返回运行状态、覆盖率及 partial 原因；真正多范围请求已贯通 Schema、运行时路由、作用域精确匹配和生产 Win32 后端。真实双独立分配夹具证明两个不连续页只被扫描一次，重叠范围在授权前拒绝。跨不可读页的 767 测试已通过，复筛时不可读的候选保留为 unresolved，状态可查询，重复取消幂等。同一进程断开再附加会清除旧候选，即使身份签名未变。生产扫描现由拥有明确生命周期的工作线程运行，UI/MCP 轮询不可变状态投影；运行中取消在分段/匹配检查点生效。512 MiB、30 秒、10,000 结果、4,096 区域以及单次 1 MiB 读取均有硬上限，区域上限和取消有真实 Win32 夹具覆盖。独立性能程序在 30 秒配置上限下完整检查 512 MiB，最新耗时 5,188 ms；同一生产路径以 1 ms 截止时间在 31 ms 返回 `time_limit` 并只检查 2,097,146 字节。游戏进程退出/重启的人工验收仍缺。

**Files:** Modify `src/platform/windows/cea_win32_readonly_backend.pas`, `src/platform/ce/cea_ce_scan_capability.pas`, `integration/cheat-engine/ce_agent_registration.pas`; create `tests/pascal/test_multi_region_value_scan.pas`.

**Interfaces:** `StartScan` 返回 `scan_id/state/coverage`；`GetStatus` 返回累计区域、字节、候选数与 `complete/partial_reason`；`RefineScan` 只在同一身份/Epoch 与现有候选集合上按新值比对。`CancelScan` 幂等释放活动扫描会话。扫描器按不超过 1 MiB 的可读分段工作，候选地址对 `value` 类型按宽度对齐。

- [ ] **Step 1: 写失败测试。** 两个可读区域分别放入 32 位 `767`，其中一个变为 `758` 再变为 `880`；每次复筛只保留正确地址。测试 10,000 结果、512 MiB、30 秒和 4,096 区域预算的 partial 原因；跳过不可读页、取消、游戏退出和重附加不混用旧候选。
- [x] **Step 2: 跑 RED。** `test_multi_region_value_scan.pas` 首次运行在“生产 first scan 立即返回 running”断言处失败；旧后端同步阻塞。
- [x] **Step 3: 最小实现。** 区域快照固定后由拥有生命周期的工作线程顺序读取；每个分段前与内部匹配循环定期检查取消/时长/结果预算。UI 主线程通过 timer 轮询不可变状态投影；达到结果、时间、区域或取消边界均保留 partial 语义。进程级多范围规划仍属于 Task 2/4 未完成项。
- [x] **Step 4: 跑 GREEN。** 新测试、`test_ce_scan_capability.pas`、`test_ce_readonly_integration.pas`、线程队列测试与 43/43 全套回归通过；后台 worker + timer 路径编译并通过运行时状态轮询测试。原生点击体验仍归 Task 4 人工验收。

### Task 4: 原生工作台与 MCP 可操作验收

**2026-09-21 进度：部分实现。** 原生进程页已有范围、类型、值、预算、确认、复筛与会话结束控件，另有进程级 `private`/`image`/`mapped` 类型选择和独立的 MCP 范围授权/撤销按钮；扫描改为后台执行，原生 timer 显示 running/ready/partial，复筛只在 ready 后启用。UI/运行时上限为 512 MiB/10,000 结果，后端另固定 30 秒/4,096 区域；进程规划最多输出 128 个精确范围。MCP 扫描工具有具体多范围参数 Schema，自进程 runtime 测试覆盖撤销、超预算/陈旧 Epoch拒绝及 MCP start/status/refine/cancel。512 MiB 性能验收已通过；插件包已安装且直接 HTTP `cea.health` 通过。独立 EXE 已构建，但 UI 点击、重启后新任务的 Codex 原生 MCP 工具调用和真实游戏端到端数值扫描尚未验收。

**Files:** Modify `app/lazarus/cea_main_form.pas`, `src/app/cea_application_runtime.pas`, `src/mcp/cea_mcp_registry.pas`, `tests/integration/test-live-mcp-app.ps1`, `README.md`.

**Interfaces:** 本机界面提供明确的目标/区域类型/数值类型/预算选择、开始/复筛/取消按钮和覆盖率说明；MCP 工具仅能对该本机授权的 scope 执行只读 scan/refine/status/cancel。没有授权、过期 Epoch 或 partial 结果不能生成“已找到信用点”的验证结论。

- [ ] **Step 1: 写失败集成测试。** 启动独立 EXE 后，在本机 UI/测试宿主建立授权 scope，再经 MCP 完成 `list_processes→attach→value scan→refine→cancel→detach`；无 scope、超预算与陈旧身份均返回稳定拒绝码。新任务的 Codex 原生工具目录中实际出现 `cea.health` 并能调用；不能仅以原始 HTTP 握手代替。
- [ ] **Step 2: 跑 RED。** 运行 `test-live-mcp-app.ps1` 的新断言及原生 UI 状态测试；预期现有应用缺少作用域/数值控件，当前 Codex 原生工具目录仍不可用。
- [ ] **Step 3: 最小实现。** UI 在扫描前显示“只读、单机、所选区域和预算”；服务断开时提供重连状态；工具 Schema 明确参数而非 `additionalProperties=true` 的空泛对象。构建/启动顺序与 Codex MCP 配置在 README 中写明，不保存 bearer 明文，不把自动启动解释成自动扫描。
- [ ] **Step 4: 跑 GREEN。** Pascal 全套、Schema/acceptance/compile-smoke、独立构建/自检、MCP HTTP 和 Codex 原生工具调用均通过；原生 UI 点击验收记录为实际通过或明确未验证。

### Task 5: 人工单机验收与发布边界

**Files:** Modify `docs/delivery/verification-report.md`, `docs/superpowers/plans/2026-09-13-game-companion-roadmap.md`.

**Interfaces:** 人工验收只使用玩家当前授权的单机游戏；记录游戏/版本、目标数值、三次人工变化、候选缩减、覆盖率、只读复核与失败情况，不在仓库持久化个人存档或固定运行时地址。

- [x] **Step 1: 写验收记录模板。** `docs/delivery/gate-4a-manual-acceptance-template.md` 包含 `game_version/process_identity/scan_scope/value_type/coverage/initial_count/refine_counts/operator_observed_values/readback_result`，不含 API 密钥、完整个人路径和内存正文。
- [x] **Step 2: 在安全自测目标先通过三次变化。** 私有自进程页已通过 767→758→880 的同一候选复筛，覆盖率明确；取消后不可复筛，detach/reattach 的 attachment serial 会丢弃旧候选，即使稳定身份签名未变化。
- [ ] **Step 3: 在用户再次明确授权且游戏版本未变化时做真实只读测试。** 若无法覆盖目标区域、候选不唯一或数值类型不明，记录 inconclusive；不以猜测地址触发写入。
- [ ] **Step 4: 更新交付报告。** 逐项记录自动化和人工结果；本计划不解除存档写入 Gate 9 或 Windows 公开发布门禁。

## Execution Handoff

本计划已开始分段实施，当前进度与验证边界记录在 `docs/delivery/verification-report.md`。本项目没有 Git 仓库，沿现有目录工作并在交付账本记录 RED/GREEN 与回归结果；未勾选的整步验收仍待完成。

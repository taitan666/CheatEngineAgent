# 存档导入与按需发现 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在独立 Windows 应用中提供玩家授权范围内的候选存档发现、选择和撤销，绝不让 AI 自动全盘扫描或把候选当作写权限。

**Architecture:** `SaveDiscoveryService` 管理会话作用域、预算与候选，Win32 端口只枚举元数据；现有 `InspectSaveFile` 是候选进入存档工作台的唯一正文读取入口。UI 建立与撤销范围，MCP 不创建范围。

**Tech Stack:** Free Pascal 3.2.2、Lazarus Win64、Windows 文件 API、现有 AgentOS runtime、Pascal/PowerShell 测试。

**Spec:** `docs/superpowers/specs/2026-09-20-save-discovery-design.md`

## Global Constraints

- 无启动时扫描、无全盘扫描、无 AI/MCP 新建或扩大作用域；仅玩家本机操作授权。
- 未选择具体文件前只获取文件名、相对路径、长度、修改时间等元数据；不读取正文、不计算正文哈希、不触发云文件下载。
- 不跟随重解析目录/符号链接，不遍历网络共享；文件数、深度、时长与取消均有界。
- 候选不是 `SaveTarget`/`SaveSnapshot`/Effect；选中后仍需本机授权与现有 `InspectSaveFile` 复核。
- 撤销停止发现、清除候选及所选目标，并阻止该作用域产生新 Effect；不删除已产生的备份/账本。
- 项目目录不是 Git 仓库；用 `docs/delivery/2026-09-20-implementation-progress.md` 记录测试/偏差，不虚构 commit。

## Review Focus

1. 授权根目录中的目录联接跳到根外时，枚举必须报告拒绝并不读取目标；任务 1 测试。
2. 扫描达到文件数/深度/时间预算或取消时，结果标记为部分覆盖而不是“未找到”；任务 1 测试。
3. MCP/LLM 调用在没有玩家操作时不能触发磁盘扫描或扩大范围；任务 2 测试。
4. 同名存档移动/修改后，候选选择必须重新经现有 reader 验证；任务 2 测试。
5. 玩家撤销范围后，待审批写 Effect 不能再基于该范围执行；任务 2/3 测试。

## 文件职责图

- `src/domain/save/cea_save_discovery_types.pas`：作用域/候选/预算和状态类型。
- `src/core/save/cea_save_discovery_service.pas`：授权、扫描、撤销、选择与脱敏投影。
- `src/platform/windows/cea_win32_save_discovery.pas`：仅元数据枚举和 Known Folder 建议。
- `src/app/cea_application_runtime.pas`：与现有只读检查及 Effect 门禁组装。
- `app/lazarus/cea_main_form.pas`：导入目录、建议位置、候选列表、取消和检查。
- `tests/pascal/test_save_discovery.pas`、`test_standalone_app_runtime.pas`：真实临时目录及权限边界。

### Task 1: 有界本机候选枚举

**Files:** Create `src/domain/save/cea_save_discovery_types.pas`, `src/core/save/cea_save_discovery_service.pas`, `src/platform/windows/cea_win32_save_discovery.pas`, `tests/pascal/test_save_discovery.pas`; modify `build/unit-manifest.txt`, Pascal search paths and `app/lazarus/cheat_engine_agent.lpi`.

**Interfaces:** `TCEASaveDiscoveryService.AuthorizeDirectory(const ARoot: string; const ABudget: TCEADiscoveryBudget; out AScope: TCEADiscoveryScope): TCEAResult`; `Scan(const AScopeId: string; out ACandidates: TCEASaveCandidateArray): TCEAResult`; `Cancel(const AScopeId: string): TCEAResult`; `Revoke(const AScopeId: string): TCEAResult`. Candidate carries opaque ID, scope ID, relative name, size/time, source `user_directory`, and inspection-required status; no bytes or authority.

- [x] **Step 1: Write failing tests.** Use a private temporary tree with one `.sav`, nested `.dat`, symlink/junction to outside, and a budget of one result; assert no constructor scan, exact scope, partial coverage on budget, no outside candidate, and cancellation. A scope with drive root, UNC or missing directory fails.
- [x] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_discovery.pas`; missing discovery units was observed.
- [x] **Step 3: Implement.** Metadata-only Win32 enumeration, fixed-local-drive scope, reparse/cloud refusal, file/depth/time limits, cancellation, partial-result reason and stable file identity are in place. Win32 enumeration uses `FindFirstFileW`, so a junction is observed and explicitly reported as skipped instead of being silently hidden by the RTL attribute filter.
- [x] **Step 4: Run GREEN and scope regression.** The real temporary junction-to-outside fixture, candidate replacement check, snapshot regressions and compile smoke pass; the outside target is never enumerated and coverage is partial with `skipped_reparse_or_cloud`.

### Task 2: Runtime selection and revocation authority

**Files:** Modify `src/app/cea_application_runtime.pas`, `src/core/save/cea_save_discovery_service.pas`, `tests/pascal/test_standalone_app_runtime.pas`, `tests/pascal/test_save_discovery.pas`.

**Interfaces:** `AuthorizeSaveDirectory/ScanSaveDirectory/SelectSaveCandidate/RevokeSaveDirectory` are local UI methods. `SelectSaveCandidate` calls existing `InspectSaveFile` after scope and file identity recheck. A runtime `CheckSaveDiscoveryAuthority` denies new/approved save Effects from a revoked scope. Existing direct single-file selection remains supported.

- [x] **Step 1: Write failing tests.** Selecting a candidate after replacement yields conflict; revoking clears selection and makes a planned backup/edition from that scope non-executable; MCP cannot create a scan scope or expose `cea.scan_save_directory`.
- [x] **Step 2: Run RED.** Candidate replacement, revoked Effect and application-stop authority tests were observed failing before their runtime fixes.
- [x] **Step 3: Implement.** Candidate-to-scope and Effect-to-scope bindings remain memory-only; Stop/Revoke durably reject pending discovered Effects before clearing bindings. Selection reopens metadata and then uses the existing snapshot reader/hash path. Direct single-file selection remains supported.
- [x] **Step 4: Run GREEN.** Replacement, planned backup, planned edit, session-stop rejection and direct-file regressions pass together with save edit/recovery and governance tests.

### Task 3: Windows 工作台 UX 与交付核验

**Files:** Modify `app/lazarus/cea_main_form.pas`, `README.md`, `docs/delivery/verification-report.md`; test `test_standalone_app_runtime.pas`, `tests/integration/test-live-mcp-app.ps1`.

**Interfaces:** UI has explicit file import, folder authorization, suggested roots, candidate list, cancel/revoke and inspect. Candidate rows are read-only and keep backup/edit/restore disabled until a verified snapshot exists. Suggested roots are only displayed until individually checked by the player.

- [x] **Step 1: Write failing runtime/UI-state assertions.** Runtime tests prove stale/revoked candidates cannot become a verified snapshot or Effect and that startup/MCP do not expose directory scanning; write controls remain disabled until `PresentSaveSnapshot` receives a verified snapshot.
- [x] **Step 2: Run RED.** The new candidate identity, revocation and session-stop assertions failed before implementation.
- [x] **Step 3: Implement UI and bounded background scan.** The native tab now has explicit directory authorization, suggested locations, metadata candidate list, background worker, cancel/revoke and candidate inspection. Partial reason is shown; MCP/log projections do not receive the absolute root.
- [x] **Step 4: Verify.** 40/40 non-parameterized Pascal tests, parameterized child integration, Schema (47/75), scaffold, compile smoke, standalone build/self-test, release acceptance and live MCP HTTP (26 tools) pass. The desktop-control surface exposed no native windows, so visual/click acceptance is explicitly unverified; no real-game compatibility or Gate 9 claim is made.

# Windows 发布安全与 Defender 预案 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让内部构建具备可核验产物清单和安全诊断，并建立不会关闭 Defender 或伪装成正式发布的发布门禁。

**Architecture:** 构建后 PowerShell 生成包含所有分发文件 SHA-256、签名状态和测试证据的内部清单；独立校验脚本拒绝缺失、篡改或不满足正式发布条件的文件。Lazarus 关于页仅显示本机哈希/签名和官方处理说明，不调用 Defender 配置 API。

**Tech Stack:** Lazarus/Free Pascal 3.2.2、PowerShell、Authenticode、SHA-256、现有 Windows build/integration scripts。

**Spec:** `docs/superpowers/specs/2026-09-20-windows-release-safety-design.md`

## Global Constraints

- 当前仅制作内部测试构建；不购买证书、签名、不发布、不上传样本，也不修改系统 Defender 配置。
- Antivirus 检测与 SmartScreen 信誉提示独立记录；签名、扫描或清单通过都不解除 `verification-report.md` 的存档写入与人工验收阻断。
- 不能要求用户关闭防护、自动恢复隔离文件、添加广泛排除项，不能把混淆/打包当作解决办法。
- 诊断输出不包含存档正文、CT 内容、绝对用户路径、Credential Manager 秘密或 MCP bearer。
- 当前目录无 Git 仓库，验证记录代替不存在的 commit。

## Review Focus

1. 构建后 DLL/EXE 被修改，校验必须失败，不能仅验证主 EXE；任务 1 测试。
2. 内部未签名包不能误标为正式可发布；任务 1 测试。
3. 清单不得收集当前用户路径、密钥或游戏文件；任务 1/2 测试。
4. SmartScreen“未识别应用”不能被解释为 Defender Antivirus 误报；任务 2 测试。
5. 当前存档写入安全阻断项不能被签名或扫描通过覆盖；任务 3 测试。

## 文件职责图

- `tools/release/new-release-manifest.ps1`：从明确的 `dist` 文件集生成内部清单与哈希。
- `tools/release/test-release-manifest.ps1`：独立复核文件、签名状态和发布门禁。
- `tests/acceptance/test-release-manifest.ps1`：临时夹具的篡改、缺文件、内部/正式模式测试。
- `src/infrastructure/windows/cea_release_identity.pas`：运行中 EXE 哈希和签名状态的只读投影。
- `app/lazarus/cea_main_form.pas`：关于/安全说明，不接触 Defender 配置。
- `docs/delivery/windows-release-playbook.md`：不同告警的操作步骤、人工验收与阻断项。

### Task 1: 内部清单与可执行校验

**Files:** Create `tools/release/new-release-manifest.ps1`, `tools/release/test-release-manifest.ps1`, `tests/acceptance/test-release-manifest.ps1`; modify `build/build-standalone-app.ps1`, `README.md`.

**Interfaces:** Generator accepts explicit `-DistDirectory`, `-ManifestPath`, `-Version`, `-Channel internal`; emits only relative filenames, SHA-256, length and Authenticode status. Verifier accepts `-DistDirectory`, `-ManifestPath`, `-Mode internal|public`; internal permits unsigned with clear non-publishable result, public requires valid signatures, complete files, externally recorded security/acceptance evidence and no open blockers.

- [x] **Step 1: Write failing acceptance test.** The temporary EXE/DLL fixture covers relative names, changed DLL, deleted EXE, path traversal and unsigned public denial.
- [x] **Step 2: Run RED.** The first acceptance run failed on the absent generator.
- [x] **Step 3: Implement minimal scripts.** Build creates an internal-only EXE/DLL manifest and the independent verifier checks exact file set, size, hash and signature status.
- [x] **Step 4: Run GREEN.** Acceptance, standalone build and independent verifier against `dist` passed; no Defender settings were changed.

### Task 2: 只读安全诊断与告警指南

**Files:** Create `src/infrastructure/windows/cea_release_identity.pas`, `docs/delivery/windows-release-playbook.md`, `tests/pascal/test_release_identity.pas`; modify `app/lazarus/cea_main_form.pas`, `build/unit-manifest.txt`, Lazarus and Pascal search paths.

**Interfaces:** `TCEAReleaseIdentity.ReadCurrent(out AIdentity: TCEAReleaseIdentityInfo): TCEAResult` returns version/build channel, SHA-256 and signature status only; no certificate private key or paths. UI shows how to verify official build and separate Antivirus versus SmartScreen help. No API that mutates Defender is introduced.

- [x] **Step 1: Write failing test.** `ReadCurrent` returns a valid SHA-256 of the test EXE and no secret/path fields; a failed signature query is reported as unsigned/unknown, not as trusted. The classifier distinguishes Antivirus and SmartScreen.
- [x] **Step 2: Run RED.** The focused test first failed because `cea_release_identity` did not exist.
- [x] **Step 3: Implement.** The read-only unit hashes the running EXE and calls `WinVerifyTrust` with UI/network retrieval disabled. The native About/Security tab shows internal channel, hash, trust result and non-bypass guidance; no Defender mutation API exists.
- [x] **Step 4: Run GREEN.** The focused test, compile smoke and native build pass. Native desktop windows were unavailable to the automation surface, so visual/click inspection remains explicitly unverified.

### Task 3: 发布门禁与完整验证

**Files:** Modify `tools/release/test-release-manifest.ps1`, `docs/delivery/windows-release-playbook.md`, `docs/delivery/verification-report.md`, `README.md`; test `tests/acceptance/test-release-manifest.ps1`.

**Interfaces:** Public mode fails closed until trusted signature, supported channel, all test/scan evidence and explicit Gate 9/manual evidence are present. Internal mode always states not publicly releasable. No automatic sample submission or publication.

- [x] **Step 1: Write failing public-gate tests.** Unsigned build, each missing evidence field (including manual game/UI and save Gate 9), and wrong channel fail independently; tampered/missing files and traversal remain covered.
- [x] **Step 2: Run RED.** The expanded cases established the missing independent preflight ordering before the verifier change.
- [x] **Step 3: Implement gate and playbook.** Public preflight requires public channel/publishable plus every explicit evidence status, then verifies every file and a valid signature. The playbook separates Antivirus, SmartScreen and policy blocks without bypass instructions.
- [x] **Step 4: Verify.** Release acceptance, 40/40 Pascal tests, child integration, Schema/scaffold/smoke, native build/self-test, actual internal manifest verification and live MCP handshake pass. Public release correctly remains blocked because the build is internal/unsigned and manual game/UI plus Gate 9 evidence are absent.

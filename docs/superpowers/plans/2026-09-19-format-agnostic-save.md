# 格式无关的存档能力 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在独立 Windows/Lazarus 应用中建立存档只读、可验证备份、测试格式字段级受控编辑及独立恢复闭环，同时保留真实游戏格式未验证边界。

**Architecture:** `Save Domain` 只定义资源身份、快照、字段观察和差异；Windows 文件端口负责全部实际文件副作用。文件操作复用 local governance gateway，但先把现有进程专属目标绑定扩展为通用资源身份并保持旧库兼容。游戏格式通过版本化 Codec 注册，未知格式只有只读与备份能力。

**Tech Stack:** Free Pascal 3.2.2、Lazarus、Win64、现有 SQLite 治理存储、Windows 文件 API、JSON Schema 2020-12、PowerShell 测试脚本。

**Spec:** `docs/superpowers/specs/2026-09-19-game-companion-save-architecture.md`

## Global Constraints

- 仅用户授权的单机离线存档；不触碰联网/多人服务端状态、反作弊绕过或隐蔽修改。
- 永远不训练、微调或改写模型权重。
- 原版 Cheat Engine 仅作参考；生产程序是 `dist/CheatEngineAgent.exe`。
- 未知或校验/重编码不完整的格式只能只读和备份，不能由 AI 猜偏移写回。
- 文件备份、编辑和恢复均是 Effect；LLM/MCP 不能审批或绕开本机确认。
- 原件和备份不共路径；失败、取消、崩溃和 unknown 不能静默转成功或自动重试写入。
- 用户未提供具体游戏/存档样本，测试格式通过不等于真实游戏兼容。
- 当前项目目录无 Git 仓库；每个任务保留可验证文件和命令记录，不虚构 commit。

## Review Focus

1. 路径从授权文件跳到 reparse point/符号链接或父目录外时，必须在任务 2 的读取与任务 5 的写前复核中拒绝。
2. 同名存档在快照后被游戏或云同步改写时，任务 5 必须以文件身份与 SHA-256 双重比较拒绝编辑。
3. 备份写入后崩溃、Receipt 缺失时，任务 3/6 必须对账，不可重复覆盖备份或宣称可恢复。
4. 替换已生效但读回或账本写入失败时，任务 5/6 必须保持 unknown、保留备份并阻止自动再写。
5. 未知二进制、同名不同版本或部分解析时，任务 2/4 必须只读、显式显示覆盖率，不暴露编辑入口。

## 文件职责图

- `src/domain/save/cea_save_types.pas`：格式无关的目标、快照、字段、备份、提议和验证类型。
- `src/domain/save/cea_save_ports.pas`：Reader、Codec、文件 Effect Port 的最小接口。
- `src/core/save/cea_save_service.pas`：只读观察、备份/编辑/恢复编排；不直接调用文件写 API。
- `src/platform/windows/cea_win32_save_reader.pas`：授权路径、文件身份、读取上限和快照哈希。
- `src/platform/windows/cea_win32_save_effect_port.pas`：备份、候选文件、同卷替换、读回和恢复的唯一写出口。
- `src/platform/save-fixtures/cea_fixture_save_codec.pas`：自有测试格式的版本化字段 Codec；不宣称真实游戏支持。
- `src/infrastructure/cea_sqlite_store.pas`：资源身份扩展、备份/编辑引用和未结算 Effect 对账。
- `src/app/cea_application_runtime.pas`、`app/lazarus/cea_main_form.pas`、`src/mcp/cea_mcp_registry.pas`：组装、用户界面和只读/提议工具面。
- `schemas/save-domain/*.schema.json`、`schemas/manifest.json`、`build/unit-manifest.txt`：机器契约和构建登记。

每次实现新 Pascal 单元时，同一步更新 `tests/pascal/run-test-program.ps1` 与 `tests/pascal/compile-smoke.ps1` 的 `-Fu` 搜索路径；不要把输出写进源码目录。所有文件修改使用 `apply_patch`。

---

### Task 1: 通用资源身份与存档领域契约

**Files:**
- Create: `src/domain/save/cea_save_types.pas`, `src/domain/save/cea_save_ports.pas`
- Create: `schemas/save-domain/save-target.schema.json`, `schemas/save-domain/save-snapshot.schema.json`, `schemas/save-domain/save-edit-proposal.schema.json`
- Modify: `src/contracts/cea_types.pas`, `src/core/governance/cea_lease_service.pas`, `src/core/governance/cea_effect_service.pas`, `src/core/governance/cea_governance_gateway.pas`, `src/infrastructure/cea_sqlite_store.pas`, `schemas/manifest.json`, `build/unit-manifest.txt`
- Test: `tests/pascal/test_save_contracts.pas`, `tests/pascal/test_governance_services.pas`, `tests/pascal/test_state_store.pas`

**Interfaces:** Existing process-bound calls remain valid. Add `TCEAResourceKind=(rkProcess,rkSaveFile)` and `ResourceKind/ResourceIdentityId` to capability context, Lease, Approval and Effect. A process call keeps its existing `ProcessIdentityId` and maps it to the same resource identity; a save call uses `rkSaveFile` and a nonempty file identity. Declare `ICEASaveReader.Inspect(const APath: string; out ASnapshot: TCEASaveSnapshot): TCEAResult` and `ReadVerified(const ASnapshot: TCEASaveSnapshot; out ABytes: TBytes): TCEAResult`; `ICEASaveCodec.Probe(const ABytes: TBytes; out ADescriptor: TCEASaveFormatDescriptor): TCEAResult`, `Decode(const ABytes: TBytes; out AFields: TCEASaveFieldArray): TCEAResult`, `Encode(const AOriginal: TBytes; const AEdit: TCEASaveEditProposal; out AEncoded: TBytes): TCEAResult`, `Validate(const ABytes: TBytes): TCEAResult`; and `ICEASaveFileEffects.InvokeEffect(const AEffect: TCEAEffect): TCEAResult`. `TCEASaveSnapshot` exposes `ByteCount`, `Sha256`, `ReadCoverage`, `Editable` and a stable file identity. `ReadVerified` returns bytes only to an in-process Codec after rechecking identity/hash; UI/MCP do not receive them.

- [ ] **Step 1: Write the failing contract and migration tests.**

```pascal
Assert(Ord(rkProcess) <> Ord(rkSaveFile));
Assert(SaveContext.ResourceKind = rkSaveFile);
Assert(SaveContext.ResourceIdentityId <> '');
Assert(Gateway.RequestEffect('save_edit', SaveContext, '{}', 'same-key').Code = rcApprovalRequired);
Assert(LoadedLegacyEffect.ResourceKind = rkProcess);
Assert(LoadedLegacyEffect.ResourceIdentityId = OldProcessIdentityId);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_contracts.pas`; expected compile failure on missing save contracts/resource kind.
- [ ] **Step 3: Add types, schemas and backward-compatible migration.** Keep existing `process_identity_id` columns/JSON readable. New rows persist `resource_kind` and `resource_identity_id`; migration fills legacy rows with `process` and their old process identity. Validate that both fields agree for process rows and reject missing save-file identity. Include resource kind/identity in Effect request hash and idempotency scope; old records retain their original stored request hash. Do not reinterpret a file identity as a PID.

```pascal
if AContext.ResourceKind = rkSaveFile then
  Require(AContext.ResourceIdentityId <> '')
else
  Require(AContext.ResourceIdentityId = AContext.ProcessIdentityId);
```

- [ ] **Step 4: Run GREEN and regression.** Run the new test, `test_governance_services.pas`, `test_state_store.pas`, `tools/schema-check/check-schemas.ps1` and `tests/pascal/compile-smoke.ps1`; expected all PASS and no changed behavior for process-bound Effects.

### Task 2: 只读快照与未知格式隔离

**Files:**
- Create: `src/platform/windows/cea_win32_save_reader.pas`, `src/core/save/cea_save_service.pas`
- Modify: `src/core/governance/cea_policy_model.pas`, `src/app/cea_application_runtime.pas`
- Test: `tests/pascal/test_save_snapshot.pas`

**Interfaces:** `TCEASaveService.Inspect(const ATaskId, ASelectedPath: string; out ASnapshot: TCEASaveSnapshot): TCEAResult` calls `ICEASaveReader`. Snapshot includes canonical path reference, volume/file ID, size, SHA-256, read coverage and `editable=false` until a matching write-capable Codec validates. Reader hard limit: 64 MiB, no wildcard paths, no directory input.

- [ ] **Step 1: Write RED fixtures.** Use a newly created temporary directory containing a 16-byte fixture, a 64 MiB+1 file, and a link/reparse path targeting outside the selected directory. Assert ordinary input yields stable hash and full byte coverage; oversized/path-escape/changed-while-reading input fails; unknown bytes remain `editable=false`.

```pascal
R := Service.Inspect('task-save-read', FixturePath, Snapshot);
Assert((R.Code = rcOk) and (Snapshot.ByteCount = 16));
Assert(Snapshot.ReadCoverage = Snapshot.ByteCount);
Assert(not Snapshot.Editable);
Assert(Service.Inspect('task-save-read', OversizePath, Snapshot).Code = rcBudgetExceeded);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_snapshot.pas`; expected missing reader/service symbols.
- [ ] **Step 3: Implement read-only opening by handle.** Open with `FILE_READ_DATA|FILE_READ_ATTRIBUTES`, reject directory/reparse ambiguity, resolve final path and volume/file ID from the open handle, stream at most 64 MiB while hashing, then compare identity/size/time before and after. Return a snapshot of bytes and provenance only through bounded `TCEAResult`; never log full bytes or path.
- [ ] **Step 4: Run GREEN.** Run the new test and existing Win32 child-process test; expected no process behavior regression. Re-run with a file modified concurrently; result must be conflict or unknown, never a full successful snapshot.

### Task 3: 治理下的不可变备份

**Files:**
- Create: `src/platform/windows/cea_win32_save_effect_port.pas`
- Create: `schemas/save-domain/save-backup.schema.json`
- Modify: `src/core/save/cea_save_service.pas`, `src/core/governance/cea_policy_model.pas`, `src/core/governance/cea_effect_service.pas`, `src/core/governance/cea_governance_gateway.pas`, `src/infrastructure/cea_sqlite_store.pas`, `schemas/manifest.json`
- Test: `tests/pascal/test_save_backup.pas`

**Interfaces:** `TCEASaveService.RequestBackup(const ATaskId, ASnapshotId: string): TCEAResult` plans `save_backup`; `ExecuteBackup(const AEffectId: string): TCEAResult` returns backup ID, Receipt ID and Proof ID. Policy may grant exactly one low-risk, path-scoped backup call automatically; this must still consume a Lease and persist an Effect before file creation. The backup directory is a dedicated app data directory, never the original save directory.

- [ ] **Step 1: Write RED tests.** Assert planning creates no file, execution creates immutable backup with matching hash, backup path differs from target, second same-key request returns the same backup identity, same-key different parameters conflict, and injected failure after bytes before Receipt leaves an unsettled Effect. Define `ExtractEffectId` and `HashFile` as test-only helpers in this program.

```pascal
R := Service.RequestBackup('task-save', Snapshot.Id);
Assert(R.Code = rcApprovalRequired);
Assert(not FileExists(ExpectedBackupPath));
R := Service.ExecuteBackup(ExtractEffectId(R.DataJson));
Assert((R.Code = rcOk) and (R.ReceiptId <> '') and (R.ProofId <> ''));
Assert(HashFile(BackupPath) = Snapshot.Sha256);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_backup.pas`; expected missing backup API.
- [ ] **Step 3: Implement backup through the file Effect port.** Reserve the destination identity and idempotency key in SQLite before copying; copy from the attested source handle to a create-new destination with write-through/flush; close and reopen the destination to verify hash and length. Record Receipt/Proof; a collided destination with different bytes is conflict, never overwrite. Extend the approval check only for `save_backup` to accept a persisted `policy_auto` decision with explicit scope/expiry/count; existing memory/save-edit approvals remain local-UI only. The test helper `ExtractEffectId` reads the planned Effect ID from JSON.
- [ ] **Step 4: Run GREEN and fault injection.** Run new test, `test_governance_services.pas`, `test_state_store.pas`; after simulated crash inspect the ledger and confirm no duplicate backup write on restart.

### Task 4: 版本化测试 Codec 与字段提议

**Files:**
- Create: `src/platform/save-fixtures/cea_fixture_save_codec.pas`, `schemas/save-domain/save-format.schema.json`, `schemas/save-domain/save-field-observation.schema.json`
- Modify: `src/core/save/cea_save_service.pas`, `schemas/manifest.json`
- Test: `tests/pascal/test_save_codec.pas`

**Interfaces:** Fixture format `CEA-SAVE-1\n` followed by canonical JSON object `{ "hp": integer 0..9999, "gold": integer 0..999999 }` and trailing SHA-256 checksum line. `ICEASaveCodec.Probe(const ABytes: TBytes; out ADescriptor: TCEASaveFormatDescriptor): TCEAResult`, `Decode`, `Encode`, `Validate` are the only way to interpret/edit fields. `TCEASaveService.ProposeFieldEdit(const ASnapshotId, AFieldPath, AExpectedJson, ANewJson: string): TCEAResult` returns an authority-free proposal.

- [ ] **Step 1: Write RED tests.** Assert exact version decodes `hp`/`gold` with byte coverage, changed checksum and `CEA-SAVE-2` are read-only, `hp=10000` is rejected, `hp=500` proposal contains old/new values but does not alter disk, and encode/decode preserves `gold` when only `hp` changes. Declare `VersionOneBytes`/`VersionTwoBytes` as test fixtures and `HashFile` as a test-only helper.

```pascal
Assert(Codec.Probe(VersionOneBytes, Descriptor).Code = rcOk);
Assert(Codec.Probe(VersionTwoBytes, Descriptor).Code <> rcOk);
Assert(Service.ProposeFieldEdit(Snapshot.Id, '/hp', '400', '500').Code = rcOk);
Assert(HashFile(SavePath) = Snapshot.Sha256);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_codec.pas`; expected missing Codec/proposal symbols.
- [ ] **Step 3: Implement fixture-only Codec and registry.** Obtain input with `ICEASaveReader.ReadVerified`, not from an old in-memory snapshot. `Probe` checks exact magic/version and checksum; `Decode` accepts only the two declared integer fields and reports full or partial coverage explicitly; `Encode` validates range and unchanged fields, writes deterministic JSON/checksum. Unknown, ambiguous, malformed and partially decoded formats expose no edit capability. Index any field projection as derived data bound to source/adapter hash and permissions.
- [ ] **Step 4: Run GREEN.** Run new test and `tools/schema-check/check-schemas.ps1`; expected proposal has `authority:none` and no file mutation.

### Task 5: 本机审批的单次编辑与读回

**Files:**
- Modify: `src/core/save/cea_save_service.pas`, `src/platform/windows/cea_win32_save_effect_port.pas`, `src/ui/cea_local_approval_port.pas`, `src/app/cea_application_runtime.pas`
- Create: `schemas/save-domain/save-edit-receipt.schema.json`, `schemas/save-domain/save-verification.schema.json`
- Modify: `schemas/manifest.json`
- Test: `tests/pascal/test_save_edit.pas`

**Interfaces:** `TCEASaveService.PlanEdit(const ATaskId, AProposalId: string): TCEAResult` produces `save_edit` Effect only after verified backup. `ExecuteApprovedEdit(const AEffectId: string): TCEAResult` uses existing local approval mechanism, revalidates resource identity, source SHA-256, Policy/Lease and proposal hash, then invokes file port once.

- [ ] **Step 1: Write RED tests.** Without backup or approval, planning/execution cannot change bytes. With approval, candidate is created in source volume, Codec validates round-trip, replacement occurs once, reopened readback yields new `hp` and unchanged `gold`. Concurrent source rewrite, path redirection, same-key altered proposal, approval expiry, missing Lease, candidate mismatch and readback failure are rejected/unknown with backup retained. Define `ApproveLocally`, `HashFile` and `ReadFixtureHp` as test-only helpers backed by existing approval/store APIs.

```pascal
Assert(Service.PlanEdit('task-save', Proposal.Id).Code = rcApprovalRequired);
Assert(HashFile(SavePath) = BeforeHash);
Assert(Service.ExecuteApprovedEdit(EffectId).Code = rcUnauthorized);
ApproveLocally(EffectId, BeforeHash, Proposal.ContentHash);
R := Service.ExecuteApprovedEdit(EffectId);
Assert((R.Code = rcOk) and (R.ReceiptId <> '') and (R.ProofId <> ''));
Assert(ReadFixtureHp(SavePath) = 500);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_edit.pas`; expected missing edit API.
- [ ] **Step 3: Implement single write出口.** Persist Effect before candidate creation. Reopen original and verify final path/file ID/hash, ensure no active writer or cloud-sync conflict, write candidate with `CREATE_NEW` in same volume, flush, re-open and validate Codec/checksum, then replace the attested file. Use an OS operation whose overwrite/backup behavior is explicitly tested on supported NTFS; on unsupported file systems fail before replacement. Independently reopen target, verify identity, SHA-256, changed/unchanged fields and persist Receipt/Proof. Never automatically repeat after unknown.
- [ ] **Step 4: Run GREEN and regression.** Run new test, `test_governed_memory_effect.pas`, `test_standalone_app_runtime.pas` and `tests/pascal/compile-smoke.ps1`; expected legacy memory approval semantics unchanged.

### Task 6: 显式恢复与崩溃对账

**Files:**
- Modify: `src/core/save/cea_save_service.pas`, `src/platform/windows/cea_win32_save_effect_port.pas`, `src/infrastructure/cea_sqlite_store.pas`
- Create: `schemas/save-domain/save-recovery.schema.json`
- Modify: `schemas/manifest.json`
- Test: `tests/pascal/test_save_recovery.pas`

**Interfaces:** `PlanRestore(const ATaskId, ABackupId, AExpectedCurrentHash: string): TCEAResult` and `ExecuteApprovedRestore(const AEffectId: string): TCEAResult` are a new `save_restore` Effect, never an automatic undo. `ReconcileUnsettledSaveEffects: TCEAResult` records `applied/rejected/unknown` plus a RecoveryCase with owner/deadline/next check when hashes are insufficient.

- [ ] **Step 1: Write RED fault-matrix tests.** Inject interruption before candidate write, after candidate flush, after replacement, after Receipt and before Proof. Assert restart does not call write API; known target/backup hashes allow read-only reconciliation, ambiguous state remains unknown. Restore with stale current hash rejects; explicit approved restore succeeds with new Receipt/Proof. `SimulateCrashAfterReplace` is a test-only fault-injection hook in a fake `ICEASaveFileEffects`; `FileWriteCallCount` counts that fake's calls.

```pascal
SimulateCrashAfterReplace;
Assert(Service.ReconcileUnsettledSaveEffects.Code = rcOk);
Assert(FileWriteCallCount = 1);
Assert(StoredEffect.State in [esApplied, esUnknown]);
Assert(Service.PlanRestore('task-restore', Backup.Id, WrongHash).Code = rcConflict);
```

- [ ] **Step 2: Run RED.** `./tests/pascal/run-test-program.ps1 -Program ./tests/pascal/test_save_recovery.pas`; expected missing restore/reconcile API.
- [ ] **Step 3: Implement read-only startup reconciliation and separately governed restore.** Do not turn uncertain evidence into success; retain backup and candidate provenance, persist RecoveryCase, block new save Effect for an unsettled target, and do not reuse the original approval for restore.
- [ ] **Step 4: Run GREEN.** Run new test, `test_state_store.pas`, `test_standalone_app_runtime.pas`; expected no automatic repeat write.

### Task 7: Windows 工作台、MCP 限权与交付核验

**Files:**
- Modify: `app/lazarus/cea_main_form.pas`, `src/app/cea_application_runtime.pas`, `src/mcp/cea_mcp_registry.pas`, `integration/cheat-engine/ce_agent_mcp_runtime_dispatcher.pas`, `README.md`, `docs/delivery/verification-report.md`, `docs/superpowers/plans/2026-09-13-game-reverse-agent-rebaseline-roadmap.md`
- Test: `tests/pascal/test_standalone_app_runtime.pas`, `tests/pascal/test_ce_mcp_runtime_dispatcher.pas`, `tests/acceptance/verify-scaffold.ps1`

**Interfaces:** UI actions `选择存档 → 查看快照 → 创建备份 → 查看字段差异 → 本机审批编辑 → 读回结果 → 单独恢复`. MCP adds only `cea.inspect_save`, `cea.get_save_snapshot`, `cea.request_save_backup`, `cea.propose_save_edit`, `cea.get_save_effect`; no approve/execute/restore write tool. If the MCP schema requires capability registration, register denied/unavailable states explicitly rather than exposing inert approval tools.

- [ ] **Step 1: Write RED integration tests.** Assert MCP inspect returns hash/coverage but no full bytes/path; proposal and backup request cannot approve or perform edit; invoking a guessed `cea.approve_save_edit` fails. UI state test verifies Edit button disabled for unknown format and until backup Proof exists. Runtime fixture round-trip produces Receipt/Proof and separate restore.

```pascal
Response := Runtime.HandleMCP(CallTool('cea.inspect_save', SelectedFixture));
Assert(Pos('sha256:', Response) > 0);
Assert(Pos(SecretFixtureBytes, Response) = 0);
Assert(Pos('method_not_found', Runtime.HandleMCP(CallTool('cea.approve_save_edit', '{}'))) > 0);
```

- [ ] **Step 2: Run RED.** Run `test_standalone_app_runtime.pas` and `test_ce_mcp_runtime_dispatcher.pas`; expected missing save methods/tools or incorrect UI readiness.
- [ ] **Step 3: Compose runtime and native UI.** UI uses the same service projection as MCP, shows coverage/compatibility and diff, requires local approval, and labels fixture format explicitly. Keep the LLM limited to proposals and avoid disclosure of full save bytes, Credential Manager secrets or unnecessary paths.
- [ ] **Step 4: Run full verification.** Run every `tests/pascal/test_*.pas` except parameterized `test_win32_child_process.pas` through `run-test-program.ps1`; run `tests/integration/test-win32-child-process.ps1`, `tools/schema-check/check-schemas.ps1`, `tests/acceptance/verify-scaffold.ps1`, `tests/pascal/compile-smoke.ps1`, `build/build-standalone-app.ps1`, `dist/CheatEngineAgent.exe --self-test`, and `tests/integration/test-live-mcp-app.ps1`. Record exact counts/exit codes and any unsupported host condition.
- [ ] **Step 5: Update delivery boundary.** Document that only the fixture format is write-capable; real game format support and manual game acceptance require user-supplied game/version/sample/field semantics. Do not mark Gate 9 complete.

## Deferred but explicit follow-ups

- **Real game adapter:** create a separate game/version-specific spec after receiving an authorized sample and field oracle; complete read-only comparison before a minimal approved edit. This plan cannot honestly close that acceptance without those inputs.
- **攻略/设定集 PDF、Live2D、语音等扩展愿景:** 已归档至 [未来扩展](../future-extensions.md)，作为独立路线后续工作，不属本存档计划的交付范围。

## Plan self-review checkpoint

Tasks 1–7 cover spec sections 3–7: contracts and resource binding, read/coverage, backup, Codec, edit/approval, recovery, UI/MCP and verification. Review Focus 1 is pinned in tasks 2/5, 2 in task 5, 3 in tasks 3/6, 4 in tasks 5/6, and 5 in tasks 2/4. No real game completion is claimed. The workspace is not a Git repository, so task checkpoints are verification reports rather than Git commits.

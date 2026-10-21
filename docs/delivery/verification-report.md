# Verification report

## Gate 8 closed MCP inputs and module listing — 2026-09-21

The registry now exposes `cea.list_modules` in addition to its existing router, for 27 advertised tools. Every input object is closed with `additionalProperties=false`; concrete required fields, enums, budgets, lengths, item bounds and the project's bounded address/hex patterns are declared where applicable. `TMCPToolRegistry.CallTool` validates each argument object before dispatch and returns `tool_arguments_schema_invalid` rather than allowing a handler to interpret undeclared input.

RED tests first showed the missing module registration and permissive schemas. Further RED cases proved that merely publishing Schema was insufficient: the server accepted unknown fields, absent required values, invalid enums, over-budget numbers, nested range extras and malformed address/hex strings. The embedded validator now enforces the subset used by this registry, including recursive array items. It is deliberately documented as a bounded validator; complete Draft 2020-12 qualification remains an external release requirement.

Fresh evidence after the change: the focused MCP/runtime suite passed, all **43/43** non-parameterized Pascal tests passed, child-process integration passed, Schema check reported `47 schemas / 77 units`, compile smoke and Lazarus build passed, and a real loopback initialize/tools-list/`cea.health` handshake reported **27 tools**. Native Codex tool discovery still requires a restarted/new task and is not inferred from direct HTTP success.

## CT draft generation design checkpoint — 2026-09-21

The approved design is recorded in `docs/superpowers/specs/2026-09-21-ct-draft-generation-design.md`. It selects a deterministic evidence compiler: model/user suggestions are typed, authoritative addresses and compatibility data are resolved from verified stored evidence, and Pascal emits an inactive script-free CT subset. Export would be a local-only create-new local governance Effect with readback hash and Receipt/Proof; MCP would be limited to proposal and query operations. Its 9-task/48-step TDD implementation plan is `docs/superpowers/plans/2026-09-21-ct-draft-generation.md` and awaits plan-review confirmation. No implementation, approval/export endpoint or claim of CT generation exists at this checkpoint.

## Gate 4a real module-set identity change — 2026-09-21

The child-process integration now builds a harmless fixture DLL next to its existing self-target. After the initial read/scan/disassembly checks and detach, the test creates a private marker that tells only the fixture process to load that DLL itself. The production `CreateToolhelp32Snapshot` module-set hash changes while PID, process start time and executable remain fixed. Reattaching through `TCEAProcessCapability` advances the Epoch by one, changes the identity ID, and rejects an old-identity memory read with `rcStaleProcessIdentity`.

The expected RED run timed out waiting for a module-set change before the fixture loader existed. After adding the loader, `test-win32-child-process.ps1` passed end to end. This validates identity invalidation on a real module change without injecting code or a DLL into any user/game process.

## Gate 4a maximum-budget performance — 2026-09-21

The standalone performance acceptance `tests/performance/run-scan-512mib-budget.ps1` uses the production Win32 backend against one committed, touched 512 MiB private allocation. With `max_bytes=536870912` and `max_duration_ms=30000`, the latest run inspected exactly 536,870,912 bytes in 5,188 ms, returned ready with no partial reason, and never exceeded the requested byte budget. A second run over the same allocation sets `max_duration_ms=1`; it returned ready/partial in 31 ms after inspecting 2,097,146 bytes, proving the real worker observes the elapsed-time ceiling.

The RED run showed that the worker stopped early but serialized `partial_reason=timeout`, inconsistent with the save-discovery subsystem's stable `time_limit` reason and with no Schema/test/document declaring `timeout`. The single production mapping was changed to `time_limit`; both performance cases then passed, followed by all **43/43** non-parameterized Pascal regression programs. The harness remains outside the fast suite because it intentionally commits and touches 512 MiB.

## Gate 8 Codex plugin packaging — 2026-09-21

The MCP endpoint is now packaged as a native Codex plugin as well as a project/user configuration entry. `tools/codex-mcp/plugin/.codex-plugin/plugin.json` references a token-free `.mcp.json`; the latter binds only `http://127.0.0.1:32145/mcp`, reads `CEA_MCP_TOKEN` from the inherited environment and leaves tool approval at `prompt`. The official plugin validator and `test-codex-plugin-package.ps1` pass, and `cheat-engine-agent@personal` is installed and enabled in this Windows profile. The standalone live test performs initialize, tools/list and an actual `cea.health` tools/call without logging the bearer.

This closes packaging and direct protocol execution, not native Codex discovery: plugin/MCP catalogs are fixed when a task starts. The current task therefore cannot honestly claim that a `mcp__cheat_engine_agent__*` tool appeared after installation. Restart Codex after configuring the shared token and use a new task for that final acceptance step.

## Gate 4a process-level planning and true multi-range scan — 2026-09-21

The scan contract, capability, runtime router and production Win32 backend now preserve 1–128 exact ranges instead of requiring exactly one. Local authorization requires ascending, non-overlapping ranges and compares every start/size pair on use; the shared total remains bounded by 512 MiB. A real two-allocation fixture finds the same typed value in two disjoint pages and reports exactly two requested pages, while an overlapping request is rejected with `scan_ranges_overlap` before scope issuance.

The native workbench also has a process-level region-kind selector. `private` is the default; `image` and `mapped` are separate explicit choices. The planner performs metadata-only `VirtualQueryEx`, returns bounded ranges, and shares the existing 4,096-region ceiling. A byte-limited plan carries `byte_limit` through the scope into the final and refined scan projections, so successful reading of the selected subset cannot be presented as complete process coverage. No startup, model request or MCP connection triggers this planner; it runs only after local confirmation.

Observed RED→GREEN: the production test first failed to compile without `TCEScanRequest.Ranges`/`AuthorizeLocalRanges`, then found only one disjoint page before backend range iteration; the runtime router rejected two ranges under its old exact-one rule; process planner tests failed without region kinds/API; and the standalone runtime failed to compile without `StartProcessValueScan`. All focused tests now pass. Fresh evidence: **43/43** non-parameterized Pascal programs, child-process integration, Schema (`47 schemas / 77 units`), scaffold, compile smoke, Lazarus build (`dist/CheatEngineAgent.exe`, `3,990,528` bytes), release-manifest acceptance and loopback MCP handshake (`26` tools).

Gate 4a is still not fully accepted: native controls were compiled but not clicked through by a desktop-control surface; the installed plugin still needs a restarted/new Codex task to prove native `cea.*` discovery; and a newly authorized real-game read-only run remains outstanding. The separate maximum-budget section above closes the automated 512 MiB/30-second performance requirement with production-path evidence.

## Gate 7 Anthropic adapter and protocol streaming — 2026-09-21

The application now offers explicit OpenAI-compatible and Anthropic-compatible Provider selection. The Anthropic adapter emits the Messages API shape and uses `x-api-key` plus `anthropic-version`; the existing OpenAI path retains Bearer authentication. Both resolve credentials only by Windows Credential Manager reference and zero their short-lived local secret strings. Neither path grants execution authority or changes model weights.

The WinHTTP transport forwards each received byte chunk to a bounded SSE collector while preserving its existing response-size cap and cancellation checks. The collector tolerates JSON split across network chunks, handles OpenAI `data:` deltas/`[DONE]` and Anthropic `message_start`/`content_block_delta`/`message_delta`, accumulates actual token usage, applies the total-token ceiling and emits a normalized `authority=proposal_only` result. The Lazarus worker implements a locked text sink; the UI timer reads snapshots on the main thread, so the network worker never touches controls directly.

RED→GREEN evidence includes the initially missing streaming unit, fragmented-event tests, both Provider request/normalization tests and a discovered access violation in a CORBA-interface temporary. Passing the concrete collector directly to the interface parameter removed that invalid conversion path. Fresh automated evidence is **43/43** non-parameterized Pascal programs, the parameterized child-process integration, scaffold acceptance (`47` JSON files), compile smoke, Lazarus build and release-manifest acceptance. After the final worker-lifecycle hardening, the rebuilt artifact is `dist/CheatEngineAgent.exe` (`3,969,024` bytes in this run).

This is protocol and local integration evidence, not real third-party interoperability. No live external credential was used. A fresh Credential Manager entry and explicit user-run network acceptance are still required for `deepseek-flash`, including observed deltas and cancel behavior. Any credential previously pasted into chat should be rotated rather than reused. Native UI click-through also remains open.

## Save discovery and Windows release-safety completion — 2026-09-21

The save workbench now lets the player explicitly authorize one fixed-local-drive directory, scans it on a background worker under 4,096-file/4-depth/30-second UI defaults, lists metadata-only candidates, supports cancellation/revocation, and reads file contents only after a candidate is selected for the existing snapshot inspection. A real temporary junction to an outside directory is observed, skipped and reported as partial coverage; its target is not enumerated. Candidate selection rechecks file ID, size and last-write time, so same-name/same-byte replacement is rejected. Revoking a scope or stopping the application durably rejects still-planned backup/edit Effects derived from that scope. Direct single-file selection remains available, and MCP has no directory authorization/scan tool.

The application also has a read-only About/Security tab showing internal channel, running EXE SHA-256, byte length and cache-only `WinVerifyTrust` status. Help text distinguishes Defender Antivirus quarantine from SmartScreen reputation and does not offer exclusion, restoration or bypass actions. Public release verification fails closed on wrong channel, each missing evidence field, unsigned/untrusted files, changed/missing files and unsafe manifest names. The current package remains internal, unsigned and non-publishable.

Observed RED→GREEN included missing discovery selection APIs, candidate replacement acceptance, revoked/session-ended planned Effects, FPC silently omitting reparse entries under `faAnyFile`, missing release-identity unit and non-independent public evidence checks. The Win32 enumerator now uses `FindFirstFileW`; Effect request hashes include the idempotency key so a rejected plan cannot collide with a distinct later task while same-task retries stay idempotent.

Fresh automated evidence: **40/40** non-parameterized Pascal programs passed; the parameterized child-process integration passed; Schema check reported `47 schemas / 75 units`; scaffold acceptance, compile smoke, release-manifest acceptance, standalone Lazarus build, actual internal-manifest verification, EXE `--self-test` (exit 0), and live loopback MCP handshake (`2025-06-18`, 26 tools) passed. The desktop-control inventory exposed no native application windows after launch, so visual/click acceptance is not claimed. The current Codex tool catalog also contains no `cea.*`/`cheat_engine_agent` tool, so native Codex MCP invocation remains open. These limitations, real-game acceptance and save-write Gate 9 continue to block public release.

## Gate 4a separate scope and MCP self-process path — 2026-09-21

The local workbench now has a separate, explicit authorization and revocation flow for one read-only MCP scan scope (up to 512 MiB and 10,000 candidates, additionally bounded by 30 seconds and 4,096 regions). The operator confirms PID/Epoch, exact span and budget before receiving an opaque scope ID in the native output pane. MCP has no tool to create that scope. A real self-process test allocates a private page, proves a revoked scope cannot start, a new local scope permits MCP numeric start/refine/status/cancel, and over-budget or stale-Epoch requests are rejected. This test uses the actual runtime and MCP protocol dispatcher, but invokes `HandleMCP` in-process; it is not a Codex-native or over-HTTP end-to-end test. The UI control itself compiled but was not visually clicked in this check.

Observed RED→GREEN: `test_standalone_app_runtime.pas` failed to compile without the separate authorization/revocation API; `test_value_scan_ui_model.pas` failed to compile without scope-only input validation. Both passed after implementation. The new UI path is additive; the original direct local scan remains synchronous and uses its own scope. A separate MCP scope is session-memory-only and is invalidated on revoke, scan cancellation or process attachment change. No write/Effect authority is added.

Fresh checks for this slice: 39/39 non-parameterized Pascal tests passed; child-process integration, Schema check (47 schemas/74 units), compile smoke and independent Lazarus build passed. The rebuilt GUI EXE `--self-test` exited 0; loopback HTTP MCP handshake listed 26 tools. Those checks do not constitute native UI click acceptance or a Codex-native MCP call.

## Gate 6 lightweight pinyin/vector increment — 2026-09-21

CT retrieval now recognizes full pinyin and pinyin initials for a versioned, bounded vocabulary of common Chinese cheat concepts, then provides a deterministic token-set similarity rank for reordered terms. This is the approved lightweight approach: it performs no network embedding request, downloads no model, and never trains, fine-tunes or mutates model weights. Search output identifies `cheat-terms-zh-v1`, `deterministic_pinyin_token_set_v1`, and `external_embedding=false`; unsupported Chinese remains subject to the existing exact/substring/fuzzy behavior rather than being guessed.

RED→GREEN evidence: a Chinese CT description `无限生命` was not found by `wuxianshengming`; after the lightweight index logic, full pinyin, `wxsm`, and reordered `生命无限` all retrieve the provenance-bound entry with distinct match types. The focused `test_ct_rag.pas` passes. General-purpose Chinese transliteration and neural semantic embeddings are intentionally outside this lightweight claim.

## Gate 4a continuation — 2026-09-21

### Background multi-region scan increment

The production Win32 value scanner now starts an owned worker thread and immediately returns `state=running`; the capability, MCP surface and Lazarus workbench poll a read-only status projection until `ready`. Refinement is rejected while work is running. Detach, application destruction and explicit cancellation signal the worker and wait for its next bounded checkpoint before closing the process handle, preventing a worker/use-after-close race. A 64 MiB in-flight fixture verifies cancellation returns within two seconds.

The enforced ceilings are now 512 MiB per authorized span, 30 seconds, 10,000 candidates, 4,096 readable regions and 1 MiB per `ReadProcessMemory` call. `test_multi_region_value_scan.pas` scans two readable pages separated by `PAGE_NOACCESS`, observes both 767 candidates, then follows the surviving candidate through 758 and 880. `test_win32_memory_regions.pas` now exercises the stable `region_limit` partial reason. The UI no longer assumes the start response contains final coverage and does not enable refinement before `ready`.

Observed RED→GREEN: the new production test first failed because `FirstScan` completed synchronously instead of returning `running`. After the worker/status implementation, older production, standalone-runtime, MCP and child-process tests initially dereferenced or asserted fields that only exist in the completed projection; each was changed to condition-poll `get_scan_status`. The standalone runtime access violation was traced to a nil JSON path caused by this obsolete synchronous assumption, not hidden by a retry.

Fresh evidence: 41/41 non-parameterized Pascal programs passed; the parameterized child-process integration passed; Schema check reported 47 schemas and 75 units; scaffold acceptance, compile smoke, release-manifest acceptance, Lazarus build, EXE `--self-test` and loopback MCP handshake (26 tools) passed. The rebuilt artifact is `dist/CheatEngineAgent.exe`.

Gate 4a remains open. The current authorization is one explicit address span which may contain many readable private regions; a process-level region-kind selector and true multi-range request are not implemented. Native UI click-through, Codex-native `cea.*` discovery after restart, forced 30-second/512-MiB performance trials and a newly authorized real-game read-only run remain unverified.

The local numeric session now supports governed exact-value refinement in the native workbench: a private-page test follows `767→758→880` through the same candidate and proves cancellation prevents a further refine. The value type, authorized range, process identity and Epoch are fixed at first scan. Scan status now projects the backend's observed candidate count and requested/inspected/skipped bytes, rather than only a generic ready flag. A candidate that becomes unreadable during refinement is retained as unresolved with `complete=false` and `partial_reason=refine_read_failed`; it is not silently dropped. Authorizing another scope during an active session is refused, and repeated cancellation is idempotent. The four MCP scan tools now advertise concrete input schemas, including scope, budget, range and session ID parameters.

An additional RED→GREEN regression detached and reattached the same self-test process while a candidate session existed. The stable process signature can retain the same ProcessIdentity/Epoch, so those fields alone did not invalidate the old session; it blocked the next scan. Successful attach/detach now advances an attachment serial, and scanner/runtime local state is discarded when that serial changes. The new scan then starts without reusing old candidates. This is a session lifecycle guard, not evidence that a real game process restart has been accepted.

Observed RED→GREEN: runtime test initially failed to compile without `RefineLocalValueScan`; UI-model test initially failed without `ValidateValueRefineUiInput`; active-scope-replacement and repeated-cancel assertions failed in `test_ce_scan_capability`; status coverage failed in `test_win32_readonly_backend`; page-protection-change refinement failed because the backend dropped unreadable candidates; MCP protocol test failed because the scan schema accepted arbitrary arguments. Each passed after its focused implementation. One full-suite run found `test_ce_scan_capability` still comparing serialized JSON text with no spaces; the status serializer emitted semantically equivalent spaced JSON. The test now parses the status object, and the subsequent full suite passed.

Fresh checks after the reattach fix: 39/39 non-parameterized Pascal tests passed; child-process integration, Schema check (47 schemas/74 units), compile smoke, independent Lazarus build, `--self-test` (exit 0), and live loopback MCP handshake (26 tools) passed. The latter verifies HTTP MCP only: the current Codex tool catalog still contains no `cheat_engine_agent`/`cea.health` native tool. Native UI visual/click acceptance and a freshly authorized real-game test were not performed. A manual evidence template is at `docs/delivery/gate-4a-manual-acceptance-template.md`.

Gate 4a remains **open**: a separate UI scope now exists, but the worker-thread/30-second/512-MiB/10,000-result/4,096-region budgets and in-flight cancel are not implemented; process-wide selectable multi-range planning, Codex-native tool invocation, and real-game read-only acceptance are not verified. The current 1-MiB synchronous range is deliberately narrower than the planned final gate. No CT generator or game write was added.

## Gate 4a numeric-scan slice — 2026-09-21

The standalone Lazarus application now has a local, explicitly confirmed read-only numeric scan entry on the process page. The user supplies one address range (at most 1 MiB), value type, current value and result cap; the runtime creates an in-memory scope bound to the attached process identity/Epoch and routes the request through the governed gateway. MCP cannot create that scope. The production backend encodes exact byte/word/dword/qword/single/double values, aligns typed matches, enumerates readable private committed regions within the selected range, skips inaccessible/guard pages, and returns requested/inspected/skipped bytes plus complete/partial reason. Existing AOB scanning remains available. This is **not** yet the planned asynchronous, process-wide multi-range scanner or a verified real-game credit locator.

Observed RED→GREEN: value encoding and alignment initially failed with missing unit/function; region filtering initially failed with missing enumerator; unscoped numeric requests were refused only after the new scope gate; the complete-scan `partial_reason` assertion failed before clearing the planner's `not_scanned` marker. A standalone runtime test fixture was moved into a private allocated page after private-only policy correctly excluded executable image memory. Test runtimes now use isolated preferred MCP ports, preserving the already running user-facing process on port 32145.

Fresh verification: 39 non-parameterized Pascal programs passed, 0 failed; child-process integration passed; Schema check passed (47 schemas, 74 units); compile smoke and scaffold acceptance passed; standalone Lazarus build passed and emitted `dist/CheatEngineAgent.exe` with an internal release manifest. A `Start-Process -Wait -PassThru -WindowStyle Hidden` invocation of `--self-test` returned exit code 0. The release-manifest acceptance script passed its expected positive and negative cases; its prior stale nonzero shell exit was corrected and rerun with exit code 0. Native UI visual/click acceptance, Codex-native MCP invocation, an authorized fresh real-game numeric scan, asynchronous cancellation, and process-wide coverage remain open. The already running application was not restarted; it may still display the older UI until the user relaunches it.

## Gate 4a implementation start — 2026-09-20

Task 1 of `docs/superpowers/plans/2026-09-20-live-game-value-scan.md` is implemented: `cea_value_scan_types.pas` now encodes exact byte/word/dword/qword/single/double values as little-endian bytes, rejects invalid/out-of-range/non-finite inputs, and exposes alignment and coverage types. The scan Schema no longer advertises string/bytes value types, and the new unit is in the manifest/compile smoke. This is an **encoding contract only**; the production backend still does not perform value/multi-region scans, and there is no claim of real-game numeric localization.

Observed RED: `test_value_scan.pas` failed before implementation because `cea_value_scan_types` did not exist; the added alignment assertions failed before `IsValueAligned` existed. Observed GREEN: `test_value_scan.pas` and existing `test_ce_scan_capability.pas` passed; `check-schemas.ps1` passed with 47 schemas/72 units; `compile-smoke.ps1` passed with one pre-existing fixture warning and one note.

The broader sequential run of 37 Pascal test programs reported **33 passed, 4 failed**: `test_save_backup`, `test_save_edit`, `test_save_recovery`, and `test_standalone_app_runtime`. `test_save_backup` reproduced a `standalone_runtime_start_failed` at `Runtime.Start`; the runtime starts its MCP server at fixed loopback port 32145 with one attempt, while the user-facing `CheatEngineAgent.exe` PID 39532 is already listening there. This establishes a test-environment port collision; the running application was **not stopped** to make tests green. The three other failing tests also instantiate the same standalone runtime; their individual failure locations were not separately diagnosed. A temporary diagnostic assertion was restored after investigation. Full-suite green remains unverified until the existing app is safely stopped or the tests/runtime support isolated ports.

The user's additional objective—background proposals for new CT tables—is recorded as a **future separate architecture work package** in the main roadmap. No generator, background analyzer, CT export, game write, or model-weight change was implemented in this slice.

## Live-game read-only findings and plan update — 2026-09-20

The user-authorized single-player `Probably Stolen Demo` process was attached through the local MCP HTTP surface for read-only scanning and then detached; no game memory was written. An AOB scan for the little-endian 32-bit value 767 in one 64 MiB range hit the 2,000-candidate cap without reporting coverage; refining those candidates to 758 returned zero. A second 48 MiB range found 44 candidates for 758; refining to 880 returned zero. These are **inconclusive partial observations**, not evidence that the game's credit value was absent or unmodifiable. The implementation supports only `scan_kind=aob` in the production backend and requires one caller-supplied range, despite the broader Schema. The native workbench has no numeric scan flow, and a Codex-native MCP tool call has not been verified in the current task, although direct local HTTP MCP worked.

The remedy is specified, **not implemented**, in `docs/superpowers/plans/2026-09-20-live-game-value-scan.md` as Gate 4a. The separate `docs/delivery/agentos-v1.4-digital-life-gap-assessment.md` compares this application's broader local governance foundation with the user-supplied v1.4-draft. No claim of full local governance or “digital life” compliance follows from the existing tests. The Provider credential used in an earlier LAN interoperability check was not persisted in this project; it should be rotated because it was disclosed in chat.

## In-progress discovery and release-safety slices — 2026-09-20

The approved follow-up plans are in `docs/superpowers/plans/2026-09-20-save-discovery.md` and `docs/superpowers/plans/2026-09-20-windows-release-safety.md`. A standalone, metadata-only Windows discovery service now requires an explicit local directory scope and bounded scan. It is **not yet connected to the runtime or native UI**; no startup/LLM/MCP scan entry was added. Junction fixture coverage, stale-candidate selection and revocation of planned Effects remain open. The build now emits an internal EXE/DLL hash and signature-status manifest; its verifier is not a public-release approval or antivirus certification.

Fresh checks: 36 non-parameterized Pascal tests passed (0 failed), child-process integration passed, schema check passed (47 schemas, 71 units), scaffold acceptance and Pascal compile smoke passed, standalone Lazarus build and `--self-test` passed, release manifest acceptance and actual `dist` verification passed, and live MCP handshake passed (26 tools). The previous section's real-game/UI/Gate 9 blockers remain unchanged.

## Save workbench extension — 2026-09-20

The independent Lazarus application now contains format-agnostic save identity, bounded read-only snapshotting, create-new verified backup, a versioned test-only `CEA-SAVE-1` Codec, field proposals, locally approved single-edit and separate restore Effects, and read-only restart reconciliation. The new native tab shows compatibility/coverage and requires local approval; MCP exposes inspection/proposal/backup planning and Effect status, but no approve/execute/restore tool. Unknown and real-game formats remain read-only and backup-only. No model training, fine-tuning, or weight mutation is implemented.

Fresh checks on this date (all exit code 0):

- 35 non-parameterized `tests/pascal/test_*.pas` programs passed, 0 failed; the parameterized child-process program passed through `tests/integration/test-win32-child-process.ps1`.
- `tools/schema-check/check-schemas.ps1`: `SCHEMA_CHECK=PASS schemas=47 ids=47 manifest=46 units=68`.
- `tests/acceptance/verify-scaffold.ps1`: `SCAFFOLD_ACCEPTANCE=PASS files=15 json=47`.
- `tests/pascal/compile-smoke.ps1`: `PASCAL_COMPILE_SMOKE=PASS compiler=3.2.2`.
- `build/build-standalone-app.ps1`: `STANDALONE_APP_BUILD=PASS bytes=3858432 sqlite_bytes=1311232`.
- `dist/CheatEngineAgent.exe --self-test`: exit code 0.
- `tests/integration/test-live-mcp-app.ps1`: `LIVE_MCP_HANDSHAKE=PASS protocol=2025-06-18 tools=26`.

The recovery regressions check that a malformed snapshot ID cannot escape the backup directory, an unsettled target blocks another Effect, and a planned candidate hash permits read-only `observed_applied` assessment. File reads now compare the opened handle's final path with the selected path; writes pin ancestor directory handles against rename/reparse changes, and verified backups receive the Windows read-only attribute. These are risk reductions, **not** a claim of adversarial atomic replacement: the final `ReplaceFileW` still names the target and cannot atomically compare its file ID against the earlier handle, so a competing local actor may replace the leaf in that narrow interval. Do not use the fixture write/restore path as a production guarantee until this is resolved. The read-only attribute also does not protect a backup from an owner deleting or replacing it; restore rechecks bytes and rejects changed material, but recoverability can be lost.

The desktop-control surface could not target the newly built application's visible Win32 window, so native visual/click-through acceptance is **not verified**. The app instance launched for that attempt was stopped afterward. The fault-injection matrix (especially interruption after candidate flush, replacement, and before Proof) is not fully automated; tests do cover a persisted interrupted Effect becoming `unknown` without automatic retry, stale-source rejection, and independent restore. No user-selected real game/version/save sample or field oracle was supplied; therefore real-game compatibility, manual game acceptance, and Gate 9 remain open. 攻略/OCR、Live2D 等扩展愿景见 [未来扩展](future-extensions.md)，已延期。

## Current verification — 2026-09-13

**Delivery:** local governance/MCP foundation and Game Reverse Agent architecture rebaseline  
**Compiler:** Free Pascal 3.2.2, `x86_64-win64`

### Executed checks

- `test_assertions_enabled.pas`: PASS; runtime assertions are enabled with `-Sa`.
- `test_contracts.pas`: PASS.
- `test_state_store.pas`: PASS; includes executable SQLite store and schema-validator coverage.
- `test_governance_services.pas`: PASS.
- `test_mcp_protocol.pas`: PASS; registry, dispatcher and protocol semantic assertions compile and run.
- `test_reverse_contracts.pas`: PASS; target/Epoch binding, provenance hash, explicit address width, authority-free recipe and Effect classification invariants run with assertions enabled.
- `test_reverse_orchestrator.pas`: PASS; fake-backed scan/refine, evidence, hypothesis, verification, recipe, governed-effect and cancellation flow.
- `test_ce_command_queue.pas`: PASS; owner-thread dispatch, wrong-thread rejection, cancellation, timeout and terminal ticket release.
- `test_ce_process_identity.pas`: PASS; stable identity, PID/start/module signature changes and Epoch advancement.
- `test_ce_readonly_integration.pas`: PASS; current-process enumeration, attested offline attach, real Win32 memory read, stale identity rejection, byte budget, address-width/range checks and detach.
- `test_ce_scan_capability.pas`: PASS; current-process exact-byte scan, refine, cancel, stale identity, single-scan concurrency and byte/result budgets.
- `test_ce_module_capability.pas`: PASS; real current-process module names, paths, bases and sizes plus result/Epoch guards.
- `test_ce_disassembly_capability.pas`: PASS; bounded real-memory input, minimal isolated NOP/RET decoding, stale identity and address-range guards.
- `test_ce_agent_registration.pas`: PASS; fail-closed dependencies, complete read-only composition, owner-thread binding, duplicate rejection and cleanup.
- `test_windows_sha256.pas`: PASS; Windows CNG SHA-256 against three independently derived vectors.
- `test_openai_compatible.pas`: PASS; request/response normalization, pre-secret prompt/output budgets, actual token usage/total budget, cancellation and timeout/cancel no-retry behavior.
- `test_winhttp_transport.pas`: PASS; a pre-cancelled request exits before opening a network handle and returns the stable cancellation code.
- `test_win32_readonly_backend.pas`: PASS; production backend with real executable hash, module-set hash, read-only attach/read/module enumeration and detach.
- `tools/schema-check/check-schemas.ps1`: PASS after the Gate 4 additions; 37 schema files, 37 unique IDs, 36 manifest entries and 49 Pascal units checked.
- `tests/pascal/compile-smoke.ps1`: PASS after adding the new `src/mcp` unit directory and enabling assertions. All imported production units compiled, linked and ran; build output remained in a unique temporary directory.
- Authority-document local links, required rebaseline artifacts and stale-status wording: PASS.

### Defect found and corrected

The first full compile-smoke run failed because its independent FPC search-path list had not been updated when `src/mcp` was added. The runner now includes `src/mcp` and uses `-Sa`; a clean rerun passed.

The approved rebaseline then added six Reverse Domain schemas, two Pascal contract/port units and four positive/negative fixtures. After the current Gate 4 slice, all sixteen Pascal test programs were rerun and passed.

Gate 3 testing found that read-only capability calls evaluated policy but did not validate or consume a scoped Lease. A failing regression test demonstrated the bypass; `TCEAGovernanceGateway.InvokeRead` now validates capability, process identity and Epoch and consumes one Lease call before dispatch.

Gate 4 was developed RED-to-GREEN. Initial compilation failed on the absent scan-capability unit and the first address-wrap test failed against the implementation; the new capability/lifecycle code and pre-dispatch range validation made both pass. FPC's Win64 installation exposes Toolhelp through `JwaTlHelp32`, so the isolated self-test backend was corrected from the unavailable `TlHelp32` unit before its first successful run.

The first final Gate 4 batch check correctly exposed an obsolete scaffold-era static rule that rejected every process API, including the newly approved read-only backend. The rule was narrowed rather than removed: `OpenProcess`/`ReadProcessMemory` are permitted only in `cea_win32_readonly_backend.pas`, while write/process-injection, VM-operation/all-access, privilege-adjustment, kernel-device and inline-credential patterns remain forbidden globally. Both schema-check and acceptance scripts passed after this correction.

On 2026-09-15, the independent application MCP integration was registered with Codex as `cheat_engine_agent` at `http://127.0.0.1:32145/mcp`, with its bearer value referenced only through `CEA_MCP_TOKEN` and default tool approval set to `prompt`. `test-live-mcp-app.ps1` started only the newly built `CheatEngineAgent.exe`, negotiated MCP `2025-06-18`, and listed 21 tools. Protocol, HTTP authentication, standalone runtime, real child-process read-only integration, compile smoke, schema check, scaffold acceptance, Lazarus rebuild, and `--self-test` all passed in the same verification batch.

The same development session added startup reconciliation for interrupted `executing` Effects, explicit read-only Unknown-effect reconciliation with new Receipt/Proof records, GCM-style typo-tolerant CT ranking, a CT-to-catalog-Evidence bridge, Credential Manager save/read/delete coverage, and bounded freeze sessions. `test_freeze_service.pas` proves activation without mutation, exact permitted-current semantics, per-write Receipt/Proof, write-count closure and stale-target rejection. `test_standalone_app_runtime.pas` performs two real self-process freeze writes, a separately approved restore, MCP plan-only enforcement, and startup conversion of an interrupted freeze to `unknown` without resumption. Full pinyin/vector retrieval, live third-party model credentials, a restarted Codex tool call, and user-selected game acceptance remain unverified.

### Current claim boundary

The tested implementation includes contract/result types, local governance governance services, SQLite event/governance plus Approval/Receipt/Proof persistence, partial schema validation, loopback MCP HTTP, Reverse Domain contracts, a fake-backed experiment orchestration/verification loop, and a production Win32 backend for real process/memory/module reads, bounded AOB scans, minimal disassembly, locally approved compare-write-readback effects and bounded freeze sessions. Freeze binds the process identity, start time, executable hash, Epoch, exact address and two permitted byte values; every actual write receives readback evidence, while target changes, third values, budget and expiry stop the session. Startup never resumes an interrupted freeze and restore remains a separate Effect. Local CT files are hardened-parsed without execution, SHA-256 addressed, normalized into SQLite and returned as provenance-bound RAG with no authority and conservative license metadata. The OpenAI-compatible and Anthropic-compatible adapters have fake-transport evidence for pre-secret budgets, actual token accounting, SSE streaming and timeout/cancel no-retry, while WinHTTP runs off the UI thread and observes cancellation between blocking operations and response chunks. Lightweight pinyin/token-set CT retrieval is implemented for a disclosed bounded vocabulary. It does **not** yet prove live third-party-provider interoperability, a restarted Codex tool call, user-selected game acceptance, arbitrary Chinese/neural semantic retrieval, or any Android host.

## Historical scaffold verification — 2026-09-12

The initial scaffold verification established 28 parseable schemas, 25 compilable Pascal interface units, policy invariants, CT fixtures and unchanged upstream Cheat Engine files. At that time the delivered units were intentionally inert. That historical claim has been superseded by the current partial implementation status above.

## Environment limits

- The bundled schema validator and checker do not yet implement the complete JSON Schema 2020-12 vocabulary. The current Python environment also has no `jsonschema` package, so the new conditional schemas have structural/manifest checks plus Pascal invariant tests, but not yet independent full-vocabulary fixture validation.
- The workspace root is not a Git repository, so project-level commit evidence is unavailable. Each downloaded upstream reference keeps its own Git history.

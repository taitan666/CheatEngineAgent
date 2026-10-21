# Cheat Engine Runtime Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the governed capability dispatcher to real Cheat Engine 7.5 process, scan, memory and UI approval facilities, first against a safe self-test process and then an explicitly authorized offline target.

**Architecture:** CE-specific adapters live behind the existing process/memory/debug/script ports and never receive raw MCP objects. A thread-safe command queue marshals all global CE and LCL access to the correct owner thread; local governance services validates exact process identity and Effect approval both before and after queueing.

**Tech Stack:** Free Pascal 3.2.2, Lazarus LCL, Cheat Engine 7.5 units (`ProcessHandlerUnit`, `memscan`, `symbolhandler`, `disassembler`, `autoassembler`, `LuaHandler`), Windows user-mode APIs.

**Spec:** `docs/superpowers/specs/2026-09-12-cheat-engine-agent-mcp-design.md`

## Global Constraints

- Complete `2026-09-12-cheat-engine-agent-mcp-design.md` first.
- Use user-mode CE facilities only; no DBK, kernel debugger, concealment or anti-cheat bypass.
- No HTTP thread may access LCL controls or CE global state directly.
- Every write must bind expected original bytes, local UI approval, exact ProcessIdentity and readback Proof.
- Keep upstream modifications limited to the composition root and Lazarus search path/resource registration.
- The workspace has no Git metadata; use verification checkpoints and do not initialize Git.

---

## File Structure

- `src/domain/ce/cea_ce_command_queue.pas`: main-thread marshalling and cancellation.
- `src/domain/ce/cea_ce_identity.pas`: PID/start/path/module hash and Epoch checks.
- `src/domain/ce/cea_ce_process_adapter.pas`: enumeration, attach and detach.
- `src/domain/ce/cea_ce_memory_adapter.pas`: bounded read, disassembly and scan ownership.
- `src/domain/ce/cea_ce_effect_adapter.pas`: compare/write/readback operation.
- `src/domain/ce/cea_ce_debug_adapter.pas`: approved debugger state changes.
- `src/domain/ce/cea_ce_script_adapter.pas`: static analysis and approved AA/Lua execution.
- `src/ui/cea_approval_form.pas` and `.lfm`: local content-bound approval UI.
- `src/ui/cea_agent_settings_form.pas` and `.lfm`: MCP enable/disable and status UI.
- `integration/cheat-engine/ce_agent_registration.pas`: single composition root.
- `tests/self-target/cea_self_target.pas`: controlled child process with known memory values.
- `tests/integration/test-ce-runtime.ps1`: end-to-end adapter harness.

### Task 1: CE command queue and safe self-test target

**Files:**
- Create: `src/domain/ce/cea_ce_command_queue.pas`
- Create: `tests/self-target/cea_self_target.pas`
- Create: `tests/pascal/test_ce_command_queue.pas`
- Create: `tests/self-target/build-self-target.ps1`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: cancellation and result contracts from the foundation plan.
- Produces: `ICEACommand.Execute`; `TCEACommandQueue.Enqueue`, `Pump`, `CancelAll`; self-target stdout handshake `{pid,address,original,replacement}`.

- [ ] **Step 1: Write a failing queue ownership test**

```pascal
Queue := TCEACommandQueue.Create(GetCurrentThreadId);
Worker := TQueueWorker.Create(Queue, Command);
Worker.Start;
while not Command.Completed do Queue.Pump(1);
Assert(Command.ExecutedThreadId = GetCurrentThreadId);
Assert(Command.ExecutionCount = 1);
Queue.CancelAll;
Assert(Queue.Enqueue(SecondCommand).Code = rcCancelled);
```

- [ ] **Step 2: Run and verify missing queue unit**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ce_command_queue.pas
```

Expected: compile failure for missing `cea_ce_command_queue`.

- [ ] **Step 3: Implement queue ownership and cancellation**

```pascal
function TCEACommandQueue.Pump(AMaxItems: Cardinal): Cardinal;
begin
  if GetCurrentThreadId <> FOwnerThreadId then
    raise ECEAThreadViolation.Create('CE command queue pumped by non-owner');
  Result := 0;
  while (Result < AMaxItems) and TryPop(Command) do begin
    if FStopping then Command.Cancel else Command.Execute;
    Inc(Result);
  end;
end;
```

Use a critical section plus event; never hold the queue lock while executing a command. A timed-out caller marks its command cancelled, but the owner checks cancellation again immediately before any Effect.

- [ ] **Step 4: Build the self-test target**

```pascal
GetMem(Buffer, 4096);
PQWord(Buffer)^ := QWord($1122334455667788);
WriteLn(Format('{"pid":%d,"address":"0x%x","original":"1122334455667788","replacement":"8877665544332211"}',
  [GetProcessID, PtrUInt(Buffer)]));
Flush(Output);
ReadLn(Command);
if Command = 'exit' then Halt(0);
```

The target allocates one page, prints exact metadata, accepts only `exit`, and performs no network or privileged operation.

- [ ] **Step 5: Run queue and self-target checkpoints**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ce_command_queue.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\self-target\build-self-target.ps1
```

Expected: queue test passes and the self-target emits valid JSON containing a nonzero PID and address.

### Task 2: Process identity, enumeration and attachment

**Files:**
- Create: `src/domain/ce/cea_ce_identity.pas`
- Modify: `src/domain/ce/cea_ce_process_adapter.pas`
- Create: `tests/pascal/test_ce_identity.pas`
- Create: `tests/integration/test-process-adapter.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: `ProcessHandlerUnit`, CE process enumeration and local governance services Lease checks.
- Produces: `TCEAProcessIdentityBuilder.BuildForPid`, `MatchesCurrent`; operational `ListProcesses`, `Attach`, `Detach`.

- [ ] **Step 1: Write failing PID reuse and identity tests**

```pascal
Identity := Builder.BuildForPid(SelfTargetPid, Epoch).Identity;
Assert(Identity.Pid = SelfTargetPid);
Assert(Identity.StartedAt <> '');
Assert(Identity.ExecutablePathHash <> '');
Assert(Identity.ExecutableSha256 <> '');
Assert(Builder.MatchesCurrent(Identity).Code = rcOk);
Tampered := Identity;
Tampered.StartedAt := '1970-01-01T00:00:00Z';
Assert(Builder.MatchesCurrent(Tampered).Code = rcStaleProcessIdentity);
```

- [ ] **Step 2: Run and verify identity builder absence**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ce_identity.pas
```

Expected: compile failure for missing `cea_ce_identity`.

- [ ] **Step 3: Implement stable identity construction**

```pascal
Identity.Pid := APid;
Identity.StartedAt := QueryProcessCreationTimeIso8601(Handle);
Identity.ExecutablePathHash := Sha256Utf8(CanonicalProcessPath(Handle));
Identity.ExecutableSha256 := Sha256File(CanonicalProcessPath(Handle));
Identity.ModuleSetHash := HashSortedModules(APid);
Identity.Architecture := QueryArchitecture(Handle);
Identity.Epoch := AEpoch;
Identity.TargetClassification := tcUnknown;
Identity.Id := Sha256Identity(Identity);
```

Open enumeration handles with query-only rights. Never expose full executable paths through MCP by default; return basename and hashes. Deny system-sensitive processes and current CE PID.

- [ ] **Step 4: Connect attach/detach to CE state through the queue**

```pascal
if not ARequest.OperatorAttestsAuthorizedDebugging then
  Exit(TCEAResult.Error(rcUnauthorized, 'operator_attestation_required', '{}'));
Queue.EnqueueAndWait(TCEAttachCommand.Create(ARequest.Pid), 10000, Result);
if Result.Code = rcOk then
  Result := IdentityBuilder.BuildForPid(ARequest.Pid, EpochService.Advance);
```

The CE command invokes the normal user-mode process open path and verifies `ProcessHandler.ProcessID`. Detach closes the active process, increments Epoch and cancels scans/effects bound to the old identity.

- [ ] **Step 5: Run identity and adapter tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ce_identity.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-process-adapter.pas
```

Expected: the self-target is listed and attached; a changed identity and CE's own process are rejected.

### Task 3: Bounded reads, disassembly and asynchronous scans

**Files:**
- Modify: `src/domain/ce/cea_ce_memory_adapter.pas`
- Create: `src/domain/ce/cea_ce_scan_session.pas`
- Create: `tests/integration/test-memory-read-scan.pas`
- Modify: `src/core/execution/cea_execution_kernel.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: validated identity, `ReadProcessMemory`, `TMemScan`, `TFoundList`, CE disassembler.
- Produces: bounded `ReadMemory`, `Disassemble`, `StartScan`, `RefineScan`, `GetScanStatus`, `CancelScan`.

- [ ] **Step 1: Write failing safe-read and scan tests**

```pascal
R := Adapter.ReadMemory(ReadRequest(SelfTargetIdentity, Address, 8));
Assert(R.Code = rcOk);
Assert(JsonValue(R.DataJson, 'bytes') = '8877665544332211');
Assert(Adapter.ReadMemory(ReadRequest(SelfTargetIdentity, Address, 1048577)).Code = rcBudgetExceeded);
ScanId := Adapter.StartScan(ExactQWordScan(SelfTargetIdentity, '$1122334455667788')).ScanId;
WaitForFinished(ScanId, 30000);
Assert(Adapter.GetScanStatus(ScanId).ResultCount >= 1);
```

- [ ] **Step 2: Run and verify operational failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-memory-read-scan.pas
```

Expected: test reaches current adapter and fails with `rcNotImplemented`.

- [ ] **Step 3: Implement bounded read and disassembly**

```pascal
if ARequest.ByteCount = 0 then
  Exit(TCEAResult.Error(rcInvalidArgument, 'byte_count_zero', '{}'));
if ARequest.ByteCount > 1024 * 1024 then
  Exit(TCEAResult.Error(rcBudgetExceeded, 'read_limit_exceeded', '{}'));
if IdentityBuilder.MatchesCurrent(Identity).Failed then Exit(StaleResult);
SetLength(Bytes, ARequest.ByteCount);
if not ReadProcessMemory(ProcessHandle, Pointer(ARequest.Address),
  @Bytes[0], Length(Bytes), BytesRead) then Exit(MapLastError);
```

Disassembly returns at most 256 instructions or 64 KiB, includes address, bytes and text, and never follows control flow outside the requested range.

- [ ] **Step 4: Implement owned scan sessions**

```pascal
Session := TCEAScanSession.Create(NewId, Identity.Id, Identity.Epoch,
  ARequest.MaxBytes, ARequest.MaxResults);
Session.MemScan := TMemScan.Create(nil);
Session.FoundList := TFoundList.Create(Session.MemScan, nil);
Session.StartExactValue(ARequest.ValueText);
FScans.Add(Session.Id, Session);
```

Each session owns and frees its `TMemScan` and `TFoundList`. Status polling returns counts and progress only. Refinement uses the same session; cancellation waits for the worker to finish before freeing objects. Epoch changes cancel all sessions.

- [ ] **Step 5: Run read/scan and cancellation tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-memory-read-scan.pas
```

Expected: known value is read and found; over-budget read is denied; cancellation leaves no scan worker.

### Task 4: Governed memory write and readback Proof

**Files:**
- Create: `src/domain/ce/cea_ce_effect_adapter.pas`
- Modify: `src/domain/ce/cea_ce_memory_adapter.pas`
- Create: `tests/integration/test-governed-write.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: approved `TCEAEffect`, exact identity, queue and write port.
- Produces: one compare/write/readback attempt with structured Receipt and Proof.

- [ ] **Step 1: Write failing compare-before-write tests**

```pascal
Assert(ExecuteWithoutApproval(WriteRequest).Code = rcApprovalRequired);
Approved := LocallyApprove(WriteRequest);
Assert(ExecuteApproved(Approved).Code = rcOk);
Assert(ReadHex(Address, 8) = ReplacementHex);
Assert(ExecuteApproved(Approved).Code = rcOk); { idempotent stored result }
WrongOriginal := NewApprovedWrite(Address, '0000000000000000', OriginalHex);
Assert(ExecuteApproved(WrongOriginal).Code = rcVerificationFailed);
```

- [ ] **Step 2: Run and verify adapter failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-governed-write.pas
```

Expected: current adapter returns `rcNotImplemented`.

- [ ] **Step 3: Implement one-shot compare/write/readback**

```pascal
ReadExact(Address, Length(Expected), BeforeBytes);
if not ConstantTimeBytesEqual(BeforeBytes, Expected) then
  Exit(VerificationFailure('original_bytes_changed'));
if not WriteProcessMemory(ProcessHandle, Pointer(Address),
  @Replacement[0], Length(Replacement), Written) then
  Exit(MapWriteFailure(GetLastError));
ReadExact(Address, Length(Replacement), AfterBytes);
if not ConstantTimeBytesEqual(AfterBytes, Replacement) then
  Exit(UnknownOrFailedProof(AfterBytes));
Result := AppliedReceiptAndPassingProof(BeforeBytes, AfterBytes);
```

Do not change page protection automatically in phase one. If the memory is not writable, return a policy-safe rejection. Persist `executing` before the queue command and store outcome before returning it to MCP.

- [ ] **Step 4: Test timeout and indeterminate outcomes**

```pascal
FakeWriter.WriteSucceeded := True;
FakeWriter.ReadbackFails := True;
R := EffectAdapter.Execute(ApprovedEffect);
Assert(R.Code = rcUnknownOutcome);
Assert(Store.LoadEffect(EffectId).State = esUnknown);
Assert(FakeWriter.WriteCount = 1);
Assert(EffectAdapter.Execute(ApprovedEffect).Code = rcUnknownOutcome);
Assert(FakeWriter.WriteCount = 1);
```

- [ ] **Step 5: Run governed write and governance regression tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-governed-write.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_governance_services.pas
```

Expected: approved self-target write passes with Proof; all denial and idempotency tests pass.

### Task 5: Local approval and Agent settings UI

**Files:**
- Create: `src/ui/cea_approval_form.pas`
- Create: `src/ui/cea_approval_form.lfm`
- Create: `src/ui/cea_agent_settings_form.pas`
- Create: `src/ui/cea_agent_settings_form.lfm`
- Create: `src/ui/cea_ui_approval_port.pas`
- Create: `tests/pascal/test_ui_approval_binding.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: planned Effect and MCP/runtime status projection.
- Produces: local-only `TCEAApprovalDecision` with exact request hash, identity, expiry and count.

- [ ] **Step 1: Write failing approval binding test**

```pascal
Decision := ApprovalPort.ApproveFromLocalUI(Effect, 60);
Assert(Decision.Origin = aoLocalUserInterface);
Assert(Decision.RequestHash = Effect.RequestHash);
Assert(Decision.ProcessIdentityId = Effect.ProcessIdentityId);
Assert(Decision.MaxExecutions = 1);
Assert(Decision.ExpiresAt > Decision.DecidedAt);
```

- [ ] **Step 2: Run and verify missing UI approval port**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ui_approval_binding.pas
```

Expected: compile failure for `cea_ui_approval_port`.

- [ ] **Step 3: Implement a non-spoofable approval dialog**

```pascal
lblTarget.Caption := Effect.ProcessDisplayName + ' / PID ' + IntToStr(Effect.Pid);
lblAddress.Caption := Effect.AddressHex;
memoBefore.Text := GroupHex(Effect.ExpectedOriginalHex);
memoAfter.Text := GroupHex(Effect.ReplacementHex);
lblExpires.Caption := Effect.ApprovalExpiresAt;
btnApprove.ModalResult := mrYes;
btnReject.ModalResult := mrNo;
```

The form receives a trusted Effect object, never editable text from MCP. It shows source, target, risk, exact before/after values and expiry. Closing the window rejects. The settings form exposes only Enable MCP, port, status, token rotation, audit location and Emergency Stop; it never displays the token.

- [ ] **Step 4: Connect approval decisions to durable state**

```pascal
if ApprovalForm.ShowModal = mrYes then
  Decision := BuildLocalDecision(Effect, Clock.UtcNowIso8601, 60, 1)
else
  Decision := BuildLocalRejection(Effect, Clock.UtcNowIso8601);
Store.SaveApproval(Decision);
```

- [ ] **Step 5: Run UI binding and headless governance tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ui_approval_binding.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_governance_services.pas
```

Expected: binding test passes and no MCP method can create a local-origin approval.

### Task 6: Debug/script gates and Cheat Engine composition root

**Files:**
- Modify: `src/domain/ce/cea_ce_debug_adapter.pas`
- Modify: `src/domain/ce/cea_ce_script_adapter.pas`
- Create: `src/domain/ce/cea_script_static_analysis.pas`
- Modify: `integration/cheat-engine/ce_agent_registration.pas`
- Modify: `Cheat Engine/cheatengine.lpr`
- Modify: `Cheat Engine/cheatengine.lpi`
- Create: `tests/pascal/test_script_static_analysis.pas`
- Create: `tests/integration/test-ce-runtime.ps1`
- Modify: `tests/acceptance/requirements-traceability.md`

**Interfaces:**
- Consumes: governed Effect execution and CE main-thread queue.
- Produces: operational registration/unregistration, approved debug actions and approved safe AA/Lua execution.

- [ ] **Step 1: Write failing prohibited-script tests**

```pascal
Assert(Analyzer.Analyze('lua', 'os.execute("cmd")').Code = rcPolicyDenied);
Assert(Analyzer.Analyze('lua', 'getInternet().getURL("https://x")').Code = rcPolicyDenied);
Assert(Analyzer.Analyze('aa', 'loadLibrary(test.dll)').Code = rcPolicyDenied);
Assert(Analyzer.Analyze('aa', 'alloc(newmem,2048)'+LineEnding+'registersymbol(newmem)').Code = rcOk);
```

- [ ] **Step 2: Run and verify analyzer absence**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_script_static_analysis.pas
```

Expected: compile failure for missing analyzer.

- [ ] **Step 3: Implement conservative capability analysis**

```pascal
DeniedLua := ['os.execute', 'io.', 'package.loadlib', 'require',
  'getInternet', 'createProcess', 'shellExecute', 'loadModule'];
DeniedAA := ['loadlibrary', 'createthread', 'luacall', 'kernelmode',
  'dbk', 'openprocess'];
```

Normalize comments and casing before matching, parse bracketed Lua sections separately, reject dynamic string construction around sensitive names, and return declared capabilities plus script hash. Ambiguity is denied.

- [ ] **Step 4: Register and stop the runtime from `cheatengine.lpr`**

```pascal
var
  AgentRegistration: TCEAResult;

begin
Application.CreateForm(TMainForm, MainForm);
AgentRegistration := RegisterCheatEngineAgent(MainForm);
if AgentRegistration.Code <> rcOk then
  OutputDebugString(PChar('Local governance services disabled: ' + AgentRegistration.MessageText));
try
  Application.Run;
finally
  UnregisterCheatEngineAgent;
end;
```

Add only the required `cheat-engine-agnet` unit paths to every active Lazarus build mode. Registration builds all concrete dependencies, installs the queue pump using `Application.QueueAsyncCall` or a short LCL timer, and keeps MCP disabled until the user enables it. Unregistration performs local governance services emergency stop before CE globals are destroyed.

- [ ] **Step 5: Build Cheat Engine and run the adapter acceptance harness**

```powershell
& 'C:\lazarus\lazbuild.exe' '.\Cheat Engine\cheatengine.lpi' --build-mode='Release 64-Bit'
powershell -NoProfile -ExecutionPolicy Bypass -File .\cheat-engine-agnet\tests\integration\test-ce-runtime.ps1
```

Expected: CE starts with MCP disabled, enabling it exposes health/read tools, the self-target passes attach/read/scan/approved-write/readback, prohibited scripts are denied, and shutdown leaves no listener or worker.

### Task 7: Authorized offline-process checkpoint

**Files:**
- Create: `tests/manual/authorized-offline-checklist.md`
- Modify: `docs/delivery/verification-report.md`
- Modify: `docs/delivery/remaining-boundary.md`

**Interfaces:**
- Consumes: a user-selected single-player offline process and completed automated self-target tests.
- Produces: signed manual evidence containing hashes and result IDs, without sensitive memory dumps.

- [ ] **Step 1: Record the exact manual prerequisites**

```text
[ ] Network/multiplayer features are closed or disabled.
[ ] The operator owns or controls the target and authorizes debugging.
[ ] The selected PID, executable hash and start time match the CE approval dialog.
[ ] The requested address belongs to a disposable test value or save-backed state.
[ ] Emergency Stop is visible and enabled.
```

- [ ] **Step 2: Execute read-only identification first**

```text
cea.list_processes -> choose target in CE UI
cea.attach_process -> capture ProcessIdentity and Epoch
cea.read_memory -> read at most 64 bytes from the selected test address
cea.disassemble -> optional, at most 32 instructions
```

Expected: target is classified `single_player_offline` by local attestation and policy; otherwise stop with `target_not_offline`.

- [ ] **Step 3: Execute one content-bound write**

```text
cea.request_memory_write(expected_original_bytes, replacement_bytes)
CE local approval dialog -> approve once
cea.get_effect_status(effect_id)
```

Expected: `applied`, one Receipt, one passing Proof and matching readback. Any uncertainty ends the test as `unknown` without retry.

- [ ] **Step 4: Restore through a new approved Effect and stop**

```text
cea.request_memory_write(expected_original_bytes=replacement,
                         replacement_bytes=original)
CE local approval dialog -> approve once
cea.emergency_stop
```

Expected: original value is restored, both Effects remain in audit history, all leases are revoked and MCP rejects new Effect requests.

- [ ] **Step 5: Update evidence and boundaries**

```powershell
rg -n "Receipt|Proof|ProcessIdentity|single_player_offline|unknown" `
  .\cheat-engine-agnet\docs\delivery\verification-report.md `
  .\cheat-engine-agnet\tests\manual\authorized-offline-checklist.md
```

Expected: evidence contains identifiers and hashes but no raw token, API secret, full path or unnecessary memory dump.

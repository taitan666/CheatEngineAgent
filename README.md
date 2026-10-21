# CheatEngineAgent

CheatEngineAgent is a Windows-first, AgentOS-governed Game Reverse Agent built as an independent Lazarus/Free Pascal application. Cheat Engine 7.5 is an upstream reference, not the application host. It targets only offline single-player processes that the operator is authorized to debug.

The product core models bounded reverse experiments, hypotheses, evidence, candidate locations, verification and reusable recipes. The native CE AI workbench is the primary first-stage surface; loopback MCP is a secondary control and diagnostic adapter. Android is a later, separate host that will share frozen domain contracts after the Windows acceptance gate.

Current implementation is partial. The independent application builds to `dist/CheatEngineAgent.exe`; AgentOS contracts, SQLite state/governance storage, schema validation, authenticated loopback MCP over HTTP, real Win32 read/background-scan/minimal-disassembly, locally approved compare-write-readback effects, crash-window/Unknown reconciliation, durable Approval/Receipt/Proof records, emergency stop, provenance-bound local CT parsing/index/GCM-style fuzzy search/RAG, CT catalog-evidence bridging, bounded freeze sessions, and OpenAI-compatible plus Anthropic-compatible WinHTTP LLM clients with Windows Credential Manager entry have executable Pascal implementations. Read-only value scans support one explicit span or up to 128 locally authorized, sorted, non-overlapping ranges. The native workbench can build those ranges from process-level `private` memory by default; `image` and `mapped` memory require explicit selection. Planning and scanning share the 512 MiB/30-second/10,000-result/4,096-region ceilings, and planning truncation remains visible as partial coverage. CT retrieval includes the approved lightweight offline path for common Chinese cheat terms: full pinyin, initials, and deterministic pinyin token-set ranking with no external embedding or model training; it is not a general-purpose Chinese transliterator or neural semantic model. LLM calls enforce prompt/RAG/output budgets before secret resolution, preserve actual provider token usage, reject total-token overruns, expose UI cancellation, never retry timeout/cancellation, and support SSE delta output on a thread-safe native workbench path for both adapters. A format-agnostic save workbench now supports bounded read-only snapshots and locally approved, create-new verified backups; its only write-capable Codec is the project's own `CEA-SAVE-1` fixture format, with separately approved edit and restore Effects. Unknown or real-game formats are read-only/backup-only. Live third-party-provider validation, complete native workbench acceptance and Android host are not complete, so the project does not yet claim a production release.

The authoritative architecture is [Game Reverse Agent rebaseline](docs/superpowers/specs/2026-09-13-game-reverse-agent-rebaseline.md), with execution order in the [rebaseline roadmap](docs/superpowers/plans/2026-09-13-game-reverse-agent-rebaseline-roadmap.md).

The product-level integration of field sampling, true pre/post event capture, state-triggered AI wake-up, the secondary-screen UI, and reusable Game Profiles is specified in [Event-driven Game Companion](docs/superpowers/specs/2026-10-21-game-companion-event-loop.md), with a staged [implementation plan](docs/superpowers/plans/2026-10-21-game-companion-event-loop.md). These documents explicitly distinguish existing code from unfinished acceptance work; they do not change the current release or safety claims.
The save extension is specified in [game companion save architecture](docs/superpowers/specs/2026-09-19-game-companion-save-architecture.md) and [its implementation plan](docs/superpowers/plans/2026-09-19-format-agnostic-save.md). Real-game write support needs a separately verified game/version Codec and an authorized sample; it is not inferred from the fixture tests.
The fixture edit/restore flow remains experimental: Windows pathname replacement is not yet an atomic compare-by-file-ID operation under adversarial concurrent changes, and a local owner can delete a read-only backup. See the [verification report](docs/delivery/verification-report.md) before using any write capability.

The [save discovery plan](docs/superpowers/plans/2026-09-20-save-discovery.md) and [Windows release-safety plan](docs/superpowers/plans/2026-09-20-windows-release-safety.md) are implemented. The native save tab supports player-authorized, bounded background metadata discovery, candidate inspection, cancellation and revocation; it never performs startup/full-disk search and MCP cannot authorize a directory. The About/Security tab shows the running EXE hash, internal channel and read-only Authenticode status. See the [release playbook](docs/delivery/windows-release-playbook.md). These features grant neither real-game write support nor public-release approval.

## Permanent boundaries

- CT learning is provenance-bound parsing, indexing, retrieval, and RAG only.
- Model training, fine-tuning, weight mutation, and weight writeback are permanently denied.
- Multiplayer targeting, anti-cheat bypass, concealment, and kernel-driver access are denied.
- Downloaded CT files are untrusted observations and are never executed automatically.
- Memory writes, debug changes, and AA/Lua execution require an AgentOS Effect and approval.

## Layout

- `bootstrap/`: ProjectBootstrap, ApplicationDescriptor, and resolved Lite FeatureSet.
- `schemas/`: JSON Schema 2020-12 contracts.
- `src/`: Pascal contracts, implemented foundations, and incomplete adapter shells.
- `integration/`: Cheat Engine and GCM-style catalog integration boundaries.
- `config/`: immutable deny and memory-effect policies.
- `tests/`: harmless CT fixtures, contract examples, and acceptance scenarios.
- `docs/`: architecture, decisions, source analysis, verification, and remaining boundaries.
- `vendor/sqlite3/`: the bundled SQLite runtime DLLs (public domain upstream).

Run the local validation with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
```

## Release build and portable mode

`build\build-release.ps1` drives the FPC compiler directly (no `lazbuild`), writes `dist\CheatEngineAgent.exe`, copies the bundled `sqlite3.dll`, and emits `dist\release-manifest.json` with the SHA-256 and length of every shipped file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-release.ps1 -Version 0.1.0
```

By default the application keeps its seven SQLite databases under `%APPDATA%\CheatEngineAgent`. Pass `--data-dir <path>` to keep them next to a chosen directory instead (portable mode):

```powershell
.\dist\CheatEngineAgent.exe --data-dir .\data
```

`--self-test` starts the runtime, calls `cea.health` over the in-process MCP dispatcher and exits with `0` on success (`20` when startup fails, `21` when the health call does not report `ready`, `22` when the data directory cannot be created). It is the headless smoke test used for release builds:

```powershell
.\dist\CheatEngineAgent.exe --self-test --data-dir .\dist\_selftest
```

Release artifacts are unsigned. Windows SmartScreen will warn, and no Authenticode chain is claimed.

## Codex MCP connection

The project-scoped `.codex/config.toml` registers the standalone application at `http://127.0.0.1:32145/mcp`. A validated Codex plugin package is also kept in `tools/codex-mcp/plugin`; the personal plugin `cheat-engine-agent@personal` can be installed from that package and uses the same environment-only credential reference. Build the application, create or rotate the bearer token, and start it with:

```powershell
.\build\build-standalone-app.ps1
.\tools\codex-mcp\configure-codex-mcp.ps1 -StartApplication
```

The script stores the token in the current Windows user's environment, never in the repository, plugin, or console output. Restart Codex after token configuration or plugin installation so the new task inherits `CEA_MCP_TOKEN` and loads the plugin MCP tools. The app must already be running before the MCP client connects. To remove the saved token:

```powershell
.\tools\codex-mcp\configure-codex-mcp.ps1 -Remove
```

## Gate 4a numeric scan (partial acceptance)

On the native Process page, attach only an authorized offline single-player process. Either enter an explicit address span or explicitly choose a process region set: `private` by default, with `image` and `mapped` opt-in. The planner produces at most 128 sorted, non-overlapping ranges under a 512 MiB total budget; the scanner also enforces 30 seconds, 10,000 candidates, 4,096 regions and 1 MiB per Windows read. Change the observed value in the game and use **按新值复筛** after the state becomes ready; **结束扫描会话** cancels/releases the candidate session. Byte/region truncation and unreadable candidates remain visible as partial coverage and never prove that the value is absent from the process.

The scan runs on a worker, exposes immutable running/ready/partial status, and observes cancellation at bounded scan checkpoints. For a separate MCP-driven scan, the native operator must first authorize the exact read-only range set and budget; MCP cannot create or expand that scope. A real self-process test covers scoped MCP start/refine/status/cancel and refusal of revoked, overlapping, over-budget and stale-Epoch requests. The production scanner has also completed a full 512 MiB run under its 30-second ceiling and a forced 1 ms `time_limit` run. The Codex plugin is installed and its package plus direct HTTP `cea.health` call are verified, but this already-running task cannot acquire a refreshed native tool catalog. A new Codex task after restart, native UI clicking and a fresh real-game acceptance run remain required. See the [Gate 4a plan](docs/superpowers/plans/2026-09-20-live-game-value-scan.md) and [verification report](docs/delivery/verification-report.md) before treating results as game evidence.

## AgentOS conformance

This project targets AgentOS Core contracts (`spec_version 1.18-draft`). Coverage is measured, not assumed: structure level, protocol level and runtime level are tracked and reported separately, and nothing is reported as passing before it has been verified. The measured baseline and the phased plan are in the [AgentOS 1.18-draft conformance transformation plan](docs/agentos-conformance-transformation-plan.md). The project does not currently claim conformance at any of the three levels.

## License

MIT — see [LICENSE](LICENSE). Third-party attribution and the boundary for upstream Cheat Engine / Game Cheats Manager material are recorded in [LICENSE-NOTICE.md](LICENSE-NOTICE.md).

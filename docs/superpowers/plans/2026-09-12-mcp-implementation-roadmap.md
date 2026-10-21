# Cheat Engine Agent MCP Implementation Roadmap

> Status update (2026-09-13): retained as a subordinate MCP work plan. Product architecture and execution order are governed by `2026-09-13-game-companion-roadmap.md`. MCP is now a secondary adapter, not the product core.

This roadmap decomposes the approved MCP design into independently testable plans. Execute them in this order:

1. `2026-09-12-cheat-engine-agent-mcp-design.md` — MCP protocol, loopback authentication, local governance boundaries, and health-check acceptance.
2. `2026-09-12-cheat-engine-runtime-adapters.md` — command queue, process identity, real CE reads/scans, locally approved writes, UI and main-program composition.
3. `2026-09-12-ct-rag-llm-codex-integration.md` — safe CT parsing/index/retrieval, OpenAI-compatible client, credential helper, project configuration and live Codex calls.

The first plan is a strict dependency of the other plans. In the third plan, CT Tasks 1–3 may proceed alongside CE adapter work after the shared contracts settle; live Codex verification waits for all earlier tasks.

No plan authorizes multiplayer or online targeting, anti-cheat bypass, kernel/DBK use, concealment, model training, fine-tuning or weight mutation.

## Specification coverage

| MCP design section | Implementation plan coverage |
|---|---|
| Goals and permanent boundaries | Foundation global constraints and Task 3; adapter global constraints; CT/LLM global constraints and Task 4 |
| Streamable HTTP and authentication | Foundation Tasks 4–6; integration Task 5 |
| Component structure and CE thread ownership | Foundation Tasks 2–6; adapter Task 1 |
| MCP tool surface | Foundation Task 4; adapter Tasks 2–6; CT/LLM Tasks 1–4 |
| Effect/approval state flow | Foundation Task 3; adapter Tasks 4–5 |
| Process identity and target admission | Adapter Tasks 2 and 7 |
| CT RAG | CT/LLM Tasks 1–3 |
| LLM client and no-weight-mutation rule | CT/LLM Task 4 |
| Stable error model | Foundation Tasks 1 and 4 |
| Codex project configuration | CT/LLM Task 5 |
| Pre-restart and post-restart verification | Foundation Task 6; adapter Tasks 6–7; CT/LLM Task 6 |
| Non-goals and completion definition | All global constraints; CT/LLM Task 6 final verification |

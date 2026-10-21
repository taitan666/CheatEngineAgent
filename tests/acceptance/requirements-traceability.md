# Requirements traceability

| Requirement | Design/document | Schema/config | Pascal boundary | Acceptance evidence | Status |
|---|---|---|---|---|---|
| Embedded single-process modular architecture | `docs/architecture/system-overview.md`, ADR 0001 | `bootstrap/application-descriptor.yaml` | `cea_runtime.pas`, `ce_agent_registration.pas` | scaffold acceptance | scaffolded |
| Real process attachment in phase 1 | `docs/architecture/ce-runtime-integration.md` | `ce-domain/process.schema.json` | `ICEProcessPort`, `TCEProcessAdapter` | CE-01 | interface only |
| Scan/read/disassemble | CE runtime integration | memory/scan schemas | `IMemoryPort`, `TCEMemoryAdapter` | CE-01/CE-02 | interface only |
| Governed memory writes | security/governance, failure/recovery | `effect.schema.json`, `memory.schema.json`, `memory-effects.yaml` | `TCEAExecutionKernel.WriteMemory` | CE-03, POL-03 | interface only |
| GCM-style CT discovery | GCM source analysis | `catalog-source.schema.json` | `TCTCatalog` | CT-01 | interface only |
| CT XML deep parsing | CT RAG pipeline | `cheat-table.schema.json` | `TCTParser` | harmless CT fixtures | interface only |
| Bilingual/pinyin/fuzzy/vector retrieval | CT RAG pipeline | `search.schema.json` | `TCTHybridSearch` | CT-02 | interface only |
| Provenance-bound RAG | CT RAG pipeline | `rag-context.schema.json` | `ICTKnowledgePort` | CT-02 | interface only |
| Provider-neutral LLM | system overview | provider/model/tool schemas | `ILLMProvider`, `TOpenAICompatibleProvider` | LLM-01 | interface only |
| Never train or modify model weights | ADR 0002 | `no-model-training.yaml`, denied FeatureSet | governance permanent deny | SAFE-02, POL-04 | enforced in scaffold policy/contracts |
| Single-player only | ADR 0003 | `single-player-only.yaml`, denied FeatureSet | governance permanent deny | SAFE-01, POL-01/02 | enforced in scaffold policy/contracts |
| No anti-cheat/kernel behavior | security/governance | policy hard denies | governance permanent deny | POL-05 | enforced in scaffold policy/contracts |
| Durable evidence/effect semantics | kernel boundaries, state machines | AgentOS core schemas | State/Governance/Execution kernels | schema checker | scaffolded |

“Interface only” means the contract and inert class exist but no operating-system or Cheat Engine call has been implemented.


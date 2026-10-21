# ADR 0001: Single-process modular architecture

**Decision:** Compile AgentOS kernels and adapters into Cheat Engine while enforcing port boundaries.

**Reason:** The user requires native CE integration. Interfaces preserve testability and prevent Core from depending on CE globals.

**Rejected:** A sidecar service and a plugin ABI split.


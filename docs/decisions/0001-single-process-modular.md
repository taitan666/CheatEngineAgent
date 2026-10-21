# ADR 0001: Single-process modular architecture

**Decision:** Keep the application's local governance services and adapters in one process while enforcing explicit port boundaries.

**Reason:** The user requires native CE integration. Interfaces preserve testability and prevent Core from depending on CE globals.

**Rejected:** A sidecar service and a plugin ABI split.


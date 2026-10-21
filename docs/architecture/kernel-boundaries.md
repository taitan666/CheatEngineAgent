# Kernel boundaries

## State Kernel

Owns versioned tasks, observations, facts, artifacts, proofs, commits, events, work ledgers, and projections. It never calls a model or CE API.

## Governance Kernel

Owns identity, policy, authority, Lease, approval, risk, budget, and disclosure decisions. Models and CT content cannot issue authority.

## Execution Kernel

Owns Epoch, bounded dispatch, Effect/Outbox, Receipt, cancellation, explicit recovery, and reconciliation. Only one authoritative executor is admitted in the first phase.

Adapters implement ports declared in `src/contracts/cea_ports.pas`. Dependencies point from adapters toward contracts; Core has no dependency on UI, CE globals, Windows APIs, HTTP, or SQLite.


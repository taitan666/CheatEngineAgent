# Security and governance

The trust boundary contains identity, policy/authority, Lease and Commit verification, controlled effect exits, the SQLite ledger, and recovery records. Plugins and model output cannot modify this boundary.

Immutable project denies cover non-single-player targets, anti-cheat bypass, kernel access, arbitrary CT network/filesystem/subprocess behavior, and every form of model training or weight mutation. Unknown target classification denies writes.

Secrets are referenced through a secret-store URI and are never stored in provider YAML, prompts, logs, receipts, or RAG documents. Model disclosure is limited to task-relevant metadata and bounded memory observations approved by policy.


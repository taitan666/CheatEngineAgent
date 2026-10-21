# ADR 0002: RAG only, never model training

**Decision:** CT learning means provenance-bound parsing, indexing, retrieval, and contextual inference only.

Fine-tuning, online training, dataset export for training, weight mutation, and weight writeback are immutable denies with no runtime override.


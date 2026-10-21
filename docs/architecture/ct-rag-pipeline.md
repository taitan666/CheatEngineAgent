# CT RAG pipeline

Sources produce immutable `CheatTableArtifact` records containing raw-byte hash, provenance, license metadata, and acquisition time. The parser emits unverified observations for game identity, compatibility, entry hierarchy, address expressions, pointer chains, AOB signatures, and AA/Lua scripts.

Validators promote only supported claims into facts and search documents. Retrieval applies hard process/module/version compatibility before exact identity, bilingual alias, pinyin, acronym, fuzzy lexical, and vector semantic ranking. Vector similarity cannot override a compatibility failure.

RAG contexts enumerate source refs, content hashes, parser/validator versions, scores, truncation, and confidence. CT content remains data, never instruction or authority. No parsing or retrieval output is used for model training or weight changes.


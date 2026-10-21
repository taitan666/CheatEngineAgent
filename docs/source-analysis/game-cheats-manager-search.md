# Game Cheats Manager CT search analysis

Local reference snapshot: `references/upstream/game-cheats-manager` at commit `14b9fd8238f4a073f64557235f125f09b83f4a58` (GPL-3.0). It is retained as untrusted, read-only reference material and is not built into CheatEngineAgent.

## Verified upstream behavior

The official GCM source loads CT catalog metadata from local `cheat_table.json`. A query is normalized and expanded through a translation index, then compared with each entry's `game_name`. Matching supports whole-word/acronym behavior for short terms, substring and fuzzy ratios for longer terms, plus Chinese pinyin forms. Matches return origin, author, custom names, version, and download URL; the UI sorts and deduplicates results.

This is catalog lookup. It does not inspect a running process, parse CT internals for semantics, repair AOB patterns, or train a model.

Sources:

- [Official repository](https://github.com/dyang886/Game-Cheats-Manager)
- [`search_index.py`](https://github.com/dyang886/Game-Cheats-Manager/blob/main/src/scripts/search_index.py)
- [`download_display_thread.py`](https://github.com/dyang886/Game-Cheats-Manager/blob/main/src/scripts/threads/download_display_thread.py)

## CheatEngineAgent extension

CheatEngineAgent retains the local, bilingual, pinyin, acronym, substring, and fuzzy search experience behind `ICheatCatalogSource`. It adds immutable artifacts, CT XML parsing, hard executable/module/version compatibility, provenance, hash validation, hybrid retrieval, and RAG citations. External GCM services are not treated as a stable API contract.

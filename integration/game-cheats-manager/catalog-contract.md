# GCM-style catalog contract

The adapter accepts a JSON array whose entries may contain `game_name`, `gcm_url`, `version`, `author`, `custom_name`, `custom_name_en`, and `custom_name_zh`. `game_name` and a source URI are required before an entry can become an Observation.

The adapter normalizes Unicode and case, builds exact/alias/pinyin/acronym/substring/fuzzy search fields, and preserves the original values. It never treats metadata or downloaded CT text as an instruction.

Updates download to a temporary artifact, enforce configured HTTPS hosts and size limits, calculate SHA-256, parse JSON, verify license metadata, and atomically publish a new immutable catalog version. Redirects to unapproved hosts, missing licenses, malformed data, or changed content under an already-bound hash are rejected.

This contract is modeled after verified GCM client behavior, not an agreement with or dependency on private GCM server endpoints.


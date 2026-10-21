# SQLite runtime dependency

These DLLs are the SQLite shared library used by the standalone application's
`TCEASqliteStore` (via FPC's `SQLite3Conn`).

- `sqlite3.dll`    — 64-bit (x86_64-win64), 1,311,232 bytes
- `sqlite3-x86.dll` — 32-bit (i386-win32), 569,856 bytes (kept for reference;
  the standalone app currently targets 64-bit only)

## Source

Copied out of the upstream Cheat Engine 7.5 tree
(`Cheat Engine\bin\win64\sqlite3.dll` / `Cheat Engine\bin\win32\sqlite3.dll`)
before that tree was removed from this repository.

## License

SQLite is in the public domain. See https://www.sqlite.org/copyright.html

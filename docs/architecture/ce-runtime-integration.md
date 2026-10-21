# CE runtime integration

Future CE adapters wrap process enumeration/attachment, `TMemScan`, address parsing, memory access, disassembly, debugger state, AutoAssembler, Lua, and CT load/save behind narrow ports.

Every attachment produces a `ProcessIdentity` containing PID, start time, executable path digest, executable hash, architecture, module-set digest, and Epoch. A changed identity invalidates addresses, scan results, and Leases.

Read-only calls still require scope and budget. Writes, freezes, breakpoint changes, AA/Lua execution, and auto-executing CT loads are Effects requiring content-bound approval and readback Proof. DBK, kernel access, anti-cheat bypass, concealment, and multiplayer targets are denied.


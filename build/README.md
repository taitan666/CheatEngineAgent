# Build integration

The files in `unit-manifest.txt` are ordered by conceptual dependency. This scaffold intentionally provides no Lazarus package or project patch because the existing Cheat Engine tree must remain untouched during the architecture delivery.

Before operational implementation, create a dedicated build target that adds the listed unit directories, compiles all units with the same FPC mode as Cheat Engine 7.5, and injects concrete adapters only through `ce_agent_registration`.


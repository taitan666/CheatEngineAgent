# Contract fixtures

Positive fixtures represent the smallest accepted shapes for Task, Effect, and CheatTableArtifact. Negative fixtures each isolate one rejection: finished task without outcome, memory write without approval, and provider configuration containing an inline secret.

The bundled PowerShell checker verifies fixture intent and project invariants. A complete JSON Schema 2020-12 implementation must later execute these fixtures directly against their schemas.


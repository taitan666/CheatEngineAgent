# Schema checker

`check-schemas.ps1` is an offline structural checker. It verifies JSON syntax, JSON Schema dialect and IDs, duplicate IDs, local references, manifest coverage, negative-fixture intent, immutable deny policies, unit-manifest coverage, and inert Pascal source.

It does not implement the complete JSON Schema 2020-12 evaluation vocabulary. Production runtime integration must select and qualify a conforming validator before accepting external data.


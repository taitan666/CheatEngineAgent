# Failure and recovery

- PID reuse or process restart invalidates ProcessIdentity, Epoch, Lease, scan results, and addresses.
- AOB zero/multiple matches produce fail/inconclusive Proof and stop execution.
- A write stores expected original bytes, performs the effect, and reads back. Mismatch fails; inability to determine the outcome records unknown.
- AA/Lua static analysis rejects undeclared or prohibited capabilities before approval.
- CT synchronization validates a temporary artifact and atomically publishes a new immutable index version.
- Provider timeout records the provider request ID and disclosure/cost state; it never replays an effectful tool call.
- Emergency stop first prevents new Effects and revokes business Leases, then persists in-flight recovery responsibility before session cancellation.

Resume rechecks TaskContract, Epoch, policy, budget, process identity, and unsettled Effects. Automatic recovery is not enabled in the Lite FeatureSet.


# Dialyzer Error Dashboard

The initial Dialyzer pass reported **16 issues** across **7 source files**.  
Our goal is to reduce this count to **0**.

---

## Error Matrix

| # | File | Errors (count) | Types |
|---|------|---------------|-------|
| 1 | `lib/jido_signal/bus/bus_snapshot.ex` | **1** | `unknown_type` |
| 2 | `lib/jido_signal/bus/bus_state.ex` | **3** | `pattern_match_cov` × 3 |
| 3 | `lib/jido_signal/bus/bus_subscriber.ex` | **2** | `call`, `pattern_match_cov` |
| 4 | `lib/jido_signal/bus/persistent_subscription.ex` | **1** | `guard_fail` |
| 5 | `lib/jido_signal/error.ex` | **4** | `call`, `no_return` × 3 |
| 6 | `lib/jido_signal/router.ex` | **1** | `pattern_match_cov` |
| 7 | `lib/jido_signal/router/validator.ex` | **4** | `pattern_match_cov` × 4 |
| **—** | **Total** | **16** | — |

---

## Per-file Action Plans

| File | Detailed Fix Plan |
|------|-------------------|
| `bus_snapshot.ex` | [todo/bus_snapshot_dialyzer.md](bus_snapshot_dialyzer.md) |
| `bus_state.ex` | [todo/bus_state_dialyzer.md](bus_state_dialyzer.md) |
| `bus_subscriber.ex` | [todo/bus_subscriber_dialyzer.md](bus_subscriber_dialyzer.md) |
| `persistent_subscription.ex` | [todo/persistent_subscription_dialyzer.md](persistent_subscription_dialyzer.md) |
| `error.ex` | [todo/error_dialyzer.md](error_dialyzer.md) |
| `router.ex` | [todo/router_dialyzer.md](router_dialyzer.md) |
| `router/validator.ex` | [todo/router_validator_dialyzer.md](router_validator_dialyzer.md) |

---

## Completion Checklist

Tick each box **after** the fix PR is merged and Dialyzer reruns clean for that file.

- [ ] 1. `bus_snapshot.ex` fixed (unknown type removed)
- [ ] 2. `bus_state.ex` fixed (3 unreachable-pattern errors)
- [ ] 3. `bus_subscriber.ex` fixed (spec mismatch & unreachable pattern)
- [ ] 4. `persistent_subscription.ex` fixed (invalid guard)
- [ ] 5. `error.ex` fixed (add `:bad_request` type, remove no_return)
- [ ] 6. `router.ex` fixed (unreachable clause)
- [ ] 7. `router/validator.ex` fixed (4 unreachable clauses)
- [ ] **Dialyzer passes with 0 errors**

---

## Next Steps for Sub-agents

1. **Claim a file** from the checklist and follow its detailed plan.  
2. Open a focused branch/PR per file.  
3. Run locally:

   ```bash
   mix compile
   mix dialyzer --format dialyxir
   ```

   Ensure the targeted error count drops accordingly.
4. After **all boxes** are ticked, run a final:

   ```bash
   mix dialyzer --format dialyxir
   ```

   The output should report **0 errors, 0 warnings**.  
5. Update this dashboard, commit, and close the Dialyzer cleanup task.

Happy hunting! 🛠️

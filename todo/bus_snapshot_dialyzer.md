# Dialyzer Fix Plan – `lib/jido_signal/bus/bus_snapshot.ex`

## Problem summary
```
lib/jido_signal/bus/bus_snapshot.ex:78:59:unknown_type
Unknown type: Jido.Signal.Bus.Signal.t/0
```

Dialyzer cannot find a type called `Jido.Signal.Bus.Signal.t/0`.  
There is **no module** `Jido.Signal.Bus.Signal` in the code-base, so every spec that refers to that type is invalid.

## Root cause
When `BusSnapshot` was written the author meant to reference the main signal struct (`Jido.Signal`) or the already-defined recorded wrapper (`Jido.Signal.Bus.RecordedSignal`). Using a non-existent module silently compiles, but Dialyzer flags it.

## Fix

1. **Open** `lib/jido_signal/bus/bus_snapshot.ex`.
2. **Locate** every type reference to `Jido.Signal.Bus.Signal.t()` (currently at, or near, line 78 in the `typedstruct` declaration).
3. Decide which real struct should be stored in a snapshot:
   * If the snapshot captures *raw* signals → use `Jido.Signal.t()`
   * If it captures *recorded* signals (includes metadata) → use `Jido.Signal.Bus.RecordedSignal.t()`
4. **Update the type spec** accordingly.

Example – choosing raw signals:

```elixir
# before
typedstruct do
  field :signals, [Jido.Signal.Bus.Signal.t()], default: []
end

# after
alias Jido.Signal, as: Signal   # add near top of file

typedstruct do
  field :signals, [Signal.t()], default: []
end
```

If you need recorded signals use:

```elixir
alias Jido.Signal.Bus.RecordedSignal, as: RecordedSignal
...
field :signals, [RecordedSignal.t()], default: []
```

5. **Remove** any stray alias to the non-existent module so future imports don’t regress.
6. **Recompile**:

```bash
mix compile
```

7. **Re-run Dialyzer**:

```bash
mix dialyzer --format dialyxir
```

The `unknown_type` error for this file should disappear.  

---

### Verification checklist for the sub-agent

- [ ] Correct type alias added (`alias Jido.Signal, as: Signal` **or** `RecordedSignal`).
- [ ] All occurrences of `Jido.Signal.Bus.Signal` replaced.
- [ ] File compiles without warnings.
- [ ] `mix dialyzer --format dialyxir` shows **zero** errors for `bus_snapshot.ex`.

_Assignee suggestion: **TypeFixAgent** (focus on spec corrections)._

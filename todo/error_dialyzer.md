# Dialyzer Fix Plan – `lib/jido_signal/error.ex`

Dialyzer reports **four problems** in this module:

| Line | Kind      | Function | Message (abridged) |
|------|-----------|----------|--------------------|
| 148  | `no_return` | `bad_request/1` | Function has no local return |
| 148  | `no_return` | `bad_request/2` | Function has no local return |
| 148  | `no_return` | `bad_request/3` | Function has no local return |
| 149  | `call`      | `bad_request/*`  | `Jido.Signal.Error.new/4` called with `:bad_request` – **type not allowed** |

---

## 1. Why Dialyzer complains

### a) Missing `:bad_request` in `@type error_type`

```elixir
@type error_type ::
        :validation_error
        | :execution_error
        | :planning_error
        | :timeout
        | :routing_error
        | :dispatch_error
```

`bad_request/1-3` call:

```elixir
new(:bad_request, message, details, stacktrace)
```

Since `:bad_request` is **not** a member of `error_type`, Dialyzer flags the
invocation (`call` error) and then concludes the helpers cannot return a value
that matches their own `@spec`, hence the three `no_return` warnings.

### b) Cascade into `no_return`

Because the call contract is violated, Dialyzer marks `new/4` as never
successfully returning when invoked from the helpers, producing three
`no_return` errors.

---

## 2. Fix

| Step | Action |
|------|--------|
| 1 | **Add `:bad_request` to `@type error_type`** list. |
| 2 | Ensure the `typedstruct` field `:type` spec still references `error_type/0` (it will now include `:bad_request`). |
| 3 | No changes needed to `new/4`; once the union includes `:bad_request` the call is valid. |
| 4 | Keep the `@spec bad_request/3` as-is (`t()` return) – it will now be satisfied. |
| 5 | Re-compile and re-run Dialyzer – all four errors disappear. |

**Patch sketch**

```diff
 @type error_type ::
         :validation_error
+        | :bad_request
         | :execution_error
         | :planning_error
         | :timeout
         | :routing_error
         | :dispatch_error
```

_No other code changes required._

---

## 3. Verification Checklist

- [ ] `:bad_request` added to `error_type`.
- [ ] File compiles: `mix compile`.
- [ ] `mix dialyzer --format dialyxir` shows **no errors** for `error.ex`.
- [ ] Unit tests still pass.

---

## 4. Suggested Sub-agent

**`ErrorTypeAgent`** – update type union and run compilation/Dialyzer to confirm fix.

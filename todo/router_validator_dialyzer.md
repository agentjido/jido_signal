# Dialyzer Fix Plan – `lib/jido_signal/router/validator.ex`

Dialyzer reports **four `pattern_match_cov` warnings** in this module:

| Line | Type | Message (abridged) |
|------|------|--------------------|
|  75  | pattern_match_cov | `variable_error` can never match – previous clauses cover the type |
|  85  | pattern_match_cov | idem |
|  96  | pattern_match_cov | idem |
| 113  | pattern_match_cov | idem |

`pattern_match_cov` = **pattern-match coverage**.  
Dialyzer has proven that, given the current type specification of the called functions, the highlighted clause is *unreachable* (dead code). This usually happens when a defensive “catch-all” clause (`variable_error`, `_`) remains after the “real” error clause already matches every non-success shape.

---

## How the bug appears

All four warnings occur inside small helper functions that normalize/validate router routes.  
Typical pattern:

```elixir
with {:ok, normalized} <- do_something(input) do
  {:ok, normalized}
else
  {:error, reason}      -> {:error, reason}        # expected error
  variable_error        -> variable_error          # ← unreachable
end
```

Because `do_something/1` is specced to return **only** `{:ok, _}` or `{:error, _}`, the final
`variable_error` clause is impossible to hit, so Dialyzer flags it.

---

## Fix Strategy

### 1. Remove unreachable catch-all clauses

For each of the four locations:

1. Delete the extra clause (`variable_error`, `_`, or similar).
2. If the whole `else` block contains only that clause, delete the entire block and keep the
   `with` happy path.

Example **before** (line ≈ 70-80):

```elixir
with {:ok, normalized} <- normalize_spec(spec) do
  {:ok, normalized}
else
  {:error, reason} -> {:error, reason}
  variable_error   -> variable_error      # unreachable
end
```

**After**:

```elixir
with {:ok, normalized} <- normalize_spec(spec) do
  {:ok, normalized}
else
  {:error, reason} -> {:error, reason}
end
```

Or, if failures are unexpected, bind directly and crash on invalid data:

```elixir
{:ok, normalized} = normalize_spec(spec)
{:ok, normalized}
```

### 2. Keep specs in sync

* **Do not** widen the spec just to silence Dialyzer unless the function truly can return additional shapes.
* If you *do* widen the spec of `normalize_spec/1` or similar, **keep the extra clause** and update its pattern to match the new shapes explicitly (rare).

---

## Detailed locations

| Function (approx.) | Action |
|--------------------|--------|
| **Line 75**  – `normalize/1` wrapper | Remove unreachable catch-all |
| **Line 85**  – `normalize!/1` or similar | Remove unreachable clause |
| **Line 96**  – `validate/1` helper | Remove unreachable clause |
| **Line 113** – `validate!/1` or similar | Remove unreachable clause |

---

## Verification Checklist

- [ ] All four unreachable clauses deleted **or** justified with wider specs.
- [ ] `lib/jido_signal/router/validator.ex` compiles without warnings (`mix compile`).
- [ ] `mix dialyzer --format dialyxir` no longer reports the 4 `pattern_match_cov` errors.
- [ ] Router unit tests still pass.

---

## Suggested Assignee

**RouterValidatorAgent** – focus on tidying unreachable patterns and ensuring spec/implementation alignment.

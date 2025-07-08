# Dialyzer Fix Plan – `lib/jido_signal/router.ex`

## Reported warning
```
lib/jido_signal/router.ex:701:pattern_match_cov
The pattern
  :variable_
can never match, because previous clauses completely cover the type

{:ok, [%Jido.Signal.Router.Route{path: binary(), …}]}
```

`pattern_match_cov` means **pattern–match coverage**: Dialyzer has verified that one of the clauses in a `case`, `with … do … else`, or multi-clause function can *never* be selected because the preceding clauses already exhaust every value the expression can produce.  
That clause is therefore _dead code_ and should be removed or the type specs should be widened.

---

## Root cause

At, or very close to, **line 701** the Router module handles the result of its own `Validator.normalize/1` (or similar) with code of this form:

```elixir
case Validator.normalize(input) do
  {:ok, routes} ->
    # happy path …

  {:error, reason} ->
    {:error, reason}

  variable_error ->          # <- unreachable
    variable_error
end
```

or inside a `with` expression:

```elixir
with {:ok, normalized} <- Validator.normalize(input),
     {:ok, validated}   <- validate(normalized) do
  {:ok, build_trie(validated)}
else
  {:error, reason} -> {:error, reason}
  variable_error     -> variable_error   # <- unreachable
end
```

`Validator.normalize/1` is currently **specced** to return only:

```elixir
{:ok, [Route.t()]} | {:error, term()}
```

Hence *all* non-success values are already captured by `{:error, reason}`.  
The final catch-all clause (`variable_error`, `_`, `:variable_`, etc.) can never match and Dialyzer flags it.

---

## Fix

### 1 – Delete unreachable clause(s)

Remove the extra catch-all clause (or the entire `else` block if it only contained the unreachable match).  
If you need stronger guarantees, replace the `case` with direct pattern-binding and let unexpected shapes crash loudly during tests:

```elixir
{:ok, normalized} = Validator.normalize(input)
{:ok, validated}  = validate(normalized)
{:ok, build_trie(validated)}
```

### 2 – OR widen the spec (rare)

If `Validator.normalize/1` *should* be able to return additional tuples (e.g. `{:warning, _}`), update **its** `@spec` and keep the clause.  
This is unlikely; prefer the simple removal.

### 3 – Keep consistent style

The same anti-pattern appears in other modules; adopt a consistent pattern-matching style across Router functions.

---

## Step-by-step implementation

1. Open `lib/jido_signal/router.ex`.
2. Scroll to around **line 690-710** and locate the `case`/`with`/function-clauses block that contains the unreachable pattern.
3. **Delete** the clause labelled `variable_error` (or `_`) that Dialyzer marked.
4. Ensure remaining clauses cover only the two documented return shapes:
   * `{:ok, routes}`
   * `{:error, reason}`
5. Save file.

```bash
mix compile
mix dialyzer --format dialyxir
```

The `pattern_match_cov` warning for `router.ex` should disappear, and the global error count drop by **1**.

---

## Verification checklist for the sub-agent

- [ ] Unreachable catch-all clause removed or justified with updated specs.
- [ ] `router.ex` compiles without warnings (`mix compile`).
- [ ] Dialyzer no longer reports a `pattern_match_cov` error at line 701.
- [ ] All router-related unit tests still pass.

---

## Suggested assignee

**RouterPatternAgent** – focuses on pattern-match coverage and spec alignment inside routing logic.

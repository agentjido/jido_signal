# Jido Instance Isolation Plan

**Status: ✅ IMPLEMENTED**

## Goal

Enable instance isolation where:
- **Default API** uses global supervisors (zero config, works out of the box)
- **Instance API** routes all operations through instance-scoped supervisors

```elixir
# Global (default) - uses Jido.Signal.Registry
Bus.start_link(name: :my_bus)

# Instance-scoped - uses MyApp.Jido.Signal.Registry
Instance.start_link(name: MyApp.Jido)
Bus.start_link(name: :my_bus, jido: MyApp.Jido)
```

## Pattern

- Functions with arity N use global supervisors
- Functions with arity N accept optional `jido:` option for instance scoping

## Isolation Scope

Instance-scoped resources:
- `Task.Supervisor` — async operations
- `Registry` — process lookup (Bus, etc.)
- `Ext.Registry` — signal extension lookup

## Key Invariant

When `jido: instance` is passed, **all** spawned tasks and processes route through that instance's supervisors. No silent fallback to globals within an instance context.

## Success Criteria

1. ✅ Existing code works unchanged (global supervisors)
2. ✅ Instance users get complete isolation with single `jido:` option
3. ✅ Cross-tenant signal contention eliminated
4. ✅ Easy to test isolation guarantees

## Implementation Details

### Changes Made

#### jido_signal package
- **New module**: `Jido.Signal.Names` - Resolves process names based on `jido:` option
- **New module**: `Jido.Signal.Instance` - Child spec for starting instance supervisors
- **Updated**: `Jido.Signal.Util.via_tuple/2` - Uses `Names.registry(opts)` for instance-scoped registry
- **Updated**: `Jido.Signal.Util.whereis/2` - Uses `Names.registry(opts)` for instance-scoped lookup
- **Updated**: `Jido.Signal.Bus.State` - Added `jido` field for storing instance
- **Updated**: `Jido.Signal.Bus.init/1` - Stores `jido` option in state
- **Updated**: `Jido.Signal.Ext.Registry` - Added `child_spec/1` for instance naming

### How It Works

1. When `Jido.Signal.Instance.start_link(name: MyApp.Jido)` is called, an instance supervisor starts
2. The instance supervisor starts: Registry, TaskSupervisor, and Ext.Registry with instance-scoped names
3. When `Bus.start_link(name: :my_bus, jido: MyApp.Jido)` is called, the `jido:` option is passed
4. `Util.via_tuple/2` resolves the registry name using `Names.registry(opts)`
5. Bus registers in the instance's registry instead of global
6. `Util.whereis/2` looks up in the correct registry based on `jido:` option

### Tests Added

- `test/jido_signal/instance_test.exs` - Tests `Names` module and `Instance` lifecycle
- `test/jido_signal/bus_instance_isolation_test.exs` - Tests Bus isolation between instances

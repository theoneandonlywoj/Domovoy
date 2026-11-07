# Known leak: a crashing runner or decider can write run inputs to the logs

**Status:** open. It's waiting on a fix in Domovoy Core, which stays at v0.3.4 here. Delete this file when that fix lands; [Closing this](#closing-this) lists the steps.

## What happens
When a runner raises an exception whose message holds a value, that value is written to the logs at `[error]`. Run inputs often reach exception messages, so a run input can end up in the log. On v0.3.4 the tests in [What's tested](#whats-tested) show these paths leak:

- a runner that raises, exits or throws, whether it's pure or declares no effect;
- a decider that raises.

A validator that raises doesn't leak: its crash report holds no value.

A test runner reproduces it with an input `secret`:

```elixir
def run(%Input{secret: secret}, _context), do: raise(ArgumentError, secret)
```

which logs:

```
[error] Task #PID<...> started from #PID<...> terminating
** (ArgumentError) sentinel-run-input-value
    test/support/leak_runner.ex:27: Domovoy.LeakRunner.run/2
    deps/domovoy_core/lib/domovoy_core/run/owner/dispatch.ex:1021: ...Dispatch.start_task/3
    deps/domovoy_core/lib/domovoy_core/engine/managed_task.ex:215: ...ManagedTask.gate/2
    lib/task/supervised.ex:105: Task.Supervised.invoke_mfa/2
```

It doesn't take a deliberate `raise`. Any standard-library call that names a value in its exception can do it: `Map.fetch!(@districts, district)` (`lib/domovoy/examples/cracow/market.ex:32`) raises a `KeyError` naming the key.

## Why it happens
1. Core calls the runner with no rescue: `runner.run(input, context)` (`deps/domovoy_core/lib/domovoy_core/run/owner/dispatch.ex:1055`). It calls a decider the same way (`deps/domovoy_core/lib/domovoy_core/run/answer.ex:228`).
2. Each call runs inside a managed task with no catch around it (`deps/domovoy_core/lib/domovoy_core/engine/managed_task.ex:215`).
3. The exception therefore reaches Elixir's `Task.Supervised`, which logs a `{Task.Supervisor, :terminating}` crash report holding the exception and its message.

Core v0.3.4 says this is deliberate: its docs state that the library doesn't format OTP's Task crash reports and tell hosts to filter them (`deps/domovoy_core/lib/domovoy_core/telemetry.ex:355-358`).

## What it doesn't affect
- **The run itself:** the run still ends `failed`, and its stored error keeps only the exception module, so the value isn't in the run's view or events.
- **Database query logging:** Core runs its Journal and Store queries with `log: false` (from v0.3.4), so stored inputs and outputs don't reach the logs through SQL parameters.
- **Returned errors:** a runner that returns `{:error, ...}` instead of raising leaks nothing.

## Exposure
Runs are enabled only on a local dev host (`composer_runs_enabled`), so the log stays on the developer's machine: the terminal running `iex -S mix phx.server`, or wherever its output is captured. Nothing here sends logs elsewhere. Anything that collects or forwards that output, or a future decision to enable runs outside local dev, would carry the value with it.

## Why there's no host-side workaround
A host log filter could drop or clean these reports, but it would depend on the private shape of Elixir's crash report and protect only this host. The decision was to fix it in Core, where the uncaught call lives, and to keep the host's tests honest meanwhile.

## What's tested
The log tests for crashing paths that leak today are tagged `@tag :pending_core_crash_redaction` and excluded from `mix test`, so the suite stays green and commits are possible. They aren't deleted or weakened:

```
mix test --only pending_core_crash_redaction
```

runs them, five on v0.3.4, and each fails because the sentinel appears in the log. Every other log test runs normally, including success, returned errors, database queries and the raising validator. Each crash path also has an untagged test of the run's state and view, which always runs.

## Closing this
1. Fix Core so a crashing runner, validator or decider (raise, exit or throw) leaves no input value in any log, and release it.
2. Pin the new Core version in `mix.exs` and run `mix deps.update domovoy_core`.
3. Remove `@tag :pending_core_crash_redaction` from the tests and its exclusion from `test/test_helper.exs`.
4. Run `mix test` and `mix precommit`: every leak test must pass.
5. Delete this file.

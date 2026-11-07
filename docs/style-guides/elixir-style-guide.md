# Elixir/BEAM style guide

This guide is the style reference for Elixir code in this repository. It targets the latest stable Elixir and OTP releases. Formatting is delegated to `mix format`; do not hand-format code that `mix format` already handles.

Every rule below states a strength (MUST, SHOULD, or MAY), a Good/Bad example pair, a rationale, and an exception. Treat MUST as a hard rule, SHOULD as the default with documented exceptions, and MAY as optional.

## Code organization

### Avoid circular dependencies

**Strength**: MUST

Good:
```elixir
# MyApp.Orders depends on MyApp.Users, never the reverse
```

Bad:
```elixir
# MyApp.Users calls MyApp.Orders; MyApp.Orders calls MyApp.Users
```

Rationale: cycles make compilation order fragile and modules harder to test in isolation.

You may break this when: an umbrella boundary genuinely requires it and the cycle is documented.

## Naming

### Predicate functions end in ?

**Strength**: SHOULD

Good:
```elixir
def active?(user), do: user.status == :active
```

Bad:
```elixir
def is_active(user), do: user.status == :active
```

Rationale: the `?` suffix signals a boolean return and matches standard library conventions.

You may break this when: implementing a callback whose name is fixed by a behaviour.

### Bang functions raise on failure

**Strength**: MUST

Good:
```elixir
def create!(attrs) do
  case create(attrs) do
    {:ok, value} -> value
    {:error, reason} -> raise MyApp.Error, reason
  end
end
```

Bad:
```elixir
def create!(attrs) do
  create(attrs)
end
```

Rationale: the `!` suffix promises a raised exception on failure, never a tagged tuple.

You may break this when: none.

## APIs

### Accept keyword options, not positional booleans

**Strength**: SHOULD

Good:
```elixir
def list_users(opts \\ []) do
  limit = Keyword.get(opts, :limit, 20)
  ...
end
```

Bad:
```elixir
def list_users(limit \\ 20, include_deleted \\ false) do
  ...
end
```

Rationale: keyword options are self-documenting at the call site and easy to extend.

You may break this when: a function has one or two fixed, well-known positional arguments.

### Return tagged tuples for fallible operations

**Strength**: SHOULD

Good:
```elixir
def fetch(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end
```

Bad:
```elixir
def fetch(id) do
  Repo.get(User, id) || raise "not found"
end
```

Rationale: tagged tuples compose with `with` and keep error handling explicit.

You may break this when: the operation cannot fail in practice, or a bang variant is the documented API.

## Error reporting

### Define domain errors as structs

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Error do
  defexception [:message, :reason]
end
```

Bad:
```elixir
raise "something went wrong"
```

Rationale: structured errors carry context and can be matched and logged consistently.

You may break this when: a quick script or one-off task.

### Do not rescue broad exceptions

**Strength**: MUST

Good:
```elixir
try do
  ...
rescue
  Ecto.NoResultsError -> {:error, :not_found}
end
```

Bad:
```elixir
try do
  ...
rescue
  _ -> {:error, :unknown}
end
```

Rationale: swallowing all exceptions hides bugs and breaks supervision expectations.

You may break this when: at a top-level boundary that must never crash, with logging.

### Let it crash

**Strength**: SHOULD

Good:
```elixir
def handle_call(:get, _from, state) do
  {:reply, state.value, state}
end
```

Bad:
```elixir
def handle_call(:get, _from, state) do
  try do
    {:reply, state.value, state}
  rescue
    _ -> {:reply, nil, state}
  end
end
```

Rationale: supervisors restart failed processes; defensive rescuing defeats fault isolation.

You may break this when: a single operation's failure must not take down the process.

## Macros

### Avoid macros when a function suffices

**Strength**: MUST

Good:
```elixir
def greet(name), do: "Hello, #{name}"
```

Bad:
```elixir
defmacro greet(name) do
  quote do: "Hello, #{unquote(name)}"
end
```

Rationale: macros complicate debugging, tooling and reasoning; functions are the default.

You may break this when: compile-time code generation or DSL is genuinely required.

### Quote hygiene

**Strength**: MUST

Good:
```elixir
quote do
  unquote(Macro.escape(expr))
end
```

Bad:
```elixir
quote do
  unquote(expr)
end
```

Rationale: escaping prevents variable capture and unintended evaluation.

You may break this when: none.

### Document macros

**Strength**: SHOULD

Good:
```elixir
@doc "Defines a route at compile time."
defmacro route(path, do: block) do
  ...
end
```

Bad:
```elixir
defmacro route(path, do: block) do
  ...
end
```

Rationale: macros are invisible at runtime; documentation is their only discoverable contract.

You may break this when: private macros used only within the defining module.

## Documentation

### Document public modules and functions

**Strength**: SHOULD

Good:
```elixir
@moduledoc "Public API for orders."

@doc "Creates an order from attributes."
@spec create(map()) :: {:ok, Order.t()} | {:error, term()}
def create(attrs), do: ...
```

Bad:
```elixir
defmodule MyApp.Orders do
end

def create(attrs), do: ...
```

Rationale: `@moduledoc`/`@doc` feed ExDoc and help callers use the API correctly.

You may break this when: trivial internal helpers with obvious names.

### Use typespecs on public functions

**Strength**: SHOULD

Good:
```elixir
@spec fetch(id :: pos_integer()) :: {:ok, User.t()} | {:error, :not_found}
def fetch(id), do: ...
```

Bad:
```elixir
def fetch(id), do: ...
```

Rationale: typespecs enable Dialyzer and document contracts. Name each argument in the spec (`id :: pos_integer()`) so ExDoc output and Dialyzer messages stay readable and unambiguous.

You may break this when: dynamic code where types are impractical.

## Testing

### Test the public API, not internals

**Strength**: SHOULD

Good:
```elixir
test "creates a user" do
  assert {:ok, %User{}} = Users.create(%{name: "a"})
end
```

Bad:
```elixir
test "hashes password" do
  assert Users.hash_password("secret") == ...
end
```

Rationale: testing internals couples tests to implementation and slows refactors.

You may break this when: an internal function is complex and has no public entry point.

### Avoid sleep in tests

**Strength**: MUST

Good:
```elixir
assert_receive {:done, result}, 1000
```

Bad:
```elixir
:timer.sleep(100)
assert result == :done
```

Rationale: sleeps make tests slow and flaky; message assertions are deterministic.

You may break this when: testing real timing behaviour that cannot be event-driven.

## Processes and supervision

### One responsibility per process

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Counter do
  use GenServer
  # only counts
end
```

Bad:
```elixir
defmodule MyApp.Worker do
  use GenServer
  # counts, caches, sends emails
end
```

Rationale: focused processes are easier to supervise, restart and reason about.

You may break this when: a small utility process combines trivial concerns.

### Supervise everything

**Strength**: MUST

Good:
```elixir
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Bad:
```elixir
{:ok, pid} = GenServer.start_link(MyApp.Worker, [])
```

Rationale: unsupervised processes are orphaned on failure and leak.

You may break this when: a short-lived task under a Task.Supervisor.

### Use the right supervisor strategy

**Strength**: SHOULD

Good:
```elixir
Supervisor.start_link(children, strategy: :one_for_one)
```

Bad:
```elixir
Supervisor.start_link(children, strategy: :one_for_all)
```

Rationale: `:one_for_one` restarts only the failed child; broader strategies cascade restarts.

You may break this when: children are tightly coupled and must restart together.

### Do not block the process mailbox

**Strength**: MUST

Good:
```elixir
def handle_call(:compute, _from, state) do
  Task.start(fn -> do_heavy_work() end)
  {:reply, :ok, state}
end
```

Bad:
```elixir
def handle_call(:compute, _from, state) do
  {:reply, do_heavy_work(), state}
end
```

Rationale: long synchronous work stalls all callers of that process.

You may break this when: the work is bounded and fast.

## Concurrency

### Prefer message passing over shared state

**Strength**: SHOULD

Good:
```elixir
send(worker, {:work, job})
```

Bad:
```elixir
# mutate a shared ETS table from multiple processes without coordination
```

Rationale: message passing is the BEAM model and avoids hidden coupling.

You may break this when: ETS is genuinely the right tool, with documented ownership.

### Use ETS only with a clear owner

**Strength**: SHOULD

Good:
```elixir
:ets.new(:cache, [:set, :public, :named_table, {:read_concurrency, true}])
```

Bad:
```elixir
:ets.new(:cache, [:bag])
```

Rationale: table type and concurrency flags must match the access pattern.

You may break this when: a throwaway table in tests.

### Avoid global process names collisions

**Strength**: MUST

Good:
```elixir
GenServer.start_link(__MODULE__, [], name: {:via, Registry, {MyApp.Registry, key}})
```

Bad:
```elixir
GenServer.start_link(__MODULE__, [], name: MyApp.Worker)
```

Rationale: global names collide across instances and break multi-tenancy.

You may break this when: a singleton process is genuinely global.

## Data structures and pattern matching

### Prefer pattern matching over conditionals

**Strength**: SHOULD

Good:
```elixir
def describe({:ok, value}), do: "got #{value}"
def describe({:error, reason}), do: "failed: #{reason}"
```

Bad:
```elixir
def describe(result) do
  if elem(result, 0) == :ok do
    "got #{elem(result, 1)}"
  else
    "failed: #{elem(result, 1)}"
  end
end
```

Rationale: pattern matching is clearer and exhaustive at the function head.

You may break this when: complex guards make heads unreadable.

### Use structs over maps for domain data

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.User do
  defstruct [:id, :email]
end
```

Bad:
```elixir
user = %{id: 1, email: "a@b.com"}
```

Rationale: structs give compile-time checks, defaults and clear contracts.

You may break this when: ad-hoc data with no stable shape.

### Avoid updating immutable data in place mentally

**Strength**: MUST

Good:
```elixir
user = %{user | email: new_email}
```

Bad:
```elixir
user.email = new_email
```

Rationale: Elixir data is immutable; rebind the whole value.

You may break this when: none.

### Pin variables in patterns

**Strength**: SHOULD

Good:
```elixir
^expected = actual
```

Bad:
```elixir
expected = actual
```

Rationale: the pin operator asserts equality instead of rebinding.

You may break this when: you intend to rebind.

## Advanced patterns: processes and supervision

### GenServer vs plain functions

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Counter do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def increment, do: GenServer.call(__MODULE__, :inc)
  def handle_call(:inc, _from, n), do: {:reply, n + 1, n + 1}
end
```

Bad:
```elixir
def double(number) do
  {:ok, pid} = Agent.start_link(fn -> number end)
  Agent.get(pid, &(&1 * 2))
end
```

Rationale: a process buys you state, concurrency and fault isolation; if none are needed, a pure function is cheaper, testable and restart-free.

You may break this when: a required OTP callback or library integration imposes a process boundary even though the component itself owns no state.

When to use:
- State must persist across requests or be shared between callers.
- Work must be serialized or rate-limited through a single mailbox.
- The component must be supervised and restarted on failure.

When not to use:
- The computation is pure and stateless.
- The value can be recomputed cheaply from inputs.
- No concurrency or fault isolation is required.

Pros:
- Centralizes mutable state behind a message-passing boundary.
- Enables supervision, restarts and serialized access.
- Hides implementation details behind a stable API.

Cons:
- Adds mailbox latency and a single point of contention.
- Harder to test than pure functions.
- Can become a god process if responsibilities accumulate.

### DynamicSupervisor for runtime children

**Strength**: SHOULD

Good:
```elixir
children = [{DynamicSupervisor, strategy: :one_for_one, name: MyApp.WorkerSupervisor}]
Supervisor.start_link(children, strategy: :one_for_one)

DynamicSupervisor.start_child(MyApp.WorkerSupervisor, {MyApp.Worker, arg})
```

Bad:
```elixir
# start a worker with GenServer.start_link/3 outside any supervisor
{:ok, pid} = GenServer.start_link(MyApp.Worker, arg)
```

Rationale: children created at runtime still need supervision, restart and cleanup; DynamicSupervisor provides that.

You may break this when: the child is truly short-lived and handled by Task.Supervisor.

When to use:
- Children are created in response to runtime events (connections, jobs, users).
- Each child has independent lifecycle and failure domain.
- You need to enumerate or terminate children dynamically.

When not to use:
- The set of children is fixed at boot.
- Children are fire-and-forget tasks.
- You only need a pool of identical workers.

Pros:
- Runtime child management with supervision semantics.
- Per-child restart and termination.
- Clear ownership and observability.

Cons:
- More boilerplate than static supervisors.
- Child spec discipline required.
- Children can outlive their logical owner unless explicitly terminated.

### PartitionSupervisor for sharded workloads

**Strength**: MAY

Good:
```elixir
children = [
  {PartitionSupervisor,
   child_spec: {MyApp.Cache, []},
   name: MyApp.CachePartitions,
   partitions: System.schedulers_online()}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Bad:
```elixir
# one global process handling all keys, becoming a bottleneck
GenServer.start_link(MyApp.Cache, [], name: MyApp.Cache)
```

Rationale: sharding stateful work across partitions reduces contention and improves cache locality on multi-core machines.

You may break this when: the workload is small or inherently single-owner.

When to use:
- A single process is a measurable bottleneck.
- Work can be partitioned by key with no cross-partition coordination.
- You want to scale with scheduler count.

When not to use:
- State must be globally consistent.
- Cross-partition transactions are needed.
- The added complexity is not justified by measurements.

Pros:
- Reduces contention and improves throughput.
- Scales with available cores.
- Keeps per-partition state small.

Cons:
- Partitioning logic and key routing required.
- Harder to reason about global state.
- Changing the partition count can move keys to different owners.

### handle_continue for post-init work

**Strength**: SHOULD

Good:
```elixir
def init(arg) do
  {:ok, %{arg: arg}, {:continue, :load}}
end

def handle_continue(:load, state) do
  data = fetch_from_db(state.arg)
  {:noreply, %{state | data: data}}
end
```

Bad:
```elixir
def init(arg) do
  data = fetch_from_db(arg)  # blocks supervisor startup
  {:ok, %{arg: arg, data: data}}
end
```

Rationale: heavy init blocks the supervisor and can cause timeouts; handle_continue defers work while keeping init fast.

You may break this when: the work is trivial and init stays well under the timeout.

When to use:
- Initialization needs I/O or expensive computation.
- The supervisor must not be blocked.
- The process should be considered started before data is ready.

When not to use:
- Init is already fast.
- Initialization must fail atomically before the child is reported as started.
- You need strict ordering across children.

Pros:
- Fast supervisor startup.
- Avoids init timeouts.
- Runs before the process handles ordinary calls or messages.

Cons:
- The supervisor can start sibling children before the continuation finishes.
- A long continuation still delays this process's mailbox.
- More callbacks to maintain.

### Task.async / Task.Supervisor for fire-and-forget and await

**Strength**: SHOULD

Good:
```elixir
task = Task.async(fn -> expensive() end)
result = Task.await(task, 5_000)

Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> notify() end)
```

Bad:
```elixir
pid = spawn(fn -> expensive() end)
# no await, no supervision, no timeout
```

Rationale: Task gives one-shot work a result reference and await semantics; Task.Supervisor adds supervised lifecycle management. Raw spawn provides neither.

You may break this when: you need a daemon process, not a one-shot task.

When to use:
- Running a bounded computation and awaiting its result.
- Fire-and-forget side effects under a supervisor.
- Parallelizing independent work with timeouts.

When not to use:
- Long-lived stateful processes.
- Work that must outlive the caller without supervision.
- Unbounded fan-out without backpressure.

Pros:
- Structured concurrency with await/timeout.
- Explicit crash propagation for linked tasks and supervision for Task.Supervisor children.
- Simple API for common cases.

Cons:
- Task.async links caller and task (crash propagation).
- Unbounded use can exhaust schedulers.
- Await timeouts must be chosen carefully.

### Monitors vs links for fault isolation

**Strength**: SHOULD

Good:
```elixir
Process.monitor(pid)  # receive {:DOWN, ref, :process, pid, reason}
# link only when you want to die together
Process.link(pid)
```

Bad:
```elixir
# linking to a process whose failure should not kill you
Process.link(untrusted_pid)
```

Rationale: links propagate exits; monitors only notify. Choose based on whether failure should be shared.

You may break this when: both processes are part of the same failure domain.

When to use:
- You need to observe a process without dying with it.
- Building a watcher or registry.
- Isolating untrusted or optional subsystems.

When not to use:
- Processes must fail together (supervision trees).
- You rely on automatic cleanup on exit.
- Simplicity favors link semantics.

Pros:
- Fine-grained fault isolation.
- Explicit handling of exits.
- Avoids cascading failures.

Cons:
- Manual DOWN handling required.
- Easier to leak or ignore failures.
- More code than links.

## Advanced patterns: concurrency and dataflow

### GenStage / Flow for backpressure

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Producer do
  use GenStage
  def handle_demand(demand, state) do
    events = fetch(demand)
    {:noreply, events, state}
  end
end
```

Bad:
```elixir
# push events into a consumer as fast as possible
Enum.each(events, &send(consumer, {:event, &1}))
```

Rationale: GenStage's demand-driven model prevents producers from overwhelming consumers.

You may break this when: data volume is small and bounded.

When to use:
- Streaming large or unbounded datasets.
- Consumer throughput is limited.
- You need explicit backpressure.

When not to use:
- Small, in-memory collections.
- Simple request/response flows.
- The overhead exceeds the benefit.

Pros:
- Built-in backpressure.
- Composable producer/consumer stages.
- Handles slow consumers gracefully.

Cons:
- Boilerplate and stage wiring.
- Learning curve.
- Overkill for simple pipelines.

### Broadway for batched/acked pipelines

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Pipeline do
  use Broadway
  def handle_message(_, message, _) do
    Broadway.Message.update_data(message, &process/1)
  end
  def handle_batch(_, messages, _, _) do
    Enum.each(messages, &persist/1)
    messages
  end
end
```

Bad:
```elixir
# consume a queue without batching or acks
loop do
  msg = receive_message()
  process(msg)
end
```

Rationale: Broadway batches and rate-limits message processing, while its producer integration manages acknowledgements after successful callbacks.

You may break this when: a single message at a time is required with no acks.

When to use:
- Consuming from queues (SQS, RabbitMQ, Kafka).
- Batching improves throughput or cost.
- Acknowledgment and retry semantics matter.

When not to use:
- No message broker involved.
- Single-message latency is critical.
- The pipeline is trivial.

Pros:
- Batching, acking, rate limiting built in.
- Graceful shutdown and draining.
- Producer abstraction.

Cons:
- Dependency on Broadway.
- Configuration complexity.
- Less control than raw GenStage.

### ETS as a cache with a clear owner

**Strength**: SHOULD

Good:
```elixir
def init(_opts) do
  table = :ets.new(:cache, [:set, :protected, {:read_concurrency, true}])
  {:ok, %{table: table}}
end
# The owner writes; other processes may read.
```

Bad:
```elixir
:ets.new(:cache, [:bag])  # wrong type, no concurrency flags, no owner
```

Rationale: ETS is fast but unforgiving; table type and concurrency flags must match access patterns and an owner must manage lifecycle.

You may break this when: a throwaway table in tests.

When to use:
- Read-heavy, write-light hot paths.
- Data fits in memory and staleness is acceptable.
- An owner process can manage invalidation.

When not to use:
- Strong consistency across nodes is needed.
- Data exceeds memory.
- A database or cache service is more appropriate.

Pros:
- Very fast in-process reads.
- Configurable concurrency.
- No network hop.

Cons:
- No persistence or replication.
- Manual invalidation and lifecycle.
- Easy to misuse concurrency flags.

### Registry for process lookup

**Strength**: SHOULD

Good:
```elixir
{:ok, _} = Registry.start_link(keys: :unique, name: MyApp.Registry)
GenServer.start_link(__MODULE__, [], name: {:via, Registry, {MyApp.Registry, key}})
```

Bad:
```elixir
# global atom name per instance
GenServer.start_link(__MODULE__, [], name: String.to_atom("worker_#{id}"))
```

Rationale: Registry provides safe, dynamic process lookup without atom leaks or global name collisions.

You may break this when: a singleton process is genuinely global.

When to use:
- Dynamic number of named processes.
- Multi-tenant or keyed workers.
- Avoiding atom table growth.

When not to use:
- A single global process.
- Static supervision tree.
- Lookup not needed.

Pros:
- No atom leaks.
- Dynamic keys.
- Integrated with supervision.

Cons:
- Registry process is a lookup bottleneck at scale.
- Extra wiring.
- Keys must be chosen carefully.

### Telemetry for observability

**Strength**: SHOULD

Good:
```elixir
:telemetry.execute([:my_app, :request, :stop], %{duration: duration}, %{route: route})
:telemetry.attach("handler", [:my_app, :request, :stop], &handle/4, nil)
```

Bad:
```elixir
IO.puts("request took #{duration}ms")  # unstructured, no metrics
```

Rationale: telemetry provides structured, decoupled instrumentation that metrics systems can consume.

You may break this when: a quick script or one-off debugging.

When to use:
- Production services needing metrics and tracing.
- Decoupling instrumentation from consumers.
- Standardizing events across libraries.

When not to use:
- Throwaway code.
- No observability pipeline exists.
- The overhead matters in a hot loop.

Pros:
- Decoupled and composable.
- Widely supported ecosystem.
- Low overhead when no handlers.

Cons:
- Event naming discipline required.
- Handlers run synchronously, so slow handlers add latency.
- Easy to over-instrument.

## Advanced patterns: distribution and interop

### Distributed Erlang (nodes, RPC)

**Strength**: MAY

Good:
```elixir
Node.connect(:"app@host")
:rpc.call(:"app@host", MyApp.Mod, :fun, [arg], 5_000)
```

Bad:
```elixir
# trusting any node on the network without TLS/cookie hygiene
Node.set_cookie(:insecure)
```

Rationale: distributed Erlang gives transparent RPC and process messaging but requires careful security and network assumptions.

You may break this when: the system is single-node or uses HTTP/gRPC instead.

When to use:
- Low-latency clustered Elixir services.
- Sharing processes across nodes.
- Erlang-native clustering (libcluster).

When not to use:
- Untrusted networks.
- Heterogeneous services better served by HTTP/gRPC.
- Operational complexity is unacceptable.

Pros:
- Transparent process messaging across nodes.
- Mature clustering tooling.
- Low latency.

Cons:
- Security depends on shared cookie.
- Network partitions require handling.
- Operational complexity.

### NIFs vs ports for native interop

**Strength**: SHOULD

Good:
```elixir
# port: OS process, crash-isolated
port = Port.open({:spawn, "native_tool"}, [:binary])

# NIF: only for trusted, fast, non-blocking code
defmodule MyApp.Native do
  use Rustler, otp_app: :my_app, crate: "native"
end
```

Bad:
```elixir
# blocking NIF on the scheduler thread
def heavy_nif(_), do: :erlang.nif_error(:nif_not_loaded)
```

Rationale: ports isolate crashes; NIFs run on scheduler threads and can stall the VM if they block.

You may break this when: the NIF is provably fast and non-blocking (or uses dirty schedulers).

When to use:
- Ports: untrusted or crash-prone native code.
- NIFs: hot, trusted, small computations.
- Dirty schedulers for blocking native work.

When not to use:
- Blocking work on normal schedulers.
- Native code that may crash the VM without isolation.
- When a pure Elixir or HTTP solution exists.

Pros:
- Ports: crash isolation.
- NIFs: minimal overhead.
- Dirty schedulers for blocking work.

Cons:
- NIF bugs can crash the VM.
- Port overhead and serialization.
- Build and deployment complexity.

## Advanced patterns: language patterns

### Protocols for polymorphism

**Strength**: SHOULD

Good:
```elixir
defprotocol MyApp.Serializable do
  def serialize(data)
end

defimpl MyApp.Serializable, for: MyApp.User do
  def serialize(u), do: %{id: u.id}
end
```

Bad:
```elixir
def serialize(%MyApp.User{} = u), do: ...
def serialize(%MyApp.Order{} = o), do: ...
# grows into a big conditional
```

Rationale: protocols provide open, extensible polymorphism without central conditionals.

You may break this when: the set of types is closed and small.

When to use:
- Behavior varies by data type and new types are added over time.
- You want extensibility without modifying core code.
- Standard library integration (Enumerable, Inspect).

When not to use:
- A closed set of types with a simple case.
- Dispatch depends on runtime context rather than the data type of the first argument.
- The abstraction adds indirection without value.

Pros:
- Open extension.
- Clear contract.
- Idiomatic Elixir.

Cons:
- Dispatch is limited to the data type of the first argument.
- Can fragment logic across modules.
- Requires defining protocol and impls.

### Behaviours for contracts/callbacks

**Strength**: SHOULD

Good:
```elixir
defmodule MyApp.Storage do
  @callback put(key :: term(), value :: term()) :: :ok | {:error, term()}
  @callback get(key :: term()) :: {:ok, term()} | {:error, :not_found}
end

defmodule MyApp.S3Storage do
  @behaviour MyApp.Storage
  def put(_k, _v), do: :ok
  def get(_k), do: {:error, :not_found}
end
```

Bad:
```elixir
# ad-hoc module with no declared callbacks
defmodule MyApp.S3Storage do
  def put(k, v), do: ...
end
```

Rationale: behaviours declare a contract, enabling mocks, compile-time checks and swappable implementations.

You may break this when: a one-off implementation with no alternate.

When to use:
- Multiple implementations of the same capability.
- Testing with mocks (Mox/Hammox).
- Plugin or adapter architectures.

When not to use:
- Single implementation with no variation.
- The contract is trivial.
- Over-abstraction for a single use.

Pros:
- Compile-time callback checks.
- Swappable implementations.
- Testability via mocks.

Cons:
- Boilerplate.
- Can be over-engineered.
- Requires discipline to keep callbacks minimal.

### Macros / DSLs at compile time

**Strength**: MUST (see "Avoid macros when a function suffices")

Good:
```elixir
defmacro route(path, do: block) do
  quote do
    def handle(unquote(path)), do: unquote(block)
  end
end
```

Bad:
```elixir
defmacro transform(x) do
  quote do: x + 1  # runtime work disguised as macro
end
```

Rationale: macros are for compile-time code generation and DSLs; using them for runtime logic obscures behavior and tooling.

You may break this when: compile-time code generation is genuinely required.

When to use:
- Building a DSL or compile-time transformation.
- Generating boilerplate from declarations.
- Conditional compilation.

When not to use:
- Runtime computation expressible as a function.
- Performance shortcuts that hurt readability.
- When a function suffices.

Pros:
- Powerful compile-time metaprogramming.
- Reduces boilerplate.
- Enables DSLs.

Cons:
- Harder to debug and tool.
- Hygiene pitfalls.
- Compile-time cost.

### Streams for lazy enumeration

**Strength**: SHOULD

Good:
```elixir
File.stream!("big.csv")
|> Stream.map(&parse/1)
|> Stream.filter(&valid?/1)
|> Enum.take(100)
```

Bad:
```elixir
File.read!("big.csv")
|> String.split("\n")
|> Enum.map(&parse/1)
|> Enum.filter(&valid?/1)
|> Enum.take(100)  # loads entire file
```

Rationale: streams process elements lazily, avoiding loading large collections into memory.

You may break this when: the collection is small and fits comfortably in memory.

When to use:
- Large or unbounded input.
- You only need a prefix of results.
- Memory is constrained.

When not to use:
- Small collections where eager is simpler.
- You need random access or a materialized result reused by several consumers.
- Debugging is easier with concrete lists.

Pros:
- Low memory footprint.
- Composable lazy pipelines.
- Early termination.

Cons:
- No random access without materializing the result.
- Errors may surface only when the stream is consumed.
- Harder to debug.

### `with` for happy-path pipelines

**Strength**: SHOULD

Good:
```elixir
with {:ok, user} <- fetch_user(id),
     {:ok, order} <- create_order(user, attrs),
     {:ok, _} <- charge(order) do
  {:ok, order}
else
  {:error, reason} -> {:error, reason}
end
```

Bad:
```elixir
case fetch_user(id) do
  {:ok, user} ->
    case create_order(user, attrs) do
      {:ok, order} -> ...
    end
  {:error, r} -> {:error, r}
end
```

Rationale: `with` flattens happy-path pipelines and centralizes error handling.

You may break this when: only one fallible step exists.

When to use:
- Multiple sequential fallible operations.
- Happy path is the common case.
- Errors share a handling strategy.

When not to use:
- A single operation (use case or direct match).
- Complex branching beyond success/failure.
- When each step needs distinct error handling.

Pros:
- Flat, readable happy path.
- Centralized else.
- Composes with tagged tuples.

Cons:
- else clauses can hide which step failed.
- Not for complex branching.
- Overuse obscures control flow.

### Tail recursion for unbounded loops

**Strength**: SHOULD

Good:
```elixir
def sum(list, acc \\ 0)
def sum([], acc), do: acc
def sum([h | t], acc), do: sum(t, acc + h)
```

Bad:
```elixir
def sum([]), do: 0
def sum([h | t]), do: h + sum(t)  # not tail-recursive
```

Rationale: tail recursion reuses the stack frame, preventing stack overflow on large inputs.

You may break this when: input size is bounded and small.

When to use:
- Processing large or unbounded collections.
- Iterative algorithms.
- Performance-sensitive loops.

When not to use:
- Small, bounded inputs.
- When Enum/Stream already express the intent clearly.
- Readability suffers.

Pros:
- Constant stack space.
- Efficient.
- Idiomatic for recursive algorithms.

Cons:
- Less readable than Enum for many.
- Accumulator plumbing.
- Easy to get wrong.

### Typespecs + Dialyzer

**Strength**: SHOULD

Good:
```elixir
@spec fetch(id :: pos_integer()) :: {:ok, User.t()} | {:error, :not_found}
def fetch(id), do: ...
```

Bad:
```elixir
def fetch(id) do ... end  # no spec, no analysis
```

Rationale: typespecs plus Dialyzer catch type errors before runtime and document contracts.

You may break this when: dynamic code where types are impractical.

When to use:
- Public APIs and shared libraries.
- Catching type errors in CI.
- Documenting contracts for callers.

When not to use:
- Highly dynamic code.
- Throwaway scripts.
- When Dialyzer noise exceeds value.

Pros:
- Static analysis based on success typings.
- Better documentation.
- Catches regressions.

Cons:
- Dialyzer's success typing does not prove that every call is safe.
- PLT construction and warnings require time to understand.
- Maintenance of specs.

### Guard-heavy function heads

**Strength**: MAY

Good:
```elixir
def process(x) when is_integer(x) and x > 0, do: x * 2
def process(x) when is_binary(x), do: String.length(x)
```

Bad:
```elixir
def process(x) do
  cond do
    is_integer(x) and x > 0 -> x * 2
    is_binary(x) -> String.length(x)
  end
end
```

Rationale: guards keep dispatch at the function head, improving clarity and exhaustiveness.

You may break this when: guards become unreadable or exceed guard-allowed expressions.

When to use:
- Simple type/range dispatch.
- Exhaustive matching over types.
- Readable, short conditions.

When not to use:
- Complex logic beyond guard expressions.
- Deeply nested conditions.
- When a case/cond is clearer.

Pros:
- Declarative dispatch.
- Compile-time guard checks.
- Clear contracts.

Cons:
- Limited expression set in guards.
- Can become unreadable.
- No side effects allowed.

### Umbrella apps

**Strength**: MAY

Good:
```elixir
# apps/web/mix.exs declares {:core, in_umbrella: true}
# apps/core has no dependency back on :web
```

Bad:
```elixir
# Split one deployable into apps by directory alone, then couple every app
# to every other app through configuration and cross-app calls.
```

Rationale: an umbrella organizes multiple OTP applications and makes their dependency graph explicit; it does not provide runtime isolation or independent deployment by itself.

You may break this when: the project is small or a single deployable.

When to use:
- The system genuinely contains multiple OTP applications with distinct ownership or lifecycle.
- Applications need explicit dependencies while sharing one repository and build.
- A library or runtime component must remain usable without the web application.

When not to use:
- Small or single-domain projects.
- The overhead of multiple apps is unjustified.
- Boundaries are unclear.

Pros:
- Explicit application dependency graph.
- Separate application configuration and supervision trees.
- Shared tooling and dependency resolution in one repository.

Cons:
- Releases and deployments remain coupled unless separately designed.
- Cross-app dependencies can still produce a distributed monolith.
- Extra configuration and build overhead for small projects.

## Review checklist

- [ ] `mix format --check-formatted` passes.
- [ ] No broad `rescue` or `catch`.
- [ ] All public functions have `@spec` and `@doc`.
- [ ] No unsupervised long-lived processes.
- [ ] Pattern matching preferred over conditionals.
- [ ] Stateful processes are justified; supervised Task work used for fire-and-forget.
- [ ] Backpressure present for data streams (GenStage/Flow/Broadway where applicable).
- [ ] ETS tables have a clear owner and correct concurrency flags.
- [ ] Registry used instead of global process names.
- [ ] Telemetry attached to key operations.
- [ ] Protocols/behaviours used for polymorphism and contracts.
- [ ] Macros are documented and hygienic.
- [ ] Streams used for large collections.
- [ ] `with` used for happy-path pipelines.
- [ ] Tail recursion for unbounded loops.
- [ ] Typespecs and Dialyzer on the public API.
- [ ] Guards readable; complex logic moved to function bodies.
- [ ] Umbrella boundaries justified.

## Source links

- Processes and supervision: [GenServer](https://hexdocs.pm/elixir/GenServer.html), [DynamicSupervisor](https://hexdocs.pm/elixir/DynamicSupervisor.html), [PartitionSupervisor](https://hexdocs.pm/elixir/PartitionSupervisor.html), [Task.Supervisor](https://hexdocs.pm/elixir/Task.Supervisor.html).
- Dataflow and observability: [GenStage](https://hexdocs.pm/gen_stage/GenStage.html), [Broadway](https://hexdocs.pm/broadway/Broadway.html), [ETS](https://www.erlang.org/doc/apps/stdlib/ets.html), [Registry](https://hexdocs.pm/elixir/Registry.html), [Telemetry](https://hexdocs.pm/telemetry/readme.html).
- Distribution and interop: [distributed Elixir](https://hexdocs.pm/elixir/distributed-tasks.html), [Port](https://www.erlang.org/doc/system/ports.html), [NIFs](https://www.erlang.org/doc/system/nif.html).
- Language patterns: [Protocol](https://hexdocs.pm/elixir/Protocol.html), [behaviours](https://hexdocs.pm/elixir/typespecs.html#behaviours), [Macro](https://hexdocs.pm/elixir/Macro.html), [Stream](https://hexdocs.pm/elixir/Stream.html), [`with`](https://hexdocs.pm/elixir/Kernel.SpecialForms.html#with/1), and [typespecs](https://hexdocs.pm/elixir/typespecs.html).

Credo check names may be attached to a rule when they provide an optional diagnostic. The official documentation above defines behavior; the guide's recommendations define project style.

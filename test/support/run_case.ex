defmodule Domovoy.RunCase do
  @moduledoc """
  For tests that really run a workflow: a shared sandbox, the runs flag on, and a
  Runtime that ends with the test. Never `async`, since the flag and the sandbox's
  shared mode are global.
  """

  use ExUnit.CaseTemplate

  alias Domovoy.Composer
  alias Domovoy.Composer.Runs
  alias Domovoy.DataCase
  alias DomovoyCore.Events
  alias DomovoyCore.Runtime

  using do
    quote do
      alias Domovoy.Repo

      import Domovoy.RunCase
    end
  end

  setup tags do
    DataCase.setup_sandbox(Map.put(tags, :async, false))
    setup_runs(tags)
  end

  @doc """
  The runs flag on, restored at exit, and a Runtime that ends with the test. A
  `ConnCase` test, which sets up its own sandbox, calls this from its `setup`.
  """
  @spec setup_runs(context :: map()) :: :ok
  def setup_runs(_context) do
    previous = Application.get_env(:domovoy, :composer_runs_enabled)
    Application.put_env(:domovoy, :composer_runs_enabled, true)
    on_exit(fn -> Application.put_env(:domovoy, :composer_runs_enabled, previous) end)

    start_supervised!({Runtime, name: Runs.runtime()})
    :ok
  end

  @doc """
  Fresh ids for one start of a draft, with these form values.
  """
  @spec start_attrs(draft :: Composer.Draft.t(), values :: map()) :: map()
  def start_attrs(draft, values) do
    %{
      draft_id: draft.id,
      lock_version: draft.lock_version,
      run_id: Ecto.UUID.generate(),
      command_id: Ecto.UUID.generate(),
      values: values
    }
  end

  @doc """
  Opens a run by its id and gives its handle.
  """
  @spec open!(run_id :: String.t()) :: DomovoyCore.Runs.Ref.t()
  def open!(run_id) do
    {:ok, %{handle: handle}} = Runs.open(Domovoy.Repo.get!(Composer.Run, run_id, log: false))
    handle
  end

  @doc """
  Waits until a run's history holds this phase, reading its events from the start, so
  a phase already passed still counts. Gives the run's view.
  """
  @spec await_phase(handle :: DomovoyCore.Runs.Ref.t(), phase :: String.t()) :: Runs.view()
  def await_phase(handle, phase), do: await_fact(handle, entered(phase))

  @doc """
  Waits until a run's history holds a fact for which `fun` is true, reading its events
  from the start. Gives the run's view.
  """
  @spec await_fact(handle :: DomovoyCore.Runs.Ref.t(), fun :: (map() -> boolean())) ::
          Runs.view()
  def await_fact(handle, fun) do
    {:ok, subscription} = Events.subscribe(handle)
    await_event(subscription, fun)
    :ok = Events.unsubscribe(subscription)

    {:ok, view} = Runs.view(handle)
    view
  end

  @doc """
  A fact matcher: the run asked a decision at this generation.
  """
  @spec asked(generation :: non_neg_integer()) :: (map() -> boolean())
  def asked(generation),
    do: &(&1["type"] == "decision_pending" and &1["generation"] == generation)

  @spec await_event(subscription :: Events.Subscription.t(), fun :: (map() -> boolean())) :: :ok
  defp await_event(subscription, fun) do
    assert_receive {:domovoy_events, ^subscription, message}, 5_000

    case message do
      {:event, envelope, cursor} ->
        :ok = Events.ack(subscription, cursor)

        if Enum.any?(envelope.facts, fun),
          do: :ok,
          else: await_event(subscription, fun)

      {:watermark, cursor} ->
        :ok = Events.ack(subscription, cursor)
        await_event(subscription, fun)
    end
  end

  @doc """
  Traces what a process, such as a LiveView, receives, so a test can wait until a run
  event has reached it.
  """
  @spec watch(pid :: pid()) :: non_neg_integer()
  def watch(pid), do: :erlang.trace(pid, true, [:receive])

  @doc """
  Waits until a watched process has received a run event holding a fact for which
  `fun` is true. A call to that process afterwards is handled after the event.
  """
  @spec await_delivered(fun :: (map() -> boolean())) :: :ok
  def await_delivered(fun) do
    receive do
      {:trace, _pid, :receive, {:domovoy_events, _subscription, {:event, envelope, _cursor}}} ->
        if Enum.any?(envelope.facts, fun), do: :ok, else: await_delivered(fun)
    after
      5_000 -> flunk("no matching run event reached the watched process")
    end
  end

  @doc """
  A fact matcher for `await_delivered/1`: the run entered this phase.
  """
  @spec entered(phase :: String.t()) :: (map() -> boolean())
  def entered(phase), do: &(&1["type"] == "phase_entered" and &1["phase"] == phase)

  @doc """
  Makes the test process the hold runners' gate. Opening it again changes nothing.
  """
  @spec open_gate() :: true
  def open_gate do
    Process.whereis(Domovoy.RunTestGate) == self() or
      Process.register(self(), Domovoy.RunTestGate)
  end
end

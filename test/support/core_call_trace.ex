defmodule Domovoy.CoreCallTrace do
  @moduledoc """
  Records every call to Core's run API, `DomovoyCore.Runs`, that any process makes
  while a function runs: a LiveView, its start task and the test process alike. It
  traces all processes, so callers must be `async: false`.
  """

  alias DomovoyCore.Runs, as: CoreRuns

  @doc """
  Runs `fun` under the trace and gives each call made meanwhile, oldest first, with its
  arguments.
  """
  @spec calls(fun :: (-> term())) :: [{function :: atom(), args :: list()}]
  def calls(fun) do
    # A tracer can't trace itself, so a separate process collects the calls.
    tracer = spawn_link(fn -> collect([]) end)

    try do
      :erlang.trace_pattern({CoreRuns, :_, :_}, true, [:local])
      :erlang.trace(:all, true, [:call, {:tracer, tracer}])
      fun.()
      :erlang.trace(:all, false, [:call])
      ref = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^ref} -> :ok
      end

      send(tracer, {:collect, self(), ref})

      receive do
        {:collected, ^ref, calls} -> calls
      end
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({CoreRuns, :_, :_}, false, [:local])
      Process.unlink(tracer)
      Process.exit(tracer, :kill)
    end
  end

  @spec collect(calls :: [{atom(), list()}]) :: no_return()
  defp collect(calls) do
    receive do
      {:trace, _pid, :call, {CoreRuns, name, args}} ->
        collect([{name, args} | calls])

      {:collect, from, ref} ->
        send(from, {:collected, ref, Enum.reverse(calls)})
        collect(calls)
    end
  end
end

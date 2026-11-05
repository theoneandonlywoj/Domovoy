defmodule Domovoy.NoExecutionTrace do
  @moduledoc """
  Proves a flow calls no runner, validator, decider or file-reading type, for
  `async: false` tests. It traces every such function, including local calls, so a
  call made from any process is seen, then proves the trace works with a control.
  """

  alias Domovoy.Catalog
  alias DomovoyCore.Decider
  alias DomovoyCore.Runner
  alias DomovoyCore.Type
  alias DomovoyCore.Validator
  alias DomovoyGitPlugin.Validator.RemotePresent

  @forbidden %{
    Runner => {:run, 2},
    Validator => {:validate, 2},
    Decider => {:decide, 3},
    Type => {:cast, 2}
  }

  # The only casts the composer makes: they parse text and touch nothing else.
  @allowed [
    {Type.UUID, :cast, 2},
    {Type.URI, :cast, 2},
    {Type.Email, :cast, 2}
  ]

  # One function of each kind. Junk arguments fail its clauses or do nothing, and a
  # trace records the call before any clause is selected.
  @controls [
    {DomovoyGitPlugin.Runner.WorktreeDirectory, :run, [:junk, :junk]},
    {RemotePresent, :validate, [:junk, :junk]},
    {Decider.Person, :decide, [:junk, :junk, :junk]},
    {Type.Date, :cast, [:junk, %{}]}
  ]

  @type call :: {module(), atom(), arity()}
  @type report :: %{
          result: term(),
          traced: [call()],
          control_calls: [call()],
          controls_expected: [call()],
          forbidden_calls: [{pid(), call()}]
        }

  @doc """
  Runs `fun` in the calling process under the trace. Fails when a target can't be
  traced. The test asserts on the report, including `fun`'s result, so a flow that
  crashed or never ran can't pass.
  """
  @spec run(fun :: (-> term())) :: report()
  def run(fun) do
    targets = targets()
    tracer = spawn_link(&collect_loop/0)

    try do
      Enum.each(targets, &trace_pattern!/1)
      :erlang.trace(:all, true, [:call, {:tracer, tracer}])

      control = run_controls()
      result = fun.()

      calls = drain(tracer)
      {control_calls, others} = Enum.split_with(calls, fn {pid, _call} -> pid == control end)

      %{
        result: result,
        traced: targets,
        control_calls: Enum.map(control_calls, &elem(&1, 1)),
        controls_expected: Enum.map(@controls, fn {m, f, a} -> {m, f, length(a)} end),
        forbidden_calls: others
      }
    after
      :erlang.trace(:all, false, [:call])
      Enum.each(targets, &:erlang.trace_pattern(&1, false, [:local]))
      unlink_and_stop(tracer)
    end
  end

  @doc """
  Every function the trace watches.
  """
  @spec targets() :: [call()]
  def targets do
    for %{installed?: true, app: app} <- Catalog.plugins(),
        {:ok, modules} <- [:application.get_key(app, :modules)],
        module <- modules,
        Code.ensure_loaded?(module),
        behaviour <- behaviours(module),
        {function, arity} <- [Map.get(@forbidden, behaviour)],
        function_exported?(module, function, arity),
        {module, function, arity} not in @allowed,
        uniq: true do
      {module, function, arity}
    end
  end

  @spec behaviours(module :: module()) :: [module()]
  defp behaviours(module) do
    :attributes
    |> module.module_info()
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.filter(&is_map_key(@forbidden, &1))
  end

  @spec trace_pattern!(call :: call()) :: :ok
  defp trace_pattern!(call) do
    1 = :erlang.trace_pattern(call, true, [:local])
    :ok
  end

  # A separate process, so a crashing control can't reach the test, and its calls
  # can be told from the subject's.
  @spec run_controls() :: pid()
  defp run_controls do
    {pid, ref} =
      spawn_monitor(fn ->
        Enum.each(@controls, fn {module, function, args} ->
          try do
            apply(module, function, args)
          rescue
            _exception -> :ok
          end
        end)
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> pid
    end
  end

  @spec drain(tracer :: pid()) :: [{pid(), call()}]
  defp drain(tracer) do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    end

    send(tracer, {:collect, self(), ref})

    receive do
      {:collected, ^ref, calls} -> calls
    end
  end

  @spec collect_loop(calls :: [{pid(), call()}]) :: no_return()
  defp collect_loop(calls \\ []) do
    receive do
      {:trace, pid, :call, {module, function, args}} ->
        collect_loop([{pid, {module, function, length(args)}} | calls])

      {:collect, from, ref} ->
        send(from, {:collected, ref, Enum.reverse(calls)})
        collect_loop(calls)
    end
  end

  @spec unlink_and_stop(pid :: pid()) :: :ok
  defp unlink_and_stop(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :ok
  end
end

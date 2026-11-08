defmodule DomovoyWeb.ComposerRunStopResumeLiveTest do
  # The call trace follows every process, so this file is never async.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  import Domovoy.RunCase,
    only: [
      setup_runs: 1,
      start_attrs: 2,
      open!: 1,
      await_phase: 2,
      open_gate: 0,
      watch: 1,
      await_delivered: 1,
      entered: 1
    ]

  alias Domovoy.Composer
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.CoreCallTrace
  alias Domovoy.Examples.Definitions
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runtime
  alias DomovoyWeb.ComposerLive.RunEvents

  # Killing a capsule makes its processes report their end.
  @moduletag :capture_log

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  # With `trap_exit` the runner outlives a stop's exit signal, so `stopping` lasts until
  # the test releases it.
  defp start_held(trap_exit \\ true) do
    open_gate()
    draft = draft!(hold_run(), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => trap_exit}))
    assert_receive {:entered, "hold", runner}, 5_000
    %{draft: draft, run_id: run_id, runner: runner, handle: open!(run_id)}
  end

  # A process has one tracer, so a page whose own calls are traced by
  # `Domovoy.CoreCallTrace` is opened unwatched.
  defp open_run(conn, run, watch? \\ true) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
    if watch?, do: watch(view.pid)
    render_async(view, 5_000)
    view
  end

  # The traced `DomovoyCore.Runs.command/3` calls for this command, by their options.
  defp commands(calls, name) do
    for {:command, [_handle, ^name, opts]} <- calls, do: opts
  end

  defp any_command?(calls), do: Enum.any?(calls, &match?({:command, [_, _, _]}, &1))

  defp put_op(view, op) do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.run, &%{&1 | op: op})
    end)
  end

  test "Stop then Resume continues the same run", %{conn: conn} do
    run = start_held()
    view = open_run(conn, run)
    assert has_element?(view, "#stop-run")
    refute has_element?(view, "#resume-run")

    view |> element("#stop-run") |> render_click()
    render_async(view, 5_000)
    await_delivered(entered("stopping"))

    # Each reread while the stop is pending keeps its op on screen.
    assert has_element?(
             view,
             "#run-op",
             "Stop accepted. Stopping active work and saving checkpoint"
           )

    assert has_element?(view, "#run-status", "Stopping active work and saving checkpoint")
    refute has_element?(view, "#resume-run")
    refute has_element?(view, "#stop-run")

    send(run.runner, :release)
    await_delivered(entered("stopped"))

    refute has_element?(view, "#run-op")
    assert has_element?(view, "#resume-run.soft-btn-primary")
    refute has_element?(view, "#stop-run")

    assert has_element?(
             view,
             "#run-status",
             "Stopped. Resume run continues it from its checkpoint"
           )

    run_id = view |> element("#run-id") |> render()

    view |> element("#resume-run") |> render_click()
    render_async(view, 5_000)
    await_delivered(entered("resuming"))

    assert view |> element("#run-id") |> render() == run_id
    assert %{committed_phase: phase} = await_phase(run.handle, "resuming")
    assert phase != "stopped"
  end

  test "a double Stop sends one command, and the second press shows it is already stopping",
       %{conn: conn} do
    run = start_held()
    view = open_run(conn, run)

    calls =
      CoreCallTrace.calls(fn ->
        view |> element("#stop-run") |> render_click()
        render_hook(view, "stop_run", %{})
        render_async(view, 5_000)
      end)

    assert [_one] = commands(calls, :stop)
    assert has_element?(view, "#run-op")
    refute has_element?(view, "#rejection-message")

    send(run.runner, :release)
    await_phase(run.handle, "stopped")
  end

  test "a Stop that couldn't be confirmed is retried under the same command id",
       %{conn: conn} do
    run = start_held()
    view = open_run(conn, run)
    id = Ecto.UUID.generate()
    put_op(view, %{command: :stop, command_id: id, operation_id: nil, state: :unconfirmed})

    calls =
      CoreCallTrace.calls(fn ->
        view |> element("#stop-run") |> render_click()
        render_async(view, 5_000)
      end)

    assert [opts] = commands(calls, :stop)
    assert opts[:command_id] == id

    send(run.runner, :release)
    await_phase(run.handle, "stopped")
  end

  test "a lifecycle event ignores its params", %{conn: conn} do
    run = start_held()
    view = open_run(conn, run)

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "stop_run", %{"command_id" => "forged", "name" => "cancel"})
        render_async(view, 5_000)
      end)

    assert [opts] = commands(calls, :stop)
    assert opts[:command_id] != "forged"
    assert commands(calls, :cancel) == []

    send(run.runner, :release)
    await_phase(run.handle, "stopped")
  end

  describe "a finished run" do
    defp finished(:succeeded) do
      run = start_held(false)
      send(run.runner, :release)
      run
    end

    defp finished(:failed) do
      draft = draft!(leak_run(), "Leak")

      {:ok, run_id} =
        Composer.start_run(start_attrs(draft, %{"secret" => "s", "mode" => "fail"}))

      %{draft: draft, run_id: run_id, handle: open!(run_id)}
    end

    defp finished(:cancelled) do
      run = start_held(false)
      {:ok, _receipt} = Composer.cancel_run(run.handle, Ecto.UUID.generate())
      run
    end

    test "never offers Stop, Resume or Cancel, and refuses a crafted Resume before Core",
         %{conn: conn} do
      for outcome <- [:succeeded, :failed, :cancelled] do
        run = finished(outcome)
        outcome_text = Atom.to_string(outcome)
        assert %{outcome: ^outcome_text} = await_phase(run.handle, "finished")

        view = open_run(conn, run, false)

        for control <- ~w(#stop-run #resume-run #cancel-run) do
          refute has_element?(view, control), "#{outcome} #{control}"
        end

        assert has_element?(view, "#new-run")

        calls =
          CoreCallTrace.calls(fn ->
            render_hook(view, "resume_run", %{})
            render_hook(view, "stop_run", %{})
            render_async(view, 5_000)
          end)

        refute any_command?(calls), "#{outcome}"
        assert has_element?(view, "#rejection-message", "isn't available for this run")
      end
    end
  end

  test "a frozen run offers only Recover, and a crafted Stop or Resume starts no owner",
       %{conn: conn} do
    run = start_held(false)
    owner = CoreRuns.whereis(run.handle)
    ref = Process.monitor(owner)
    [{_id, capsule, :supervisor, _modules}] = Runtime.capsules(Runs.runtime())
    Process.exit(capsule, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

    view = open_run(conn, run, false)
    assert has_element?(view, "#recover-run")

    for control <- ~w(#stop-run #resume-run #cancel-run) do
      refute has_element?(view, control)
    end

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "stop_run", %{})
        render_hook(view, "resume_run", %{})
        render_async(view, 5_000)
      end)

    refute any_command?(calls)
    refute Enum.any?(calls, &match?({:activate, _args}, &1))
    assert CoreRuns.whereis(run.handle) == nil
    assert has_element?(view, "#rejection-message", "Recover it first")
  end

  describe "after a resync" do
    defp start_review do
      document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
      {:ok, values} = RunInputs.parse(document, @review_form)
      draft = draft!(document, "Review")
      {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
      handle = open!(run_id)
      %{awaiting: [%{occurrence: occurrence}]} = await_phase(handle, "waiting")
      %{draft: draft, run_id: run_id, handle: handle, occurrence: occurrence}
    end

    test "the fold is marked stale, and a decision Core still awaits can be answered",
         %{conn: conn} do
      run = start_review()
      view = open_run(conn, run, false)
      refute has_element?(view, "#run-fold-stale")

      %{socket: %{assigns: %{run: %{sub: sub}}}} = :sys.get_state(view.pid)
      send(view.pid, {:domovoy_events, sub, {:closed, %{type: :resync_required}}})

      assert has_element?(view, "#run-fold-stale", "Step badges may be out of date")

      # The history that folded the occurrence is gone; Core's status still lists it.
      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.run.fold, &%{&1 | occurrences: %{}})
      end)

      params = %{"occurrence" => run.occurrence, "choice" => "accept", "inputs" => %{}}
      calls = CoreCallTrace.calls(fn -> render_hook(view, "decide", params) end)

      assert [_decide] = commands(calls, :decide)
      refute has_element?(view, "#rejection-message")
      assert %{outcome: "succeeded"} = await_phase(run.handle, "finished")
    end
  end

  test "refusals are told in plain words" do
    assert RunEvents.refusal_text({:refused, :rerun_limit}) ==
             "This run can't create another generation. Start a new run instead."

    assert RunEvents.refusal_text({:refused, :busy}) == "Core is busy. Try again in a moment."
    assert RunEvents.refusal_text({:refused, :mystery}) == "Core refused that for this run."

    assert RunEvents.refusal_text({:not_offered, :resume}) ==
             "That isn't available for this run right now."
  end
end

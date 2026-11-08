defmodule DomovoyWeb.ComposerRunPauseReconcileLiveTest do
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
  alias Domovoy.Composer.Runs
  alias Domovoy.CoreCallTrace
  alias Domovoy.PureHoldRunner
  alias Domovoy.UncertainHoldRunner
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runtime

  # Killing a capsule makes its processes report their end.
  @moduletag :capture_log

  setup :setup_runs

  defp start_held(runner) do
    open_gate()
    draft = draft!(hold_run(runner), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", held}, 5_000
    %{draft: draft, run_id: run_id, runner: held, handle: open!(run_id)}
  end

  # Kills the run's capsule, so its owner and its held attempt end with no settlement.
  defp kill_owner(run) do
    owner = CoreRuns.whereis(run.handle)
    ref = Process.monitor(owner)
    [{_id, capsule, :supervisor, _modules}] = Runtime.capsules(Runs.runtime())
    Process.exit(capsule, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000
    run
  end

  # An effectful attempt cut off mid-run: the next owner can't tell whether its effect
  # happened, so the run blocks until a person checks.
  defp start_blocked do
    run = UncertainHoldRunner |> start_held() |> kill_owner()
    :ok = Runs.activate(run.handle)
    view = await_phase(run.handle, "blocked")
    assert %{block_reason: "effect_uncertain", uncertainties: [uncertainty]} = view
    Map.put(run, :uncertainty, uncertainty)
  end

  defp open_run(conn, run, watch? \\ true) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
    if watch?, do: watch(view.pid)
    render_async(view, 5_000)
    view
  end

  defp commands(calls, name), do: for({:command, [_handle, ^name, opts]} <- calls, do: opts)
  defp any_command?(calls), do: Enum.any?(calls, &match?({:command, [_, _, _]}, &1))

  defp refute_mark_succeeded(view) do
    refute has_element?(view, "button", "Mark succeeded")
    refute has_element?(view, "a", "Mark succeeded")
  end

  test "Pause finishes active work, then Unpause lets the run go on", %{conn: conn} do
    run = start_held(PureHoldRunner)
    view = open_run(conn, run)
    assert has_element?(view, "#run-more #pause-run")
    refute has_element?(view, "#unpause-run")

    view |> element("#pause-run") |> render_click()
    render_async(view, 5_000)
    await_delivered(entered("pausing"))

    assert has_element?(view, "#run-status", "Finishing active work before pausing")
    refute has_element?(view, "#pause-run")
    assert has_element?(view, "#stop-run")

    send(run.runner, :release)
    await_delivered(entered("paused"))

    assert has_element?(view, "#run-status", "Paused")
    assert has_element?(view, "#run-more #unpause-run")
    refute has_element?(view, "#pause-run")
    refute_mark_succeeded(view)

    view |> element("#unpause-run") |> render_click()
    render_async(view, 5_000)

    assert %{outcome: "succeeded"} = await_phase(run.handle, "finished")
  end

  test "a blocked run offers no Pause, and reconciling sends one command on confirmation",
       %{conn: conn} do
    run = start_blocked()
    view = open_run(conn, run, false)

    refute has_element?(view, "#pause-run")
    refute has_element?(view, "#run-more")
    assert has_element?(view, "#run-status", "Blocked")
    refute_mark_succeeded(view)

    view |> element("#review-uncertainty") |> render_click()
    assert has_element?(view, "#uncertainty-review", "hold")
    assert has_element?(view, "#uncertainty-0", "generation 0")

    # Opening the confirmation sends nothing.
    calls = CoreCallTrace.calls(fn -> view |> element("#open-reconcile-0") |> render_click() end)
    refute any_command?(calls)
    assert has_element?(view, "#reconcile-dialog", "Checked: safe to retry")
    refute_mark_succeeded(view)

    calls =
      CoreCallTrace.calls(fn ->
        view |> element("#confirm-reconcile") |> render_click()
        render_async(view, 5_000)
      end)

    assert [opts] = commands(calls, :reconcile)
    assert opts[:uncertainty] == run.uncertainty
    # The evidence is fixed: no input value, path or reason reaches Core's history.
    assert opts[:evidence] == %{"kind" => "operator_checked", "action" => "retry"}
    refute has_element?(view, "#reconcile-dialog")

    # Settled, the step runs again.
    assert_receive {:entered, "hold", runner}, 5_000
    send(runner, :release)
    assert %{outcome: "succeeded"} = await_phase(run.handle, "finished")
  end

  test "an uncertainty Core doesn't list is refused before any Core call", %{conn: conn} do
    run = start_blocked()
    view = open_run(conn, run, false)

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "open_reconcile", %{"uncertainty" => "node:other@0#1"})
        render_hook(view, "confirm_reconcile", %{"uncertainty" => "node:other@0#1"})
        render_hook(view, "confirm_reconcile", %{"uncertainty" => ["forged"]})
        render_hook(view, "confirm_reconcile", %{})
        render_async(view, 5_000)
      end)

    refute any_command?(calls)
    refute has_element?(view, "#reconcile-dialog")
    assert has_element?(view, "#rejection-message", "isn't available for this run")
    assert {:ok, %{committed_phase: "blocked"}} = Runs.view(run.handle)
  end

  test "a second uncertainty while one check is being sent is refused, and its dialog closes",
       %{conn: conn} do
    run = start_blocked()
    view = open_run(conn, run, false)
    other = "node:hold@0#2"

    # A check of the first is still being sent when Core's status lists another.
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.run, fn page_run ->
        op = %{
          command: :reconcile,
          command_id: Ecto.UUID.generate(),
          operation_id: nil,
          state: :sending,
          args: [run.uncertainty]
        }

        status = %{page_run.status | uncertainties: [run.uncertainty, other]}
        %{page_run | op: op, status: status}
      end)
    end)

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "open_reconcile", %{"uncertainty" => other})
        assert has_element?(view, "#reconcile-dialog")
        render_hook(view, "confirm_reconcile", %{"uncertainty" => other})
        render_async(view, 5_000)
      end)

    refute any_command?(calls)
    refute has_element?(view, "#reconcile-dialog")
    assert has_element?(view, "#rejection-message", "Another check is still being sent")
  end

  test "Not yet and Escape close the reconcile dialog and send nothing", %{conn: conn} do
    run = start_blocked()
    view = open_run(conn, run, false)
    view |> element("#review-uncertainty") |> render_click()

    calls =
      CoreCallTrace.calls(fn ->
        view |> element("#open-reconcile-0") |> render_click()
        view |> element("#close-reconcile") |> render_click()
        refute has_element?(view, "#reconcile-dialog")

        view |> element("#open-reconcile-0") |> render_click()
        assert has_element?(view, "#reconcile-dialog")
        view |> element("#reconcile-dialog") |> render_keydown(%{"key" => "Escape"})
        refute has_element?(view, "#reconcile-dialog")
        render_async(view, 5_000)
      end)

    refute any_command?(calls)
    assert {:ok, %{committed_phase: "blocked"}} = Runs.view(run.handle)
  end

  test "a frozen run refuses Pause, Unpause and reconciling, and starts no owner",
       %{conn: conn} do
    run = PureHoldRunner |> start_held() |> kill_owner()
    view = open_run(conn, run, false)
    assert has_element?(view, "#recover-run")
    refute has_element?(view, "#run-more")

    calls =
      CoreCallTrace.calls(fn ->
        render_hook(view, "pause_run", %{})
        render_hook(view, "unpause_run", %{})
        render_hook(view, "open_reconcile", %{"uncertainty" => "node:hold@0#1"})
        render_hook(view, "confirm_reconcile", %{"uncertainty" => "node:hold@0#1"})
        render_async(view, 5_000)
      end)

    refute any_command?(calls)
    refute Enum.any?(calls, &match?({:activate, _args}, &1))
    assert CoreRuns.whereis(run.handle) == nil
    refute_mark_succeeded(view)
  end
end

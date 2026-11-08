defmodule DomovoyWeb.ComposerRunRecoverLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1, start_attrs: 2, open!: 1, open_gate: 0]

  alias Domovoy.Composer
  alias Domovoy.Composer.Runs
  alias DomovoyCore.Runs, as: CoreRuns
  alias DomovoyCore.Runtime

  # Killing a capsule makes its processes report their end.
  @moduletag :capture_log

  setup :setup_runs

  # A capsule is temporary, so once killed nothing brings its owner back by itself.
  defp freeze do
    open_gate()
    draft = draft!(hold_run(), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", _runner}, 5_000

    handle = open!(run_id)
    owner = CoreRuns.whereis(handle)
    ref = Process.monitor(owner)

    [{_id, capsule, :supervisor, _modules}] = Runtime.capsules(Runs.runtime())
    Process.exit(capsule, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

    {:ok, view} = Runs.view(handle)
    assert %{committed_phase: "running", owner_live?: false} = view
    assert CoreRuns.whereis(handle) == nil

    %{draft: draft, run_id: run_id, handle: handle, seq: view.committed_seq}
  end

  test "a frozen run executes nothing until Recover", %{conn: conn} do
    frozen = freeze()
    {:ok, view, _html} = live(conn, ~p"/composer/#{frozen.draft.id}?run=#{frozen.run_id}")
    render_async(view, 5_000)

    # Opening and subscribing start no owner.
    assert CoreRuns.whereis(frozen.handle) == nil
    assert {:ok, %{committed_seq: seq}} = Runs.view(frozen.handle)
    assert seq == frozen.seq

    assert has_element?(view, "#recover-run")
    refute has_element?(view, "#cancel-run")
    assert has_element?(view, "#run-status", "lost its process")

    render_hook(view, "confirm_cancel_run", %{})
    assert has_element?(view, "#rejection-message", "Recover it first")
    assert CoreRuns.whereis(frozen.handle) == nil
    refute_received {:entered, "hold", _runner}

    view |> element("#recover-run") |> render_click()

    assert_receive {:entered, "hold", runner}, 5_000
    assert is_pid(CoreRuns.whereis(frozen.handle))
    refute has_element?(view, "#recover-run")
    send(runner, :release)
  end
end

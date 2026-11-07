defmodule DomovoyWeb.ComposerRunCancelLiveTest do
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

  setup :setup_runs

  defp start_held do
    open_gate()
    draft = draft!(hold_run(), "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", runner}, 5_000
    %{draft: draft, run_id: run_id, runner: runner}
  end

  defp open_run(conn, held) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")
    watch(view.pid)
    render_async(view, 5_000)
    view
  end

  test "a confirmed Cancel finishes the run cancelled", %{conn: conn} do
    held = start_held()
    view = open_run(conn, held)
    await_delivered(&(&1["type"] == "attempt_admitted"))

    view |> element("#cancel-run") |> render_click()
    assert has_element?(view, "#cancel-run-dialog")

    view |> element("#close-cancel-run") |> render_click()
    refute has_element?(view, "#cancel-run-dialog")

    view |> element("#cancel-run") |> render_click()
    view |> element("#confirm-cancel-run") |> render_click()
    refute has_element?(view, "#cancel-run-dialog")

    await_delivered(entered("finished"))

    assert %{outcome: "cancelled"} = await_phase(open!(held.run_id), "finished")
    assert has_element?(view, "#run-status", "Cancelled")
    assert has_element?(view, "#run-outcome", "cancelled")
    refute has_element?(view, "#cancel-run")
    refute has_element?(view, "#rejection")
  end

  test "a crafted cancel on a succeeded run, and on a cancelled one, is refused by type",
       %{conn: conn} do
    succeeded = start_held()
    send(succeeded.runner, :release)
    await_phase(open!(succeeded.run_id), "finished")

    cancelled = start_held()
    :ok = Composer.cancel_run(open!(cancelled.run_id))
    assert %{outcome: "cancelled"} = await_phase(open!(cancelled.run_id), "finished")

    for held <- [succeeded, cancelled] do
      view = open_run(conn, held)
      refute has_element?(view, "#cancel-run")

      render_hook(view, "open_cancel_run", %{})
      refute has_element?(view, "#cancel-run-dialog")

      render_hook(view, "confirm_cancel_run", %{})

      assert has_element?(view, "#rejection-core-id", "already_terminal")
      assert has_element?(view, "#run-phase", "finished")
    end
  end
end

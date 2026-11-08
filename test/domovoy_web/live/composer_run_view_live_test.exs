defmodule DomovoyWeb.ComposerRunViewLiveTest do
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

  # A held run of `hold_run/0`, waiting for the test to release its runner.
  defp start_held(document \\ hold_run()) do
    open_gate()
    draft = draft!(document, "Held")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, %{"trap_exit" => false}))
    assert_receive {:entered, "hold", runner}, 5_000
    %{draft: draft, run_id: run_id, runner: runner}
  end

  # Opens a run page and waits until its first replayed attempt has reached it. The
  # replay can land before the watch begins, so the page's fold is read first.
  defp open_run(conn, path) do
    {:ok, view, _html} = live(conn, path)
    watch(view.pid)
    render_async(view, 5_000)
    %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)
    if run.fold.attempts == %{}, do: await_delivered(&(&1["type"] == "attempt_admitted"))
    render(view)
    view
  end

  defp lock(draft) do
    {:ok, %{lock_version: lock}} = Composer.get_draft(draft.id)
    lock
  end

  defp fold(view) do
    %{socket: %{assigns: %{run: run}}} = :sys.get_state(view.pid)
    run.fold
  end

  describe "live status" do
    test "a held card shows running, then succeeded, and never moves", %{conn: conn} do
      held = start_held()
      view = open_run(conn, ~p"/composer/#{held.draft.id}/stages/main?run=#{held.run_id}")

      %{x: x, y: y} =
        Enum.find(Composer.stage_view(held.draft.document, "main").cards, &(&1.name == "hold"))

      assert has_element?(
               view,
               "#node-hold[data-run-status='running'][data-x='#{x}'][data-y='#{y}']"
             )

      assert has_element?(view, "#node-hold-run-status", "Running")
      assert has_element?(view, "#run-status", "Running hold")
      assert has_element?(view, "#cancel-run")

      send(held.runner, :release)
      await_delivered(entered("finished"))

      assert has_element?(
               view,
               "#node-hold[data-run-status='succeeded'][data-x='#{x}'][data-y='#{y}']"
             )

      assert has_element?(view, "#node-hold-run-status", "Done")
      assert has_element?(view, "#run-status", "Finished")
      refute has_element?(view, "#cancel-run")
    end

    test "the workflow shows the stage's status and its outline shows the run", %{conn: conn} do
      held = start_held()
      view = open_run(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")

      assert has_element?(view, "#vertex-main[data-run-status='running']")
      assert has_element?(view, "#outline-panel #run-phase", "running")
      assert has_element?(view, "#outline-panel #recent-run-#{held.run_id}")
      assert has_element?(view, "#outline-panel #run-input-trap_exit")
      refute has_element?(view, "#inputs-form")
      refute has_element?(view, "#composer-tools")
    end
  end

  describe "the run switcher" do
    defp waiting_view do
      %{
        committed_phase: "waiting",
        outcome: nil,
        generation: 0,
        committed_seq: 4,
        awaiting: [%{occurrence: "o", decision: "review", choices: ["accept"]}],
        error: nil
      }
    end

    test "a finished run with no summary is no Unfinished run, only a check", %{conn: conn} do
      held = start_held()
      send(held.runner, :release)
      await_phase(open!(held.run_id), "finished")

      {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}")
      render_async(view, 5_000)

      refute has_element?(view, "#latest-run-link")
      assert has_element?(view, "#recent-run-status-#{held.run_id}", "Needs a check")
      assert has_element?(view, "#attention-runs-link", "1 run may need you")
    end

    test "a written waiting summary is the Unfinished run, listed first", %{conn: conn} do
      held = start_held()
      draft = held.draft
      send(held.runner, :release)
      await_phase(open!(held.run_id), "finished")
      :ok = Composer.summarize_run(held.run_id, waiting_view())

      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      render_async(view, 5_000)

      assert has_element?(
               view,
               "#latest-run-link[href='/composer/#{draft.id}?run=#{held.run_id}']"
             )

      assert has_element?(view, "#recent-run-status-#{held.run_id}", "Needs you")

      assert has_element?(
               view,
               "#all-runs-link[href='/composer/runs?draft=#{draft.id}']"
             )
    end

    test "a run page's switcher opens the runs, with its attention count", %{conn: conn} do
      held = start_held()
      view = open_run(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")

      # Opening the run wrote its summary through, so it now reads as running.
      assert %{committed_phase: "running"} =
               Domovoy.Repo.get(Domovoy.Composer.RunSummary, held.run_id)

      assert has_element?(view, "#outline-panel[hidden]")

      view |> element("#run-switcher") |> render_click()
      assert has_element?(view, "#outline-panel:not([hidden]) #recent-run-#{held.run_id}")

      {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")
      render_async(view, 5_000)
      assert has_element?(view, "#run-switcher-attention", "1")
      assert has_element?(view, "#recent-run-status-#{held.run_id}", "Running")
    end
  end

  describe "read-only" do
    test "edits saved in draft mode change nothing in a run", %{conn: conn} do
      held = start_held()
      {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}")

      # In the draft these all save, which also gives Undo a history.
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => "extra", "kind" => "stage"}})
      render_hook(view, "save_title", %{"title" => %{"value" => "Renamed"}})

      render_hook(view, "node_moved", %{
        "node" => "main",
        "x" => 7,
        "y" => 9,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "ok"})
      assert has_element?(view, "#undo:not([disabled])")

      before = saved_document(held.draft)
      lock = lock(held.draft)

      render_patch(view, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")
      render_async(view, 5_000)

      for {event, params} <- [
            {"undo", %{}},
            {"save_title", %{"title" => %{"value" => "Again"}}},
            {"add_vertex", %{"vertex" => %{"name" => "more", "kind" => "stage"}}},
            {"set_workflow_name", %{"workflow_name" => %{"value" => "other_name"}}},
            {"remove_vertex", %{"vertex" => "main"}},
            {"save_input", %{"input" => %{"name" => "x", "type" => "DomovoyCore.Type.String"}}},
            {"open_start", %{}},
            {"open_tools", %{}},
            {"validate", %{}}
          ] do
        render_hook(view, event, params)
        assert has_element?(view, "#composer"), event
      end

      render_hook(view, "node_moved", %{
        "node" => "main",
        "x" => 1,
        "y" => 2,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "rejected"})

      assert saved_document(held.draft) == before
      assert lock(held.draft) == lock
      assert {:ok, %{title: "Renamed"}} = Composer.get_draft(held.draft.id)
      refute has_element?(view, "#composer-tools")
      # New run is the one start allowed on a run page; it only opens the launcher.
      assert has_element?(view, "#launcher-panel:not([hidden]) #start-form")
    end

    test "a crafted select with focus and tools changes only the selection", %{conn: conn} do
      held = start_held()
      view = open_run(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")

      render_hook(view, "select_node", %{"node" => "main", "focus" => "issue-x", "tools" => true})

      assert has_element?(view, "#run-selected-name", "main")
      refute has_element?(view, "#composer-tools")
      refute_push_event(view, "composer:focus", %{})

      render_hook(view, "select_node", %{"node" => "not_a_vertex"})
      assert has_element?(view, "#run-selected-name", "main")

      render_hook(view, "deselect_node", %{})
      refute has_element?(view, "#run-selected")
    end
  end

  describe "navigation" do
    test "a malformed or foreign run is removed with a notice", %{conn: conn} do
      held = start_held()
      other = start_held(hold_run())
      {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}")

      for run <- ["not-a-uuid", other.run_id, Ecto.UUID.generate()] do
        render_patch(view, ~p"/composer/#{held.draft.id}?run=#{run}")
        assert_patch(view, ~p"/composer/#{held.draft.id}")
        assert has_element?(view, "#flash-info", "That run isn't one of this draft's.")
        refute has_element?(view, "#run-header")
        assert has_element?(view, "#composer-header")
      end
    end

    test "a stage round trip keeps the run", %{conn: conn} do
      held = start_held()
      view = open_run(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")

      view |> element("#vertex-main-open") |> render_click()
      assert_patch(view, ~p"/composer/#{held.draft.id}/stages/main?run=#{held.run_id}")
      assert has_element?(view, "#node-hold[data-run-status='running']")

      view |> element("#breadcrumb-workflow") |> render_click()
      assert_patch(view, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")
      assert has_element?(view, "#vertex-main[data-run-status='running']")
    end

    test "a reload mid-run restores level, run and status with no duplicate attempt", %{
      conn: conn
    } do
      held = start_held()
      path = ~p"/composer/#{held.draft.id}/stages/main?run=#{held.run_id}"
      first = open_run(conn, path)
      reloaded = open_run(conn, path)

      for view <- [first, reloaded] do
        assert has_element?(view, "#breadcrumb-stage", "main")
        assert has_element?(view, "#run-id", String.slice(held.run_id, 0, 8))
        assert has_element?(view, "#node-hold[data-run-status='running']")
        assert map_size(fold(view).attempts) == 1
      end
    end

    test "after an A-to-B patch, A's events never change B", %{conn: conn} do
      a = start_held()
      view = open_run(conn, ~p"/composer/#{a.draft.id}/stages/main?run=#{a.run_id}")

      # B is a second run of the same draft.
      {:ok, b_run} = Composer.start_run(start_attrs(a.draft, %{"trap_exit" => false}))
      assert_receive {:entered, "hold", b_runner}, 5_000

      render_patch(view, ~p"/composer/#{a.draft.id}/stages/main?run=#{b_run}")
      render_async(view, 5_000)
      await_delivered(&(&1["type"] == "attempt_admitted"))

      send(a.runner, :release)
      await_phase(open!(a.run_id), "finished")

      assert has_element?(view, "#run-id", String.slice(b_run, 0, 8))
      assert has_element?(view, "#node-hold[data-run-status='running']")

      send(b_runner, :release)
      await_delivered(entered("finished"))
      assert has_element?(view, "#node-hold[data-run-status='succeeded']")
    end

    test "a snapshot whose stage left the draft still opens, with the draft-changed notice",
         %{conn: conn} do
      held = start_held()

      {:ok, document, _kind} =
        Composer.edit(held.draft.document, {:add_stage, "other"})

      {:ok, document, _kind} = Composer.edit(document, {:set_start, "other"})
      {:ok, document, _kind} = Composer.edit(document, {:remove_vertex, "main"})
      {:ok, _saved} = Composer.save_document(held.draft, document)

      view = open_run(conn, ~p"/composer/#{held.draft.id}/stages/main?run=#{held.run_id}")

      assert has_element?(view, "#breadcrumb-stage", "main")
      assert has_element?(view, "#node-hold[data-run-status='running']")
      assert has_element?(view, "#run-draft-changed")
    end

    test "a layout-only move shows no notice", %{conn: conn} do
      held = start_held()

      {:ok, document, :layout} =
        Composer.edit(held.draft.document, {:move, :workflow, "main", 300, 400})

      {:ok, _saved} = Composer.save_document(held.draft, document)

      view = open_run(conn, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")

      refute has_element?(view, "#run-draft-changed")
    end

    test "back to the draft keeps Undo while nothing else saved it", %{conn: conn} do
      held = start_held()
      {:ok, view, _html} = live(conn, ~p"/composer/#{held.draft.id}")
      render_hook(view, "add_vertex", %{"vertex" => %{"name" => "extra", "kind" => "stage"}})

      render_patch(view, ~p"/composer/#{held.draft.id}?run=#{held.run_id}")
      render_async(view, 5_000)
      refute has_element?(view, "#vertex-extra")

      view |> element("#back-to-draft") |> render_click()
      assert_patch(view, ~p"/composer/#{held.draft.id}")
      assert has_element?(view, "#vertex-extra")
      assert has_element?(view, "#undo:not([disabled])")
    end
  end
end

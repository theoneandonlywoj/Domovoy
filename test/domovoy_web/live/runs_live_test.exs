defmodule DomovoyWeb.RunsLiveTest do
  # The call trace sees every process, so this file isn't async.
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1]
  import Ecto.Query

  alias Domovoy.Composer.Run
  alias Domovoy.Composer.Runs
  alias Domovoy.Composer.RunSummary
  alias Domovoy.CoreCallTrace
  alias Domovoy.Repo

  defp row!(draft, seconds_ago) do
    Repo.insert!(
      %Run{
        id: Ecto.UUID.generate(),
        draft_id: draft && draft.id,
        workflow_name: "hold_run",
        document: hold_run(),
        fingerprint: "unstarted",
        start_command_id: "start",
        inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds_ago)
      },
      log: false
    )
  end

  defp summarize!(row, phase) do
    :ok =
      Runs.summarize(row.id, %{
        committed_phase: phase,
        outcome: if(phase == "finished", do: "succeeded"),
        generation: 0,
        committed_seq: 3,
        awaiting: [],
        error: nil
      })

    row
  end

  defp age_summary!(row, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds)
    Repo.update_all(from(s in RunSummary, where: s.run_id == ^row.id), set: [refreshed_at: at])
    row
  end

  # The run ids Core was asked to open while `fun` ran.
  defp opened(fun) do
    for {:open, [_runtime, _workflow, run_id, _opts]} <- CoreCallTrace.calls(fun), do: run_id
  end

  # The page's refresh tasks still running, as LiveView tracks its async work.
  defp refresh_tasks(view) do
    %{socket: socket} = :sys.get_state(view.pid)

    for {{:refresh_page, _filters, _cursor}, {_ref, pid, _kind}} <-
          Map.get(socket.private, :live_async, %{}),
        do: pid
  end

  describe "with runs on" do
    setup :setup_runs

    test "the drafts page links to every run", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/composer")
      assert has_element?(view, "#runs-link[href='/composer/runs']")
    end

    test "rows show their summary, and the status filter is allowlisted", %{conn: conn} do
      draft = draft!(hold_run(), "Held")
      waiting = draft |> row!(30) |> summarize!("waiting")
      finished = draft |> row!(20) |> summarize!("finished")

      {:ok, view, _html} = live(conn, ~p"/composer/runs")

      assert has_element?(view, "#run-row-#{waiting.id}-status", "Waiting")
      assert has_element?(view, "#run-row-#{finished.id}-status", "Succeeded")

      assert has_element?(
               view,
               "#run-row-#{waiting.id} a[href='/composer/#{draft.id}?run=#{waiting.id}']"
             )

      assert has_element?(view, "#runs-count", "Showing 2 runs")

      view |> form("#runs-filter", runs_filter: %{status: "attention"}) |> render_change()
      assert_patch(view, ~p"/composer/runs?#{[status: "attention"]}")

      assert has_element?(view, "#run-row-#{waiting.id}")
      refute has_element?(view, "#run-row-#{finished.id}")

      # A status outside the list shows everything, and a malformed draft nothing.
      {:ok, view, _html} = live(conn, ~p"/composer/runs?#{[status: "nonsense"]}")
      assert has_element?(view, "#run-row-#{finished.id}")

      {:ok, view, _html} = live(conn, ~p"/composer/runs?#{[draft: "not-a-uuid"]}")
      refute has_element?(view, "#run-row-#{finished.id}")
      assert has_element?(view, "#runs-empty")

      {:ok, view, _html} = live(conn, ~p"/composer/runs?#{[draft: draft.id]}")
      assert has_element?(view, "#run-row-#{finished.id}")
    end

    test "Show older runs pages 25 at a time, opening no run", %{conn: conn} do
      draft = draft!(hold_run(), "Held")
      rows = for seconds <- 1..30, do: draft |> row!(seconds) |> summarize!("finished")
      {newest, oldest} = Enum.split(rows, 25)

      calls =
        opened(fn ->
          {:ok, view, _html} = live(conn, ~p"/composer/runs")
          render_async(view)

          assert has_element?(view, "#run-row-#{List.last(newest).id}")
          refute has_element?(view, "#run-row-#{hd(oldest).id}")

          view |> element("#runs-more") |> render_click()
          render_async(view)

          assert has_element?(view, "#run-row-#{List.last(oldest).id}")
          assert has_element?(view, "#runs-count", "Showing 30 runs")
          refute has_element?(view, "#runs-more")
        end)

      assert calls == []
    end

    test "a page refreshes only its stale unfinished row, in one task", %{conn: conn} do
      draft = draft!(hold_run(), "Held")
      _fresh = draft |> row!(40) |> summarize!("waiting")
      _finished = draft |> row!(30) |> summarize!("finished") |> age_summary!(600)
      stale = draft |> row!(20) |> summarize!("waiting") |> age_summary!(60)

      calls =
        opened(fn ->
          {:ok, view, _html} = live(conn, ~p"/composer/runs")
          render_async(view)
        end)

      assert calls == [stale.id]
      # It has no Core run, which says nothing newer than the summary, so only its
      # refresh time moves.
      summary = Repo.get(RunSummary, stale.id)
      assert %RunSummary{error_type: nil, committed_phase: "waiting"} = summary
      assert DateTime.diff(DateTime.utc_now(), summary.refreshed_at) < 30
    end

    # The cancelled task may die mid-query, which the sandbox logs as a disconnect.
    @tag :capture_log
    test "a filter event cancels the refresh still running for the list before it", %{
      conn: conn
    } do
      draft = draft!(hold_run(), "Held")
      rows = for seconds <- 1..25, do: draft |> row!(seconds) |> summarize!("waiting")

      {:ok, view, _html} = live(conn, ~p"/composer/runs")
      render_async(view)
      # The first page's refresh made them fresh, so they are aged again.
      Enum.each(rows, &age_summary!(&1, 60))

      # A page of 25 stale rows is still being refreshed when the next filter event
      # comes, which leaves one refresh running: its own.
      render_hook(view, "filter", %{"runs_filter" => %{"status" => "waiting"}})
      [first] = refresh_tasks(view)
      ref = Process.monitor(first)

      render_hook(view, "filter", %{"runs_filter" => %{"status" => "attention"}})
      assert_receive {:DOWN, ^ref, :process, ^first, {:shutdown, :cancel}}, 5_000
      # Only the newest list's refresh is left to wait for, if it hasn't ended yet.
      %{socket: %{assigns: %{refreshes: refreshes}}} = :sys.get_state(view.pid)
      assert refreshes in [[], [{:refresh_page, %{draft_id: nil, status: "attention"}, nil}]]
      render_async(view)
    end

    test "hostile filter and paging events change nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/composer/runs?#{[status: "waiting"]}")

      render_hook(view, "filter", %{"runs_filter" => %{"status" => %{"x" => 1}, "draft" => ["a"]}})

      assert_patch(view, ~p"/composer/runs")

      render_hook(view, "filter", %{"runs_filter" => "junk"})
      render_hook(view, "more", %{"cursor" => "junk"})
      assert has_element?(view, "#runs-empty")
    end

    test "a run whose draft was deleted links to its own route", %{conn: conn} do
      orphan = nil |> row!(10) |> summarize!("finished")

      {:ok, view, _html} = live(conn, ~p"/composer/runs?#{[draft: "deleted"]}")

      assert has_element?(view, "#run-row-#{orphan.id} a[href='/composer/runs/#{orphan.id}']")
      assert has_element?(view, "#run-row-#{orphan.id}", "Draft deleted")
    end
  end

  describe "with runs off" do
    setup do
      previous = Application.get_env(:domovoy, :composer_runs_enabled)
      Application.put_env(:domovoy, :composer_runs_enabled, false)
      on_exit(fn -> Application.put_env(:domovoy, :composer_runs_enabled, previous) end)
    end

    test "says so, and reads nothing", %{conn: conn} do
      calls =
        CoreCallTrace.calls(fn ->
          {:ok, view, _html} = live(conn, ~p"/composer/runs")
          assert has_element?(view, "#runs-unavailable")
          refute has_element?(view, "#runs-filter")
          refute has_element?(view, "#runs")
        end)

      assert calls == []

      {:ok, view, _html} = live(conn, ~p"/composer")
      refute has_element?(view, "#runs-link")
    end
  end
end

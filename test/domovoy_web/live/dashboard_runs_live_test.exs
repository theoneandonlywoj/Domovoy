defmodule DomovoyWeb.DashboardRunsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1]

  alias Domovoy.Composer.Run
  alias Domovoy.Composer.Runs
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

  describe "with runs on" do
    setup :setup_runs

    test "the runs list renders in the dashboard, with Workflows active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/runs")

      assert has_element?(view, "#runs")
      assert has_element?(view, "#dashboard-nav-workflows[aria-current='page']")
    end

    test "its links and filter patches stay in the dashboard", %{conn: conn} do
      draft = draft!(hold_run(), "Held")
      run = draft |> row!(20) |> summarize!("finished")
      orphan = nil |> row!(10) |> summarize!("finished")

      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/runs")

      assert has_element?(view, "nav[aria-label='Breadcrumb'] a[href='/dashboard/workflows']")

      assert has_element?(
               view,
               "#open-run-row-#{run.id}[href='/dashboard/workflows/#{draft.id}?run=#{run.id}']"
             )

      assert has_element?(
               view,
               "#open-run-row-#{orphan.id}[href='/dashboard/workflows/runs/#{orphan.id}']"
             )

      refute has_element?(view, "a[href^='/composer']")

      view |> form("#runs-filter", runs_filter: %{status: "attention"}) |> render_change()
      assert_patch(view, "/dashboard/workflows/runs?status=attention")
    end

    test "malformed filters fall back to all and match no row", %{conn: conn} do
      draft!(hold_run(), "Held") |> row!(20) |> summarize!("finished")

      {:ok, view, _html} =
        live(conn, ~p"/dashboard/workflows/runs?status=nonsense&draft=not-a-uuid")

      assert has_element?(
               view,
               "#runs-filter select[name='runs_filter[status]'] option[value='all'][selected]"
             )

      refute has_element?(view, "#runs [id^='run-row-']")
    end
  end

  describe "with runs off" do
    setup do
      previous = Application.get_env(:domovoy, :composer_runs_enabled)
      Application.put_env(:domovoy, :composer_runs_enabled, false)
      on_exit(fn -> Application.put_env(:domovoy, :composer_runs_enabled, previous) end)
    end

    test "says so inside the dashboard shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows/runs")

      assert has_element?(view, "#runs-unavailable")
      assert has_element?(view, "#dashboard-nav-workflows[aria-current='page']")
    end
  end
end

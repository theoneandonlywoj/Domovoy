defmodule DomovoyWeb.DashboardWorkflowsRunsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.RunCase, only: [setup_runs: 1, start_attrs: 2]

  alias Domovoy.Composer

  setup :setup_runs

  test "a card shows its draft's newest run, and none without one", %{conn: conn} do
    ran = draft!(leak_run(), "Ran")
    idle = draft!(leak_run(), "Idle")

    {:ok, _run_id} =
      Composer.start_run(start_attrs(ran, %{"secret" => "s", "mode" => "succeed"}))

    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    # The tone depends on how far the run got, so only the pill itself is asserted.
    assert has_element?(view, "#workflow-#{ran.id}-last-run[data-run-pill]")
    refute has_element?(view, "#workflow-#{idle.id}-last-run")
  end
end

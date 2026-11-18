defmodule DomovoyWeb.DashboardCreateProjectLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.DashboardFixtures

  alias Domovoy.Dashboard
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project
  alias Domovoy.Repo

  @dialog "#dashboard-new-project-dialog"

  # Seeds may be committed in the shared test DB, so the rows are cleared first; the
  # delete rolls back with the test.
  setup do
    Repo.delete_all(Job)
    Repo.delete_all(Project)
    :ok
  end

  @spec text(view :: term(), selector :: String.t()) :: String.t()
  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  @spec open(conn :: Plug.Conn.t()) :: term()
  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/projects")
    view |> element("#dashboard-new-project-open") |> render_click()
    view
  end

  @spec submit(view :: term(), attrs :: map()) :: String.t()
  defp submit(view, attrs),
    do: view |> form("#dashboard-new-project", project: attrs) |> render_submit()

  test "the n p button exists only on the projects panel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/projects")
    assert has_element?(view, ~s(#dashboard-new-project-open[data-shortcut="n p"]))

    for path <- ["/dashboard", "/dashboard/jobs", "/dashboard/workflows"] do
      {:ok, other, _html} = live(conn, path)
      refute has_element?(other, "#dashboard-new-project-open")
    end
  end

  test "the button opens the dialog with its explainer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/projects")
    refute has_element?(view, @dialog)

    view |> element("#dashboard-new-project-open") |> render_click()
    assert has_element?(view, ~s(#{@dialog}[role="dialog"][aria-modal="true"]))
    assert has_element?(view, "#dashboard-new-project-explainer")
    refute has_element?(view, "#{@dialog}[phx-window-keydown]")
  end

  test "a valid submit closes the dialog and shows an idle card with zero stats", %{conn: conn} do
    view = open(conn)
    submit(view, %{name: "Nova", path: "~/Repos/Nova"})
    refute has_element?(view, @dialog)

    nova = Enum.find(Dashboard.list_projects(), &(&1.name == "Nova"))
    id = "project-#{nova.id}"

    assert has_element?(view, "##{id}-status", "Idle")
    assert text(view, "##{id}-counts") == "0 repos · 0 worktrees · 0 jobs · 0 workflows"

    bars =
      view
      |> element("##{id}-activity")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[aria-hidden] > span")
      |> Enum.to_list()

    assert length(bars) == 14
    assert Enum.all?(bars, &(LazyHTML.attribute(&1, "style") == ["height: 0%"]))

    {:ok, reloaded, _html} = live(conn, ~p"/dashboard/projects")
    assert has_element?(reloaded, "##{id}")

    {:ok, overview, _html} = live(conn, ~p"/dashboard")
    assert text(overview, "#dashboard-tile-projects-count") == "1"
  end

  test "a blank submit keeps the dialog with errors and inserts nothing", %{conn: conn} do
    view = open(conn)
    submit(view, %{name: "", path: ""})

    assert has_element?(view, "#{@dialog} .text-error")
    assert Dashboard.count_projects() == 0
  end

  test "a duplicate name keeps the dialog with one name error", %{conn: conn} do
    project!(%{"name" => "Nova"})
    view = open(conn)
    submit(view, %{name: "Nova", path: "~/elsewhere"})

    assert has_element?(view, @dialog)

    assert text(view, "#{@dialog} .fieldset:has(#project_name) .text-error") ==
             "has already been taken"

    assert Dashboard.count_projects() == 1
  end

  test "a name with NUL is refused and not echoed", %{conn: conn} do
    view = open(conn)
    submit(view, %{name: "a\u0000b", path: "x"})

    assert has_element?(view, "#{@dialog} .fieldset:has(#project_name) .text-error")
    assert has_element?(view, ~s(#project_name[value=""]))
    assert Dashboard.count_projects() == 0
  end

  test "a non-string name shows an error without a crash", %{conn: conn} do
    view = open(conn)
    render_submit(view, "create_project", %{"project" => %{"name" => %{"a" => 1}, "path" => "x"}})

    assert has_element?(view, "#{@dialog} .text-error")
    assert render(view)
    assert Dashboard.count_projects() == 0
  end

  test "Cancel and the hook-pushed Escape close the dialog", %{conn: conn} do
    view = open(conn)
    view |> element("#dashboard-cancel-project") |> render_click()
    refute has_element?(view, @dialog)

    view |> element("#dashboard-new-project-open") |> render_click()
    view |> element("#dashboard-new-project") |> render_hook("close_create", %{})
    refute has_element?(view, @dialog)
  end

  describe "events from another panel" do
    test "create_project on the jobs panel inserts nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
      before = Dashboard.count_projects()

      render_submit(view, "create_project", %{"project" => %{"name" => "Rogue", "path" => "x"}})

      assert render(view)
      assert Dashboard.count_projects() == before
    end

    test "open_create for a project on the workflows panel renders no dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")
      render_click(view, "open_create", %{"entity" => "project"})

      refute has_element?(view, @dialog)
    end
  end
end

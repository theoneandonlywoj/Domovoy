defmodule DomovoyWeb.DashboardCreateJobLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures
  import Domovoy.DashboardFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.Draft
  alias Domovoy.Dashboard
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project
  alias Domovoy.Repo

  @dialog "#dashboard-new-job-dialog"

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
    {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
    view |> element("#dashboard-new-job-open") |> render_click()
    view
  end

  @spec job_count() :: non_neg_integer()
  defp job_count, do: Repo.aggregate(Job, :count)

  describe "with a project and a workflow" do
    setup do
      %{project: project!(%{"name" => "Borg"}), draft: draft!(scenario_a(), "Release")}
    end

    test "the n j button exists only on the jobs panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
      assert has_element?(view, ~s(#dashboard-new-job-open[data-shortcut="n j"]))

      for path <- ["/dashboard", "/dashboard/projects", "/dashboard/workflows"] do
        {:ok, other, _html} = live(conn, path)
        refute has_element?(other, "#dashboard-new-job-open")
      end
    end

    test "the selects list the drafts and the projects", %{conn: conn, project: project} do
      view = open(conn)

      assert has_element?(view, ~s(#{@dialog}[role="dialog"][aria-modal="true"]))
      assert has_element?(view, "#job_draft_id option", "Release")
      assert has_element?(view, ~s(#job_project_id option[value="#{project.id}"]), "Borg")
      refute has_element?(view, "#dashboard-new-job-hint")
    end

    test "a valid submit shows a queued row and grows the counts",
         %{conn: conn, project: project, draft: draft} do
      {:ok, overview, _html} = live(conn, ~p"/dashboard")
      active = String.to_integer(text(overview, "#dashboard-tile-jobs-count"))

      view = open(conn)
      queued = String.to_integer(text(view, "#jobs-chip-queued-count"))

      view
      |> form("#dashboard-new-job",
        job: %{title: "Ship it", draft_id: draft.id, project_id: project.id, branch: "main"}
      )
      |> render_submit()

      refute has_element?(view, @dialog)
      [job] = Dashboard.list_jobs()
      id = "job-#{job.number}"

      assert has_element?(view, "##{id}-status", "Queued")
      assert has_element?(view, "##{id}-workflow", "Release")
      assert has_element?(view, "##{id}-project", "Borg")
      refute has_element?(view, "##{id}-progress")
      assert text(view, "#jobs-chip-queued-count") == Integer.to_string(queued + 1)

      {:ok, overview, _html} = live(conn, ~p"/dashboard")
      assert text(overview, "#dashboard-tile-jobs-count") == Integer.to_string(active + 1)
    end

    test "a tampered project id is a field error", %{conn: conn, draft: draft} do
      view = open(conn)

      render_submit(view, "create_job", %{
        "job" => %{"title" => "x", "project_id" => "not-a-uuid", "draft_id" => draft.id}
      })

      assert has_element?(view, "#job_project_id.select-error")
      assert render(view)
      assert job_count() == 0
    end

    test "a draft deleted after the modal opened is a field error",
         %{conn: conn, project: project, draft: draft} do
      view = open(conn)
      {:ok, _deleted} = Composer.delete_draft(draft)

      view
      |> form("#dashboard-new-job",
        job: %{title: "x", draft_id: draft.id, project_id: project.id}
      )
      |> render_submit()

      assert has_element?(view, "#job_draft_id.select-error")
      assert job_count() == 0
    end

    test "non-string values show errors without a crash", %{conn: conn} do
      view = open(conn)

      render_submit(view, "create_job", %{
        "job" => %{"title" => %{"a" => 1}, "project_id" => ["x"]}
      })

      assert has_element?(view, "#{@dialog} .text-error")
      assert render(view)
      assert job_count() == 0
    end

    test "a title with NUL is refused and not echoed",
         %{conn: conn, project: project, draft: draft} do
      view = open(conn)

      view
      |> form("#dashboard-new-job",
        job: %{title: "a\u0000b", draft_id: draft.id, project_id: project.id}
      )
      |> render_submit()

      assert has_element?(view, @dialog)
      assert has_element?(view, ~s(#job_title[value=""]))
      assert job_count() == 0
    end

    test "create_job on the projects panel inserts nothing",
         %{conn: conn, project: project, draft: draft} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/projects")

      render_submit(view, "create_job", %{
        "job" => %{"title" => "Rogue", "project_id" => project.id, "draft_id" => draft.id}
      })

      assert render(view)
      assert job_count() == 0
    end
  end

  describe "with no projects and no drafts" do
    setup do
      Repo.delete_all(Draft)
      :ok
    end

    test "the selects and the hint say what to create first", %{conn: conn} do
      view = open(conn)

      assert text(view, ~s(#job_project_id option[value=""])) == "Create a project first"
      assert text(view, ~s(#job_draft_id option[value=""])) == "Create a workflow first"
      assert has_element?(view, "#dashboard-new-job-hint", "Create a project first.")
      assert has_element?(view, "#dashboard-new-job-hint", "Create a workflow first.")

      view |> form("#dashboard-new-job", job: %{title: "x"}) |> render_submit()

      assert has_element?(view, "#job_project_id.select-error")
      assert has_element?(view, "#job_draft_id.select-error")
      assert has_element?(view, "#dashboard-new-job-hint")
      assert job_count() == 0
    end
  end
end

defmodule DomovoyWeb.DashboardWorkflowsLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures
  import Domovoy.DashboardFixtures

  alias Domovoy.Composer

  defp card_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#drafts > [id^='workflow-']")
    |> Enum.count()
  end

  test "lists the drafts as cards with Workflows active", %{conn: conn} do
    draft = draft!(scenario_a(), "Scenario A")
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    assert has_element?(view, "#dashboard-nav-workflows[aria-current='page']")
    assert has_element?(view, "#drafts[phx-update='stream'] #workflow-#{draft.id}", "Scenario A")

    assert has_element?(
             view,
             "#open-workflow-#{draft.id}[href='/dashboard/workflows/#{draft.id}']"
           )

    assert has_element?(view, "#workflow-#{draft.id}-stages", "1 stage")
  end

  test "search narrows the cards, and a query with no match shows none", %{conn: conn} do
    kept = draft!(scenario_a(), "Borg nightly")
    other = draft!(scenario_a(), "Something else")
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")
    all = card_count(view)
    assert all >= 2

    view |> form("#dashboard-search", search: %{q: "borg night"}) |> render_change()
    assert_patch(view, ~p"/dashboard/workflows?#{[q: "borg night"]}")
    view |> form("#dashboard-search", search: %{q: "borg "}) |> render_change()
    assert_patch(view, ~p"/dashboard/workflows?#{[q: "borg"]}")
    assert has_element?(view, "#workflow-#{kept.id}")
    refute has_element?(view, "#workflow-#{other.id}")
    assert card_count(view) < all

    {:ok, empty, _html} = live(conn, ~p"/dashboard/workflows?q=zzz")
    assert card_count(empty) == 0
    assert has_element?(empty, "#drafts-empty")
  end

  test "a card draws its layout, or a placeholder when it has none", %{conn: conn} do
    drawn = draft!(scenario_a(), "Drawn")
    bare = draft!(put_in(scenario_a(), ["layout", "workflow"], %{}), "Bare")
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    assert has_element?(view, "#workflow-#{drawn.id}-miniature")
    refute has_element?(view, "#workflow-#{drawn.id}-placeholder")
    assert has_element?(view, "#workflow-#{bare.id}-placeholder")
    refute has_element?(view, "#workflow-#{bare.id}-miniature")
  end

  test "a malformed layout draws the placeholder and the page still renders", %{conn: conn} do
    good = draft!(scenario_a(), "Good")

    bad =
      for layout <- ["x", 1, ["a"], %{"workflow" => "x"}],
          do: draft!(Map.put(scenario_a(), "layout", layout), "Bad")

    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    assert has_element?(view, "#workflow-#{good.id}-miniature")
    for draft <- bad, do: assert(has_element?(view, "#workflow-#{draft.id}-placeholder"))
  end

  test "with runs off, a card shows no last run", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    assert has_element?(view, "#workflow-#{draft.id}")
    refute has_element?(view, "#workflow-#{draft.id}-last-run")
  end

  defp open_new_workflow(view) do
    view |> element("#dashboard-new-workflow-open") |> render_click()
    view
  end

  test "creating a workflow opens it in the dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")
    open_new_workflow(view)
    assert has_element?(view, "#dashboard-create-workflow[phx-disable-with]")

    view
    |> form("#dashboard-new-workflow", draft: %{title: "From the dashboard"})
    |> render_submit()

    {path, _flash} = assert_redirect(view)

    assert [%{id: id}] =
             Enum.filter(Composer.list_drafts(), &(&1.title == "From the dashboard"))

    assert String.starts_with?(path, "/dashboard/workflows/")
    assert path == ~p"/dashboard/workflows/#{id}"
  end

  test "a refused title shows an error and keeps the dialog open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")
    open_new_workflow(view)
    before = Composer.count_drafts()

    view |> form("#dashboard-new-workflow", draft: %{title: "   "}) |> render_submit()

    assert has_element?(view, "#dashboard-new-workflow-dialog")
    assert has_element?(view, "#dashboard-new-workflow .text-error")
    assert Composer.count_drafts() == before
  end

  test "the floating button carries its shortcut and opens the dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    assert has_element?(
             view,
             ~s(#dashboard-new-workflow-open[data-shortcut="n w"][aria-haspopup="dialog"][phx-click])
           )

    # Closed means absent: any [aria-modal] in the DOM blocks page shortcuts and hints.
    refute has_element?(view, "#dashboard-new-workflow-dialog")
    open_new_workflow(view)

    assert has_element?(
             view,
             ~s(#dashboard-new-workflow-dialog[role="dialog"][aria-modal="true"])
           )

    refute has_element?(view, "#dashboard-new-workflow-dialog[phx-window-keydown]")

    assert has_element?(view, "#dashboard-new-workflow-explainer")
    assert has_element?(view, "#draft_title[phx-mounted]")
    assert has_element?(view, ~s(#dashboard-new-workflow[phx-hook]))

    assert has_element?(
             view,
             ~s(#dashboard-create-workflow[aria-keyshortcuts="Meta+Enter Control+Enter"])
           )
  end

  test "Cancel and the hook's close event close the dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    open_new_workflow(view)
    render_click(element(view, "#dashboard-cancel-workflow"))
    refute has_element?(view, "#dashboard-new-workflow-dialog")

    open_new_workflow(view)
    view |> element("#dashboard-new-workflow") |> render_hook("close_create", %{})
    refute has_element?(view, "#dashboard-new-workflow-dialog")
  end

  # No automated test runs the colocated hooks, so this only shows the IME-safe Escape
  # code is in place; the browser checklist covers its behaviour.
  test "the dialogs own Escape in their hooks, not a window binding" do
    src = File.read!("lib/domovoy_web/components/dashboard_components.ex")

    refute src =~ "phx-window-keydown"
    assert src =~ ~s|pushEvent("close_create"|
    assert src =~ ~s|pushEvent("cancel_delete"|
    assert length(String.split(src, "isComposing")) - 1 >= 2
  end

  test "no panel binds the old create prefix", %{conn: conn} do
    for path <- ["/dashboard", "/dashboard/projects", "/dashboard/jobs", "/dashboard/workflows"] do
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, ~s([data-shortcut^="c "]))
    end
  end

  test "each panel has only its own button", %{conn: conn} do
    panels = [
      {"/dashboard", nil},
      {"/dashboard/projects", "project"},
      {"/dashboard/jobs", "job"},
      {"/dashboard/workflows", "workflow"}
    ]

    for {path, own} <- panels do
      {:ok, view, _html} = live(conn, path)

      for entity <- ["project", "job", "workflow"] do
        assert has_element?(view, "#dashboard-new-#{entity}-open") == (entity == own)
      end
    end
  end

  describe "deleting a workflow" do
    test "Delete asks first; Cancel and Esc keep the workflow", %{conn: conn} do
      draft = draft!(scenario_a(), "Keep me")
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

      refute has_element?(view, "#confirm-delete-workflow")
      view |> element("#workflow-#{draft.id}-delete") |> render_click()

      assert has_element?(view, "#confirm-delete-workflow[role=alertdialog][aria-modal=true]")
      assert has_element?(view, "#confirm-delete-workflow-title", "Keep me")
      assert has_element?(view, "#confirm-delete-workflow[phx-hook]")
      refute has_element?(view, "#confirm-delete-workflow[phx-window-keydown]")

      assert has_element?(
               view,
               ~s(#confirm-delete-workflow-button[aria-keyshortcuts="Meta+Enter Control+Enter"])
             )

      view |> element("#cancel-delete-workflow") |> render_click()
      refute has_element?(view, "#confirm-delete-workflow")
      assert has_element?(view, "#workflow-#{draft.id}")

      view |> element("#workflow-#{draft.id}-delete") |> render_click()
      view |> element("#confirm-delete-workflow") |> render_hook("cancel_delete", %{})
      refute has_element?(view, "#confirm-delete-workflow")
      assert {:ok, _draft} = Composer.get_draft(draft.id)
    end

    test "confirming deletes the workflow and removes its card", %{conn: conn} do
      draft = draft!(scenario_a(), "Delete me")
      other = draft!(scenario_a(), "Stays")
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

      view |> element("#workflow-#{draft.id}-delete") |> render_click()
      view |> element("#confirm-delete-workflow-button") |> render_click()

      refute has_element?(view, "#confirm-delete-workflow")
      refute has_element?(view, "#workflow-#{draft.id}")
      assert has_element?(view, "#workflow-#{other.id}")
      assert {:error, _gone} = Composer.get_draft(draft.id)
    end

    test "deleting a workflow a job runs keeps the job and its workflow name", %{conn: conn} do
      draft = draft!(scenario_a(), "Release")
      job = job!(project!(), %{"draft_id" => draft.id})
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

      view |> element("#workflow-#{draft.id}-delete") |> render_click()
      view |> element("#confirm-delete-workflow-button") |> render_click()
      refute has_element?(view, "#workflow-#{draft.id}")

      {:ok, view, _html} = live(conn, ~p"/dashboard/jobs")
      assert has_element?(view, "#job-#{job.number}-workflow", "Release")
    end

    test "a stale or bogus delete request leaves the page working", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

      render_hook(view, "ask_delete", %{"id" => Ecto.UUID.generate()})
      refute has_element?(view, "#confirm-delete-workflow")
      render_hook(view, "delete", %{})
      assert has_element?(view, "#drafts")
    end
  end

  test "hostile events leave the page alive", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    render_hook(view, "open_create", %{"entity" => "nope"})
    refute has_element?(view, "#dashboard-new-workflow-dialog")

    for {event, params} <- [
          {"nope", %{}},
          {"create", %{"draft" => "x"}},
          {"create", %{"draft" => %{"title" => %{"a" => 1}}}},
          {"create", %{"draft" => %{"title" => "a\0b"}}},
          {"search", %{"search" => %{"q" => %{"a" => 1}}}},
          {"search", %{}}
        ] do
      render_hook(view, event, params)
    end

    assert has_element?(view, "#workflow-#{draft.id}")
  end

  test "create on another panel inserts no draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/projects")
    before = Composer.count_drafts()

    render_hook(view, "create", %{"draft" => %{"title" => "x"}})

    assert Composer.count_drafts() == before
    assert has_element?(view, "#projects")
  end
end

defmodule DomovoyWeb.DashboardWorkflowsLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

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

  test "creating a workflow opens it in the dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")
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

  test "a refused title shows an error and stays on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

    view |> form("#dashboard-new-workflow", draft: %{title: "   "}) |> render_submit()

    assert has_element?(view, "#dashboard-new-workflow")
    assert has_element?(view, "#dashboard-new-workflow .text-error")
  end

  test "hostile events leave the page alive", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/dashboard/workflows")

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
end

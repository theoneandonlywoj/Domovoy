defmodule DomovoyWeb.DashboardComposerLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.Document

  defp open(conn, draft, path \\ nil) do
    {:ok, view, _html} = live(conn, path || ~p"/dashboard/workflows/#{draft.id}")
    view
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()

  # Every `/composer` link inside the dashboard must be the export download, the only
  # exit the dashboard has.
  defp hrefs_leak?(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("a[href]")
    |> LazyHTML.attribute("href")
    |> Enum.any?(fn href ->
      String.starts_with?(href, "/composer") and not String.ends_with?(href, "/export")
    end)
  end

  test "the composer renders beside the drawer, with Workflows active", %{conn: conn} do
    draft = draft!(scenario_a())
    view = open(conn, draft)

    assert has_element?(view, "#composer")
    assert has_element?(view, "#dashboard-drawer[data-modal-background]")
    assert has_element?(view, "#dashboard-nav-workflows[aria-current='page']")
    assert has_element?(view, "#breadcrumb a[href='/dashboard/workflows']", "Drafts")
    refute hrefs_leak?(view)
  end

  test "a stage's Open and the breadcrumb stay in the dashboard", %{conn: conn} do
    draft = draft!(scenario_a())
    view = open(conn, draft)

    click(view, "#vertex-prepare-open")
    assert_patch(view, "/dashboard/workflows/#{draft.id}/stages/prepare")
    assert has_element?(view, "#node-ask_claude")
    refute hrefs_leak?(view)

    click(view, "#breadcrumb-workflow")
    assert_patch(view, "/dashboard/workflows/#{draft.id}")
    refute hrefs_leak?(view)
  end

  test "issue links stay in the dashboard", %{conn: conn} do
    document =
      edit_all(scenario_a(), [
        {:put_choice, "review",
         %{"name" => "bad", "description" => "Bad", "target" => ["rerun", "review"]}}
      ])

    draft = draft!(document)
    view = open(conn, draft, ~p"/dashboard/workflows/#{draft.id}/stages/prepare?tools=1")

    hrefs =
      view
      |> element("#issues")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a[href^='/']")
      |> LazyHTML.attribute("href")

    assert hrefs != []
    assert Enum.all?(hrefs, &String.starts_with?(&1, "/dashboard/workflows/#{draft.id}"))
    refute hrefs_leak?(view)
  end

  test "a run that isn't the draft's patches back to it in the dashboard", %{conn: conn} do
    draft = draft!(scenario_a())
    view = open(conn, draft)

    render_patch(view, ~p"/dashboard/workflows/#{draft.id}?run=#{Ecto.UUID.generate()}")
    assert_patch(view, "/dashboard/workflows/#{draft.id}")
    assert has_element?(view, "#flash-info")
    refute hrefs_leak?(view)
  end

  test "loading the latest after a conflict stays in the dashboard", %{conn: conn} do
    draft = draft!(scenario_a())
    path = ~p"/dashboard/workflows/#{draft.id}/stages/prepare"
    stale = open(conn, draft, path)
    fresh = open(conn, draft, path)

    render_hook(fresh, "node_moved", %{
      "node" => "ask_claude",
      "x" => 10,
      "y" => 20,
      "level" => "stage:prepare"
    })

    render_hook(stale, "node_moved", %{
      "node" => "ask_claude",
      "x" => 30,
      "y" => 40,
      "level" => "stage:prepare"
    })

    assert has_element?(stale, "#conflict-banner")

    click(stale, "#load-latest")
    assert_patch(stale, path)
    refute has_element?(stale, "#conflict-banner")
    refute hrefs_leak?(stale)
  end

  test "undoing the stage on screen leads back to the workflow", %{conn: conn} do
    draft = draft!(Document.new("w"))
    view = open(conn, draft)

    view |> form("#add-vertex-form", vertex: %{name: "fresh", kind: "stage"}) |> render_submit()
    click(view, "#vertex-fresh-open")
    assert_patch(view, "/dashboard/workflows/#{draft.id}/stages/fresh")
    click(view, "#undo")

    assert_patch(view, "/dashboard/workflows/#{draft.id}")
    refute has_element?(view, "#vertex-fresh")
  end

  test "an unknown stage redirects to the workflow in the dashboard", %{conn: conn} do
    draft = draft!(scenario_a())

    assert {:error, {_kind, %{to: to, flash: %{"info" => _notice}}}} =
             live(conn, ~p"/dashboard/workflows/#{draft.id}/stages/nope")

    assert to == "/dashboard/workflows/#{draft.id}"
  end

  test "a missing draft goes to the dashboard's list with a flash", %{conn: conn} do
    for id <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert {:error,
              {_kind,
               %{
                 to: "/dashboard/workflows",
                 flash: %{"error" => "That draft doesn't exist anymore."}
               }}} = live(conn, ~p"/dashboard/workflows/#{id}")
    end
  end

  test "a draft deleted while open redirects to the dashboard's list", %{conn: conn} do
    draft = draft!(scenario_a())
    view = open(conn, draft, ~p"/dashboard/workflows/#{draft.id}/stages/prepare")
    {:ok, _deleted} = Composer.delete_draft(draft)

    click(view, "#node-ask_claude-select")
    click(view, "#remove-node")

    assert {"/dashboard/workflows", %{"error" => "That draft doesn't exist anymore."}} =
             assert_redirect(view)
  end
end

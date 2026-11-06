defmodule DomovoyWeb.ComposerSeededDraftsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Draft
  alias Domovoy.Examples.Seeds

  # `make db-seed-test` commits the seeds to this database, outside the sandbox. These
  # tests count on starting without them; the delete rolls back with the test.
  setup do
    Domovoy.Repo.delete_all(Draft)
    assert [_create_worktree, _cracow_prices] = Seeds.run()
    :ok
  end

  test "the list shows both, and each opens and reaches Definition valid", %{conn: conn} do
    {:ok, list, _html} = live(conn, ~p"/composer")

    for draft <- Composer.list_drafts() do
      assert has_element?(list, "a[href='/composer/#{draft.id}']")

      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      refute has_element?(view, "#definition-valid")

      view |> element("#validate") |> render_click()
      assert has_element?(view, "#definition-valid")
    end
  end

  test "the route decider shows as the decision's selected decider", %{conn: conn} do
    draft = Enum.find(Composer.list_drafts(), &(&1.document["name"] == "create_worktree"))
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    view |> element("#vertex-route-select") |> render_click()

    assert has_element?(
             view,
             "#decision-form select option[selected]" <>
               "[value='Domovoy.Examples.Worktree.WorktreeRouteDecider']"
           )

    assert has_element?(
             view,
             "#decision-form select option[value='DomovoyCore.Decider.Person']"
           )
  end

  describe "a fresh create_worktree seed shows its descriptions" do
    setup do
      draft = Enum.find(Composer.list_drafts(), &(&1.document["name"] == "create_worktree"))
      %{draft: draft, document: draft.document}
    end

    defp assert_title(view, selector, item) do
      assert {:ok, text} = Document.description(item)
      icon = view |> element(selector) |> render() |> LazyHTML.from_fragment()
      assert LazyHTML.attribute(icon, "title") == [text]
    end

    test "on the workflow view", %{conn: conn, draft: draft, document: document} do
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

      assert_title(view, "#vertex-route-description", document["vertices"]["route"])
    end

    test "on stage inspect", %{conn: conn, draft: draft, document: document} do
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/inspect")
      resolve = document["vertices"]["inspect"]["nodes"]["resolve"]
      branch_name = document["inputs"]["branch_name"]

      assert_title(view, "#node-resolve-description", resolve)
      assert_title(view, "#source-branch_name-description", branch_name)
      assert_title(view, "#input-branch_name-description", branch_name)
    end

    test "on stage create, for an earlier source", %{conn: conn, draft: draft, document: document} do
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/create")
      worktree_name = document["vertices"]["inspect"]["nodes"]["worktree_name"]

      assert_title(view, "#source-worktree_name-description", worktree_name)
    end
  end
end

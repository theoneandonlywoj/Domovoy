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
    assert [_create_worktree, _cracow_prices, _cracow_review] = Seeds.run()
    :ok
  end

  test "the list shows all three, and each opens and reaches Definition valid", %{conn: conn} do
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

    view |> element("#vertex-choose_create_or_use_worktree-select") |> render_click()

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

  test "the decision form shows and saves the node the decider reads", %{conn: conn} do
    draft = Enum.find(Composer.list_drafts(), &(&1.document["name"] == "create_worktree"))
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

    view |> element("#vertex-choose_create_or_use_worktree-select") |> render_click()

    assert has_element?(
             view,
             "#decision-form select[name='decision[node]'] option[selected][value='look_up_worktree']"
           )

    view
    |> form("#decision-form", decision: %{node: "describe_synced_worktree"})
    |> render_submit()

    {:ok, saved} = Composer.get_draft(draft.id)
    decision = saved.document["vertices"]["choose_create_or_use_worktree"]
    assert decision["decider_options"] == %{"node" => "describe_synced_worktree"}
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

      assert_title(
        view,
        "#vertex-choose_create_or_use_worktree-description",
        document["vertices"]["choose_create_or_use_worktree"]
      )
    end

    test "on stage inspect_worktree", %{conn: conn, draft: draft, document: document} do
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/inspect_worktree")
      look_up = document["vertices"]["inspect_worktree"]["nodes"]["look_up_worktree"]
      branch_name = document["inputs"]["branch_name"]

      assert_title(view, "#node-look_up_worktree-description", look_up)
      assert_title(view, "#source-branch_name-description", branch_name)
      assert_title(view, "#input-branch_name-description", branch_name)
    end

    test "on stage create_missing_worktree, for an earlier source", %{
      conn: conn,
      draft: draft,
      document: document
    } do
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/create_missing_worktree")
      worktree_name = document["vertices"]["inspect_worktree"]["nodes"]["derive_worktree_name"]

      assert_title(view, "#source-derive_worktree_name-description", worktree_name)
    end
  end
end

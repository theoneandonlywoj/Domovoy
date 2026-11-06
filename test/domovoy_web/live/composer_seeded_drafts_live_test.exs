defmodule DomovoyWeb.ComposerSeededDraftsLiveTest do
  use DomovoyWeb.ConnCase, async: false

  alias Domovoy.Composer
  alias Domovoy.Examples.Seeds

  setup do
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
end

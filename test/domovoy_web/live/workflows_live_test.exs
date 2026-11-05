defmodule DomovoyWeb.WorkflowsLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer

  test "the home page links to the composer", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("a#composer-link[href='/composer']") |> Enum.count() == 1
  end

  test "lists saved drafts in a stream", %{conn: conn} do
    draft = draft!(scenario_a(), "Scenario A")
    {:ok, view, _html} = live(conn, ~p"/composer")

    assert has_element?(view, "#drafts[phx-update='stream'] #drafts-#{draft.id}", "Scenario A")
    assert has_element?(view, "#open-#{draft.id}[href='/composer/#{draft.id}']")
  end

  test "creating a draft opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/composer")
    assert has_element?(view, "#create-draft[phx-disable-with]")

    view |> form("#draft-form", draft: %{title: "From the form"}) |> render_submit()

    {path, _flash} = assert_redirect(view)

    assert [%{title: "From the form", id: id}] =
             Enum.filter(Composer.list_drafts(), &(&1.title == "From the form"))

    assert path == ~p"/composer/#{id}"
  end

  test "a refused title shows an error and stays on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/composer")

    view |> form("#draft-form", draft: %{title: "   "}) |> render_submit()

    assert has_element?(view, "#draft-form")
    assert has_element?(view, "#draft-form .text-error")
  end

  test "deleting removes the row, and a second delete refreshes the list", %{conn: conn} do
    draft = draft!(scenario_a())
    other = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer")

    view |> element("#delete-#{draft.id}") |> render_click()
    refute has_element?(view, "#drafts-#{draft.id}")
    assert Composer.get_draft(draft.id) == {:error, :not_found}

    {:ok, _deleted} = Composer.delete_draft(other)
    render_hook(view, "delete", %{"id" => other.id})
    refute has_element?(view, "#drafts-#{other.id}")
  end

  test "plugin status separates installed from verified", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/composer")

    assert has_element?(view, "#plugin-git-status", "installed, not verified")
    assert has_element?(view, "#plugin-mise-status", "installed, not verified")
    assert has_element?(view, "#plugin-claude_code-status", "installed, not verified")

    for plugin <- ~w(github linear slack) do
      assert has_element?(view, "#plugin-#{plugin}-status", "not installed")
    end
  end

  test "hostile events leave the page alive", %{conn: conn} do
    draft = draft!(scenario_a())
    {:ok, view, _html} = live(conn, ~p"/composer")

    for {event, params} <- [
          {"nope", %{}},
          {"create", %{"draft" => "x"}},
          {"create", %{"draft" => %{"title" => %{"a" => 1}}}},
          {"create", %{"draft" => %{"title" => "a\0b"}}},
          {"delete", %{}},
          {"delete", %{"id" => %{"a" => 1}}},
          {"delete", %{"id" => "not-a-uuid"}}
        ] do
      render_hook(view, event, params)
    end

    assert has_element?(view, "#drafts-#{draft.id}")
    assert {:ok, _draft} = Composer.get_draft(draft.id)
  end
end

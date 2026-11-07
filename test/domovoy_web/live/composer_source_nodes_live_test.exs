defmodule DomovoyWeb.ComposerSourceNodesLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"

  # Stage `first` makes `made` and `spare`. Stage `second` reads `made`, and leaves `spare`
  # unread. Input `name` shows on both.
  defp sourced do
    edit_all(Document.new("w"), [
      {:put_input, "name", %{"type" => @string, "required" => true}},
      {:add_stage, "first"},
      {:add_stage, "second"},
      {:set_start, "first"},
      {:remove_vertex, "main"},
      {:set_next, "first", "second"},
      {:add_node, "first", @resolve, "made"},
      {:add_node, "first", @resolve, "spare"},
      {:bind, "first", "made", "worktree_name", "name", replace_literal: false},
      {:bind, "first", "spare", "worktree_name", "name", replace_literal: false},
      {:add_node, "second", @directory, "reader"},
      {:add_node, "second", @directory, "idle"},
      {:bind, "second", "reader", "worktree", "made", replace_literal: false},
      {:bind, "second", "idle", "worktree", "made", replace_literal: false}
    ])
  end

  defp open(conn, draft, stage) do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/#{stage}")
    view
  end

  defp move(view, stage, node, x, y) do
    render_hook(view, "node_moved", %{
      "node" => node,
      "x" => x,
      "y" => y,
      "level" => "stage:#{stage}"
    })
  end

  defp lock(draft) do
    {:ok, %{lock_version: lock}} = Composer.get_draft(draft.id)
    lock
  end

  defp position(draft, stage, name), do: saved_document(draft)["layout"]["stages"][stage][name]

  test "an input has a node with its socket, and its rail row has none", %{conn: conn} do
    view = open(conn, draft!(sourced()), "second")

    assert has_element?(view, "article#source-name[data-source-node]")
    assert has_element?(view, ~s(#source-name [data-socket="out:name"][data-source="name"]))
    assert has_element?(view, "#source-name #input-name-connect")
    assert has_element?(view, "#inputs-rows #input-name")
    refute has_element?(view, "#inputs-rows [data-socket]")
    refute has_element?(view, "#inputs-rows #input-name-connect")
  end

  test "a read earlier source has a node, and its row has no socket", %{conn: conn} do
    view = open(conn, draft!(sourced()), "second")

    assert has_element?(view, ~s(#source-made [data-socket="out:made"]))
    assert has_element?(view, "#source-made #prior-made-connect")
    assert has_element?(view, "#prior-made-origin")
    assert has_element?(view, "#prior-made-generation")
    refute has_element?(view, "#prior-made [data-socket]")
    refute has_element?(view, "#prior-made #prior-made-connect")
  end

  test "an unread earlier source keeps its row's socket and Connect to, with no node", %{
    conn: conn
  } do
    view = open(conn, draft!(sourced()), "second")

    refute has_element?(view, "#source-spare")
    assert has_element?(view, ~s(#prior-spare [data-socket="out:spare"]))
    assert has_element?(view, "#prior-spare #prior-spare-connect")
  end

  test "binding an unread earlier source moves its socket to a new node", %{conn: conn} do
    draft = draft!(sourced())
    view = open(conn, draft, "second")

    render_hook(view, "connect", %{"source" => "spare", "node" => "idle", "field" => "worktree"})

    assert saved_document(draft)["vertices"]["second"]["nodes"]["idle"]["inputs"]["worktree"] ==
             %{"bind" => "spare"}

    assert has_element?(view, ~s(#source-spare [data-socket="out:spare"]))
    assert has_element?(view, "#source-spare #prior-spare-connect")
    refute has_element?(view, "#prior-spare [data-socket]")
    refute has_element?(view, "#prior-spare #prior-spare-connect")
  end

  test "every id and socket on the page stays unique", %{conn: conn} do
    view = open(conn, draft!(sourced()), "second")
    document = LazyHTML.from_fragment(render(view))

    for attribute <- ["id", "data-socket"] do
      values = document |> LazyHTML.query("[#{attribute}]") |> LazyHTML.attribute(attribute)
      assert values != []
      assert values == Enum.uniq(values)
    end
  end

  test "an input's issue link still reaches its rail row", %{conn: conn} do
    # A required input with a default is an analyzer issue on that input.
    document =
      edit_all(sourced(), [
        {:put_input, "both", %{"type" => @string, "required" => true, "default" => "x"}}
      ])

    view = open(conn, draft!(document), "second")
    render_click(element(view, "#open-tools"))

    assert has_element?(view, ~s(a[href="#input-both"]))
    assert has_element?(view, "#inputs-rows li#input-both")
  end

  test "opening a stage writes nothing to the draft", %{conn: conn} do
    draft = draft!(sourced())
    before = saved_document(draft)
    version = lock(draft)

    view = open(conn, draft, "second")
    assert has_element?(view, "#source-name")

    assert saved_document(draft) == before
    assert lock(draft) == version
    refute has_element?(view, "#undo:not([disabled])")
  end

  test "moving a source saves it for that stage, keeps validity, and undoes", %{conn: conn} do
    draft = draft!(sourced())
    view = open(conn, draft, "second")
    render_click(element(view, "#validate"))
    fingerprint = view |> element("#definition-fingerprint") |> render()

    move(view, "second", "name", 11.2, -22)
    assert_reply(view, %{status: "ok"})

    assert position(draft, "second", "name") == %{"x" => 11, "y" => -22}
    assert position(draft, "first", "name") == nil
    assert has_element?(view, "#source-name[data-x='11'][data-y='-22'][style*='left:11px']")
    assert has_element?(view, "#definition-valid")
    assert view |> element("#definition-fingerprint") |> render() == fingerprint

    render_click(element(view, "#undo"))

    assert position(draft, "second", "name") == nil
  end

  test "removing an input with two positions clears both, and undo restores all", %{conn: conn} do
    document =
      edit_all(sourced(), [
        {:move, {:stage, "first"}, "name", 1, 2},
        {:move, {:stage, "second"}, "name", 3, 4},
        {:put_input, "extra", %{"type" => @string}},
        {:move, {:stage, "first"}, "extra", 5, 6},
        {:move, {:stage, "second"}, "extra", 7, 8}
      ])

    draft = draft!(document)
    view = open(conn, draft, "second")

    render_click(element(view, "#input-extra-remove"))

    assert position(draft, "first", "extra") == nil
    assert position(draft, "second", "extra") == nil
    refute has_element?(view, "#source-extra")

    render_click(element(view, "#undo"))

    assert is_map_key(saved_document(draft)["inputs"], "extra")
    assert position(draft, "first", "extra") == %{"x" => 5, "y" => 6}
    assert position(draft, "second", "extra") == %{"x" => 7, "y" => 8}
    assert has_element?(view, "#source-extra[data-x='7'][data-y='8']")
  end

  test "moving an unread source is rejected and the draft is unchanged", %{conn: conn} do
    draft = draft!(sourced())
    before = saved_document(draft)
    version = lock(draft)
    view = open(conn, draft, "second")
    assert has_element?(view, "#prior-spare")

    move(view, "second", "spare", 1, 2)

    assert_reply(view, %{status: "rejected"})
    assert saved_document(draft) == before
    assert lock(draft) == version
  end

  test "the workflow canvas has no source nodes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft!(sourced()).id}")

    assert has_element?(view, "#input-name")
    refute has_element?(view, "article[data-source-node]")
    refute has_element?(view, "#inputs-rows [data-socket]")
  end
end

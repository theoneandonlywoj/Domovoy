defmodule DomovoyWeb.ComposerCanvasEventsLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer

  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"

  defp open(conn, document \\ scenario_a()) do
    draft = draft!(document)
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")
    {draft, view}
  end

  defp position(draft, node) do
    saved_document(draft)["layout"]["stages"]["prepare"][node]
  end

  defp move(view, node, x, y) do
    render_hook(view, "node_moved", %{
      "node" => node,
      "x" => x,
      "y" => y,
      "level" => "stage:prepare"
    })
  end

  defp lock(draft) do
    {:ok, %{lock_version: lock}} = Composer.get_draft(draft.id)
    lock
  end

  test "both levels expose accessible local zoom controls outside the world", %{conn: conn} do
    draft = draft!(scenario_a())
    before = saved_document(draft)
    version = lock(draft)

    for path <- [~p"/composer/#{draft.id}", ~p"/composer/#{draft.id}/stages/prepare"] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "#stage-canvas > #canvas-zoom[role='group'][aria-label='Canvas zoom'][data-canvas-control]"
             )

      assert has_element?(
               view,
               "#canvas-zoom-slider[type='range'][min='25'][max='200'][step='5'][value='100']" <>
                 "[aria-label='Canvas zoom level'][phx-update='ignore']"
             )

      assert has_element?(view, "#canvas-zoom-percent[aria-live='polite']", "Fit · 100%")
      assert has_element?(view, "#canvas-zoom-slider[aria-valuetext='Fit · 100%']")
      assert has_element?(view, "#canvas-fit[type='button']")

      assert has_element?(
               view,
               "#canvas-fit",
               if(path =~ "/stages/", do: "Fit stage", else: "Fit workflow")
             )

      assert has_element?(view, "#canvas-fit-selection[type='button'][disabled]")
      assert has_element?(view, "#canvas-actual-size[type='button']")
      refute has_element?(view, "#canvas-zoom-reset")
      refute has_element?(view, "[phx-update='ignore'] #canvas-fit")

      refute has_element?(view, "#stage-world #canvas-zoom")
      refute has_element?(view, "#canvas-zoom [phx-click]")
      refute has_element?(view, "#undo:not([disabled])")
    end

    assert saved_document(draft) == before
    assert lock(draft) == version
  end

  describe "node_moved" do
    test "saves the position, a remount shows it, and identity and validity hold", %{conn: conn} do
      {draft, view} = open(conn)
      render_click(element(view, "#validate"))
      fingerprint = view |> element("#definition-fingerprint") |> render()

      move(view, "ask_claude", 321.4, 654)
      assert_reply(view, %{status: "ok"})

      assert position(draft, "ask_claude") == %{"x" => 321, "y" => 654}
      assert has_element?(view, "#definition-valid")
      assert view |> element("#definition-fingerprint") |> render() == fingerprint

      assert has_element?(
               view,
               "#node-ask_claude[data-x='321'][data-y='654'][style*='left:321px']"
             )

      {:ok, remounted, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")
      assert has_element?(remounted, "#node-ask_claude[data-x='321'][data-y='654']")
    end

    test "an unchanged position replies noop, with no save and no undo", %{conn: conn} do
      {draft, view} = open(conn)
      %{"x" => x, "y" => y} = position(draft, "ask_claude")
      before = lock(draft)

      move(view, "ask_claude", x, y)

      assert_reply(view, %{status: "noop"})
      assert lock(draft) == before
      refute has_element?(view, "#undo:not([disabled])")
    end

    test "a move can be undone", %{conn: conn} do
      {draft, view} = open(conn)
      original = position(draft, "ask_claude")

      move(view, "ask_claude", 1, 2)
      render_hook(view, "undo", %{})

      assert position(draft, "ask_claude") == original
      refute has_element?(view, "#undo:not([disabled])")
    end

    test "from a stale tab replies conflict and keeps the newer save", %{conn: conn} do
      {draft, stale} = open(conn)
      {:ok, fresh, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")

      move(fresh, "ask_claude", 10, 20)
      assert_reply(fresh, %{status: "ok"})

      move(stale, "ask_claude", 30, 40)
      assert_reply(stale, %{status: "conflict"})

      assert position(draft, "ask_claude") == %{"x" => 10, "y" => 20}
      assert has_element?(stale, "#conflict-banner")
    end

    test "a position that isn't a number is refused and the view lives", %{conn: conn} do
      {draft, view} = open(conn)
      before = saved_document(draft)

      for {x, y} <- [{"12", 1}, {1, nil}, {%{"a" => 1}, 1}, {[1], 1}, {true, 1}] do
        move(view, "ask_claude", x, y)
        assert_reply(view, %{status: "rejected"})
        assert saved_document(draft) == before
        assert has_element?(view, "#composer")
      end
    end

    test "an unknown node is refused", %{conn: conn} do
      {draft, view} = open(conn)
      before = saved_document(draft)

      move(view, "gone", 1, 2)

      assert_reply(view, %{status: "rejected"})
      assert saved_document(draft) == before
    end

    test "a workflow card's release can't move the node of that name in a stage", %{conn: conn} do
      draft = draft!(edit_all(scenario_a(), [{:add_node, "prepare", @directory, "prepare"}]))
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")
      before = saved_document(draft)

      render_hook(view, "node_moved", %{
        "node" => "prepare",
        "x" => 7,
        "y" => 8,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "rejected"})
      assert saved_document(draft) == before
      refute has_element?(view, "#rejection")
    end

    test "a stage's release can't move the vertex it raced back to", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      before = saved_document(draft)

      render_hook(view, "node_moved", %{
        "node" => "prepare",
        "x" => 7,
        "y" => 8,
        "level" => "stage:prepare"
      })

      assert_reply(view, %{status: "rejected"})
      assert saved_document(draft) == before
    end

    test "a wrong shape gets no status, which the hook reverts", %{conn: conn} do
      {draft, view} = open(conn)
      before = saved_document(draft)

      render_hook(view, "node_moved", %{"node" => "ask_claude"})

      assert saved_document(draft) == before
      assert has_element?(view, "#composer")
    end
  end

  describe "connect" do
    test "a drag's event gives the same binding as the form", %{conn: conn} do
      document =
        edit_all(scenario_a(), [{:clear_input, "prepare", "ask_claude", "context"}])

      {by_drag, drag_view} = open(conn, document)
      {by_form, form_view} = open(conn, document)

      render_hook(drag_view, "connect", %{
        "source" => "prompt",
        "node" => "ask_claude",
        "field" => "context"
      })

      form_view |> element("#input-prompt-connect") |> render_click()
      form_view |> element("#connect-ask_claude-context") |> render_click()

      assert saved_document(by_drag) == saved_document(by_form)
      assert has_element?(drag_view, "#field-ask_claude-context-value", "prompt")
    end

    test "a mismatch shows the explanation with its adapter, changing nothing", %{conn: conn} do
      {draft, view} = open(conn)
      before = saved_document(draft)

      render_hook(view, "connect", %{
        "source" => "resolve_worktree",
        "node" => "ask_claude",
        "field" => "working_directory"
      })

      assert has_element?(view, "#rejection-message", "Git Worktree")
      assert has_element?(view, "#adapter-DomovoyGitPlugin-Runner-WorktreeDirectory")
      assert saved_document(draft) == before
    end

    test "over a literal asks to confirm", %{conn: conn} do
      {draft, view} =
        open(
          conn,
          edit_all(scenario_a(), [
            {:set_literal, "prepare", "ask_claude", "context", "Review", replace_binding: true}
          ])
        )

      before = saved_document(draft)

      render_hook(view, "connect", %{
        "source" => "prompt",
        "node" => "ask_claude",
        "field" => "context"
      })

      assert has_element?(view, "#confirm-replace-literal")
      assert saved_document(draft) == before
    end

    test "add_after from the handle adds ordering only", %{conn: conn} do
      {draft, view} = open(conn)
      inputs = saved_document(draft)["vertices"]["prepare"]["nodes"]["detect_mise"]["inputs"]

      render_hook(view, "add_after", %{
        "after" => %{"node" => "detect_mise", "source" => "resolve_worktree"}
      })

      node = saved_document(draft)["vertices"]["prepare"]["nodes"]["detect_mise"]
      assert node["after"] == ["resolve_worktree"]
      assert node["inputs"] == inputs
      render_click(element(view, "#open-tools"))
      assert has_element?(view, "#rel-after-detect_mise-resolve_worktree")
    end
  end

  describe "connect_preview" do
    defp preview(view, params) do
      render_hook(view, "connect_preview", params)
      assert_reply(view, %{targets: targets})
      Map.new(targets, &{&1.socket, &1})
    end

    test "says what fits, with a cycle target not fitting", %{conn: conn} do
      {_draft, view} = open(conn)

      targets = preview(view, %{"source" => "ask_claude", "kind" => "value"})

      assert %{fit: :incompatible, label: label} = targets["in:trust_mise.worktree"]
      refute label =~ "accepted by Any"
      assert targets["in:ask_claude.context"].fit == :incompatible
    end

    test "agrees with the Connect-to list", %{conn: conn} do
      {_draft, view} = open(conn)

      targets = preview(view, %{"source" => "resolve_worktree", "kind" => "value"})

      assert targets["in:worktree_directory.worktree"].fit == :exact
      assert targets["in:trust_mise.worktree"].fit == :accepted_by_any
      assert targets["in:ask_claude.working_directory"].fit == :incompatible
    end

    test "for After, a node already waited on doesn't fit", %{conn: conn} do
      {_draft, view} = open(conn)

      targets = preview(view, %{"source" => "ask_claude", "kind" => "after"})

      assert targets["after-in:trust_mise"].fit == :incompatible
      assert targets["after-in:ask_claude"].fit == :incompatible

      targets = preview(view, %{"source" => "detect_mise", "kind" => "after"})
      assert targets["after-in:ask_claude"].fit == :exact
    end

    test "an unknown source has no targets, and nothing is saved", %{conn: conn} do
      {draft, view} = open(conn)
      before = lock(draft)

      assert preview(view, %{"source" => "gone", "kind" => "value"}) == %{}
      assert lock(draft) == before
    end
  end

  describe "open_picker" do
    test "lists the runners reading the source, and closing restores all", %{conn: conn} do
      {_draft, view} = open(conn)
      directory = "#runner-DomovoyGitPlugin-Runner-WorktreeDirectory"
      detect = "#runner-DomovoyMisePlugin-Runner-Detect"
      assert has_element?(view, detect)

      render_hook(view, "open_picker", %{"source" => "resolve_worktree"})

      assert has_element?(view, "#picker-source", "resolve_worktree")
      assert has_element?(view, directory)
      refute has_element?(view, detect)

      view |> element("#close-picker") |> render_click()

      refute has_element?(view, "#picker-source")
      assert has_element?(view, detect)
    end

    test "an unknown source opens nothing", %{conn: conn} do
      {_draft, view} = open(conn)
      render_hook(view, "open_picker", %{"source" => "gone"})
      refute has_element?(view, "#picker-source")
    end
  end

  describe "the wire layer" do
    test "lists every relationship as an edge, solid or dashed by kind", %{conn: conn} do
      {_draft, view} = open(conn)

      [json] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#composer-wires[phx-hook='ComposerCanvas'][phx-update='ignore']")
        |> LazyHTML.attribute("data-edges")

      edges = Jason.decode!(json)

      assert %{"kind" => "value", "problem" => false} =
               Enum.find(edges, &(&1["to"] == "in:trust_mise.worktree"))

      assert %{"kind" => "after", "from" => "after-out:trust_mise"} =
               Enum.find(edges, &(&1["to"] == "after-in:ask_claude"))
    end

    test "every edge's sockets exist in the stage", %{conn: conn} do
      {_draft, view} = open(conn)
      document = view |> render() |> LazyHTML.from_fragment()

      [json] =
        document |> LazyHTML.query("#composer-wires") |> LazyHTML.attribute("data-edges")

      for edge <- Jason.decode!(json), socket <- [edge["from"], edge["to"]] do
        assert has_element?(view, ~s([data-socket="#{socket}"])), socket
      end
    end
  end

  test "the undo event works from the canvas", %{conn: conn} do
    {draft, view} = open(conn)
    before = saved_document(draft)

    render_hook(view, "add_after", %{
      "after" => %{"node" => "detect_mise", "source" => "resolve_worktree"}
    })

    refute saved_document(draft) == before
    render_hook(view, "undo", %{})
    assert saved_document(draft) == before
  end

  test "Close drops the selection", %{conn: conn} do
    {_draft, view} = open(conn)
    view |> element("#node-ask_claude-select") |> render_click()
    assert has_element?(view, "#inspector-runner")

    view |> element("#deselect-node") |> render_click()

    refute has_element?(view, "#inspector-runner")
  end

  test "inspector floats over the canvas and Tools is independent on both levels", %{conn: conn} do
    draft = draft!(scenario_a())
    before = saved_document(draft)
    version = lock(draft)

    for {path, node} <- [
          {~p"/composer/#{draft.id}", "vertex-prepare"},
          {~p"/composer/#{draft.id}/stages/prepare", "node-ask_claude"}
        ] do
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "#inspector-panel")

      assert has_element?(
               view,
               "#open-tools[aria-expanded='false'][aria-controls='composer-tools']"
             )

      render_click(element(view, "#open-tools"))
      assert has_element?(view, "#composer-tools #issues")
      refute has_element?(view, "#inspector-panel")
      render_click(element(view, "#close-tools"))
      refute has_element?(view, "#composer-tools")
      render_click(element(view, "##{node}-select"))
      assert has_element?(view, "#inspector-panel #deselect-node")
      render_click(element(view, "#deselect-node"))
      refute has_element?(view, "#inspector-panel")
      render_hook(view, "select_node", %{"node" => "gone"})
      refute has_element?(view, "#inspector-panel")
      refute has_element?(view, "#undo:not([disabled])")
    end

    assert saved_document(draft) == before
    assert lock(draft) == version
  end

  test "input Connect-to opens Tools without selection and preserves unresolved controls", %{
    conn: conn
  } do
    {draft, view} = open(conn)
    before = saved_document(draft)
    version = lock(draft)
    render_click(element(view, "#input-worktree_name-connect"))
    assert has_element?(view, "#composer-tools #connect-to")
    refute has_element?(view, "#inspector-panel")
    render_click(element(view, "#close-tools"))
    refute has_element?(view, "#composer-tools")
    render_click(element(view, "#open-tools"))
    assert has_element?(view, "#connect-resolve_worktree-worktree_name")
    render_click(element(view, "#connect-close"))
    refute has_element?(view, "#connect-to")
    assert saved_document(draft) == before
    assert lock(draft) == version
    refute has_element?(view, "#undo:not([disabled])")
  end

  test "switching nodes, deselection, navigation and removal leave only valid inspectors", %{
    conn: conn
  } do
    draft = draft!(scenario_a())

    for {path, first, second, remove} <- [
          {~p"/composer/#{draft.id}", "vertex-prepare", "vertex-review", "remove-vertex"},
          {~p"/composer/#{draft.id}/stages/prepare", "node-ask_claude", "node-detect_mise",
           "remove-node"}
        ] do
      {:ok, view, _html} = live(conn, path)
      render_click(element(view, "##{first}-select"))
      assert has_element?(view, "##{first}-select[aria-pressed='true']")
      render_click(element(view, "##{second}-select"))
      assert has_element?(view, "##{second}-select[aria-pressed='true']")
      assert has_element?(view, "#inspector-panel")
      render_hook(view, "deselect_node", %{})
      refute has_element?(view, "#inspector-panel")
      render_click(element(view, "##{second}-select"))
      render_click(element(view, "##{remove}"))
      refute has_element?(view, "#inspector-panel")
    end
  end
end

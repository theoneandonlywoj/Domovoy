defmodule DomovoyWeb.ComposerWorkspaceLiveTest do
  use DomovoyWeb.ConnCase, async: false

  import Domovoy.ComposerFixtures

  import Domovoy.RunCase,
    only: [setup_runs: 1, start_attrs: 2, open!: 1, await_phase: 2, watch: 1]

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Examples.Definitions

  setup :setup_runs

  @review_form %{
    "rooms" => "3",
    "bathrooms" => "1",
    "area" => "58.5",
    "district" => "Krowodrza"
  }

  # A Cracow review run waiting at its `review` decision.
  defp start_review do
    document = Enum.find(Definitions.all(), &(&1.title == "Cracow house price review")).document
    {:ok, values} = RunInputs.parse(document, @review_form)
    draft = draft!(document, "Review")
    {:ok, run_id} = Composer.start_run(start_attrs(draft, values))
    await_phase(open!(run_id), "waiting")
    %{draft: draft, run_id: run_id}
  end

  defp open_run(conn, path) do
    {:ok, view, _html} = live(conn, path)
    watch(view.pid)
    render_async(view, 5_000)
    view
  end

  defp shown(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    Map.take(assigns, [:panel, :surface, :selected])
  end

  describe "a draft" do
    test "the canvas is the workspace's first child on both levels, with no rails", %{
      conn: conn
    } do
      draft = draft!(scenario_a())

      for path <- [~p"/composer/#{draft.id}", ~p"/composer/#{draft.id}/stages/prepare"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#workspace[data-surface='canvas'] > #stage-canvas:first-child")
        refute has_element?(view, "#left-rail")
        refute has_element?(view, "#right-rail")
        assert has_element?(view, "#workspace > #outline-panel[hidden]")
        refute has_element?(view, "#inspector-panel")
      end
    end

    test "the outline opens and closes by toggling hidden, keeping its forms", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      assert has_element?(view, "#inputs-rail #inputs-popover #inputs-form")

      render_click(element(view, "#open-outline"))
      assert has_element?(view, "#inputs-rail #inputs-form")
      refute has_element?(view, "#outline-panel #inputs-form")
      assert has_element?(view, "#open-outline[aria-expanded='true']")
      assert has_element?(view, "#workspace[data-surface='outline']")

      render_click(element(view, "#close-outline-panel"))
      assert has_element?(view, "#outline-panel[hidden]")
      assert has_element?(view, "#workspace[data-surface='canvas']")
    end

    test "selecting a card shows the inspector over the canvas, and deselecting hides it", %{
      conn: conn
    } do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

      render_click(element(view, "#vertex-prepare-select"))
      assert has_element?(view, "#workspace > #inspector-panel #deselect-node")
      assert has_element?(view, "#workspace[data-surface='details'] > #stage-canvas")

      render_click(element(view, "#deselect-node"))
      refute has_element?(view, "#inspector-panel")
      assert has_element?(view, "#workspace[data-surface='canvas']")
    end

    test "a surface outside the allowlist changes nothing", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      before = shown(view)

      for params <- [%{"surface" => "../x"}, %{"surface" => %{"a" => "b"}}, %{}] do
        render_hook(view, "set_surface", params)
        assert shown(view) == before
      end

      render_click(element(view, "#surface-outline"))
      assert %{surface: "outline", panel: "outline"} = shown(view)
      render_click(element(view, "#surface-canvas"))
      assert %{surface: "canvas", panel: "outline"} = shown(view)
    end

    test "Tools and Connect to from the inspector make the canvas the one surface", %{
      conn: conn
    } do
      draft = draft!(scenario_a())
      path = ~p"/composer/#{draft.id}/stages/prepare?node=resolve_worktree"
      {:ok, view, _html} = live(conn, path)
      assert %{surface: "details"} = shown(view)

      render_hook(view, "open_tools", %{})
      assert has_element?(view, "#workspace[data-surface='canvas'] > #composer-tools")

      render_click(element(view, "#close-tools"))
      render_patch(view, path <> "&again=1")
      render_hook(view, "select_node", %{"node" => "resolve_worktree"})
      assert %{surface: "details"} = shown(view)

      render_hook(view, "open_connect", %{"source" => "resolve_worktree"})
      assert has_element?(view, "#workspace[data-surface='canvas'] #composer-tools #connect-to")
    end

    test "a Clear that warns and an issue focus into Tools make the canvas the one surface", %{
      conn: conn
    } do
      # In `second`, an Any field and a concrete one both read `main`'s worktree, so
      # clearing the concrete one warns.
      document =
        edit_all(Document.new("w"), [
          {:put_input, "worktree_name", %{"type" => "DomovoyCore.Type.String"}},
          {:add_stage, "second"},
          {:set_next, "main", "second"},
          {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeResolve", "resolve_worktree"},
          {:bind, "main", "resolve_worktree", "worktree_name", "worktree_name",
           replace_literal: false},
          {:add_node, "second", "DomovoyMisePlugin.Runner.Trust", "trust_mise"},
          {:add_node, "second", "DomovoyGitPlugin.Runner.WorktreeDirectory",
           "worktree_directory"},
          {:bind, "second", "worktree_directory", "worktree", "resolve_worktree",
           replace_literal: false},
          {:bind, "second", "trust_mise", "worktree", "resolve_worktree", replace_literal: false}
        ])

      draft = draft!(document)
      path = ~p"/composer/#{draft.id}/stages/second?node=worktree_directory"
      {:ok, view, _html} = live(conn, path)
      assert %{surface: "details"} = shown(view)

      render_hook(view, "clear_input", %{"node" => "worktree_directory", "field" => "worktree"})
      assert has_element?(view, "#composer-tools #clear-preview")
      assert has_element?(view, "#workspace[data-surface='canvas'] > #composer-tools")

      render_click(element(view, "#cancel-clear-input"))
      render_click(element(view, "#close-tools"))
      render_hook(view, "select_node", %{"node" => "worktree_directory"})
      assert %{surface: "details"} = shown(view)

      render_hook(view, "select_node", %{
        "node" => "worktree_directory",
        "focus" => "issue-x",
        "tools" => true
      })

      assert has_element?(view, "#workspace[data-surface='canvas'] > #composer-tools")
    end

    test "a stage's catalog lists runners when the outline opens after entering it", %{
      conn: conn
    } do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")

      render_patch(view, ~p"/composer/#{draft.id}/stages/prepare")
      assert has_element?(view, "#outline-panel[hidden]")
      render_click(element(view, "#open-outline"))
      assert has_element?(view, "#outline-panel:not([hidden]) #catalog-runners li[id^='runner-']")
    end

    test "the surface returns to the canvas only when the level changes", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}?node=prepare")
      assert %{surface: "details", selected: "prepare"} = shown(view)

      render_patch(view, ~p"/composer/#{draft.id}?node=prepare&other=1")
      assert %{surface: "details", selected: "prepare"} = shown(view)

      render_click(element(view, "#surface-outline"))
      render_patch(view, ~p"/composer/#{draft.id}?other=2")
      assert %{surface: "outline", panel: "outline"} = shown(view)

      render_patch(view, ~p"/composer/#{draft.id}/stages/prepare")
      assert %{surface: "canvas", panel: "outline", selected: nil} = shown(view)
    end

    test "Fit selection is enabled with a selection, and only the inspector can be pinned", %{
      conn: conn
    } do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      assert has_element?(view, "#canvas-fit-selection[disabled]")
      refute has_element?(view, "#pin-inspector")

      render_click(element(view, "#vertex-prepare-select"))
      assert has_element?(view, "#stage-canvas[data-selected='prepare']")
      assert has_element?(view, "#canvas-fit-selection:not([disabled])")
      assert has_element?(view, "#inspector-panel #pin-inspector[aria-pressed='false']")
      assert has_element?(view, "#inspector-panel #inspector-resize[role='separator']")
      refute has_element?(view, "#outline-panel #pin-inspector")
    end

    test "canvas only toggles the chrome away and back, whatever the params", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
      refute has_element?(view, "#composer[data-canvas-only]")
      refute has_element?(view, "#exit-canvas-only")

      render_click(element(view, "#composer-header #canvas-only"))
      assert has_element?(view, "#composer[data-canvas-only]")
      assert has_element?(view, "#workspace > #stage-canvas:first-child")
      assert has_element?(view, "#workspace > #canvas-only-bar #exit-canvas-only")
      assert has_element?(view, "#canvas-only-status", draft.title)

      render_click(element(view, "#exit-canvas-only"))
      refute has_element?(view, "#composer[data-canvas-only]")
      refute has_element?(view, "#canvas-only-bar")

      before = shown(view)

      for params <- [%{"canvas_only?" => "false"}, %{"panel" => "outline", "surface" => "../x"}] do
        render_hook(view, "toggle_canvas_only", params)
        assert has_element?(view, "#composer[data-canvas-only]")
        assert shown(view) == before
        render_hook(view, "toggle_canvas_only", params)
        refute has_element?(view, "#composer[data-canvas-only]")
      end
    end
  end

  describe "a run" do
    test "the canvas leads the workspace, and the run's status sits in the outline", %{
      conn: conn
    } do
      run = start_review()
      view = open_run(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")

      assert has_element?(view, "#workspace > #stage-canvas[data-read-only]:first-child")
      refute has_element?(view, "#left-rail")
      refute has_element?(view, "#right-rail")
      assert has_element?(view, "#outline-panel[hidden] #run-phase", "waiting")
      assert has_element?(view, "#outline-panel #recent-run-#{run.run_id}")
      assert has_element?(view, "#surface-outline", "Steps")
      assert has_element?(view, "#surface-details", "Review")

      render_click(element(view, "#open-outline"))
      assert has_element?(view, "#outline-panel:not([hidden]) #run-sentence")
      render_click(element(view, "#close-outline-panel"))
      assert has_element?(view, "#outline-panel[hidden]")
    end

    test "panel events with hostile params change nothing, and edits stay refused", %{
      conn: conn
    } do
      run = start_review()
      view = open_run(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
      before = shown(view)

      for params <- [%{"surface" => "../x"}, %{"surface" => ["details"]}] do
        render_hook(view, "set_surface", params)
        assert shown(view) == before
      end

      move = %{"node" => "review", "x" => 1, "y" => 2, "level" => "workflow"}
      render_hook(view, "node_moved", move)
      assert_reply(view, %{status: "rejected"})
      assert {:ok, %{document: document}} = Composer.get_draft(run.draft.id)
      assert document == run.draft.document

      render_hook(view, "add_node", %{"add_node" => %{"runner" => "x", "name" => "fresh"}})
      assert {:ok, %{document: ^document}} = Composer.get_draft(run.draft.id)
    end

    test "an Answer link shows the decision as the one surface, and a later patch keeps it", %{
      conn: conn
    } do
      run = start_review()
      path = ~p"/composer/#{run.draft.id}?run=#{run.run_id}"
      view = open_run(conn, path)
      assert has_element?(view, "#workspace[data-surface='canvas']")

      view |> element("#surface-details") |> render_click()
      assert_patch(view, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, node: "review"]}")
      assert has_element?(view, "#workspace[data-surface='details'] > #inspector-panel")

      render_patch(view, ~p"/composer/#{run.draft.id}?#{[run: run.run_id, node: "review", x: 1]}")
      assert has_element?(view, "#workspace[data-surface='details'] > #inspector-panel")
      assert shown(view).selected == "review"
    end

    test "canvas only works on a run, shows its sentence and keeps it read-only", %{
      conn: conn
    } do
      run = start_review()
      view = open_run(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
      before = shown(view)

      render_hook(view, "toggle_canvas_only", %{"surface" => "details", "x" => ["y"]})
      assert has_element?(view, "#composer[data-canvas-only]")
      assert has_element?(view, "#workspace > #stage-canvas[data-read-only]:first-child")
      status = view |> element("#run-status") |> render() |> LazyHTML.from_fragment()
      assert has_element?(view, "#canvas-only-status", LazyHTML.text(status) |> String.trim())
      assert shown(view) == before

      render_hook(view, "add_node", %{"add_node" => %{"runner" => "x", "name" => "fresh"}})
      assert {:ok, %{document: document}} = Composer.get_draft(run.draft.id)
      assert document == run.draft.document

      render_click(element(view, "#exit-canvas-only"))
      refute has_element?(view, "#composer[data-canvas-only]")
      assert has_element?(view, "#run-header #canvas-only")
    end

    test "the cancel dialog wraps focus and makes the page behind it inert", %{conn: conn} do
      run = start_review()
      view = open_run(conn, ~p"/composer/#{run.draft.id}?run=#{run.run_id}")
      render_click(element(view, "#vertex-review-select"))

      render_click(element(view, "#cancel-run"))
      assert has_element?(view, "#cancel-run-focus #cancel-run-dialog[aria-modal='true']")
      refute has_element?(view, "#workspace #cancel-run-dialog")
      refute has_element?(view, "#run-header #cancel-run-dialog")
      assert has_element?(view, "#run-header[data-modal-background]")
      assert has_element?(view, "#workspace[data-modal-background]")

      assert has_element?(
               view,
               "[phx-mounted*='inert'][phx-remove*='pop_focus'] #cancel-run-focus"
             )

      render_click(element(view, "#close-cancel-run"))
      refute has_element?(view, "#cancel-run-dialog")
      assert shown(view).selected == "review"
    end
  end
end

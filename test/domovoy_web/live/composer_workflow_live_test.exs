defmodule DomovoyWeb.ComposerWorkflowLiveTest do
  use DomovoyWeb.ConnCase

  import Domovoy.ComposerFixtures

  alias Domovoy.Composer
  alias Domovoy.Composer.Document

  @string "DomovoyCore.Type.String"
  @any_reader "DomovoyMisePlugin.Runner.Trust"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"

  defp open(conn, document \\ scenario_a()) do
    draft = draft!(document)
    {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}")
    {draft, view}
  end

  defp click(view, selector), do: view |> element(selector) |> render_click()

  defp choice(view, params) do
    view |> form("#choice-form", choice: params) |> render_submit()
  end

  defp lock(draft) do
    {:ok, %{lock_version: lock}} = Composer.get_draft(draft.id)
    lock
  end

  describe "the view" do
    test "shows cards, routes, markers and breadcrumb", %{conn: conn} do
      {_draft, view} = open(conn)

      assert has_element?(view, "#breadcrumb-workflow")
      assert has_element?(view, "#vertex-prepare[data-node='prepare']")
      assert has_element?(view, "#vertex-prepare-start")
      assert has_element?(view, "#vertex-prepare-nodes", "5 nodes")
      assert has_element?(view, "#vertex-prepare-next", "review")
      assert has_element?(view, "#choice-review-approve-route", "Halt")
      assert has_element?(view, "#choice-review-revise-route", "Rerun / next generation prepare")
      assert has_element?(view, "#loop-limits", "max_generations 10")
      assert has_element?(view, "#loop-limits", "max_steps 1000")
    end

    test "a stage with no next is a finish, and no loop shows no limits", %{conn: conn} do
      {_draft, view} = open(conn, Document.new("w"))

      assert has_element?(view, "#vertex-main-finish")
      refute has_element?(view, "#loop-limits")
    end

    test "a stage card links to its stage, and the breadcrumb back", %{conn: conn} do
      {draft, view} = open(conn)

      click(view, "#vertex-prepare-open[data-card-open]")
      assert_patch(view, ~p"/composer/#{draft.id}/stages/prepare")
      assert has_element?(view, "#node-ask_claude")
      assert has_element?(view, "#catalog-runners li[id^='runner-']")

      click(view, "#breadcrumb-workflow")
      assert_patch(view, ~p"/composer/#{draft.id}")
      assert has_element?(view, "#stage-world[data-level='workflow'] #vertex-review")
    end

    test "undoing the stage on screen leads back to the workflow", %{conn: conn} do
      {draft, view} = open(conn, Document.new("w"))

      view |> form("#add-vertex-form", vertex: %{name: "fresh", kind: "stage"}) |> render_submit()
      click(view, "#vertex-fresh-open")
      click(view, "#undo")

      assert_patch(view, ~p"/composer/#{draft.id}")
      refute has_element?(view, "#vertex-fresh")
    end
  end

  describe "editing vertices" do
    test "add, set start, and remove, each saved", %{conn: conn} do
      {draft, view} = open(conn, Document.new("w"))

      view |> form("#add-vertex-form", vertex: %{name: "a", kind: "stage"}) |> render_submit()

      view
      |> form("#add-vertex-form", vertex: %{name: "ask", kind: "decision"})
      |> render_submit()

      click(view, "#vertex-a-select")
      click(view, "#set-start")
      assert saved_document(draft)["start"] == "a"

      click(view, "#vertex-main-select")
      click(view, "#remove-vertex")

      assert %{
               "vertices" =>
                 %{"a" => %{"kind" => "stage"}, "ask" => %{"kind" => "decision"}} = vertices
             } =
               saved_document(draft)

      refute is_map_key(vertices, "main")
    end

    test "a colliding name is explained, and the form keeps the text", %{conn: conn} do
      {_draft, view} = open(conn)

      view
      |> form("#add-vertex-form", vertex: %{name: "prepare", kind: "stage"})
      |> render_submit()

      assert has_element?(view, "#rejection-message", "already in use")
      assert has_element?(view, "#add-vertex-form input[name='vertex[name]'][value='prepare']")
    end

    test "the next select and a dragged route set the same route", %{conn: conn} do
      {draft, view} = open(conn, edit_all(Document.new("w"), [{:add_stage, "b"}]))

      click(view, "#vertex-main-select")
      view |> form("#next-form", next: %{vertex: "b"}) |> render_change()
      assert saved_document(draft)["vertices"]["main"]["next"] == "b"

      view |> form("#next-form", next: %{vertex: ""}) |> render_change()
      assert saved_document(draft)["vertices"]["main"]["next"] == nil

      render_hook(view, "add_after", %{"after" => %{"node" => "b", "source" => "main"}})
      assert saved_document(draft)["vertices"]["main"]["next"] == "b"

      render_hook(view, "connect_preview", %{"source" => "main", "kind" => "after"})
      assert_reply(view, %{targets: [%{socket: "after-in:b", fit: :exact}]})
    end

    test "dragging a card saves a workflow position, keeping validity", %{conn: conn} do
      {draft, view} = open(conn)
      click(view, "#validate")

      render_hook(view, "node_moved", %{
        "node" => "review",
        "x" => 500.4,
        "y" => 60,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "ok"})
      assert saved_document(draft)["layout"]["workflow"]["review"] == %{"x" => 500, "y" => 60}
      assert has_element?(view, "#vertex-review[data-x='500'][data-y='60']")
      assert has_element?(view, "#definition-valid")
    end

    test "an unchanged position replies noop, with no save", %{conn: conn} do
      {draft, view} = open(conn)
      %{"x" => x, "y" => y} = saved_document(draft)["layout"]["workflow"]["review"]
      before = lock(draft)

      render_hook(view, "node_moved", %{
        "node" => "review",
        "x" => x,
        "y" => y,
        "level" => "workflow"
      })

      assert_reply(view, %{status: "noop"})
      assert lock(draft) == before
    end
  end

  describe "choices follow target rules" do
    setup %{conn: conn} do
      {draft, view} = open(conn)
      click(view, "#vertex-review-select")
      %{draft: draft, view: view}
    end

    test "Run and Halt show no input controls", %{view: view} do
      for params <- [%{kind: "run", vertex: "prepare"}, %{kind: "halt"}] do
        view |> form("#choice-form", choice: params) |> render_change()

        refute has_element?(view, "#choice-form input[name='choice[input_name]']")
        refute has_element?(view, "#choice-new-generation")
      end
    end

    test "Rerun on a Stage takes typed inputs, and states a new generation", %{
      view: view,
      draft: draft
    } do
      view |> form("#choice-form", choice: %{kind: "rerun", vertex: "prepare"}) |> render_change()
      assert has_element?(view, "#choice-new-generation")

      choice(view, %{
        name: "again",
        description: "Again",
        kind: "rerun",
        vertex: "prepare",
        input_name: "note",
        input_type: @string
      })

      refute has_element?(view, "#rejection")

      saved =
        Enum.find(
          saved_document(draft)["vertices"]["review"]["choices"],
          &(&1["name"] == "again")
        )

      assert saved == %{
               "name" => "again",
               "description" => "Again",
               "target" => ["rerun", "prepare"],
               "inputs" => %{"note" => @string}
             }
    end

    test "editing a Rerun keeps its inputs, and retargeting it drops them", %{
      view: view,
      draft: draft
    } do
      click(view, "#edit-choice-review-revise")
      assert has_element?(view, "#choice-form input[name='choice[name]'][value='revise']")

      choice(view, %{description: "Reworded", kind: "rerun", vertex: "prepare"})

      revise =
        Enum.find(
          saved_document(draft)["vertices"]["review"]["choices"],
          &(&1["name"] == "revise")
        )

      assert revise["description"] == "Reworded"
      assert revise["inputs"] == %{"prompt" => @string}

      click(view, "#edit-choice-review-revise")
      choice(view, %{kind: "halt"})

      revise =
        Enum.find(
          saved_document(draft)["vertices"]["review"]["choices"],
          &(&1["name"] == "revise")
        )

      assert revise["target"] == ["halt"]
      assert revise["inputs"] == %{}
    end

    test "Rerun targeting a Decision has no inputs and is a linked issue", %{view: view} do
      view |> form("#choice-form", choice: %{kind: "rerun", vertex: "review"}) |> render_change()
      refute has_element?(view, "#choice-new-generation")

      choice(view, %{name: "bad", description: "Bad", kind: "rerun", vertex: "review"})

      assert has_element?(
               view,
               "#issues a[href='#choice-review-bad']",
               "Only a Stage can be re-run"
             )

      assert has_element?(view, "#choice-review-bad[tabindex='-1']")
    end

    test "a blank description is a linked issue", %{view: view} do
      choice(view, %{name: "blank", description: " ", kind: "halt"})
      assert has_element?(view, "#issues a[href='#choice-review-blank']")
    end

    test "removing a choice removes its route", %{view: view, draft: draft} do
      click(view, "#remove-choice-review-approve")

      refute has_element?(view, "#choice-review-approve")
      assert [%{"name" => "revise"}] = saved_document(draft)["vertices"]["review"]["choices"]
    end

    test "prompt and decider save", %{view: view, draft: draft} do
      view
      |> form("#decision-form", decision: %{prompt: "Really?"})
      |> render_submit()

      assert saved_document(draft)["vertices"]["review"]["prompt"] == "Really?"
    end

    test "a choice issue seen from a stage links to the workflow", %{conn: conn, draft: draft} do
      document =
        edit_all(saved_document(draft), [
          {:put_choice, "review",
           %{"name" => "bad", "description" => "Bad", "target" => ["rerun", "review"]}}
        ])

      saved = draft!(document)
      {:ok, view, _html} = live(conn, ~p"/composer/#{saved.id}/stages/prepare")

      assert has_element?(
               view,
               "#issues a[href='/composer/#{saved.id}']",
               "Only a Stage can be re-run"
             )
    end
  end

  describe "sources across stages" do
    # `first` precedes `second`, where a field of Any type can read `first`'s worktree.
    defp across do
      edit_all(Document.new("w"), [
        {:put_input, "worktree_name", %{"type" => @string, "required" => true}},
        {:add_stage, "second"},
        {:set_next, "main", "second"},
        {:add_node, "main", @resolve, "resolve_worktree"},
        {:bind, "main", "resolve_worktree", "worktree_name", "worktree_name",
         replace_literal: false},
        {:add_node, "second", @any_reader, "trust_mise"},
        {:add_node, "second", @directory, "worktree_directory"}
      ])
    end

    defp open_second(conn) do
      draft = draft!(across())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/second")
      {draft, view}
    end

    test "the rail shows where a source comes from, and the Any rule", %{conn: conn} do
      {_draft, view} = open_second(conn)

      assert has_element?(
               view,
               "#prior-resolve_worktree-origin",
               "From stage: main / node: resolve_worktree / Git Worktree"
             )

      assert has_element?(view, "#any-across-stages", "Any matches only Any")
    end

    test "a prior source always says it may be from an earlier generation, loop or not", %{
      conn: conn
    } do
      {_draft, view} = open_second(conn)
      assert has_element?(view, "#prior-resolve_worktree-generation", "earlier generation")
      refute has_element?(view, "#loop-limits")

      document = edit_all(across(), [{:set_next, "second", "main"}])
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft!(document).id}/stages/second")
      assert has_element?(view, "#prior-resolve_worktree-generation", "earlier generation")
    end

    test "binding Any across stages is refused with the explanation", %{conn: conn} do
      {draft, view} = open_second(conn)
      click(view, "#prior-resolve_worktree-connect")
      click(view, "#connect-trust_mise-worktree")

      assert has_element?(view, "#rejection-message", "Across stages Any matches only Any")
      assert saved_document(draft)["vertices"]["second"]["nodes"]["trust_mise"]["inputs"] == %{}
    end

    test "a drag from a prior source previews and binds like Connect to", %{conn: conn} do
      {draft, view} = open_second(conn)

      render_hook(view, "connect_preview", %{"source" => "resolve_worktree", "kind" => "value"})
      assert_reply(view, %{targets: [_ | _] = targets})
      assert %{fit: :exact} = Enum.find(targets, &(&1.socket == "in:worktree_directory.worktree"))

      render_hook(view, "connect", %{
        "source" => "resolve_worktree",
        "node" => "worktree_directory",
        "field" => "worktree"
      })

      assert %{"worktree" => %{"bind" => "resolve_worktree"}} =
               saved_document(draft)["vertices"]["second"]["nodes"]["worktree_directory"][
                 "inputs"
               ]
    end

    test "removing a concrete sibling warns before it commits", %{conn: conn} do
      document =
        edit_all(across(), [
          {:bind, "second", "worktree_directory", "worktree", "resolve_worktree",
           replace_literal: false},
          {:bind, "second", "trust_mise", "worktree", "resolve_worktree", replace_literal: false}
        ])

      draft = draft!(document)
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/second")
      before = saved_document(draft)

      click(view, "#rel-bind-worktree_directory-worktree-delete")
      assert has_element?(view, "#clear-warnings", "Any")
      assert saved_document(draft) == before

      click(view, "#cancel-clear-input")
      refute has_element?(view, "#clear-preview")
      assert saved_document(draft) == before

      click(view, "#rel-bind-worktree_directory-worktree-delete")
      click(view, "#confirm-clear-input")
      refute has_element?(view, "#clear-preview")

      assert saved_document(draft)["vertices"]["second"]["nodes"]["worktree_directory"]["inputs"] ==
               %{}
    end

    test "clearing a binding nothing depends on just clears", %{conn: conn} do
      draft = draft!(scenario_a())
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/prepare")

      click(view, "#rel-bind-ask_claude-context-delete")

      refute has_element?(view, "#clear-preview")

      refute is_map_key(
               saved_document(draft)["vertices"]["prepare"]["nodes"]["ask_claude"]["inputs"],
               "context"
             )
    end
  end

  describe "a deleted producer in an unreachable stage" do
    test "shows an unresolved issue with no export", %{conn: conn} do
      document =
        edit_all(across(), [
          {:set_next, "main", nil},
          {:bind, "second", "worktree_directory", "worktree", "resolve_worktree",
           replace_literal: false},
          {:remove_node, "main", "resolve_worktree"}
        ])

      draft = draft!(document)
      {:ok, view, _html} = live(conn, ~p"/composer/#{draft.id}/stages/second")

      assert has_element?(view, "#field-worktree_directory-worktree-unresolved")
      assert has_element?(view, "#issue-count")
      refute has_element?(view, "#issues-empty")

      click(view, "#validate")

      refute has_element?(view, "#definition-valid")
      refute has_element?(view, "#export")
      assert conn |> get(~p"/composer/#{draft.id}/export") |> response(422)
    end
  end
end

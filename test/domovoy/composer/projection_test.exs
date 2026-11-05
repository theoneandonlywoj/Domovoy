defmodule Domovoy.Composer.ProjectionTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.Operations
  alias Domovoy.Composer.Projection

  @string "DomovoyCore.Type.String"
  @any "DomovoyCore.Type.Any"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @trust "DomovoyMisePlugin.Runner.Trust"

  defp card(view, name), do: Enum.find(view.cards, &(&1.name == name))
  defp relationship(view, id), do: Enum.find(view.relationships, &(&1.dom_id == id))

  defp field(card, id) do
    Enum.find(card.required ++ card.configured ++ card.unset, &(&1.id == id))
  end

  describe "stage_view/2 cards" do
    test "reflect the runner's contract" do
      resolve = scenario_a() |> Projection.stage_view("prepare") |> card("resolve_worktree")

      assert resolve.label == "Git WorktreeResolve"
      assert resolve.output == "Git Worktree"
      assert [%{id: "worktree_name", required: true}] = resolve.required
      assert [%{id: "working_directory"}] = resolve.unset
      assert [%{label: "Git WorktreeNameIsSafe"}] = resolve.inherited
      assert resolve.policy.max_attempts == 1
      assert resolve.policy.effect == "pure"
      assert resolve.policy.store == true
    end

    test "split optional inputs by whether they hold a value" do
      ask = scenario_a() |> Projection.stage_view("prepare") |> card("ask_claude")

      assert ask.configured |> Enum.map(& &1.id) |> Enum.sort() == [
               "options",
               "working_directory"
             ]

      assert field(ask, "options").value == {:literal, "{}"}
      assert field(ask, "context").value == {:bind, "prompt"}
    end

    test "place a card at its saved position" do
      document =
        edit_all(scenario_a(), [{:move, {:stage, "prepare"}, "ask_claude", 123, 456}])

      ask = document |> Projection.stage_view("prepare") |> card("ask_claude")
      assert {ask.x, ask.y} == {123, 456}
    end

    test "list only sources this field could read" do
      document = scenario_a()
      ask = document |> Projection.stage_view("prepare") |> card("ask_claude")

      assert "prompt" in field(ask, "context").sources
      assert "worktree_directory" in field(ask, "working_directory").sources
      refute "resolve_worktree" in field(ask, "working_directory").sources
      refute "ask_claude" in field(ask, "context").sources
    end
  end

  describe "workflow_view/1" do
    defp vertex(view, name), do: Enum.find(view.cards, &(&1.name == name))

    test "a stage shows its node count, next route, and start" do
      prepare = scenario_a() |> Projection.workflow_view() |> vertex("prepare")

      assert %{kind: "stage", start?: true, node_count: 5, next: "review", issue_count: 0} =
               prepare
    end

    test "a decision's routes come by kind, and only those with a vertex draw a wire" do
      view = Projection.workflow_view(scenario_a())

      assert [
               %{name: "approve", kind: :halt, label: "Halt", target: nil},
               %{
                 name: "revise",
                 kind: :rerun,
                 label: "Rerun / next generation",
                 target: "prepare"
               }
             ] = vertex(view, "review").choices

      assert [
               %{from: "after-out:prepare", to: "after-in:review", kind: :next},
               %{from: "choice-out:review.revise", to: "after-in:prepare", kind: :rerun}
             ] = view.edges
    end

    test "a stage with no next is a finish, and only a path back makes a loop" do
      document = Document.new("w")
      assert %{next: nil} = document |> Projection.workflow_view() |> vertex("main")
      refute Projection.workflow_view(document).loop?
      assert Projection.workflow_view(scenario_a()).loop?
    end

    test "counts every issue inside a vertex, and reads saved positions" do
      document =
        edit_all(scenario_a(), [
          {:clear_input, "prepare", "ask_claude", "context"},
          {:move, :workflow, "review", 11, 22}
        ])

      view = Projection.workflow_view(document)
      assert vertex(view, "prepare").issue_count > 0
      assert %{x: 11, y: 22, issue_count: 0} = vertex(view, "review")
    end

    test "route_targets/2 offers a stage every other vertex, and a decision nothing" do
      assert [%{socket: "after-in:review", fit: :exact}] =
               Projection.route_targets(scenario_a(), "prepare")

      assert Projection.route_targets(scenario_a(), "review") == []
      assert Projection.route_targets(scenario_a(), "nope") == []
    end
  end

  describe "stage_view/2 prior sources" do
    defp two_stages do
      edit_all(scenario_a(), [
        {:add_stage, "after_review"},
        {:put_choice, "review",
         %{"name" => "go", "description" => "Go on", "target" => ["run", "after_review"]}}
      ])
    end

    test "name the stage, node and type of what precedes this stage" do
      rows = Projection.stage_view(two_stages(), "after_review").prior_sources
      row = Enum.find(rows, &(&1.name == "worktree_directory"))

      assert row.origin == "From stage: prepare / node: worktree_directory / Directory"
      refute Enum.any?(rows, &(&1.name == "prompt"))
    end

    test "leave out the stage's own nodes, and whatever doesn't precede it" do
      document =
        Document.new("w")
        |> edit_all([{:add_stage, "other"}, {:add_node, "other", @directory, "d"}])

      assert Projection.stage_view(document, "main").prior_sources == []
      refute Projection.stage_view(document, "main").cards != []
      assert Projection.stage_view(document, "other").prior_sources == []
    end

    test "name the decision of a choice input" do
      document =
        edit_all(two_stages(), [
          {:put_choice, "review",
           %{
             "name" => "go",
             "description" => "Go on",
             "target" => ["rerun", "after_review"],
             "inputs" => %{"note" => @string}
           }}
        ])

      rows = Projection.stage_view(document, "after_review").prior_sources

      assert Enum.find(rows, &(&1.name == "note")).origin ==
               "From decision: review / input: note / String"
    end
  end

  describe "issue_rows/3 on the workflow" do
    test "a choice issue selects its decision and focuses its route" do
      document =
        edit_all(scenario_a(), [
          {:put_choice, "review",
           %{"name" => "approve", "description" => "Accept", "target" => ["rerun", "review"]}}
        ])

      issue =
        Enum.find(
          Projection.workflow_view(document).issues,
          &(&1.target == {:choice, "review", "approve"})
        )

      assert [%{anchor: "choice-review-approve", node: "review", patch_workflow: false}] =
               Projection.issue_rows(document, [issue], nil)

      assert [%{patch_workflow: true, patch_stage: nil}] =
               Projection.issue_rows(document, [issue], "prepare")
    end
  end

  describe "stage_view/2 tolerates what the catalog no longer knows" do
    test "an unknown runner and field show, with their issues" do
      document =
        scenario_a()
        |> put_in(["vertices", "prepare", "nodes", "detect_mise", "runner"], "Gone.Runner")
        |> put_in(
          ["vertices", "prepare", "nodes", "ask_claude", "inputs", "gone"],
          %{"literal" => "x"}
        )

      view = Projection.stage_view(document, "prepare")
      detect = card(view, "detect_mise")

      assert detect.label == "Gone.Runner"
      assert [%Issue{code: :unknown_runner}] = detect.issues

      assert %{type_label: "Unknown field", issues: [%Issue{code: :unknown_field}]} =
               view |> card("ask_claude") |> field("gone")
    end

    test "a nil stage has no cards" do
      assert %{cards: [], relationships: []} = Projection.stage_view(scenario_a(), nil)
    end

    test "issues group by target" do
      document = edit_all(scenario_a(), [{:clear_input, "prepare", "ask_claude", "context"}])
      target = {:field, "prepare", "ask_claude", "context"}

      assert %{^target => [%Issue{code: :required_missing}]} =
               Projection.stage_view(document, "prepare").issues_by_target
    end
  end

  describe "relationship names" do
    test "an Any field reading a same-stage producer says accepted by Any" do
      view = Projection.stage_view(scenario_a(), "prepare")

      assert relationship(view, "rel-bind-trust_mise-worktree").label ==
               "Bind resolve_worktree output to trust_mise.worktree; accepted by Any"

      assert relationship(view, "rel-bind-ask_claude-context").label ==
               "Bind prompt to ask_claude.context"
    end

    # `main` runs before `later`, so it can't read what `later` makes. A sibling reading
    # the same source with its concrete type satisfies `check/4` alone, which is what
    # this label must not rely on.
    test "Any isn't claimed for a source the stage can't read" do
      document =
        edit_all(Document.new("w"), [
          {:add_stage, "later"},
          {:set_next, "main", "later"},
          {:add_node, "later", @resolve, "made_later"},
          {:add_node, "main", @directory, "sibling"},
          {:add_node, "main", @trust, "reader"},
          {:bind, "main", "sibling", "worktree", "made_later", replace_literal: false},
          {:bind, "main", "reader", "worktree", "made_later", replace_literal: false}
        ])

      assert {:ok, :accepted_by_any} =
               Compatibility.check(document, "main", @any, "made_later")

      assert Compatibility.visibility(document, "main", "made_later") == :not_visible

      view = Projection.stage_view(document, "main")
      row = relationship(view, "rel-bind-reader-worktree")
      refute row.label =~ "accepted by Any"
      assert row.problem?

      target =
        document
        |> Projection.connect_targets("main", "made_later")
        |> Enum.find(&(&1.field == "worktree" and &1.node == "reader"))

      assert target.fit == :incompatible
      refute target.label =~ "accepted by Any"
    end

    test "After rows read as ordering" do
      view = Projection.stage_view(scenario_a(), "prepare")

      assert relationship(view, "rel-after-ask_claude-trust_mise").label ==
               "ask_claude runs after trust_mise"
    end

    test "a deleted producer's reference is marked unresolved" do
      document = edit_all(scenario_a(), [{:remove_node, "prepare", "worktree_directory"}])
      row = document |> Projection.stage_view("prepare") |> card("ask_claude")

      assert %{unresolved?: true, value: {:bind, "worktree_directory"}} =
               field(row, "working_directory")
    end
  end

  describe "connect_targets/3" do
    test "keeps incompatible fields and marks them" do
      targets = Projection.connect_targets(scenario_a(), "prepare", "resolve_worktree")

      assert %{fit: :incompatible} =
               Enum.find(targets, &({&1.node, &1.field} == {"ask_claude", "working_directory"}))

      assert %{fit: :accepted_by_any, label: label} =
               Enum.find(targets, &({&1.node, &1.field} == {"trust_mise", "worktree"}))

      assert label == "Bind resolve_worktree output to trust_mise.worktree; accepted by Any"

      assert %{fit: :exact} =
               Enum.find(targets, &({&1.node, &1.field} == {"worktree_directory", "worktree"}))
    end

    test "a target the bind would refuse as a cycle isn't accepted by Any" do
      targets = Projection.connect_targets(scenario_a(), "prepare", "ask_claude")
      target = Enum.find(targets, &({&1.node, &1.field} == {"trust_mise", "worktree"}))

      assert target.fit == :incompatible
      refute target.label =~ "accepted by Any"

      assert {:error, %Issue{code: :cycle}} =
               Operations.edit(
                 scenario_a(),
                 {:bind, "prepare", "trust_mise", "worktree", "ask_claude",
                  replace_literal: false}
               )
    end

    test "a fit is exactly what the bind accepts, for every source and field of the stage" do
      document = scenario_a()
      sources = ["prompt" | Map.keys(Document.nodes(document, "prepare"))]

      for source <- sources, target <- Projection.connect_targets(document, "prepare", source) do
        bind =
          {:bind, "prepare", target.node, target.field, source, replace_literal: true}

        assert match?({:ok, _document, _kind}, Operations.edit(document, bind)) ==
                 (target.fit != :incompatible),
               "#{source} -> #{target.node}.#{target.field}"
      end
    end
  end

  test "consumers/2 names every field reading a node" do
    assert Projection.consumers(scenario_a(), "resolve_worktree") == [
             "trust_mise.worktree",
             "worktree_directory.worktree"
           ]
  end

  describe "issue_rows/3" do
    test "link each issue to what it's about" do
      issues = [
        %Issue{code: :a, message: "a", target: {:field, "prepare", "ask_claude", "context"}},
        %Issue{code: :b, message: "b", target: {:input, "prompt"}},
        %Issue{code: :c, message: "c", target: :workflow},
        %Issue{code: :d, message: "d", target: {:after, "prepare", "ask_claude", "gone"}}
      ]

      assert [
               %{anchor: "field-ask_claude-context", node: "ask_claude", patch_stage: nil},
               %{anchor: "input-prompt", node: nil},
               %{anchor: "workflow-settings", node: nil},
               %{anchor: "rel-after-ask_claude-gone", node: "ask_claude"}
             ] = Projection.issue_rows(scenario_a(), issues, "prepare")
    end

    test "an issue in another stage patches there, and a Decision doesn't" do
      document =
        edit_all(scenario_a(), [{:add_stage, "other"}, {:put_input, "x", %{"type" => @string}}])

      issues = [
        %Issue{code: :a, message: "a", target: {:node, "other", "n"}},
        %Issue{code: :b, message: "b", target: {:vertex, "review"}}
      ]

      assert [%{patch_stage: "other"}, %{patch_stage: nil}] =
               Projection.issue_rows(document, issues, "prepare")
    end
  end
end

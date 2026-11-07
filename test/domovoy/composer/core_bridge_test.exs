defmodule Domovoy.Composer.CoreBridgeTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Catalog
  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias DomovoyCore.Graph
  alias DomovoyCore.Retry
  alias DomovoyCore.Type
  alias DomovoyCore.Workflow
  alias DomovoyMisePlugin.Runner.Trust

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @trust "DomovoyMisePlugin.Runner.Trust"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"
  @list_sessions "DomovoyClaudeCodePlugin.Runner.ListSessions"
  @describe_options "DomovoyClaudeCodePlugin.Validator.DescribeOptionsAreValid"
  @sentinel "sentinel-secret-value"

  defp document(ops), do: edit_all(Document.new("w"), ops)

  defp bind(stage, node, field, source) do
    {:bind, stage, node, field, source, replace_literal: false}
  end

  defp raw_bind(document, stage, node, field, source) do
    put_in(document, ["vertices", stage, "nodes", node, "inputs", field], %{"bind" => source})
  end

  defp built!(document) do
    assert {:ok, %Workflow{} = workflow} = CoreBridge.build(document)
    workflow
  end

  defp node_of(workflow, stage, name), do: workflow.vertices[stage].graph.nodes_by_name[name]

  defp rejected(document) do
    assert {:error, [%Issue{code: :core_rejected} = issue]} = CoreBridge.build(document)
    issue
  end

  # Stage `main` gives a Worktree and stage `later` reads it, or the like.
  defp two_stages(ops) do
    document([
      {:put_input, "name", %{"type" => @string}},
      {:add_stage, "later"},
      {:set_next, "main", "later"},
      {:add_node, "main", @resolve, "resolve"},
      bind("main", "resolve", "worktree_name", "name"),
      {:add_node, "main", @detect, "detect"} | ops
    ])
  end

  describe "build/1 on scenario A" do
    test "builds real Core structs" do
      workflow = built!(scenario_a())

      assert workflow.name == "scenario_a"
      assert workflow.start == "prepare"
      assert workflow.inputs["prompt"] == %{type: Type.String, required: true}
      assert workflow.vertices["prepare"].next == "review"
      assert workflow.vertices["review"].decider == DomovoyCore.Decider.Person

      revise = Enum.find(workflow.vertices["review"].choices, &(&1.name == "revise"))
      assert revise.target == {:rerun, "prepare"}
      assert revise.inputs == %{"prompt" => Type.String}
    end

    test "an Any field binds with its declared type, not its source's" do
      node = node_of(built!(scenario_a()), "prepare", "trust_mise")

      assert node.runner == Trust
      assert node.bind.worktree.from == "resolve_worktree"
      assert node.bind.worktree.type == Type.Any
    end

    test "parses literals and takes the field's type" do
      node = node_of(built!(scenario_a()), "prepare", "ask_claude")

      assert node.args == %{options: {%{}, Type.Map}}
      assert node.after == ["trust_mise"]
    end

    test "holds the layout on the workflow only" do
      document = scenario_a()
      workflow = built!(document)

      assert workflow.metadata == %{"domovoy_editor" => document["layout"]}
      assert workflow.vertices["prepare"].metadata == %{}
      assert node_of(workflow, "prepare", "ask_claude").metadata == %{}
    end
  end

  describe "build/1 on execution options" do
    test "overrides only max_attempts" do
      document =
        document([
          {:add_node, "main", @detect, "detect"},
          {:set_execution, "main", "detect", 3, false}
        ])

      node = node_of(built!(document), "main", "detect")

      assert node.retry ==
               Retry.new(
                 [max_attempts: 3],
                 DomovoyMisePlugin.Runner.Detect.__domovoy_core__(:retry)
               )

      assert node.store? == false

      plain =
        node_of(built!(document([{:add_node, "main", @detect, "detect"}])), "main", "detect")

      assert plain.retry == DomovoyMisePlugin.Runner.Detect.__domovoy_core__(:retry)
      assert plain.store? == true
    end

    test "resolves validators" do
      document =
        document([
          {:add_node, "main", @ask, "ask"},
          {:set_literal, "main", "ask", "context", "text", replace_binding: false},
          {:set_validators, "main", "ask", [@describe_options]}
        ])

      assert node_of(built!(document), "main", "ask").validators == [
               DomovoyClaudeCodePlugin.Validator.DescribeOptionsAreValid
             ]
    end

    test "keeps default and required only when the document holds them" do
      document =
        document([
          {:put_input, "a", %{"type" => @string}},
          {:put_input, "b", %{"type" => @string, "default" => "x"}},
          {:put_input, "c", %{"type" => "DomovoyCore.Type.Any", "default" => nil}},
          {:put_input, "d", %{"type" => @integer, "default" => "1"}}
        ])
        |> update_in(["inputs", "a"], &Map.delete(&1, "required"))

      inputs = built!(document).inputs

      assert inputs["a"] == %{type: Type.String}
      assert inputs["b"] == %{type: Type.String, default: "x", required: false}
      assert inputs["c"] == %{type: Type.Any, default: nil, required: false}
      assert inputs["d"] == %{type: Type.Integer, default: 1, required: false}
    end
  end

  describe "type rules against real Core" do
    # Each row is one binding. `Compatibility` and real Core must agree on it, in type
    # and in the Core identifier. `edit/2` refuses most of these, so they're hand-built.
    @rows [
      {"same graph, exact", :same, "main", @directory, "worktree", "resolve", :ok},
      {"same graph, Any field", :same, "main", @trust, "worktree", "resolve", :ok},
      {"same graph, mismatch", :same, "main", @directory, "worktree", "detect",
       :binding_type_mismatch},
      {"across stages, exact", :across, "later", @directory, "worktree", "resolve", :ok},
      {"across stages, Any field", :across, "later", @trust, "worktree", "resolve",
       :stage_input_type_mismatch},
      {"across stages, mismatch", :across, "later", @directory, "worktree", "detect",
       :stage_input_type_mismatch},
      {"workflow input, exact", :input, "later", @resolve, "worktree_name", "name", :ok},
      {"workflow input, mismatch", :input, "later", @directory, "worktree", "name",
       :stage_input_type_mismatch},
      {"workflow input, Any field", :input, "later", @trust, "worktree", "name",
       :stage_input_type_mismatch}
    ]

    for {label, _scope, stage, runner, field, source, expected} <- @rows do
      @stage stage
      @runner runner
      @field field
      @source source
      @expected expected

      test label do
        document =
          two_stages([{:add_node, @stage, @runner, "reader"}])
          |> raw_bind(@stage, "reader", @field, @source)
          |> fill_required(@stage, @runner)

        {:ok, entry} = Catalog.field(@runner, @field)
        verdict = Compatibility.check(document, @stage, entry.type_id, @source)

        case @expected do
          :ok ->
            assert {:ok, _fit} = verdict
            assert %Workflow{} = built!(document)
            refute Enum.any?(Analyzer.issues(document), &(&1.core_id != nil))

          core_id ->
            assert {:error, %Issue{core_id: ^core_id}} = verdict
            assert {:error, [%Issue{core_id: ^core_id}]} = CoreBridge.build(document)
            assert core_id in Enum.map(Analyzer.issues(document), & &1.core_id)
        end
      end
    end

    test "an Any field across stages passes while a sibling reads the source concretely" do
      document =
        two_stages([
          {:add_node, "later", @trust, "reader"},
          {:add_node, "later", @directory, "sibling"},
          bind("later", "sibling", "worktree", "resolve")
        ])
        |> raw_bind("later", "reader", "worktree", "resolve")
        |> raw_bind("later", "reader", "mise", "detect")

      assert {:ok, :accepted_by_any} =
               Compatibility.check(document, "later", "DomovoyCore.Type.Any", "resolve")

      assert %Workflow{} = built!(document)
      assert Analyzer.issues(document) == []

      alone =
        update_in(document, ["vertices", "later", "nodes"], &Map.delete(&1, "sibling"))

      assert {:error, [%Issue{core_id: :stage_input_type_mismatch}]} = CoreBridge.build(alone)
      assert :stage_input_type_mismatch in Enum.map(Analyzer.issues(alone), & &1.core_id)
    end

    test "conflicting concrete readings of one source" do
      document =
        document([
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @directory, "directory"}
        ])
        |> raw_bind("main", "resolve", "worktree_name", "shared")
        |> raw_bind("main", "directory", "worktree", "shared")

      assert {:error, [%Issue{core_id: :conflicting_input_types}]} = CoreBridge.build(document)

      assert [%Issue{core_id: :conflicting_input_types}] =
               Compatibility.conflicting_inputs(document, "main")
    end

    test "an Any reading of a source never conflicts" do
      document =
        document([
          {:put_input, "shared", %{"type" => @string}},
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @detect, "detect"},
          {:add_node, "main", @trust, "trust"}
        ])
        |> raw_bind("main", "resolve", "worktree_name", "shared")
        |> raw_bind("main", "trust", "worktree", "shared")
        |> raw_bind("main", "trust", "mise", "detect")

      assert Compatibility.conflicting_inputs(document, "main") == []
      assert %Workflow{} = built!(document)
    end

    test "a stage that start doesn't reach is not checked by Core, and is by the analyzer" do
      document =
        document([
          {:add_stage, "orphan"},
          {:add_node, "orphan", @resolve, "resolve"}
        ])
        |> raw_bind("orphan", "resolve", "worktree_name", "gone")

      assert %Workflow{} = built!(document)
      assert :unresolved_source in Enum.map(Analyzer.issues(document), & &1.code)
    end

    test "visibility agrees with Core's stage_input_unbound" do
      document =
        two_stages([
          {:add_node, "later", @resolve, "late"},
          bind("later", "late", "worktree_name", "name"),
          {:add_node, "main", @directory, "reader"}
        ])
        |> raw_bind("main", "reader", "worktree", "late")

      assert Compatibility.visibility(document, "main", "late") == :not_visible
      assert {:error, [%Issue{core_id: :stage_input_unbound}]} = CoreBridge.build(document)
    end
  end

  describe "build/1 failures" do
    test "a graph error stops the build rather than be masked by a later stage" do
      document =
        two_stages([
          {:add_node, "later", @directory, "reader"},
          bind("later", "reader", "worktree", "resolve")
        ])
        |> put_in(["vertices", "main", "nodes", "detect", "after"], ["gone"])

      assert {:error, [issue]} = CoreBridge.build(document)
      assert issue.core_id == :after_source_not_found
      assert issue.target == {:vertex, "main"}
    end

    test "a raised invalid_node gives its identifier and targets the node" do
      document = document([{:add_node, "main", @ask, "ask"}])

      issue = rejected(document)
      assert issue.core_id == :invalid_node
      assert issue.target == {:node, "main", "ask"}
    end

    test "a raise with no identifier has a nil core_id" do
      document =
        document([{:add_decision, "ask"}, {:put_decision, "ask", %{"prompt" => "Go?"}}])

      issue = rejected(document)
      assert issue.core_id == nil
      assert issue.target == {:vertex, "ask"}
    end

    test "a returned error uses its type" do
      document =
        document([{:put_input, "x", %{"type" => @string, "required" => true, "default" => "y"}}])

      assert rejected(document).core_id == :invalid_workflow_input
      assert rejected(Map.put(document([]), "start", "ghost")).core_id == :vertex_not_in_workflow
    end

    test "never echoes a value from a raise" do
      document = put_in(document([]), ["vertices", "main", "next"], [@sentinel])
      issue = rejected(document)

      refute issue.message =~ @sentinel
      assert issue.core_id == nil
    end

    test "never echoes a literal that doesn't parse" do
      document =
        document([
          {:add_node, "main", @list_sessions, "list"},
          {:set_literal, "main", "list", "limit", @sentinel, replace_binding: false}
        ])

      refute inspect(rejected(document)) =~ @sentinel
    end

    test "hand-built names don't raise or load anything" do
      for document <- [
            document([{:add_node, "main", @detect, "d"}])
            |> put_in(["vertices", "main", "nodes", "d", "runner"], "Elixir.System"),
            document([{:add_node, "main", @detect, "d"}]) |> raw_bind("main", "d", "nope", "x"),
            document([{:add_node, "main", @detect, "d"}])
            |> put_in(["vertices", "main", "nodes", "d", "validators"], ["Elixir.System"]),
            document([{:put_input, "x", %{"type" => @string}}])
            |> put_in(["inputs", "x", "type"], "Elixir.System"),
            document([{:put_input, "x", %{"type" => @string}}])
            |> put_in(["inputs", "x", "default"], 1)
          ] do
        assert {:error, [%Issue{core_id: nil}]} = CoreBridge.build(document)
      end
    end

    test "any term gives an issue" do
      for term <- [nil, 1, "x", [], %{}, %{"vertices" => 1}, %{"vertices" => %{"a" => 1}}] do
        assert {:error, [%Issue{target: _target}]} = CoreBridge.build(term)
      end
    end
  end

  describe "guarded/2" do
    test "passes a value and turns every failure into an issue" do
      assert CoreBridge.guarded(:workflow, fn -> {:ok, 1} end) == {:ok, 1}
      assert CoreBridge.guarded(:workflow, fn -> 1 end) == {:ok, 1}

      for fun <- [
            fn -> raise "boom #{@sentinel}" end,
            fn -> throw(@sentinel) end,
            fn -> exit(@sentinel) end,
            fn -> {:error, @sentinel} end
          ] do
        assert {:error, [%Issue{code: :core_rejected, core_id: nil} = issue]} =
                 CoreBridge.guarded(:workflow, fun)

        refute issue.message =~ @sentinel
      end
    end

    test "reads the identifier from a raised message only as a known prefix" do
      assert {:error, [%Issue{core_id: :invalid_decider}]} =
               CoreBridge.guarded(:workflow, fn -> raise ArgumentError, "invalid_decider: %{}" end)

      assert {:error, [%Issue{core_id: nil}]} =
               CoreBridge.guarded(:workflow, fn -> raise ArgumentError, "made_up: %{}" end)
    end

    test "passes nested issues through" do
      issues = [%Issue{code: :core_rejected, target: {:vertex, "a"}, message: "m"}]
      assert CoreBridge.guarded(:workflow, fn -> {:error, issues} end) == {:error, issues}
    end
  end

  test "a raw Graph's Error stays a host issue" do
    assert %DomovoyCore.Error{type: :duplicate_node_name} =
             Graph.new([%DomovoyCore.Node{name: "a"}, %DomovoyCore.Node{name: "a"}])

    assert {:error, [%Issue{core_id: :duplicate_node_name}]} =
             CoreBridge.guarded(:workflow, fn ->
               Graph.new([%DomovoyCore.Node{name: "a"}, %DomovoyCore.Node{name: "a"}])
             end)
  end

  # Trust also requires `mise`, read exactly, so it can't affect a row.
  defp fill_required(document, stage, @trust),
    do: raw_bind(document, stage, "reader", "mise", "detect")

  defp fill_required(document, _stage, _runner), do: document
end

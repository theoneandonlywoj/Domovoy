defmodule Domovoy.Composer.AnalyzerTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias DomovoyClaudeCodePlugin.Runner.AskClaude
  alias DomovoyClaudeCodePlugin.Type.ClaudeAnswer
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Type
  alias DomovoyCore.Workflow
  alias DomovoyGitPlugin.Runner.WorktreeDirectory
  alias DomovoyGitPlugin.Runner.WorktreeResolve
  alias DomovoyGitPlugin.Type.Worktree
  alias DomovoyMisePlugin.Runner.Detect
  alias DomovoyMisePlugin.Type.Executable

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @any "DomovoyCore.Type.Any"
  @date "DomovoyCore.Type.Date"
  @path "DomovoyCore.Type.Path"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @trust "DomovoyMisePlugin.Runner.Trust"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"
  @list_sessions "DomovoyClaudeCodePlugin.Runner.ListSessions"
  @write_file "DomovoyCore.Runner.WriteFile"
  @remote_present "DomovoyGitPlugin.Validator.RemotePresent"
  @session_directory "DomovoyClaudeCodePlugin.Validator.SessionDirectoryIsValid"
  @describe_options "DomovoyClaudeCodePlugin.Validator.DescribeOptionsAreValid"
  @sentinel "sentinel-secret-value"

  defp document(ops \\ []), do: edit_all(Document.new("w"), ops)

  defp bind(stage, node, field, source) do
    {:bind, stage, node, field, source, replace_literal: false}
  end

  defp literal(stage, node, field, raw) do
    {:set_literal, stage, node, field, raw, replace_binding: false}
  end

  defp put_input_raw(document, stage, node, field, value) do
    put_in(document, ["vertices", stage, "nodes", node, "inputs", field], value)
  end

  # Stage `main` holds a resolver, and stage `later` follows it.
  defp two_stages(ops \\ []) do
    document([
      {:put_input, "name", %{"type" => @string}},
      {:add_stage, "later"},
      {:set_next, "main", "later"},
      {:add_node, "main", @resolve, "resolve"},
      bind("main", "resolve", "worktree_name", "name") | ops
    ])
  end

  defp with_choices(choices) do
    document = document([{:add_decision, "ask"}, {:put_decision, "ask", %{"prompt" => "Go?"}}])
    put_in(document, ["vertices", "ask", "choices"], choices)
  end

  defp choice(name, target, inputs \\ %{}) do
    %{"name" => name, "description" => "Why", "target" => target, "inputs" => inputs}
  end

  defp codes(document), do: document |> Analyzer.issues() |> Enum.map(& &1.code)

  defp reported(document, code, target) do
    issues = Analyzer.issues(document)
    issue = Enum.find(issues, &(&1.code == code and &1.target == target))
    assert issue, "no #{code} on #{inspect(target)} in #{inspect(issues)}"
    issue
  end

  defp raw_workflow(vertices, opts \\ %{}) do
    Workflow.new(Map.merge(%{name: "raw", start: "a", vertices: vertices}, opts))
  end

  defp raw_stage(name, nodes, next \\ nil) do
    Stage.new(%{name: name, graph: Graph.new(nodes), next: next})
  end

  defp raw_detect(name \\ "detect", opts \\ %{}) do
    Node.new(Map.merge(%{name: name, runner: Detect, type: Executable}, opts))
  end

  defp raw_resolve(name, source) do
    Node.new(%{
      name: name,
      runner: WorktreeResolve,
      type: Worktree,
      bind: %{worktree_name: {source, Type.String}}
    })
  end

  defp raw_directory(name, source, type \\ Worktree) do
    Node.new(%{
      name: name,
      runner: WorktreeDirectory,
      type: Type.Directory,
      bind: %{worktree: {source, type}}
    })
  end

  test "scenario A has no issues" do
    assert Analyzer.issues(scenario_a()) == []
  end

  describe "rules Core rejects: a raw Core control, then the analyzer" do
    test "empty choices" do
      assert_raise ArgumentError, ~r/offers no choice/, fn ->
        Decision.new(%{name: "ask", prompt: "Go?", choices: []})
      end

      reported(with_choices([]), :no_choices, {:vertex, "ask"})
    end

    test "duplicate choices" do
      halt = Choice.new(%{name: "stop", description: "End", target: :halt})

      assert_raise ArgumentError, ~r/more than once/, fn ->
        Decision.new(%{name: "ask", prompt: "Go?", choices: [halt, halt]})
      end

      document = with_choices([choice("stop", ["halt"]), choice("stop", ["halt"])])
      reported(document, :duplicate_choice, {:choice, "ask", "stop"})
    end

    test "invalid next" do
      assert %Error{type: :vertex_not_in_workflow} =
               raw_workflow(%{"a" => raw_stage("a", [], "ghost")})

      document =
        document([{:add_stage, "gone"}, {:set_next, "main", "gone"}, {:remove_vertex, "gone"}])

      issue = reported(document, :unknown_next, {:vertex, "main"})
      assert issue.core_id == :vertex_not_in_workflow
    end

    test "invalid start" do
      assert %Error{type: :vertex_not_in_workflow} =
               raw_workflow(%{"a" => raw_stage("a", [])}, %{start: "ghost"})

      document =
        document([{:add_stage, "other"}, {:set_start, "other"}, {:remove_vertex, "other"}])

      issue = reported(document, :unknown_start, :workflow)
      assert issue.core_id == :vertex_not_in_workflow
    end

    test "binding_type_mismatch" do
      assert %Error{type: :binding_type_mismatch} =
               Graph.new([
                 raw_resolve("resolve", "name"),
                 Node.new(%{
                   name: "ask",
                   runner: AskClaude,
                   type: ClaudeAnswer,
                   bind: %{
                     context: {"name", Type.String},
                     working_directory: {"resolve", Type.Directory}
                   }
                 })
               ])

      document =
        two_stages([{:add_node, "main", @ask, "ask"}, bind("main", "ask", "context", "name")])
        |> put_input_raw("main", "ask", "working_directory", %{"bind" => "resolve"})

      issue = reported(document, :type_mismatch, {:field, "main", "ask", "working_directory"})
      assert issue.core_id == :binding_type_mismatch
    end

    test "graph_has_cycle" do
      assert %Error{type: :graph_has_cycle} =
               Graph.new([
                 raw_detect("a", %{after: ["b"]}),
                 raw_detect("b", %{after: ["a"]})
               ])

      document =
        document([{:add_node, "main", @detect, "a"}, {:add_node, "main", @detect, "b"}])
        |> put_in(["vertices", "main", "nodes", "a", "after"], ["b"])
        |> put_in(["vertices", "main", "nodes", "b", "after"], ["a"])

      issue = reported(document, :cycle, {:vertex, "main"})
      assert issue.core_id == :graph_has_cycle
      assert issue.message =~ "a, b"
    end

    test "after_source_not_found" do
      assert %Error{type: :after_source_not_found} =
               Graph.new([raw_detect("a", %{after: ["gone"]})])

      document =
        document([
          {:add_node, "main", @detect, "gone"},
          {:add_node, "main", @detect, "a"},
          {:add_after, "main", "a", "gone"},
          {:remove_node, "main", "gone"}
        ])

      issue = reported(document, :after_source_not_found, {:after, "main", "a", "gone"})
      assert issue.core_id == :after_source_not_found
    end

    test "stage_input_type_mismatch" do
      vertices = %{
        "a" => raw_stage("a", [raw_detect()], "b"),
        "b" => raw_stage("b", [raw_resolve("resolve", "detect")])
      }

      assert %Error{type: :stage_input_type_mismatch} = raw_workflow(vertices)

      document =
        document([
          {:add_stage, "later"},
          {:set_next, "main", "later"},
          {:add_node, "main", @detect, "detect"},
          {:add_node, "later", @resolve, "resolve"}
        ])
        |> put_input_raw("later", "resolve", "worktree_name", %{"bind" => "detect"})

      issue = reported(document, :type_mismatch, {:field, "later", "resolve", "worktree_name"})
      assert issue.core_id == :stage_input_type_mismatch
    end

    test "stage_input_unbound" do
      assert %Error{type: :stage_input_unbound} =
               raw_workflow(%{"a" => raw_stage("a", [raw_resolve("resolve", "gone")])})

      document =
        document([{:put_input, "gone", %{"type" => @string}}])
        |> then(&edit_all(&1, [{:add_node, "main", @resolve, "resolve"}]))
        |> then(&edit_all(&1, [bind("main", "resolve", "worktree_name", "gone")]))
        |> then(&edit_all(&1, [{:remove_input, "gone"}]))

      issue = reported(document, :unresolved_source, {:field, "main", "resolve", "worktree_name"})
      assert issue.core_id == :stage_input_unbound
    end

    test "stage_input_unbound for a source that runs later" do
      vertices = %{
        "a" => raw_stage("a", [raw_directory("directory", "resolve")], "b"),
        "b" => raw_stage("b", [raw_resolve("resolve", "name")])
      }

      assert %Error{type: :stage_input_unbound} =
               raw_workflow(vertices, %{inputs: %{"name" => %{type: Type.String}}})

      document =
        two_stages()
        |> edit_all([
          {:add_node, "later", @resolve, "late"},
          bind("later", "late", "worktree_name", "name"),
          {:add_node, "main", @directory, "directory"},
          bind("main", "directory", "worktree", "late")
        ])

      assert Compatibility.visibility(document, "main", "late") == :not_visible

      issue = reported(document, :source_not_visible, {:field, "main", "directory", "worktree"})
      assert issue.core_id == :stage_input_unbound
    end

    test "choice_inputs_not_rerun" do
      ask =
        Decision.new(%{
          name: "ask",
          prompt: "Go?",
          choices: [
            Choice.new(%{
              name: "stop",
              description: "End",
              target: :halt,
              inputs: %{"note" => Type.String}
            })
          ]
        })

      assert %Error{type: :choice_inputs_not_rerun} =
               raw_workflow(%{"ask" => ask}, %{start: "ask"})

      document = with_choices([choice("stop", ["halt"], %{"note" => @string})])
      issue = reported(document, :choice_inputs_not_rerun, {:choice, "ask", "stop"})
      assert issue.core_id == :choice_inputs_not_rerun
    end

    test "conflicting_input_types" do
      assert %Error{type: :conflicting_input_types} =
               Graph.new([raw_resolve("resolve", "shared"), raw_directory("directory", "shared")])

      document =
        document([
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @directory, "directory"}
        ])
        |> put_input_raw("main", "resolve", "worktree_name", %{"bind" => "shared"})
        |> put_input_raw("main", "directory", "worktree", %{"bind" => "shared"})

      issue =
        reported(document, :conflicting_input_types, {:field, "main", "resolve", "worktree_name"})

      assert issue.core_id == :conflicting_input_types
      assert issue.message =~ "Git Worktree"
    end

    test "name_collision" do
      assert %Error{type: :name_collision} =
               raw_workflow(%{"a" => raw_stage("a", [raw_detect("shared")])}, %{
                 inputs: %{"shared" => %{type: Type.String}}
               })

      document =
        document([{:put_input, "shared", %{"type" => @string}}])
        |> put_in(["vertices", "main", "nodes", "shared"], Document.new_node(@detect))

      issue = reported(document, :name_collision, {:node, "main", "shared"})
      assert issue.core_id == :name_collision
    end

    test "name_collision between a decision and an input" do
      ask =
        Decision.new(%{
          name: "ask",
          prompt: "Go?",
          choices: [Choice.new(%{name: "stop", description: "End", target: :halt})]
        })

      assert %Error{type: :name_collision} =
               raw_workflow(%{"ask" => ask}, %{
                 start: "ask",
                 inputs: %{"ask" => %{type: Type.String}}
               })

      document =
        with_choices([choice("stop", ["halt"])])
        |> put_in(["inputs", "ask"], %{"type" => @string, "required" => false})

      reported(document, :name_collision, {:vertex, "ask"})
    end

    test "required missing" do
      assert_raise ArgumentError, ~r/invalid_node:.*required_input/, fn ->
        Node.new(%{name: "ask", runner: AskClaude, type: ClaudeAnswer})
      end

      document = document([{:add_node, "main", @ask, "ask"}])
      issue = reported(document, :required_missing, {:field, "main", "ask", "context"})
      assert issue.core_id == :invalid_node
    end

    test "max_attempts of zero or below" do
      assert_raise ArgumentError, ~r/invalid_node:.*invalid_retry/, fn ->
        raw_detect("detect", %{retry: [max_attempts: 0]})
      end

      for attempts <- [0, -1] do
        document =
          document([
            {:add_node, "main", @detect, "detect"},
            {:set_execution, "main", "detect", attempts, true}
          ])

        issue = reported(document, :invalid_max_attempts, {:node, "main", "detect"})
        assert issue.core_id == :invalid_node
      end
    end

    test "a Rerun target that is a Decision" do
      ask =
        Decision.new(%{
          name: "ask",
          prompt: "Go?",
          choices: [Choice.new(%{name: "again", description: "Again", target: {:rerun, "ask"}})]
        })

      assert %Error{type: :rerun_target_not_a_stage} =
               raw_workflow(%{"ask" => ask}, %{start: "ask"})

      document = with_choices([choice("again", ["rerun", "ask"])])
      issue = reported(document, :rerun_target_not_a_stage, {:choice, "ask", "again"})
      assert issue.core_id == :rerun_target_not_a_stage
    end

    test "a choice target that doesn't exist" do
      ask =
        Decision.new(%{
          name: "ask",
          prompt: "Go?",
          choices: [Choice.new(%{name: "on", description: "On", target: {:run, "ghost"}})]
        })

      assert %Error{type: :vertex_not_in_workflow} =
               raw_workflow(%{"ask" => ask}, %{start: "ask"})

      for target <- [["run", "ghost"], ["rerun", "ghost"]] do
        document = with_choices([choice("on", target)])
        reported(document, :unknown_target, {:choice, "ask", "on"})
      end
    end

    test "required plus default" do
      assert %Error{type: :invalid_workflow_input} =
               raw_workflow(%{"a" => raw_stage("a", [])}, %{
                 inputs: %{"x" => %{type: Type.String, required: true, default: "y"}}
               })

      document =
        document([{:put_input, "x", %{"type" => @string, "required" => true, "default" => "y"}}])

      issue = reported(document, :required_with_default, {:input, "x"})
      assert issue.core_id == :invalid_workflow_input
    end

    test "a choice and a workflow input sharing a key with another type" do
      ask =
        Decision.new(%{
          name: "ask",
          prompt: "Go?",
          choices: [
            Choice.new(%{
              name: "again",
              description: "Again",
              target: {:rerun, "a"},
              inputs: %{"x" => Type.Integer}
            })
          ]
        })

      assert %Error{type: :choice_input_type_mismatch} =
               raw_workflow(%{"a" => raw_stage("a", [], "ask"), "ask" => ask}, %{
                 inputs: %{"x" => %{type: Type.String}}
               })

      document =
        with_choices([choice("again", ["rerun", "main"], %{"x" => @integer})])
        |> put_in(["inputs", "x"], %{"type" => @string, "required" => false})

      issue = reported(document, :choice_input_type_mismatch, {:choice, "ask", "again"})
      assert issue.core_id == :choice_input_type_mismatch
    end

    test "two choices sharing a key with another type" do
      document =
        with_choices([
          choice("one", ["rerun", "main"], %{"x" => @string}),
          choice("two", ["rerun", "main"], %{"x" => @integer})
        ])

      assert :choice_input_type_mismatch in codes(document)
    end

    test "an invalid name" do
      assert_raise ArgumentError, ~r/not a name/, fn ->
        Stage.new(%{name: "a b", graph: Graph.new()})
      end

      document = put_in(document(), ["vertices", "a b"], Document.stage())
      issue = reported(document, :invalid_name, {:vertex, "a b"})
      refute issue.message =~ "a b"

      assert :invalid_name in codes(Map.put(document(), "name", "a b"))
    end
  end

  describe "rules stricter than Core: Core accepts, the analyzer reports" do
    test "a blank required literal" do
      node =
        Node.new(%{
          name: "resolve",
          runner: WorktreeResolve,
          type: Worktree,
          args: %{worktree_name: {"  ", Type.String}}
        })

      assert %Workflow{} = raw_workflow(%{"a" => raw_stage("a", [node])})

      document =
        document([
          {:add_node, "main", @resolve, "resolve"},
          literal("main", "resolve", "worktree_name", "  ")
        ])

      reported(document, :blank_required, {:field, "main", "resolve", "worktree_name"})
    end

    test "a dangling reference in a stage start doesn't reach" do
      vertices = %{
        "a" => raw_stage("a", []),
        "orphan" => raw_stage("orphan", [raw_resolve("resolve", "gone")])
      }

      assert %Workflow{} = raw_workflow(vertices)

      document =
        document([{:put_input, "gone", %{"type" => @string}}, {:add_stage, "orphan"}])
        |> edit_all([
          {:add_node, "orphan", @resolve, "resolve"},
          bind("orphan", "resolve", "worktree_name", "gone"),
          {:remove_input, "gone"}
        ])

      assert Compatibility.visibility(document, "orphan", "gone") == :stage_unreachable

      issue =
        reported(document, :unresolved_source, {:field, "orphan", "resolve", "worktree_name"})

      assert issue.core_id == nil
    end

    test "a source that exists but can't precede a stage start doesn't reach" do
      document =
        document([{:put_input, "name", %{"type" => @string}}, {:add_stage, "orphan"}])
        |> edit_all([
          {:add_node, "main", @resolve, "resolve"},
          bind("main", "resolve", "worktree_name", "name"),
          {:add_node, "orphan", @directory, "directory"},
          bind("orphan", "directory", "worktree", "resolve")
        ])

      issue = reported(document, :unresolved_source, {:field, "orphan", "directory", "worktree"})
      assert issue.core_id == nil
    end

    test "a null default" do
      assert %Workflow{} =
               raw_workflow(%{"a" => raw_stage("a", [])}, %{
                 inputs: %{"x" => %{type: Type.Integer, default: nil}}
               })

      document = document([{:put_input, "x", %{"type" => @integer, "default" => nil}}])
      reported(document, :null_default, {:input, "x"})
    end

    test "a blank prompt" do
      assert %Decision{} =
               Decision.new(%{
                 name: "ask",
                 prompt: " ",
                 choices: [Choice.new(%{name: "stop", description: "End", target: :halt})]
               })

      document =
        with_choices([choice("stop", ["halt"])])
        |> put_in(["vertices", "ask", "prompt"], "  ")

      reported(document, :blank_prompt, {:vertex, "ask"})
    end

    test "a blank description" do
      assert %Choice{} = Choice.new(%{name: "stop", description: " ", target: :halt})

      assert_raise ArgumentError, fn ->
        Choice.new(%{name: "s", description: "", target: :halt})
      end

      for {description, core_id} <- [{"", :invalid_choice_description}, {"  ", nil}] do
        document =
          with_choices([%{choice("stop", ["halt"]) | "description" => description}])

        assert reported(document, :blank_description, {:choice, "ask", "stop"}).core_id == core_id
      end
    end

    test "a default on a bind-only type" do
      assert %Workflow{} =
               raw_workflow(%{"a" => raw_stage("a", [])}, %{
                 inputs: %{"on" => %{type: Type.Date, default: "2026-10-30"}}
               })

      for type <- [@date, "DomovoyGitPlugin.Type.Worktree"], default <- ["2026-10-30", nil] do
        document = document([{:put_input, "on", %{"type" => type, "default" => default}}])
        reported(document, :default_bind_only, {:input, "on"})
      end
    end
  end

  describe "a workflow input default a required field can't take" do
    # Core builds this definition, then any run omitting the input hands the default
    # to the field and fails with invalid_input (inputs.ex:204-206, runner.ex:269-271).
    defp default_bound(type, field, runner, default) do
      document([
        {:put_input, "given", %{"type" => type, "default" => default}},
        {:add_node, "main", runner, "reader"},
        bind("main", "reader", field, "given")
      ])
    end

    test "Core's definition accepts it and the runner refuses the value" do
      assert {:ok, _workflow} =
               CoreBridge.build(default_bound(@string, "worktree_name", @resolve, ""))

      refute DomovoyCore.Runner.changeset(WorktreeResolve, %{worktree_name: ""}).valid?
      refute DomovoyCore.Runner.changeset(WorktreeResolve, %{worktree_name: nil}).valid?
    end

    test "blank text is an issue on the field" do
      for default <- ["", "   "] do
        document = default_bound(@string, "worktree_name", @resolve, default)
        target = {:field, "main", "reader", "worktree_name"}

        assert %Issue{core_id: nil} = reported(document, :unusable_input_default, target)
      end
    end

    test "an Any default decoding to blank text or null is an issue on the field" do
      for default <- [nil, "null", ~s("  ")] do
        document = default_bound(@any, "worktree", @trust, default)
        reported(document, :unusable_input_default, {:field, "main", "reader", "worktree"})
      end
    end

    test "a null default names the field as well as the input" do
      document = default_bound(@string, "worktree_name", @resolve, nil)

      reported(document, :unusable_input_default, {:field, "main", "reader", "worktree_name"})
      reported(document, :null_default, {:input, "given"})
    end

    test "a usable default, or an optional field, is fine" do
      refute :unusable_input_default in codes(
               default_bound(@string, "worktree_name", @resolve, "tree")
             )

      refute :unusable_input_default in codes(default_bound(@any, "worktree", @trust, "{}"))

      refute :unusable_input_default in codes(
               default_bound(@integer, "limit", @list_sessions, "1")
             )

      refute :unusable_input_default in codes(
               default_bound(@string, "config_dir", @list_sessions, " ")
             )
    end

    test "an absent default is not this issue" do
      document =
        document([
          {:put_input, "given", %{"type" => @string}},
          {:add_node, "main", @resolve, "reader"},
          bind("main", "reader", "worktree_name", "given")
        ])

      refute :unusable_input_default in codes(document)
    end
  end

  describe "a stage reading a producer whose graph fails" do
    setup do
      document =
        two_stages([
          {:add_node, "main", @detect, "detect"},
          {:add_after, "main", "detect", "resolve"},
          {:add_node, "later", @directory, "directory"},
          bind("later", "directory", "worktree", "resolve")
        ])
        |> put_in(["vertices", "main", "nodes", "detect", "after"], ["gone"])

      %{document: document}
    end

    test "Core reports only the later stage, because it drops the broken stage's nodes", %{
      document: document
    } do
      assert Compatibility.visibility(document, "later", "resolve") == :visible

      vertices = %{
        "a" =>
          raw_stage(
            "a",
            [raw_resolve("resolve", "name"), raw_detect("detect", %{after: ["gone"]})],
            "b"
          ),
        "b" => raw_stage("b", [raw_directory("directory", "resolve")])
      }

      assert %Error{type: :stage_input_unbound} =
               raw_workflow(vertices, %{inputs: %{"name" => %{type: Type.String}}})
    end

    test "the analyzer reports both", %{document: document} do
      reported(document, :after_source_not_found, {:after, "main", "detect", "gone"})

      issue = reported(document, :source_not_visible, {:field, "later", "directory", "worktree"})
      assert issue.core_id == :stage_input_unbound
      assert issue.message =~ "main"
    end

    test "fixing the graph clears both", %{document: document} do
      fixed = put_in(document, ["vertices", "main", "nodes", "detect", "after"], [])
      assert Analyzer.issues(fixed) == []
    end

    test "a type mismatch from the broken stage isn't masked", %{document: document} do
      mismatched =
        put_input_raw(document, "later", "directory", "worktree", %{"bind" => "detect"})

      target = {:field, "later", "directory", "worktree"}
      reported(mismatched, :source_not_visible, target)
      assert reported(mismatched, :type_mismatch, target).core_id == :stage_input_type_mismatch
    end
  end

  describe "literals" do
    test "follow the allowlist" do
      for {runner, field, raw} <- [
            {@list_sessions, "limit", "10"},
            {@ask, "context", "text"},
            {@ask, "options", "{}"},
            {@trust, "worktree", ~s({"a": 1})},
            {@write_file, "path", "~/x"}
          ] do
        document =
          document([{:add_node, "main", runner, "node"}, literal("main", "node", field, raw)])

        refute :invalid_literal in codes(document)
      end
    end

    test "a value that doesn't parse is an issue naming its type, never its value" do
      document =
        document([
          {:add_node, "main", @list_sessions, "list"},
          literal("main", "list", "limit", "not an int #{@sentinel}")
        ])

      issue = reported(document, :invalid_literal, {:field, "main", "list", "limit"})
      assert issue.message =~ "Integer"
      refute inspect(Analyzer.issues(document)) =~ @sentinel
    end

    test "null on a required Any field" do
      document =
        document([
          {:add_node, "main", @trust, "trust"},
          literal("main", "trust", "worktree", "null")
        ])

      reported(document, :null_required, {:field, "main", "trust", "worktree"})
    end

    test "null on an optional Any field is fine" do
      document = document([{:add_node, "main", @detect, "detect"}])
      refute :null_required in codes(document)
    end

    test "a quoted blank on a required Any field" do
      document =
        document([
          {:add_node, "main", @trust, "trust"},
          literal("main", "trust", "worktree", ~s("  "))
        ])

      reported(document, :blank_required, {:field, "main", "trust", "worktree"})
    end

    test "a hand-built literal on a bind-only field" do
      document =
        document([{:add_node, "main", @directory, "directory"}])
        |> put_input_raw("main", "directory", "worktree", %{"literal" => "x"})

      issue = reported(document, :invalid_literal, {:field, "main", "directory", "worktree"})
      assert issue.message =~ "binding"
    end

    test "a hand-built literal that isn't text" do
      document =
        document([{:add_node, "main", @list_sessions, "list"}])
        |> put_input_raw("main", "list", "limit", %{"literal" => 10})

      reported(document, :invalid_literal, {:field, "main", "list", "limit"})
    end

    test "a default goes through the same parser" do
      document = document([{:put_input, "n", %{"type" => @integer, "default" => "x"}}])
      reported(document, :invalid_default, {:input, "n"})

      assert Analyzer.issues(
               document([{:put_input, "n", %{"type" => @integer, "default" => "1"}}])
             ) == []

      assert Analyzer.issues(
               document([{:put_input, "p", %{"type" => @path, "default" => "~/x"}}])
             ) == []
    end

    test "absent and explicit null defaults stay distinct; Any accepts null" do
      assert Analyzer.issues(document([{:put_input, "x", %{"type" => @string}}])) == []

      assert Analyzer.issues(document([{:put_input, "x", %{"type" => @any, "default" => nil}}])) ==
               []

      assert :null_default in codes(
               document([{:put_input, "x", %{"type" => @string, "default" => nil}}])
             )
    end
  end

  describe "validators" do
    test "report a curated validator that reads fields the runner lacks" do
      document =
        document([
          {:add_node, "main", @detect, "detect"},
          {:set_validators, "main", "detect", [@remote_present]}
        ])

      issue = reported(document, :validator_misfit, {:node, "main", "detect"})
      assert issue.message =~ "RemotePresent"
    end

    test "report one that duplicates an inherited validator" do
      document =
        document([
          {:add_node, "main", @ask, "ask"},
          bind_literal("ask"),
          {:set_validators, "main", "ask", [@session_directory]}
        ])

      reported(document, :duplicate_validator, {:node, "main", "ask"})
    end

    test "accept a curated validator that fits" do
      document =
        document([
          {:add_node, "main", @ask, "ask"},
          bind_literal("ask"),
          {:set_validators, "main", "ask", [@describe_options]}
        ])

      assert Analyzer.issues(document) == []
    end

    test "report a hand-built unknown or repeated validator" do
      document = document([{:add_node, "main", @ask, "ask"}, bind_literal("ask")])

      unknown =
        put_in(document, ["vertices", "main", "nodes", "ask", "validators"], ["Elixir.System"])

      reported(unknown, :unknown_validator, {:node, "main", "ask"})

      repeated =
        put_in(document, ["vertices", "main", "nodes", "ask", "validators"], [
          @describe_options,
          @describe_options
        ])

      reported(repeated, :duplicate_validator, {:node, "main", "ask"})
    end
  end

  describe "names that resolve to nothing" do
    test "an unknown runner, field, type and decider" do
      document =
        document([
          {:add_node, "main", @detect, "detect"},
          {:put_input, "x", %{"type" => @string}}
        ])
        |> put_input_raw("main", "detect", "nope", %{"literal" => "1"})
        |> put_in(["inputs", "x", "type"], "Elixir.System")
        |> put_in(["vertices", "main", "nodes", "ghost"], Document.new_node("Elixir.System"))

      reported(document, :unknown_runner, {:node, "main", "ghost"})
      reported(document, :unknown_field, {:field, "main", "detect", "nope"})
      reported(document, :unknown_type, {:input, "x"})

      decision =
        with_choices([choice("stop", ["halt"])])
        |> put_in(["vertices", "ask", "decider"], "Elixir.System")

      reported(decision, :unknown_decider, {:vertex, "ask"})
    end

    test "a producer with an unknown runner adds no second issue to its reader" do
      document =
        two_stages([
          {:add_node, "later", @directory, "directory"},
          bind("later", "directory", "worktree", "resolve")
        ])
        |> put_in(["vertices", "main", "nodes", "resolve", "runner"], "Elixir.System")

      assert codes(document) == [:unknown_runner]
    end
  end

  test "deleting a producer keeps the reference visible, even where start doesn't reach" do
    document = scenario_a()

    {:ok, deleted, :definition} =
      Domovoy.Composer.Operations.edit(document, {:remove_node, "prepare", "worktree_directory"})

    target = {:field, "prepare", "ask_claude", "working_directory"}
    issue = reported(deleted, :unresolved_source, target)
    assert issue.message =~ "worktree_directory"
    refute is_map_key(deleted["inputs"], "worktree_directory")
  end

  test "a document with node, graph and workflow problems lists them all, each with a target" do
    document =
      two_stages([
        {:add_node, "main", @ask, "ask"},
        {:add_node, "main", @detect, "detect"},
        {:add_decision, "ask_user"},
        {:set_next, "later", "ask_user"},
        {:put_input, "n", %{"type" => @integer, "required" => true, "default" => "x"}}
      ])
      |> put_in(["vertices", "main", "nodes", "detect", "after"], ["gone"])
      |> Map.put("start", "ghost")

    found = codes(document)

    for code <- [
          :required_missing,
          :after_source_not_found,
          :unknown_start,
          :no_choices,
          :blank_prompt,
          :required_with_default,
          :invalid_default
        ] do
      assert code in found
    end

    for %Issue{target: target, message: message} <- Analyzer.issues(document) do
      assert target
      assert is_binary(message)
    end
  end

  test "the order is stable" do
    document =
      document(Enum.map(1..40, &{:add_node, "main", @ask, "ask_#{&1}"}))
      |> Map.put("start", "ghost")

    issues = Analyzer.issues(document)

    assert Analyzer.issues(:erlang.binary_to_term(:erlang.term_to_binary(document))) == issues
    assert hd(issues).code == :unknown_start

    node_order = for %Issue{target: {:field, _s, node, _f}} <- issues, do: node
    assert node_order == Enum.sort(node_order)
  end

  defp bind_literal(node), do: literal("main", node, "context", "text")
end

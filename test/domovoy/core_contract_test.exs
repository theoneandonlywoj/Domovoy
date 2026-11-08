defmodule Domovoy.CoreContractTest do
  # Pins the Core 0.3.4 behaviour the composer relies on. Nothing here runs a
  # node or starts DomovoyCore.Runtime; a failure means a pin moved.
  use ExUnit.Case, async: true

  alias DomovoyClaudeCodePlugin.Runner.AskClaude
  alias DomovoyClaudeCodePlugin.Type.ClaudeAnswer
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Definition
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
  alias DomovoyMisePlugin.Runner.Trust
  alias DomovoyMisePlugin.Type.Executable

  test "the host runs Core 0.3.4" do
    assert Application.spec(:domovoy_core, :vsn) == ~c"0.3.4"
  end

  describe "scenario A" do
    test "round-trips with equal struct, fingerprint and bytes" do
      workflow = scenario_a()
      assert %Workflow{} = workflow

      assert {:ok, json} = Workflow.to_json(workflow)
      assert {:ok, decoded} = Workflow.from_json(json)

      assert decoded == workflow
      assert Definition.fingerprint(decoded) == Definition.fingerprint(workflow)
      assert Workflow.to_json(decoded) == {:ok, json}
    end

    test "metadata is outside the fingerprint" do
      workflow = scenario_a()
      moved = scenario_a(%{"layout" => %{"resolve_worktree" => %{"x" => 40, "y" => 80}}})

      refute moved == workflow
      assert Definition.fingerprint(moved).root == Definition.fingerprint(workflow).root
    end
  end

  describe "input metadata" do
    @description %{"description" => "The worktree to resolve."}

    test "round-trips outside the fingerprint" do
      plain = input_workflow(%{type: Type.String, required: true})
      described = input_workflow(%{type: Type.String, required: true, metadata: @description})

      assert described.inputs["worktree_name"][:metadata] == @description

      assert {:ok, json} = Workflow.to_json(described)
      assert Jason.decode!(json)["inputs"]["worktree_name"]["metadata"] == @description
      assert {:ok, decoded} = Workflow.from_json(json)

      assert decoded == described
      assert Workflow.to_json(decoded) == {:ok, json}
      assert Definition.fingerprint(described).root == Definition.fingerprint(plain).root
    end

    test "refuses a non-map" do
      assert input_workflow(%{type: Type.String, required: true, metadata: 3}) ==
               Error.invalid_workflow_input("worktree_name", :invalid_metadata)
    end
  end

  describe "runner reflection" do
    test "gives the fixed output types scenario A uses" do
      assert WorktreeResolve.__domovoy_core__(:output) == Worktree
      assert WorktreeDirectory.__domovoy_core__(:output) == Type.Directory
      assert Detect.__domovoy_core__(:output) == Executable
      assert Trust.__domovoy_core__(:output) == Type.Map
      assert AskClaude.__domovoy_core__(:output) == ClaudeAnswer
    end

    test "declares Trust.worktree as Any and requires AskClaude.context" do
      assert Trust.__domovoy_core__(:input).__schema__(:type, :worktree) == Type.Any
      assert :context in AskClaude.__domovoy_core__(:required)
    end
  end

  describe "Any field bindings" do
    test "are accepted from a producer in the same graph" do
      assert %Workflow{} = workflow(%{"a" => stage("a", [resolve(), detect(), trust()])}, "a")
    end

    test "are rejected from a producer in an earlier stage" do
      vertices = %{
        "a" => stage("a", [resolve(), detect()], "b"),
        "b" => stage("b", [trust()])
      }

      assert %Error{type: :stage_input_type_mismatch} = workflow(vertices, "a")
    end

    test "pass across stages when a sibling binds the same source with its concrete type" do
      vertices = %{
        "a" => stage("a", [resolve(), detect()], "b"),
        "b" => stage("b", [trust(), worktree_directory()])
      }

      assert %Workflow{} = workflow(vertices, "a")
    end
  end

  test "a Date string default round-trips with an equal fingerprint" do
    workflow =
      Workflow.new(%{
        name: "dated",
        vertices: %{"a" => stage("a", [])},
        start: "a",
        inputs: %{"on" => %{type: Type.Date, default: "2026-10-30"}}
      })

    assert %Workflow{} = workflow
    assert {:ok, decoded} = workflow |> Workflow.to_json!() |> Workflow.from_json()
    assert decoded == workflow
    assert Definition.fingerprint(decoded) == Definition.fingerprint(workflow)
  end

  test "a dangling reference in an unreachable stage validates" do
    orphan =
      Node.new(%{
        name: "ask",
        runner: AskClaude,
        type: ClaudeAnswer,
        bind: %{context: {"gone", Type.String}}
      })

    vertices = %{"a" => stage("a", []), "orphan" => stage("orphan", [orphan])}

    assert %Workflow{} = workflow(vertices, "a")
  end

  test "raw Graph.new reports duplicate_node_name" do
    assert %Error{type: :duplicate_node_name} = Graph.new([detect(), detect()])
  end

  defp scenario_a(metadata \\ %{}) do
    Workflow.new(%{
      name: "scenario_a",
      start: "prepare",
      metadata: metadata,
      inputs: %{
        "worktree_name" => %{type: Type.String, required: true},
        "prompt" => %{type: Type.String, required: true}
      },
      vertices: %{
        "prepare" =>
          stage(
            "prepare",
            [
              resolve(),
              worktree_directory(),
              detect(),
              trust(),
              Node.new(%{
                name: "ask_claude",
                runner: AskClaude,
                type: ClaudeAnswer,
                bind: %{
                  context: {"prompt", Type.String},
                  working_directory: {"worktree_directory", Type.Directory}
                },
                args: %{options: {%{}, Type.Map}},
                after: ["trust_mise"]
              })
            ],
            "review"
          ),
        "review" =>
          Decision.new(%{
            name: "review",
            prompt: "Approve the answer?",
            choices: [
              Choice.new(%{name: "approve", description: "Accept", target: :halt}),
              Choice.new(%{
                name: "revise",
                description: "Ask again",
                target: {:rerun, "prepare"},
                inputs: %{"prompt" => Type.String}
              })
            ]
          })
      }
    })
  end

  defp input_workflow(input) do
    Workflow.new(%{
      name: "contract",
      start: "a",
      vertices: %{"a" => stage("a", [resolve()])},
      inputs: %{"worktree_name" => input}
    })
  end

  defp workflow(vertices, start) do
    Workflow.new(%{
      name: "contract",
      start: start,
      vertices: vertices,
      inputs: %{"worktree_name" => %{type: Type.String, required: true}}
    })
  end

  defp stage(name, nodes, next \\ nil) do
    args = %{name: name, graph: Graph.new(nodes)}
    Stage.new(if(next, do: Map.put(args, :next, next), else: args))
  end

  defp resolve do
    Node.new(%{
      name: "resolve_worktree",
      runner: WorktreeResolve,
      type: Worktree,
      bind: %{worktree_name: {"worktree_name", Type.String}}
    })
  end

  defp detect, do: Node.new(%{name: "detect_mise", runner: Detect, type: Executable})

  defp trust do
    Node.new(%{
      name: "trust_mise",
      runner: Trust,
      type: Type.Map,
      bind: %{worktree: {"resolve_worktree", Type.Any}, mise: {"detect_mise", Executable}}
    })
  end

  defp worktree_directory do
    Node.new(%{
      name: "worktree_directory",
      runner: WorktreeDirectory,
      type: Type.Directory,
      bind: %{worktree: {"resolve_worktree", Worktree}}
    })
  end
end

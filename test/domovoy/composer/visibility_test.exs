defmodule Domovoy.Composer.VisibilityTest do
  # One document drives both sides: `Compatibility.visibility/3` reads it, and
  # `build/1` hands the same document to real `Workflow.new`.
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2]

  alias Domovoy.Catalog
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Document
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Workflow

  @string "DomovoyCore.Type.String"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"

  defp document(ops) do
    edit_all(
      Document.new("w"),
      List.flatten([{:put_input, "prompt", %{"type" => @string}} | ops])
    )
  end

  defp resolve(stage, name \\ "resolve") do
    [
      {:add_node, stage, @resolve, name},
      {:bind, stage, name, "worktree_name", "prompt", replace_literal: false}
    ]
  end

  defp directory(stage, source) do
    [
      {:add_node, stage, @directory, "directory"},
      {:bind, stage, "directory", "worktree", source, replace_literal: false}
    ]
  end

  defp reader(stage, source) do
    [
      {:add_node, stage, @resolve, "reader"},
      {:bind, stage, "reader", "worktree_name", source, replace_literal: false}
    ]
  end

  defp choice(decision, name, target, inputs \\ %{}) do
    {:put_choice, decision,
     %{"name" => name, "description" => name, "target" => target, "inputs" => inputs}}
  end

  defp build(document) do
    inputs =
      Map.new(document["inputs"], fn {name, input} -> {name, %{type: type(input["type"])}} end)

    vertices =
      Map.new(document["vertices"], fn {name, vertex} -> {name, vertex(name, vertex)} end)

    Workflow.new(%{
      name: document["name"],
      start: document["start"],
      inputs: inputs,
      vertices: vertices
    })
  end

  defp vertex(name, %{"kind" => "stage", "next" => next, "nodes" => nodes}) do
    graph = Graph.new(Enum.map(nodes, fn {node_name, node} -> core_node(node_name, node) end))
    args = %{name: name, graph: graph}

    Stage.new(if(next, do: Map.put(args, :next, next), else: args))
  end

  defp vertex(name, %{"kind" => "decision", "choices" => choices}) do
    Decision.new(%{name: name, prompt: "Ask?", choices: Enum.map(choices, &core_choice/1)})
  end

  defp core_node(name, node) do
    {:ok, runner} = Catalog.runner(node["runner"])

    bind =
      Map.new(node["inputs"], fn {field, %{"bind" => source}} ->
        {:ok, entry} = Catalog.field(node["runner"], field)
        {entry.name, {source, entry.type}}
      end)

    Node.new(%{name: name, runner: runner.module, type: runner.output_module, bind: bind})
  end

  defp core_choice(%{"target" => target} = choice) do
    Choice.new(%{
      name: choice["name"],
      description: choice["description"],
      target: core_target(target),
      inputs: Map.new(choice["inputs"], fn {key, id} -> {key, type(id)} end)
    })
  end

  defp core_target(["halt"]), do: :halt
  defp core_target(["run", vertex]), do: {:run, vertex}
  defp core_target(["rerun", vertex]), do: {:rerun, vertex}

  defp type(id) do
    {:ok, entry} = Catalog.type(id)
    entry.module
  end

  defp assert_agree(document, stage, source, :not_visible) do
    assert Compatibility.visibility(document, stage, source) == :not_visible

    assert %Error{type: :stage_input_unbound, reason: %{stage_name: ^stage, input_name: ^source}} =
             build(document)
  end

  defp assert_agree(document, stage, source, answer) do
    assert Compatibility.visibility(document, stage, source) == answer
    assert %Workflow{} = build(document)
  end

  describe "a node" do
    test "of a stage before is visible" do
      document([
        {:add_stage, "later"},
        {:set_next, "main", "later"},
        resolve("main"),
        directory("later", "resolve")
      ])
      |> assert_agree("later", "resolve", :visible)
    end

    test "of the stage itself is visible, with or without a path" do
      document([resolve("main"), directory("main", "resolve")])
      |> assert_agree("main", "resolve", :visible)
    end

    test "of a stage after is not visible" do
      document([
        {:add_stage, "later"},
        {:set_next, "main", "later"},
        resolve("later"),
        directory("main", "resolve")
      ])
      |> assert_agree("main", "resolve", :not_visible)
    end

    test "of a stage start can't reach is not visible, even when it leads to the reader" do
      document([
        {:add_stage, "orphan"},
        {:set_next, "orphan", "main"},
        resolve("orphan"),
        directory("main", "resolve")
      ])
      |> assert_agree("main", "resolve", :not_visible)
    end

    test "of a sibling branch is not visible" do
      document([
        {:add_stage, "left"},
        {:add_stage, "right"},
        {:add_decision, "pick"},
        {:set_next, "main", "pick"},
        choice("pick", "go_left", ["run", "left"]),
        choice("pick", "go_right", ["run", "right"]),
        resolve("left"),
        directory("right", "resolve")
      ])
      |> assert_agree("right", "resolve", :not_visible)
    end

    test "after the stage on a rerun cycle is visible, because a rerun reads it" do
      document([
        {:add_stage, "later"},
        {:add_decision, "ask"},
        {:set_next, "main", "later"},
        {:set_next, "later", "ask"},
        choice("ask", "again", ["rerun", "main"]),
        resolve("later"),
        directory("main", "resolve")
      ])
      |> assert_agree("main", "resolve", :visible)
    end
  end

  describe "a choice input" do
    test "of a decision that reruns the stage is visible" do
      document([
        {:add_decision, "ask"},
        {:set_next, "main", "ask"},
        choice("ask", "again", ["rerun", "main"], %{"note" => @string}),
        reader("main", "note")
      ])
      |> assert_agree("main", "note", :visible)
    end

    test "of a decision start can't reach is not visible" do
      document([
        {:add_decision, "ask"},
        choice("ask", "again", ["rerun", "main"], %{"note" => @string}),
        reader("main", "note")
      ])
      |> assert_agree("main", "note", :not_visible)
    end

    test "of a reachable decision that doesn't precede the stage is not visible" do
      document([
        {:add_stage, "other"},
        {:add_decision, "ask"},
        {:set_next, "main", "ask"},
        choice("ask", "elsewhere", ["rerun", "other"], %{"note" => @string}),
        reader("main", "note")
      ])
      |> assert_agree("main", "note", :not_visible)
    end
  end

  test "a workflow input is visible everywhere, with no path needed" do
    document([
      {:add_stage, "later"},
      {:set_next, "main", "later"},
      reader("later", "prompt")
    ])
    |> assert_agree("later", "prompt", :visible)

    document([{:add_stage, "orphan"}, reader("orphan", "prompt")])
    |> assert_agree("orphan", "prompt", :visible)
  end

  test "a dangling source in a reachable stage is not visible" do
    document([
      resolve("main", "gone"),
      directory("main", "gone"),
      {:remove_node, "main", "gone"}
    ])
    |> assert_agree("main", "gone", :not_visible)
  end

  describe "a stage start can't reach" do
    test "is never checked by Core, so a source it can't read is told apart" do
      document([
        {:add_stage, "orphan"},
        {:add_stage, "end"},
        {:set_next, "orphan", "end"},
        resolve("orphan"),
        directory("end", "resolve")
      ])
      |> assert_agree("end", "resolve", :stage_unreachable)
    end

    test "holds a dangling source Core still accepts" do
      document([
        {:add_stage, "orphan"},
        resolve("main", "gone"),
        directory("orphan", "gone"),
        {:remove_node, "main", "gone"}
      ])
      |> assert_agree("orphan", "gone", :stage_unreachable)
    end
  end

  test "rewiring changes the answer as it changes Core's" do
    wired =
      document([
        {:add_stage, "later"},
        {:set_next, "main", "later"},
        resolve("main"),
        directory("later", "resolve")
      ])

    wired
    |> edit_all([{:set_next, "main", nil}])
    |> assert_agree("later", "resolve", :stage_unreachable)

    wired
    |> edit_all([{:add_stage, "first"}, {:set_next, "first", "later"}, {:set_start, "first"}])
    |> assert_agree("later", "resolve", :not_visible)
  end
end

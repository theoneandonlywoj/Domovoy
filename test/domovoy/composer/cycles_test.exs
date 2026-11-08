defmodule Domovoy.Composer.CyclesTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.Cycles
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue

  @detect "DomovoyMisePlugin.Runner.Detect"

  defp stage(names) do
    edit_all(Document.new("w"), Enum.map(names, &{:add_node, "main", @detect, &1}))
  end

  # The write path refuses cycles, so a raw After list stands in for a stored one.
  defp waits(document, node, sources) do
    put_in(document, ["vertices", "main", "nodes", node, "after"], sources)
  end

  test "an acyclic stage has none" do
    assert Cycles.find(scenario_a(), "prepare") == []
    assert Cycles.check(scenario_a(), "prepare") == :ok
  end

  test "names exactly the cycle, not the nodes waiting behind it" do
    document =
      stage(["alpha", "bravo", "downstream"])
      |> waits("alpha", ["bravo"])
      |> waits("bravo", ["alpha"])
      |> waits("downstream", ["alpha"])

    assert Cycles.find(document, "main") == [["alpha", "bravo"]]

    assert {:error, %Issue{code: :cycle, core_id: :graph_has_cycle, message: message}} =
             Cycles.check(document, "main")

    assert message =~ "alpha"
    assert message =~ "bravo"
    refute message =~ "downstream"
    assert message =~ "Decision with a Rerun"
  end

  test "a node waiting on itself is a cycle of one" do
    assert Cycles.find(waits(stage(["alpha", "bravo"]), "alpha", ["alpha"]), "main") == [
             ["alpha"]
           ]
  end

  test "a binding counts as an edge" do
    document =
      stage(["alpha", "bravo"])
      |> waits("alpha", ["bravo"])
      |> put_in(["vertices", "main", "nodes", "bravo", "inputs"], %{"f" => %{"bind" => "alpha"}})

    assert Cycles.find(document, "main") == [["alpha", "bravo"]]
  end

  test "lists separate cycles separately" do
    document =
      stage(["a", "b", "c", "d"])
      |> waits("a", ["b"])
      |> waits("b", ["a"])
      |> waits("c", ["d"])
      |> waits("d", ["c"])

    assert Cycles.find(document, "main") == [["a", "b"], ["c", "d"]]
  end

  test "ignores names outside the stage, such as a dangling reference" do
    assert Cycles.find(waits(stage(["alpha"]), "alpha", ["gone"]), "main") == []
  end

  test "is empty for a decision or an unknown stage" do
    assert Cycles.find(scenario_a(), "review") == []
    assert Cycles.find(scenario_a(), "gone") == []
  end

  test "leaves no digraph table behind" do
    Cycles.find(scenario_a(), "prepare")

    assert Enum.filter(:ets.all(), &(:ets.info(&1, :owner) == self())) == []
  end

  describe "closes?/4" do
    test "agrees with check/2 for every pair of nodes in scenario A" do
      document = Domovoy.ComposerFixtures.scenario_a()
      names = Map.keys(Domovoy.Composer.Document.nodes(document, "prepare"))

      for node <- names, source <- names do
        waiting =
          update_in(
            document,
            ["vertices", "prepare", "nodes", node, "after"],
            &[source | &1]
          )

        assert Cycles.closes?(document, "prepare", node, source) ==
                 (Cycles.check(waiting, "prepare") != :ok),
               "#{node} on #{source}"
      end
    end

    test "a source that isn't a node of the stage closes nothing" do
      document = Domovoy.ComposerFixtures.scenario_a()
      refute Cycles.closes?(document, "prepare", "ask_claude", "prompt")
      refute Cycles.closes?(document, "prepare", "ask_claude", "gone")
    end
  end
end

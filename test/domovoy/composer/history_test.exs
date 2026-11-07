defmodule Domovoy.Composer.HistoryTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2]

  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.History
  alias Domovoy.Composer.Operations

  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"

  test "starts empty, and undoing nothing says so" do
    assert History.empty?(History.reset())
    assert History.undo(History.reset()) == :empty
  end

  test "undoes newest first, with the kind of each edit" do
    history =
      History.reset()
      |> History.push(%{"n" => 1}, :definition)
      |> History.push(%{"n" => 2}, :layout)

    assert {%{"n" => 2}, :layout, history} = History.undo(history)
    assert {%{"n" => 1}, :definition, history} = History.undo(history)
    assert History.empty?(history)
  end

  test "keeps only the newest 100" do
    history = Enum.reduce(1..150, History.reset(), &History.push(&2, %{"n" => &1}, :definition))

    remaining =
      Stream.unfold(history, fn history ->
        case History.undo(history) do
          {document, _kind, rest} -> {document["n"], rest}
          :empty -> nil
        end
      end)
      |> Enum.to_list()

    assert remaining == Enum.to_list(150..51//-1)
  end

  test "binding over a literal and undoing restores the literal as one entry" do
    before =
      edit_all(Document.new("w"), [
        {:put_input, "prompt", %{"type" => "DomovoyCore.Type.String"}},
        {:add_node, "main", @ask, "ask"},
        {:set_literal, "main", "ask", "context", "Review this diff", replace_binding: false}
      ])

    {:ok, updated, kind} =
      Operations.edit(before, {:bind, "main", "ask", "context", "prompt", replace_literal: true})

    assert context(updated) == %{"bind" => "prompt"}

    assert {restored, :definition, rest} =
             History.undo(History.push(History.reset(), before, kind))

    assert context(restored) == %{"literal" => "Review this diff"}
    assert restored == before
    assert History.empty?(rest)
  end

  test "deleting a producer and undoing returns the node and every reference" do
    before =
      edit_all(Document.new("w"), [
        {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeResolve", "resolve"},
        {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeDirectory", "directory"},
        {:bind, "main", "directory", "worktree", "resolve", replace_literal: false},
        {:add_after, "main", "directory", "resolve"}
      ])

    {:ok, updated, kind} = Operations.edit(before, {:remove_node, "main", "resolve"})

    refute is_map_key(Document.nodes(updated, "main"), "resolve")
    refute is_map_key(updated["layout"]["stages"]["main"], "resolve")
    assert Compatibility.source_type(updated, "main", "resolve") == :error

    assert %{"inputs" => inputs, "after" => ["resolve"]} =
             Document.nodes(updated, "main")["directory"]

    assert inputs["worktree"] == %{"bind" => "resolve"}

    assert {restored, :definition, rest} =
             History.undo(History.push(History.reset(), before, kind))

    assert restored == before
    assert {:same_graph, _type} = Compatibility.source_type(restored, "main", "resolve")
    assert History.empty?(rest)
  end

  defp context(document) do
    get_in(document, ["vertices", "main", "nodes", "ask", "inputs", "context"])
  end
end

defmodule Domovoy.Composer.DocumentTest do
  use Domovoy.DataCase, async: true

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.ComposerFixtures

  @string "DomovoyCore.Type.String"

  test "new/1 has one empty stage as its start, placed in the layout" do
    document = Document.new("w")

    assert %{"version" => 1, "name" => "w", "start" => "main", "inputs" => %{}} = document
    assert %{"kind" => "stage", "next" => nil, "nodes" => %{}} = document["vertices"]["main"]
    assert document["layout"]["workflow"]["main"]
    assert document["layout"]["stages"]["main"] == %{}
  end

  test "survives a JSON round trip unchanged, so Postgres can't alter it" do
    document = ComposerFixtures.scenario_a()

    assert document |> Jason.encode!() |> Jason.decode!() == document
  end

  describe "scenario A" do
    setup do
      %{document: ComposerFixtures.scenario_a()}
    end

    test "matches the canonical definition exactly", %{document: document} do
      assert document["version"] == 1
      assert document["name"] == "scenario_a"
      assert document["start"] == "prepare"

      assert document["inputs"] == %{
               "worktree_name" => %{"type" => @string, "required" => true},
               "prompt" => %{"type" => @string, "required" => true}
             }

      assert document["vertices"] == %{
               "prepare" => %{
                 "kind" => "stage",
                 "next" => "review",
                 "nodes" => %{
                   "resolve_worktree" =>
                     node_of("DomovoyGitPlugin.Runner.WorktreeResolve", %{
                       "worktree_name" => %{"bind" => "worktree_name"}
                     }),
                   "worktree_directory" =>
                     node_of("DomovoyGitPlugin.Runner.WorktreeDirectory", %{
                       "worktree" => %{"bind" => "resolve_worktree"}
                     }),
                   "detect_mise" => node_of("DomovoyMisePlugin.Runner.Detect", %{}),
                   "trust_mise" =>
                     node_of("DomovoyMisePlugin.Runner.Trust", %{
                       "worktree" => %{"bind" => "resolve_worktree"},
                       "mise" => %{"bind" => "detect_mise"}
                     }),
                   "ask_claude" =>
                     node_of(
                       "DomovoyClaudeCodePlugin.Runner.AskClaude",
                       %{
                         "context" => %{"bind" => "prompt"},
                         "working_directory" => %{"bind" => "worktree_directory"},
                         "options" => %{"literal" => "{}"}
                       },
                       ["trust_mise"]
                     )
                 }
               },
               "review" => %{
                 "kind" => "decision",
                 "prompt" => "Approve the answer?",
                 "decider" => "DomovoyCore.Decider.Person",
                 "choices" => [
                   %{
                     "name" => "approve",
                     "description" => "Accept",
                     "target" => ["halt"],
                     "inputs" => %{}
                   },
                   %{
                     "name" => "revise",
                     "description" => "Ask again",
                     "target" => ["rerun", "prepare"],
                     "inputs" => %{"prompt" => @string}
                   }
                 ]
               }
             }
    end
  end

  test "nodes/2 is empty for a decision or an unknown vertex" do
    document = ComposerFixtures.scenario_a()

    assert Document.nodes(document, "review") == %{}
    assert Document.nodes(document, "gone") == %{}
  end

  test "an absent default and an explicit nil default stay distinct through Postgres" do
    {:ok, draft} = Composer.create_draft(%{title: "Defaults"})

    document =
      ComposerFixtures.edit_all(draft.document, [
        {:put_input, "absent", %{"type" => @string}},
        {:put_input, "null", %{"type" => "DomovoyCore.Type.Any", "default" => nil}}
      ])

    assert {:ok, _saved} = Composer.save_document(draft, document)
    assert {:ok, %{document: reloaded}} = Composer.get_draft(draft.id)

    refute Map.has_key?(reloaded["inputs"]["absent"], "default")
    assert Map.fetch!(reloaded["inputs"]["null"], "default") == nil
  end

  defp node_of(runner, inputs, waits \\ []) do
    %{
      "runner" => runner,
      "inputs" => inputs,
      "after" => waits,
      "validators" => [],
      "retry" => %{},
      "store" => true
    }
  end
end

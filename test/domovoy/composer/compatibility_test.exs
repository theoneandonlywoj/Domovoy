defmodule Domovoy.Composer.CompatibilityTest do
  use ExUnit.Case, async: true

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue

  @any "DomovoyCore.Type.Any"
  @string "DomovoyCore.Type.String"
  @directory "DomovoyCore.Type.Directory"
  @worktree "DomovoyGitPlugin.Type.Worktree"

  defp two_stages do
    edit_all(Document.new("w"), [
      {:add_stage, "later"},
      {:set_next, "main", "later"},
      {:put_input, "prompt", %{"type" => @string}},
      {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeResolve", "resolve"},
      {:add_node, "later", "DomovoyMisePlugin.Runner.Trust", "trust"},
      {:add_node, "later", "DomovoyGitPlugin.Runner.WorktreeDirectory", "directory"}
    ])
  end

  describe "stage_sources/2" do
    defp reading do
      edit_all(two_stages(), [
        {:bind, "later", "directory", "worktree", "resolve", replace_literal: false}
      ])
    end

    defp bound(document, stage, node, field, source) do
      put_in(document, ["vertices", stage, "nodes", node, "inputs", field], %{"bind" => source})
    end

    test "gives every input and each read visible source, and no unread one" do
      assert Compatibility.stage_sources(two_stages(), "later") == ["prompt"]
      assert Compatibility.stage_sources(reading(), "later") == ["prompt", "resolve"]
      assert Compatibility.stage_sources(reading(), "main") == ["prompt"]
    end

    test "gives a read choice input" do
      document =
        edit_all(scenario_a(), [
          {:add_stage, "after_review"},
          {:put_choice, "review",
           %{
             "name" => "go",
             "description" => "Go on",
             "target" => ["run", "after_review"],
             "inputs" => %{"note" => @string}
           }},
          {:add_node, "after_review", "DomovoyGitPlugin.Runner.WorktreeResolve", "again"}
        ])

      assert "note" not in Compatibility.stage_sources(document, "after_review")

      read =
        edit_all(document, [
          {:bind, "after_review", "again", "worktree_name", "note", replace_literal: false}
        ])

      assert "note" in Compatibility.stage_sources(read, "after_review")
    end

    test "leaves out a read that doesn't precede the stage" do
      document = bound(two_stages(), "main", "resolve", "worktree_name", "directory")

      assert Compatibility.stage_sources(document, "main") == ["prompt"]
    end

    test "leaves out the stage's own nodes, even one sharing an input's name" do
      own = bound(two_stages(), "later", "trust", "worktree", "directory")
      assert Compatibility.stage_sources(own, "later") == ["prompt"]

      hand_built = put_in(two_stages(), ["inputs", "resolve"], %{"type" => @string})
      assert Compatibility.stage_sources(hand_built, "main") == ["prompt"]
    end

    test "leaves out a read node whose runner left the catalog" do
      document =
        put_in(reading(), ["vertices", "main", "nodes", "resolve", "runner"], "Gone.Runner")

      assert Compatibility.stage_sources(document, "later") == ["prompt"]
    end

    test "a nil stage has none" do
      assert Compatibility.stage_sources(reading(), nil) == []
    end
  end

  describe "within one graph" do
    test "an exact type passes" do
      assert Compatibility.check(two_stages(), "main", @worktree, "resolve") == {:ok, :exact}
    end

    test "an Any field accepts a concrete source" do
      assert Compatibility.check(scenario_a(), "prepare", @any, "resolve_worktree") ==
               {:ok, :accepted_by_any}
    end

    test "a mismatch names both types, mirrors Core and offers the real adapter" do
      assert {:error, %Issue{} = issue} =
               Compatibility.check(scenario_a(), "prepare", @directory, "resolve_worktree")

      assert issue.code == :type_mismatch
      assert issue.core_id == :binding_type_mismatch
      assert issue.message =~ "Git Worktree"
      assert issue.message =~ "Directory"
      assert [%{id: "DomovoyGitPlugin.Runner.WorktreeDirectory"}] = issue.adapters
    end

    test "a mismatch with no adapter explains the gap and offers nothing" do
      assert {:error, %Issue{adapters: [], message: message}} =
               Compatibility.check(scenario_a(), "prepare", @string, "ask_claude")

      assert message =~ "No installed runner converts"
    end
  end

  describe "across stages" do
    test "an exact type passes from a node and from a workflow input" do
      assert Compatibility.check(two_stages(), "later", @worktree, "resolve") == {:ok, :exact}
      assert Compatibility.check(two_stages(), "later", @string, "prompt") == {:ok, :exact}
    end

    test "a concrete mismatch mirrors Core's stage error" do
      assert {:error, %Issue{code: :type_mismatch, core_id: :stage_input_type_mismatch}} =
               Compatibility.check(two_stages(), "later", @string, "resolve")
    end

    test "an Any field is refused, explaining that Any matches only Any" do
      assert {:error, %Issue{code: :type_mismatch, adapters: [], message: message} = issue} =
               Compatibility.check(two_stages(), "later", @any, "resolve")

      assert issue.core_id == :stage_input_type_mismatch
      assert message =~ "Across stages Any matches only Any"
      assert message =~ "Git Worktree"
    end

    test "an Any field is refused from a workflow input too" do
      assert {:error, %Issue{code: :type_mismatch}} =
               Compatibility.check(two_stages(), "later", @any, "prompt")
    end

    test "an Any field passes when a sibling reads the source with its concrete type" do
      document =
        edit_all(two_stages(), [
          {:bind, "later", "directory", "worktree", "resolve", replace_literal: false}
        ])

      assert Compatibility.check(document, "later", @any, "resolve") == {:ok, :accepted_by_any}
    end

    test "a choice input has a type wherever it sits, and visibility decides if Core counts it" do
      document =
        edit_all(two_stages(), [
          {:add_decision, "ask"},
          {:put_choice, "ask",
           %{
             "name" => "again",
             "description" => "Again",
             "target" => ["rerun", "main"],
             "inputs" => %{"note" => @string}
           }}
        ])

      assert Compatibility.check(document, "later", @string, "note") == {:ok, :exact}
      assert Compatibility.visibility(document, "later", "note") == :not_visible

      wired = edit_all(document, [{:set_next, "later", "ask"}])

      assert Compatibility.check(wired, "later", @string, "note") == {:ok, :exact}
      assert Compatibility.visibility(wired, "later", "note") == :visible
    end

    test "check/4 accepts by type alone, so an accepted source can still be hidden" do
      document =
        edit_all(two_stages(), [
          {:add_node, "later", "DomovoyGitPlugin.Runner.WorktreeResolve", "late_resolve"},
          {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeDirectory", "early"},
          {:bind, "main", "early", "worktree", "late_resolve", replace_literal: false}
        ])

      assert Compatibility.check(document, "main", @any, "late_resolve") ==
               {:ok, :accepted_by_any}

      assert Compatibility.visibility(document, "main", "late_resolve") == :not_visible
    end
  end

  test "an unknown source is refused without echoing it" do
    assert {:error, %Issue{code: :unknown_source, message: message}} =
             Compatibility.check(two_stages(), "main", @string, "sentinel_name")

    refute message =~ "sentinel_name"
  end

  test "source_type/3 tells a stage's own nodes from outside sources" do
    document = two_stages()

    assert Compatibility.source_type(document, "main", "resolve") == {:same_graph, @worktree}
    assert Compatibility.source_type(document, "later", "resolve") == {:external, @worktree}
    assert Compatibility.source_type(document, "later", "prompt") == {:external, @string}
    assert Compatibility.source_type(document, "later", "gone") == :error
  end
end

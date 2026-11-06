defmodule Domovoy.Composer.OperationsTest do
  # Not async: the hostile tests purge a shared module.
  use ExUnit.Case, async: false

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.Operations
  alias Domovoy.ComposerFixtures.UnloadedProbe

  @string "DomovoyCore.Type.String"
  @any "DomovoyCore.Type.Any"
  @resolve "DomovoyGitPlugin.Runner.WorktreeResolve"
  @directory "DomovoyGitPlugin.Runner.WorktreeDirectory"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @trust "DomovoyMisePlugin.Runner.Trust"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"
  @list_sessions "DomovoyClaudeCodePlugin.Runner.ListSessions"
  @sentinel "sentinel-secret-value"

  defp node_at(document, stage, name), do: Document.nodes(document, stage)[name]
  defp input(document, stage, name, field), do: node_at(document, stage, name)["inputs"][field]

  defp bind(stage, node, field, source, replace \\ false) do
    {:bind, stage, node, field, source, replace_literal: replace}
  end

  defp literal(stage, node, field, raw, replace \\ false) do
    {:set_literal, stage, node, field, raw, replace_binding: replace}
  end

  defp refused(document, op, code) do
    assert {:error, %Issue{code: ^code} = issue} = Operations.edit(document, op)
    issue
  end

  # Stage `main` holds a producer; stage `later` holds its cross-stage consumers.
  defp two_stages do
    edit_all(Document.new("w"), [
      {:add_stage, "later"},
      {:set_next, "main", "later"},
      {:add_node, "main", @resolve, "resolve"},
      {:add_node, "later", @trust, "trust"},
      {:add_node, "later", @directory, "directory"}
    ])
  end

  defp nodes(names) do
    edit_all(Document.new("w"), Enum.map(names, &{:add_node, "main", @ask, &1}))
  end

  describe "the plan's minimal caller" do
    test "binds Any to a same-stage producer, and refuses a mismatch with an adapter" do
      document = scenario_a()

      assert {:ok, _document, :none} =
               Operations.edit(
                 document,
                 bind("prepare", "trust_mise", "worktree", "resolve_worktree")
               )

      cleared = edit_all(document, [{:clear_input, "prepare", "trust_mise", "worktree"}])

      assert {:ok, ^document, :definition} =
               Operations.edit(
                 cleared,
                 bind("prepare", "trust_mise", "worktree", "resolve_worktree")
               )

      assert {:error, %Issue{code: :type_mismatch, adapters: [_ | _]}} =
               Operations.edit(
                 document,
                 bind("prepare", "ask_claude", "working_directory", "resolve_worktree")
               )
    end
  end

  describe "scenario A rows" do
    test "a mismatch names the types and targets the field" do
      issue =
        refused(
          scenario_a(),
          bind("prepare", "ask_claude", "working_directory", "resolve_worktree"),
          :type_mismatch
        )

      assert issue.message =~ "Git Worktree"
      assert issue.message =~ "Directory"
      assert issue.target == {:field, "prepare", "ask_claude", "working_directory"}
    end

    test "Any across stages is refused until a sibling binds concretely" do
      document = two_stages()

      issue = refused(document, bind("later", "trust", "worktree", "resolve"), :type_mismatch)
      assert issue.message =~ "Across stages Any matches only Any"

      sibling = edit_all(document, [bind("later", "directory", "worktree", "resolve")])

      assert {:ok, _document, :definition} =
               Operations.edit(sibling, bind("later", "trust", "worktree", "resolve"))
    end
  end

  describe "add_node" do
    test "adds an empty node on the next free grid slot" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @detect, "first"},
          {:add_node, "main", @detect, "second"}
        ])

      assert node_at(document, "main", "first") == Document.new_node(@detect)

      first = document["layout"]["stages"]["main"]["first"]
      second = document["layout"]["stages"]["main"]["second"]
      assert first != second

      freed =
        edit_all(document, [
          {:remove_node, "main", "first"},
          {:add_node, "main", @detect, "third"}
        ])

      assert freed["layout"]["stages"]["main"]["third"] == first
    end

    test "refuses a decision as the stage" do
      refused(scenario_a(), {:add_node, "review", @detect, "x"}, :unknown_stage)
    end
  end

  describe "rename_node" do
    setup do
      document =
        edit_all(two_stages(), [
          bind("later", "directory", "worktree", "resolve"),
          {:add_node, "main", @detect, "detect"},
          {:add_after, "main", "detect", "resolve"}
        ])

      %{document: document}
    end

    test "updates references in every stage and the layout", %{document: document} do
      place = document["layout"]["stages"]["main"]["resolve"]

      renamed = edit_all(document, [{:rename_node, "main", "resolve", "found"}])

      assert node_at(renamed, "main", "resolve") == nil
      assert node_at(renamed, "main", "found")["runner"] == @resolve
      assert input(renamed, "later", "directory", "worktree") == %{"bind" => "found"}
      assert node_at(renamed, "main", "detect")["after"] == ["found"]
      assert renamed["layout"]["stages"]["main"]["found"] == place
      refute Map.has_key?(renamed["layout"]["stages"]["main"], "resolve")
    end

    test "refuses collisions with nodes, inputs, choice inputs and decisions" do
      document = scenario_a()

      for taken <- ["detect_mise", "prompt", "review"] do
        refused(document, {:rename_node, "prepare", "ask_claude", taken}, :name_collision)
      end

      with_choice_input =
        edit_all(document, [
          {:put_choice, "review",
           %{
             "name" => "note",
             "description" => "Note",
             "target" => ["rerun", "prepare"],
             "inputs" => %{"note_text" => @string}
           }}
        ])

      refused(
        with_choice_input,
        {:rename_node, "prepare", "ask_claude", "note_text"},
        :name_collision
      )
    end

    test "to its own name changes nothing", %{document: document} do
      assert {:ok, ^document, :none} =
               Operations.edit(document, {:rename_node, "main", "resolve", "resolve"})
    end

    test "refuses an invalid name", %{document: document} do
      refused(document, {:rename_node, "main", "resolve", "a/b"}, :invalid_name)
    end

    test "onto a name its own binding dangles on is a self-cycle" do
      document =
        edit_all(nodes(["ask"]), [
          {:add_node, "main", @directory, "directory"},
          bind("main", "ask", "working_directory", "directory"),
          {:remove_node, "main", "directory"}
        ])

      refused(document, {:rename_node, "main", "ask", "directory"}, :cycle)
    end
  end

  describe "remove_node" do
    test "leaves references visible, and creates no workflow input" do
      updated =
        edit_all(scenario_a(), [{:remove_node, "prepare", "worktree_directory"}])

      assert node_at(updated, "prepare", "worktree_directory") == nil

      assert input(updated, "prepare", "ask_claude", "working_directory") == %{
               "bind" => "worktree_directory"
             }

      refute Map.has_key?(updated["inputs"], "worktree_directory")
      refute Map.has_key?(updated["layout"]["stages"]["prepare"], "worktree_directory")
    end
  end

  describe "bind and set_literal" do
    setup do
      document =
        edit_all(nodes(["ask"]), [
          {:put_input, "prompt", %{"type" => @string}},
          literal("main", "ask", "context", "Review this diff")
        ])

      %{document: document}
    end

    test "refuses to bind over a literal without the flag, leaving it unchanged", %{
      document: document
    } do
      issue = refused(document, bind("main", "ask", "context", "prompt"), :literal_present)
      assert issue.target == {:field, "main", "ask", "context"}
      refute issue.message =~ "Review this diff"
    end

    test "with the flag, replaces the literal", %{document: document} do
      updated = edit_all(document, [bind("main", "ask", "context", "prompt", true)])

      assert input(updated, "main", "ask", "context") == %{"bind" => "prompt"}
    end

    test "reports a mismatch before asking to replace", %{document: document} do
      with_producer = edit_all(document, [{:add_node, "main", @resolve, "resolve"}])

      refused(with_producer, bind("main", "ask", "context", "resolve"), :type_mismatch)
    end

    test "refuses a literal over a binding without the flag", %{document: document} do
      bound = edit_all(document, [bind("main", "ask", "context", "prompt", true)])

      refused(bound, literal("main", "ask", "context", "text"), :binding_present)

      replaced = edit_all(bound, [literal("main", "ask", "context", "text", true)])
      assert input(replaced, "main", "ask", "context") == %{"literal" => "text"}
    end

    test "stores any text as a literal, leaving parsing to the analyzer" do
      updated =
        edit_all(Document.new("w"), [
          {:add_node, "main", @list_sessions, "sessions"},
          literal("main", "sessions", "limit", "not an int")
        ])

      assert input(updated, "main", "sessions", "limit") == %{"literal" => "not an int"}
    end

    test "refuses a literal on a bind-only field" do
      document = edit_all(Document.new("w"), [{:add_node, "main", @directory, "directory"}])

      issue = refused(document, literal("main", "directory", "worktree", "x"), :bind_only)
      assert issue.message =~ "Git Worktree"
    end

    test "refuses an unknown source", %{document: document} do
      refused(document, bind("main", "ask", "context", "gone"), :unknown_source)
    end
  end

  describe "cycles" do
    setup do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @detect, "alpha"},
          {:add_node, "main", @detect, "bravo"},
          {:add_node, "main", @detect, "downstream"},
          {:add_after, "main", "bravo", "alpha"},
          {:add_after, "main", "downstream", "alpha"}
        ])

      %{document: document}
    end

    test "After adds ordering only, and a reverse After is a cycle", %{document: document} do
      assert node_at(document, "main", "bravo")["inputs"] == %{}
      assert node_at(document, "main", "bravo")["after"] == ["alpha"]

      issue = refused(document, {:add_after, "main", "alpha", "bravo"}, :cycle)

      assert issue.message =~ "alpha"
      assert issue.message =~ "bravo"
      refute issue.message =~ "downstream"
      assert issue.message =~ "Rerun"
    end

    test "After on itself is a cycle", %{document: document} do
      refused(document, {:add_after, "main", "alpha", "alpha"}, :cycle)
    end

    test "After needs a node of the same stage", %{document: document} do
      refused(document, {:add_after, "main", "alpha", "gone"}, :unknown_node)
    end

    test "a binding back along an After is a cycle" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @directory, "directory"},
          {:add_after, "main", "resolve", "directory"}
        ])

      refused(document, bind("main", "directory", "worktree", "resolve"), :cycle)
    end

    test "a self-binding is a cycle, even where the type fits" do
      document = edit_all(Document.new("w"), [{:add_node, "main", @trust, "trust"}])

      refused(document, bind("main", "trust", "worktree", "trust"), :cycle)
    end

    test "removing an After reverses cleanly, and repeats as :none", %{document: document} do
      updated = edit_all(document, [{:remove_after, "main", "bravo", "alpha"}])

      assert node_at(updated, "main", "bravo")["after"] == []

      assert {:ok, ^updated, :none} =
               Operations.edit(updated, {:remove_after, "main", "bravo", "alpha"})
    end
  end

  describe "several relationships between two nodes" do
    test "deleting one binding leaves the other and the After" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @detect, "detect"},
          {:add_node, "main", @trust, "trust"},
          bind("main", "trust", "worktree", "resolve"),
          bind("main", "trust", "mise", "detect"),
          {:add_after, "main", "trust", "detect"}
        ])

      updated = edit_all(document, [{:clear_input, "main", "trust", "mise"}])

      assert input(updated, "main", "trust", "mise") == nil
      assert input(updated, "main", "trust", "worktree") == %{"bind" => "resolve"}
      assert node_at(updated, "main", "trust")["after"] == ["detect"]
    end

    test "clearing an empty field repeats as :none, and an unknown field is refused" do
      document = nodes(["ask"])

      assert {:ok, ^document, :none} =
               Operations.edit(document, {:clear_input, "main", "ask", "context"})

      refused(document, {:clear_input, "main", "ask", "gone"}, :unknown_field)
    end
  end

  describe "replace_runner" do
    test "keeps same-name compatible inputs and validators, drops the rest, as one edit" do
      document =
        edit_all(Document.new("w"), [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_node, "main", @ask, "ask"},
          bind("main", "ask", "context", "prompt"),
          literal("main", "ask", "options", "{}"),
          {:set_validators, "main", "ask",
           [
             "DomovoyClaudeCodePlugin.Validator.SessionDirectoryIsValid",
             "DomovoyGitPlugin.Validator.RemotePresent"
           ]}
        ])

      session = "DomovoyClaudeCodePlugin.Runner.CreateOrContinueClaudeSession"

      assert %{document: updated, dropped: dropped} =
               Operations.preview(document, {:replace_runner, "main", "ask", session})

      assert node_at(updated, "main", "ask")["runner"] == session
      assert input(updated, "main", "ask", "context") == %{"bind" => "prompt"}
      assert input(updated, "main", "ask", "options") == %{"literal" => "{}"}

      assert node_at(updated, "main", "ask")["validators"] == [
               "DomovoyClaudeCodePlugin.Validator.SessionDirectoryIsValid"
             ]

      assert dropped == [{:validator, "DomovoyGitPlugin.Validator.RemotePresent"}]
    end

    test "drops a field the new runner lacks or can't take, and warns about consumers" do
      document = scenario_a()
      op = {:replace_runner, "prepare", "resolve_worktree", @detect}

      assert %{document: updated, dropped: dropped, warnings: warnings} =
               Operations.preview(document, op)

      assert input(updated, "prepare", "resolve_worktree", "worktree_name") == nil
      assert dropped == [{:field, "worktree_name"}]

      targets = Enum.map(warnings, & &1.target)
      assert {:field, "prepare", "worktree_directory", "worktree"} in targets
      refute {:field, "prepare", "trust_mise", "worktree"} in targets
    end

    test "keeps a literal only where the new field has the same type" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @list_sessions, "sessions"},
          literal("main", "sessions", "config_dir", "text"),
          {:add_node, "main", @trust, "trust"},
          literal("main", "trust", "worktree", "{}")
        ])

      summary = "DomovoyClaudeCodePlugin.Runner.SessionSummary"
      updated = edit_all(document, [{:replace_runner, "main", "sessions", summary}])
      assert input(updated, "main", "sessions", "config_dir") == %{"literal" => "text"}

      # Trust.worktree is Any, while WorktreeDirectory.worktree is bind-only.
      updated = edit_all(document, [{:replace_runner, "main", "trust", @directory}])
      assert node_at(updated, "main", "trust")["inputs"] == %{}
    end

    test "keeps a dangling binding, so the reference stays visible" do
      document =
        edit_all(nodes(["ask"]), [
          {:add_node, "main", @directory, "directory"},
          bind("main", "ask", "working_directory", "directory"),
          {:remove_node, "main", "directory"},
          {:replace_runner, "main", "ask", "DomovoyClaudeCodePlugin.Runner.DescribeClaudeCode"}
        ])

      assert input(document, "main", "ask", "working_directory") == %{"bind" => "directory"}
    end

    test "refuses an unknown runner" do
      refused(nodes(["ask"]), {:replace_runner, "main", "ask", "Elixir.System"}, :unknown_runner)
    end
  end

  describe "insert_adapter" do
    setup do
      document =
        edit_all(nodes(["ask"]), [
          {:add_node, "main", @resolve, "resolve"},
          {:add_node, "main", @directory, "worktree_directory"}
        ])

      %{document: document}
    end

    test "wires source to adapter to field in one edit, with a unique name", %{document: document} do
      op = {:insert_adapter, "main", "resolve", "ask", "working_directory", @directory}

      assert {:ok, updated, :definition} = Operations.edit(document, op)

      assert input(updated, "main", "ask", "working_directory") == %{
               "bind" => "worktree_directory_2"
             }

      assert node_at(updated, "main", "worktree_directory_2")["runner"] == @directory
      assert input(updated, "main", "worktree_directory_2", "worktree") == %{"bind" => "resolve"}
      assert updated["layout"]["stages"]["main"]["worktree_directory_2"]
    end

    test "refuses a runner that isn't an adapter for these types", %{document: document} do
      refused(
        document,
        {:insert_adapter, "main", "resolve", "ask", "working_directory", @detect},
        :invalid_adapter
      )
    end

    test "refuses an unknown source, runner or a field holding a literal", %{document: document} do
      refused(
        document,
        {:insert_adapter, "main", "gone", "ask", "working_directory", @directory},
        :unknown_source
      )

      refused(
        document,
        {:insert_adapter, "main", "resolve", "ask", "working_directory", "Elixir.System"},
        :unknown_runner
      )

      with_literal = edit_all(document, [literal("main", "ask", "working_directory", ".")])

      refused(
        with_literal,
        {:insert_adapter, "main", "resolve", "ask", "working_directory", @directory},
        :adapter_over_literal
      )
    end
  end

  describe "set_validators" do
    test "accepts curated ids in order, refusing others and duplicates" do
      document = nodes(["ask"])
      first = "DomovoyClaudeCodePlugin.Validator.AskOptionsAreValid"
      second = "DomovoyClaudeCodePlugin.Validator.SessionDirectoryIsValid"

      updated = edit_all(document, [{:set_validators, "main", "ask", [second, first]}])
      assert node_at(updated, "main", "ask")["validators"] == [second, first]

      refused(
        document,
        {:set_validators, "main", "ask",
         ["DomovoyClaudeCodePlugin.Reflect.Validator.WindowIsValid"]},
        :unknown_validator
      )

      refused(document, {:set_validators, "main", "ask", ["Elixir.System"]}, :unknown_validator)
      refused(document, {:set_validators, "main", "ask", [first, first]}, :invalid_params)
    end
  end

  describe "set_execution" do
    test "sets the retry override and store, with nil clearing the override" do
      document = nodes(["ask"])

      updated = edit_all(document, [{:set_execution, "main", "ask", 3, false}])

      assert %{"retry" => %{"max_attempts" => 3}, "store" => false} =
               node_at(updated, "main", "ask")

      cleared = edit_all(updated, [{:set_execution, "main", "ask", nil, true}])
      assert %{"retry" => retry, "store" => true} = node_at(cleared, "main", "ask")
      assert retry == %{}
    end
  end

  describe "set_description" do
    test "writes to a node, stage, decision and input as a definition edit" do
      document = scenario_a()
      metadata = %{"description" => "Text."}

      for {target, path} <- [
            {{:node, "prepare", "ask_claude"}, ["vertices", "prepare", "nodes", "ask_claude"]},
            {{:vertex, "prepare"}, ["vertices", "prepare"]},
            {{:vertex, "review"}, ["vertices", "review"]},
            {{:input, "prompt"}, ["inputs", "prompt"]}
          ] do
        assert {:ok, updated, :definition} =
                 Operations.edit(document, {:set_description, target, "Text."})

        assert get_in(updated, path ++ ["metadata"]) == metadata
        assert Document.description(get_in(updated, path)) == {:ok, "Text."}
      end
    end

    test "an unknown item is refused" do
      document = scenario_a()

      refused(document, {:set_description, {:node, "prepare", "nope"}, "Text."}, :unknown_node)
      refused(document, {:set_description, {:vertex, "nope"}, "Text."}, :unknown_vertex)
      refused(document, {:set_description, {:input, "nope"}, "Text."}, :unknown_input)
    end

    test "a wrong target and a blank text are refused, without echoing the text" do
      document = scenario_a()

      for op <- [
            {:set_description, {:vertex, 1}, @sentinel},
            {:set_description, {:node, 1, 2}, @sentinel},
            {:set_description, {:input, 1}, @sentinel},
            {:set_description, {:other, "x"}, @sentinel},
            {:set_description, {:vertex, "prepare"}, 1},
            {:set_description, {:vertex, "prepare"}, ""},
            {:set_description, {:vertex, "prepare"}, "   "}
          ] do
        issue = refused(document, op, :invalid_params)
        refute issue.message =~ @sentinel
      end
    end

    test "put_input keeps the description when the type changes" do
      document = described_input()

      assert {:ok, updated, :definition} =
               Operations.edit(document, {:put_input, "floor", %{"type" => @any}})

      assert updated["inputs"]["floor"] == %{
               "type" => @any,
               "required" => false,
               "metadata" => %{"description" => "Text."}
             }
    end

    test "put_input saving the same input is no edit" do
      document = described_input()

      assert {:ok, ^document, :none} =
               Operations.edit(document, {:put_input, "floor", %{"type" => @string}})
    end

    test "put_input refuses a metadata attr" do
      refused(
        described_input(),
        {:put_input, "floor", %{"type" => @string, "metadata" => %{"description" => "Other."}}},
        :invalid_params
      )
    end

    test "rename_node keeps it" do
      document = edit_all(scenario_a(), [described_resolve()])

      updated = edit_all(document, [{:rename_node, "prepare", "resolve_worktree", "lookup"}])

      assert Document.description(node_at(updated, "prepare", "lookup")) == {:ok, "Text."}
    end

    test "replace_runner to another runner clears it" do
      document = edit_all(scenario_a(), [described_resolve()])

      updated = edit_all(document, [{:replace_runner, "prepare", "resolve_worktree", @detect}])

      refute is_map_key(node_at(updated, "prepare", "resolve_worktree"), "metadata")
    end

    test "replace_runner to the same runner keeps it, as no edit" do
      document = edit_all(scenario_a(), [described_resolve()])

      assert {:ok, ^document, :none} =
               Operations.edit(
                 document,
                 {:replace_runner, "prepare", "resolve_worktree", @resolve}
               )
    end

    defp described_input do
      edit_all(Document.new("w"), [
        {:put_input, "floor", %{"type" => @string}},
        {:set_description, {:input, "floor"}, "Text."}
      ])
    end

    defp described_resolve do
      {:set_description, {:node, "prepare", "resolve_worktree"}, "Text."}
    end
  end

  describe "placement" do
    # The widest cards, and the room a route's curve needs beside each of the two.
    @vertex_width 280
    @node_width 320
    @wire_room 2 * 60

    test "new vertices leave room for wires between the cards" do
      document = Document.new("w") |> edit_all([{:add_stage, "b"}, {:add_decision, "c"}])
      slots = Map.values(document["layout"]["workflow"])

      assert_gaps(slots, @vertex_width)
    end

    test "new nodes leave room for wires, and their rows don't touch" do
      document = nodes(["a", "b", "c", "d", "e"])
      slots = Map.values(document["layout"]["stages"]["main"])

      assert_gaps(slots, @node_width)
      assert [first_row, second_row] = slots |> Enum.map(& &1["y"]) |> Enum.uniq() |> Enum.sort()
      assert second_row - first_row >= 400
    end

    defp assert_gaps(slots, width) do
      columns = slots |> Enum.map(& &1["x"]) |> Enum.uniq() |> Enum.sort()
      assert length(columns) > 1

      for [left, right] <- Enum.chunk_every(columns, 2, 1, :discard) do
        assert right - left - width >= @wire_room
      end
    end
  end

  describe "move" do
    test "is a layout edit with rounded and clamped positions" do
      document = nodes(["ask"])

      assert {:ok, updated, :layout} =
               Operations.edit(document, {:move, {:stage, "main"}, "ask", 10.6, -200_000})

      assert updated["layout"]["stages"]["main"]["ask"] == %{"x" => 11, "y" => -100_000}

      assert {:ok, updated, :layout} =
               Operations.edit(document, {:move, :workflow, "main", 1.0e308, 0})

      assert updated["layout"]["workflow"]["main"] == %{"x" => 100_000, "y" => 0}
    end

    test "refuses an unknown scope, name or non-numeric position" do
      document = nodes(["ask"])

      refused(document, {:move, {:stage, "gone"}, "ask", 0, 0}, :unknown_stage)
      refused(document, {:move, {:stage, "main"}, "gone", 0, 0}, :unknown_node)
      refused(document, {:move, :workflow, "gone", 0, 0}, :unknown_vertex)
      refused(document, {:move, "main", "ask", 0, 0}, :invalid_params)
      refused(document, {:move, {:stage, "main"}, "ask", "1", 0}, :invalid_params)
    end
  end

  describe "source node positions" do
    # `resolve` of stage `main` is read by `directory` of stage `later`, and input `name`
    # exists on both. `main`'s `unread` isn't read by anything.
    defp sourced do
      edit_all(two_stages(), [
        {:put_input, "name", %{"type" => @string}},
        {:add_node, "main", @detect, "unread"},
        bind("later", "directory", "worktree", "resolve")
      ])
    end

    defp placed(document, stage, name), do: document["layout"]["stages"][stage][name]

    test "moving an input saves it under that stage only, as a layout change" do
      document = sourced()

      assert {:ok, updated, :layout} =
               Operations.edit(document, {:move, {:stage, "later"}, "name", 5, 6})

      assert placed(updated, "later", "name") == %{"x" => 5, "y" => 6}
      assert placed(updated, "main", "name") == nil
    end

    test "moving a read earlier source saves it under the reading stage" do
      assert {:ok, updated, :layout} =
               Operations.edit(sourced(), {:move, {:stage, "later"}, "resolve", 5, 6})

      assert placed(updated, "later", "resolve") == %{"x" => 5, "y" => 6}
      assert placed(updated, "main", "resolve") == placed(sourced(), "main", "resolve")
    end

    test "a second identical move changes nothing" do
      moved = edit_all(sourced(), [{:move, {:stage, "later"}, "name", 5, 6}])

      assert {:ok, ^moved, :none} =
               Operations.edit(moved, {:move, {:stage, "later"}, "name", 5, 6})
    end

    test "refuses an unread earlier source, an unknown-runner read and an unknown name" do
      document = sourced()
      refused(document, {:move, {:stage, "later"}, "unread", 0, 0}, :unknown_node)
      refused(document, {:move, {:stage, "later"}, "gone", 0, 0}, :unknown_node)

      unknown =
        put_in(document, ["vertices", "main", "nodes", "resolve", "runner"], "Gone.Runner")

      refused(unknown, {:move, {:stage, "later"}, "resolve", 0, 0}, :unknown_node)
    end

    test "remove_input clears the input's position on every stage" do
      document =
        edit_all(sourced(), [
          {:move, {:stage, "main"}, "name", 1, 2},
          {:move, {:stage, "later"}, "name", 3, 4}
        ])

      updated = edit_all(document, [{:remove_input, "name"}])

      assert placed(updated, "main", "name") == nil
      assert placed(updated, "later", "name") == nil
    end

    test "remove_input still succeeds on a layout it can't read" do
      document = sourced()

      for layout <- [%{}, %{"stages" => 5}, %{"stages" => %{"main" => 5}}] do
        hand_built = Map.put(document, "layout", layout)

        assert {:ok, updated, :definition} =
                 Operations.edit(hand_built, {:remove_input, "name"})

        assert updated["layout"] == layout
      end
    end

    test "rename_node keeps a downstream position under the new name" do
      document = edit_all(sourced(), [{:move, {:stage, "later"}, "resolve", 5, 6}])

      updated = edit_all(document, [{:rename_node, "main", "resolve", "renamed"}])

      assert placed(updated, "later", "renamed") == %{"x" => 5, "y" => 6}
      assert placed(updated, "later", "resolve") == nil
      assert placed(updated, "main", "renamed") == placed(document, "main", "resolve")
    end

    test "remove_node and remove_vertex clear downstream positions" do
      document = edit_all(sourced(), [{:move, {:stage, "later"}, "resolve", 5, 6}])

      removed = edit_all(document, [{:remove_node, "main", "resolve"}])
      assert placed(removed, "later", "resolve") == nil
      assert placed(removed, "main", "resolve") == nil

      gone =
        edit_all(document, [{:set_start, "later"}, {:remove_vertex, "main"}])

      assert placed(gone, "later", "resolve") == nil
      refute is_map_key(gone["layout"]["stages"], "main")
    end
  end

  describe "workflow ops" do
    test "set_workflow_name and set_start check names" do
      document = scenario_a()

      assert edit_all(document, [{:set_workflow_name, "renamed"}])["name"] == "renamed"
      refused(document, {:set_workflow_name, "a b"}, :invalid_name)

      assert edit_all(document, [{:set_start, "review"}])["start"] == "review"
      refused(document, {:set_start, "gone"}, :unknown_vertex)
    end

    test "put_input keeps an absent default apart from an explicit nil" do
      document =
        edit_all(Document.new("w"), [
          {:put_input, "absent", %{"type" => @string}},
          {:put_input, "null", %{"type" => @any, "default" => nil}},
          {:put_input, "text", %{"type" => @string, "default" => "x", "required" => true}}
        ])

      assert document["inputs"]["absent"] == %{"type" => @string, "required" => false}

      assert document["inputs"]["null"] == %{
               "type" => @any,
               "default" => nil,
               "required" => false
             }

      assert document["inputs"]["text"]["required"] == true
    end

    test "put_input allows a required input with a default, as an analyzer issue" do
      assert {:ok, _document, :definition} =
               Operations.edit(
                 Document.new("w"),
                 {:put_input, "both", %{"type" => @string, "required" => true, "default" => "x"}}
               )
    end

    test "put_input refuses unknown types, node and decision names, and bad shapes" do
      document = scenario_a()

      refused(document, {:put_input, "x", %{"type" => "Elixir.System"}}, :unknown_type)
      refused(document, {:put_input, "x", %{"type" => "DomovoyCore.Type.Choice"}}, :unknown_type)
      refused(document, {:put_input, "x", %{}}, :unknown_type)
      refused(document, {:put_input, "ask_claude", %{"type" => @string}}, :name_collision)
      refused(document, {:put_input, "review", %{"type" => @string}}, :name_collision)
      refused(document, {:put_input, "a/b", %{"type" => @string}}, :invalid_name)

      refused(
        document,
        {:put_input, "x", %{"type" => @string, "required" => "yes"}},
        :invalid_params
      )

      refused(document, {:put_input, "x", %{"type" => @string, "default" => 1}}, :invalid_params)
      refused(document, {:put_input, "x", %{"type" => @string, "other" => 1}}, :invalid_params)
    end

    test "a workflow input and a choice input may share a key only with the same type" do
      document = scenario_a()

      assert {:ok, _document, _kind} =
               Operations.edit(
                 document,
                 {:put_input, "prompt", %{"type" => @string, "required" => false}}
               )

      refused(document, {:put_input, "prompt", %{"type" => @any}}, :name_collision)
    end

    test "remove_input leaves references, and refuses an unknown name" do
      updated = edit_all(scenario_a(), [{:remove_input, "prompt"}])

      refute Map.has_key?(updated["inputs"], "prompt")
      assert input(updated, "prepare", "ask_claude", "context") == %{"bind" => "prompt"}
      refused(updated, {:remove_input, "prompt"}, :unknown_input)
    end
  end

  describe "vertex ops" do
    test "add_stage and add_decision place the vertex" do
      document = edit_all(Document.new("w"), [{:add_stage, "second"}, {:add_decision, "ask"}])

      assert document["vertices"]["second"] == Document.stage()
      assert document["vertices"]["ask"] == Document.decision()
      assert document["layout"]["workflow"]["second"]
      assert document["layout"]["workflow"]["ask"]
      assert document["layout"]["stages"]["second"] == %{}
    end

    test "refuse colliding names" do
      document = scenario_a()

      refused(document, {:add_stage, "prepare"}, :name_collision)
      refused(document, {:add_decision, "prepare"}, :name_collision)
      refused(document, {:add_decision, "ask_claude"}, :name_collision)
      refused(document, {:add_decision, "prompt"}, :name_collision)
    end

    test "remove_vertex clears layout and leaves references" do
      updated = edit_all(scenario_a(), [{:remove_vertex, "review"}])

      refute Map.has_key?(updated["vertices"], "review")
      refute Map.has_key?(updated["layout"]["workflow"], "review")
      assert updated["vertices"]["prepare"]["next"] == "review"
    end

    test "set_next takes a vertex or nil, on a stage only" do
      document = scenario_a()

      assert edit_all(document, [{:set_next, "prepare", nil}])["vertices"]["prepare"]["next"] ==
               nil

      refused(document, {:set_next, "prepare", "gone"}, :unknown_vertex)
      refused(document, {:set_next, "review", "prepare"}, :unknown_stage)
    end

    test "put_decision sets the prompt and a curated decider" do
      document = scenario_a()
      updated = edit_all(document, [{:put_decision, "review", %{"prompt" => "New?"}}])

      assert updated["vertices"]["review"]["prompt"] == "New?"
      assert updated["vertices"]["review"]["choices"] == document["vertices"]["review"]["choices"]

      refused(document, {:put_decision, "prepare", %{"prompt" => "x"}}, :unknown_decision)

      refused(
        document,
        {:put_decision, "review", %{"decider" => "Elixir.System"}},
        :unknown_decider
      )

      refused(document, {:put_decision, "review", %{"prompt" => 1}}, :invalid_params)
      refused(document, {:put_decision, "review", %{"kind" => "stage"}}, :invalid_params)
    end
  end

  describe "choices" do
    @approve %{"name" => "approve", "description" => "Accept", "target" => ["halt"]}

    test "put_choice updates a choice by name, keeping its place" do
      document = scenario_a()

      updated =
        edit_all(document, [{:put_choice, "review", %{@approve | "description" => "Yes"}}])

      assert [%{"name" => "approve", "description" => "Yes"}, %{"name" => "revise"}] =
               updated["vertices"]["review"]["choices"]
    end

    test "allows what the analyzer reports: blank text, Rerun on a Decision, inputs on Halt" do
      document = scenario_a()

      for choice <- [
            %{@approve | "description" => ""},
            %{@approve | "target" => ["rerun", "review"]},
            Map.put(@approve, "inputs", %{"prompt" => @string})
          ] do
        assert {:ok, _document, :definition} =
                 Operations.edit(document, {:put_choice, "review", choice})
      end
    end

    test "refuses unknown targets, types and colliding input keys" do
      document = scenario_a()
      put = fn change -> {:put_choice, "review", Map.merge(@approve, change)} end

      refused(document, put.(%{"target" => ["run", "gone"]}), :unknown_vertex)
      refused(document, put.(%{"target" => ["jump", "prepare"]}), :invalid_params)
      refused(document, put.(%{"target" => "halt"}), :invalid_params)
      refused(document, put.(%{"name" => "a/b"}), :invalid_name)
      refused(document, put.(%{"inputs" => %{"note" => "Elixir.System"}}), :unknown_type)
      refused(document, put.(%{"inputs" => %{"a/b" => @string}}), :invalid_name)
      refused(document, put.(%{"inputs" => %{"ask_claude" => @string}}), :name_collision)
      refused(document, put.(%{"inputs" => %{"review" => @string}}), :name_collision)
      refused(document, put.(%{"inputs" => %{"prompt" => @any}}), :name_collision)
      refused(document, {:put_choice, "prepare", @approve}, :unknown_decision)
    end

    test "a choice's own input can change type when nothing else shares the key" do
      document =
        edit_all(scenario_a(), [
          {:put_choice, "review", Map.put(@approve, "inputs", %{"note" => @string})}
        ])

      assert {:ok, _document, :definition} =
               Operations.edit(
                 document,
                 {:put_choice, "review", Map.put(@approve, "inputs", %{"note" => @any})}
               )
    end

    test "remove_choice removes by name, and refuses an unknown one" do
      updated = edit_all(scenario_a(), [{:remove_choice, "review", "approve"}])

      assert [%{"name" => "revise"}] = updated["vertices"]["review"]["choices"]
      refused(updated, {:remove_choice, "review", "approve"}, :unknown_choice)
    end
  end

  describe "rename over a dangling After" do
    test "keeps one edge, so one remove_after clears it" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @detect, "gone"},
          {:add_node, "main", @detect, "other"},
          {:add_node, "main", @detect, "waiter"},
          {:add_after, "main", "waiter", "gone"},
          {:add_after, "main", "waiter", "other"},
          {:remove_node, "main", "gone"},
          {:rename_node, "main", "other", "gone"}
        ])

      assert node_at(document, "main", "waiter")["after"] == ["gone"]

      cleared = edit_all(document, [{:remove_after, "main", "waiter", "gone"}])
      assert node_at(cleared, "main", "waiter")["after"] == []
    end
  end

  describe "generated adapter name" do
    defp adapter_setup do
      edit_all(Document.new("w"), [
        {:add_stage, "later"},
        {:add_node, "main", @resolve, "resolve"},
        {:add_node, "main", @ask, "consumer"},
        {:add_node, "main", @ask, "reader"},
        {:add_node, "main", @directory, "worktree_directory"}
      ])
    end

    defp adapter_op do
      {:insert_adapter, "main", "resolve", "consumer", "working_directory", @directory}
    end

    test "avoids the name of a dangling binding" do
      document =
        edit_all(adapter_setup(), [
          bind("main", "reader", "working_directory", "worktree_directory"),
          {:remove_node, "main", "worktree_directory"}
        ])

      updated = edit_all(document, [adapter_op()])

      assert input(updated, "main", "consumer", "working_directory") ==
               %{"bind" => "worktree_directory_2"}

      assert node_at(updated, "main", "worktree_directory_2")
      refute node_at(updated, "main", "worktree_directory")
      assert %{warnings: []} = Operations.preview(document, adapter_op())
    end

    test "avoids the name of a dangling After" do
      document =
        edit_all(adapter_setup(), [
          {:add_after, "main", "reader", "worktree_directory"},
          {:remove_node, "main", "worktree_directory"}
        ])

      updated = edit_all(document, [adapter_op()])

      assert node_at(updated, "main", "worktree_directory_2")
      refute node_at(updated, "main", "worktree_directory")
    end

    test "avoids a name only another stage's dangling binding uses" do
      document =
        edit_all(adapter_setup(), [
          {:add_node, "later", @ask, "far"},
          {:set_next, "main", "later"},
          bind("later", "far", "working_directory", "worktree_directory"),
          {:remove_node, "main", "worktree_directory"}
        ])

      updated = edit_all(document, [adapter_op()])

      assert node_at(updated, "main", "worktree_directory_2")
    end
  end

  describe "preview/2 analyzer issues" do
    test "lists only the issues the op adds" do
      document = edit_all(scenario_a(), [{:add_node, "prepare", @ask, "second"}])

      assert %{new_issues: [issue]} =
               Operations.preview(document, {:clear_input, "prepare", "trust_mise", "mise"})

      assert issue.code == :required_missing
      assert issue.target == {:field, "prepare", "trust_mise", "mise"}
    end

    test "lists none when the op fixes one" do
      document = edit_all(scenario_a(), [{:clear_input, "prepare", "trust_mise", "mise"}])
      op = bind("prepare", "trust_mise", "mise", "detect_mise")

      assert %{new_issues: []} = Operations.preview(document, op)
    end
  end

  describe "preview/2 source visibility" do
    defp worktree_chain do
      edit_all(Document.new("w"), [
        {:add_stage, "middle"},
        {:add_stage, "last"},
        {:set_next, "main", "middle"},
        {:set_next, "middle", "last"},
        {:add_node, "middle", @resolve, "resolve"},
        {:add_node, "last", @directory, "directory"},
        bind("last", "directory", "worktree", "resolve")
      ])
    end

    test "edit/2 stays permissive and preview warns on a source that runs later" do
      document =
        edit_all(two_stages(), [
          {:add_node, "later", @resolve, "late_resolve"},
          {:add_node, "main", @directory, "early"}
        ])

      op = bind("main", "early", "worktree", "late_resolve")

      assert {:ok, updated, :definition} = Operations.edit(document, op)
      assert input(updated, "main", "early", "worktree") == %{"bind" => "late_resolve"}

      assert %{warnings: [warning]} = Operations.preview(document, op)
      assert warning.code == :source_not_visible
      assert warning.core_id == :stage_input_unbound
      assert warning.target == {:field, "main", "early", "worktree"}
      assert warning.message =~ "late_resolve"
    end

    test "warns when moving a binding from one hidden source to another" do
      document =
        edit_all(two_stages(), [
          {:add_node, "later", @resolve, "late_a"},
          {:add_node, "later", @resolve, "late_b"},
          {:add_node, "main", @directory, "early"},
          bind("main", "early", "worktree", "late_a")
        ])

      assert %{warnings: [%{code: :source_not_visible} = warning]} =
               Operations.preview(document, bind("main", "early", "worktree", "late_b", true))

      assert warning.message =~ "late_b"
    end

    test "warns when set_next stops a source preceding a reachable stage" do
      assert %{warnings: [warning]} =
               Operations.preview(worktree_chain(), {:set_next, "main", "last"})

      assert warning.code == :source_not_visible
      assert warning.core_id == :stage_input_unbound
      assert warning.target == {:field, "last", "directory", "worktree"}
    end

    test "warns when set_next leaves the consuming stage unreachable, which Core won't report" do
      assert %{warnings: [warning]} =
               Operations.preview(worktree_chain(), {:set_next, "middle", nil})

      assert warning.code == :source_not_visible
      assert warning.core_id == nil
      assert warning.target == {:field, "last", "directory", "worktree"}
    end

    test "warns when remove_vertex breaks the path a source reaches the stage by" do
      document =
        edit_all(two_stages(), [
          {:add_stage, "between"},
          {:add_stage, "last"},
          {:set_next, "later", "between"},
          {:set_next, "between", "last"},
          {:add_node, "last", @directory, "far"},
          bind("last", "far", "worktree", "resolve")
        ])

      assert %{warnings: [warning]} = Operations.preview(document, {:remove_vertex, "between"})

      assert warning.code == :source_not_visible
      assert warning.target == {:field, "last", "far", "worktree"}
    end

    test "wiring the source in front of the stage clears the warning" do
      document = edit_all(worktree_chain(), [{:set_next, "main", "last"}])

      assert %{warnings: []} = Operations.preview(document, {:set_next, "main", "middle"})
    end

    test "warns when a hidden source's producer is removed" do
      document = edit_all(worktree_chain(), [{:set_next, "main", "last"}])

      assert %{warnings: [%{code: :unknown_source} = warning]} =
               Operations.preview(document, {:remove_node, "middle", "resolve"})

      assert warning.target == {:field, "last", "directory", "worktree"}
    end

    test "an unrelated edit doesn't repeat a hidden source's warning" do
      document = edit_all(worktree_chain(), [{:set_next, "main", "last"}])

      assert %{warnings: []} = Operations.preview(document, {:move, :workflow, "main", 1, 1})
    end

    test "a binding to a workflow input never warns" do
      document =
        edit_all(two_stages(), [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_stage, "orphan"},
          {:add_node, "orphan", @resolve, "alone"}
        ])

      assert %{warnings: []} =
               Operations.preview(document, bind("orphan", "alone", "worktree_name", "prompt"))
    end
  end

  describe "preview/2" do
    test "warns when removing a sibling leaves an Any field failing" do
      document =
        edit_all(two_stages(), [
          bind("later", "directory", "worktree", "resolve"),
          bind("later", "trust", "worktree", "resolve")
        ])

      assert %{warnings: [warning], dropped: []} =
               Operations.preview(document, {:clear_input, "later", "directory", "worktree"})

      assert warning.target == {:field, "later", "trust", "worktree"}
      assert warning.message =~ "Across stages Any matches only Any"
    end

    test "warns when removing a producer leaves consumers dangling" do
      assert %{warnings: warnings} =
               Operations.preview(scenario_a(), {:remove_node, "prepare", "trust_mise"})

      assert {:after, "prepare", "ask_claude", "trust_mise"} in Enum.map(warnings, & &1.target)
    end

    test "warns when a new name re-resolves a dangling reference" do
      document =
        edit_all(two_stages(), [
          bind("later", "directory", "worktree", "resolve"),
          {:remove_node, "main", "resolve"}
        ])

      assert %{warnings: [warning]} =
               Operations.preview(document, {:add_node, "main", @resolve, "resolve"})

      assert warning.code == :reference_resolved
      assert warning.target == {:field, "later", "directory", "worktree"}
    end

    test "warns about a dangling After a rename re-resolves" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @detect, "gone"},
          {:add_node, "main", @detect, "waiter"},
          {:add_node, "main", @detect, "other"},
          {:add_after, "main", "waiter", "gone"},
          {:remove_node, "main", "gone"}
        ])

      assert %{warnings: [warning]} =
               Operations.preview(document, {:rename_node, "main", "other", "gone"})

      assert warning.target == {:after, "main", "waiter", "gone"}
    end

    test "an edit breaking nothing has no warnings" do
      assert %{warnings: [], dropped: []} =
               Operations.preview(scenario_a(), {:move, :workflow, "prepare", 1, 1})
    end

    test "renaming a consumer of a dangling reference doesn't warn" do
      document =
        edit_all(two_stages(), [
          bind("later", "directory", "worktree", "resolve"),
          {:remove_node, "main", "resolve"}
        ])

      assert %{warnings: []} =
               Operations.preview(document, {:rename_node, "later", "directory", "dir"})
    end

    test "returns the same rejection edit/2 gives, without changing anything" do
      assert {:error, %Issue{code: :unknown_runner}} =
               Operations.preview(scenario_a(), {:add_node, "prepare", "Elixir.System", "x"})
    end
  end

  describe "idempotency" do
    @repeats [
      {:add_after, "prepare", "ask_claude", "trust_mise"},
      {:set_validators, "prepare", "ask_claude", []},
      {:set_execution, "prepare", "ask_claude", nil, true},
      {:set_workflow_name, "scenario_a"},
      {:set_start, "prepare"},
      {:set_next, "prepare", "review"},
      {:put_decision, "review", %{"prompt" => "Approve the answer?"}},
      {:put_input, "prompt", %{"type" => "DomovoyCore.Type.String", "required" => true}},
      {:bind, "prepare", "ask_claude", "context", "prompt", replace_literal: false},
      {:set_literal, "prepare", "ask_claude", "options", "{}", replace_binding: false}
    ]

    test "an edit repeating the current state returns :none and the same document" do
      document = scenario_a()

      for op <- @repeats do
        assert {:ok, ^document, :none} = Operations.edit(document, op)
      end
    end

    test "a second identical edit returns :none with no diff" do
      op = {:move, {:stage, "prepare"}, "ask_claude", 5, 5}

      assert {:ok, moved, :layout} = Operations.edit(scenario_a(), op)
      assert {:ok, ^moved, :none} = Operations.edit(moved, op)
    end

    test "a second identical description returns :none with no diff" do
      op = {:set_description, {:vertex, "prepare"}, "Text."}

      assert {:ok, described, :definition} = Operations.edit(scenario_a(), op)
      assert {:ok, ^described, :none} = Operations.edit(described, op)
    end

    test "fixture building is repeatable" do
      assert scenario_a() == scenario_a()
    end
  end

  describe "hostile input" do
    setup do
      :code.purge(UnloadedProbe)
      :code.delete(UnloadedProbe)
      :code.purge(UnloadedProbe)
      assert :code.is_loaded(UnloadedProbe) == false

      %{document: scenario_a()}
    end

    test "random names leave the document unchanged and create no atom", %{document: document} do
      random = "zz_unknown_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000_000)}"

      ops = [
        {:add_node, random, @detect, "x"},
        {:add_node, "prepare", random, "x"},
        {:rename_node, "prepare", random, "x"},
        {:remove_node, "prepare", random},
        bind(random, "ask_claude", "context", "prompt"),
        bind("prepare", random, "context", "prompt"),
        bind("prepare", "ask_claude", random, "prompt"),
        bind("prepare", "ask_claude", "context", random),
        literal("prepare", "ask_claude", random, "x"),
        {:clear_input, "prepare", "ask_claude", random},
        {:add_after, "prepare", "ask_claude", random},
        {:replace_runner, "prepare", "ask_claude", random},
        {:insert_adapter, "prepare", random, "ask_claude", "context", @ask},
        {:set_validators, "prepare", "ask_claude", [random]},
        {:move, {:stage, random}, "ask_claude", 0, 0},
        {:set_start, random},
        {:put_input, "x", %{"type" => random}},
        {:remove_input, random},
        {:remove_vertex, random},
        {:set_next, "prepare", random},
        {:put_decision, random, %{}},
        {:put_decision, "review", %{"decider" => random}},
        {:put_choice, random, %{}},
        {:remove_choice, "review", random},
        {:set_description, {:node, random, "ask_claude"}, "x"},
        {:set_description, {:node, "prepare", random}, "x"},
        {:set_description, {:vertex, random}, "x"},
        {:set_description, {:input, random}, "x"}
      ]

      for op <- ops do
        assert {:error, %Issue{}} = Operations.edit(document, op), inspect(op)
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom(random) end
    end

    test "module names and hidden ids are refused", %{document: document} do
      ids = [
        "Elixir.System",
        "System",
        "DomovoyClaudeCodePlugin.Monitoring.Runner.Fold",
        "DomovoyClaudeCodePlugin.Reflect.Runner.CollectTranscripts"
      ]

      for id <- ids do
        assert {:error, %Issue{code: :unknown_runner}} =
                 Operations.edit(document, {:add_node, "prepare", id, "x"})

        assert {:error, %Issue{code: :unknown_runner}} =
                 Operations.edit(document, {:replace_runner, "prepare", "ask_claude", id})

        assert {:error, %Issue{code: :unknown_type}} =
                 Operations.edit(document, {:put_input, "x", %{"type" => id}})
      end

      assert {:error, %Issue{code: :unknown_type}} =
               Operations.edit(
                 document,
                 {:put_input, "x", %{"type" => "DomovoyCore.Type.Choice"}}
               )
    end

    test "an unloaded module is refused and stays unloaded", %{document: document} do
      id = inspect(UnloadedProbe)

      for op <- [
            {:add_node, "prepare", id, "x"},
            {:replace_runner, "prepare", "ask_claude", id},
            {:put_input, "x", %{"type" => id}},
            {:set_validators, "prepare", "ask_claude", [id]},
            {:put_decision, "review", %{"decider" => id}},
            {:add_node, "prepare", Atom.to_string(UnloadedProbe), "x"}
          ] do
        assert {:error, %Issue{}} = Operations.edit(document, op)
        assert :code.is_loaded(UnloadedProbe) == false
      end
    end

    test "NUL and broken UTF-8 are refused in every string", %{document: document} do
      for bad <- ["a\0b", <<0xFF>>] do
        ops = [
          literal("prepare", "ask_claude", "context", bad, true),
          {:put_decision, "review", %{"prompt" => bad}},
          {:put_choice, "review", %{"name" => "c", "description" => bad, "target" => ["halt"]}},
          {:put_input, "x", %{"type" => @string, "default" => bad}},
          {:put_input, bad, %{"type" => @string}},
          {:set_workflow_name, bad},
          {:add_stage, bad},
          {:add_node, "prepare", @detect, bad},
          {:set_validators, "prepare", "ask_claude", [bad]},
          {:set_description, {:vertex, "prepare"}, bad},
          {:set_description, {:input, bad}, "text"},
          {:put_choice, "review",
           %{
             "name" => "c",
             "description" => "d",
             "target" => ["halt"],
             "inputs" => %{bad => @string}
           }}
        ]

        for op <- ops do
          assert {:error, %Issue{code: :invalid_text}} = Operations.edit(document, op),
                 inspect(op)
        end
      end
    end

    @wrong_shapes [
      :unknown_op,
      nil,
      1,
      "add_stage",
      %{},
      [],
      {},
      {:no_such_op, "x"},
      {:add_node, 1, "r", "n"},
      {:add_node, "prepare", nil, "n"},
      {:add_node, "prepare", "r", %{}},
      {:add_node, "prepare", "r"},
      {:rename_node, "prepare", ["a"], "b"},
      {:remove_node, "prepare", 1},
      {:bind, "prepare", "ask_claude", "context", 1, replace_literal: false},
      {:bind, "prepare", "ask_claude", "context", "prompt", replace_literal: "yes"},
      {:bind, "prepare", "ask_claude", "context", "prompt", []},
      {:bind, "prepare", "ask_claude", "context", "prompt"},
      {:set_literal, "prepare", "ask_claude", "context", 1, replace_binding: false},
      {:set_literal, "prepare", "ask_claude", "context", %{}, replace_binding: false},
      {:set_literal, "prepare", "ask_claude", "context", "x", replace_binding: nil},
      {:clear_input, "prepare", "ask_claude", nil},
      {:add_after, "prepare", "ask_claude", ["x"]},
      {:remove_after, "prepare", "ask_claude", 1},
      {:replace_runner, "prepare", "ask_claude", nil},
      {:insert_adapter, "prepare", 1, "ask_claude", "context", "r"},
      {:set_validators, "prepare", "ask_claude", "x"},
      {:set_validators, "prepare", "ask_claude", nil},
      {:set_execution, "prepare", "ask_claude", "3", true},
      {:set_execution, "prepare", "ask_claude", 1.5, true},
      {:set_execution, "prepare", "ask_claude", 3, "true"},
      {:move, {:stage, "prepare"}, "ask_claude", "1", 2},
      {:move, {:stage, "prepare"}, "ask_claude", 1, nil},
      {:move, {:stage, "prepare"}, 1, 1, 2},
      {:move, %{}, "ask_claude", 1, 2},
      {:set_workflow_name, 1},
      {:set_start, nil},
      {:put_input, "x", "DomovoyCore.Type.String"},
      {:put_input, 1, %{}},
      {:remove_input, nil},
      {:add_stage, []},
      {:add_decision, %{}},
      {:remove_vertex, 1},
      {:set_next, "prepare", 1},
      {:put_decision, "review", "x"},
      {:put_choice, "review", "x"},
      {:put_choice, "review", %{}},
      {:put_choice, "review", %{"name" => 1, "description" => "d", "target" => ["halt"]}},
      {:put_choice, "review", %{"name" => "c", "description" => nil, "target" => ["halt"]}},
      {:put_choice, "review", %{"name" => "c", "description" => "d", "target" => nil}},
      {:put_choice, "review", %{"name" => "c", "description" => "d", "target" => ["run", 1]}},
      {:put_choice, "review",
       %{"name" => "c", "description" => "d", "target" => ["halt"], "inputs" => []}},
      {:put_choice, "review",
       %{"name" => "c", "description" => "d", "target" => ["halt"], "extra" => 1}},
      {:remove_choice, "review", nil}
    ]

    test "wrong shapes return an Issue and leave the document alone", %{document: document} do
      for op <- @wrong_shapes do
        assert {:error, %Issue{}} = Operations.edit(document, op), inspect(op)
      end
    end
  end

  describe "security" do
    test "a sentinel literal never appears in an Issue" do
      document =
        edit_all(nodes(["ask"]), [
          {:put_input, "prompt", %{"type" => @string}},
          {:add_node, "main", @directory, "directory"},
          literal("main", "ask", "context", @sentinel)
        ])

      issues =
        for {op, _code} <- [
              {bind("main", "ask", "context", "prompt"), :literal_present},
              {literal("main", "directory", "worktree", @sentinel), :bind_only},
              {{:insert_adapter, "main", "prompt", "ask", "context", @detect}, :literal_present},
              {literal("main", "ask", "context", @sentinel <> <<0>>), :invalid_text}
            ] do
          {:error, issue} = Operations.edit(document, op)
          issue
        end

      refute inspect(issues) =~ @sentinel

      assert %{warnings: warnings} =
               Operations.preview(document, {:clear_input, "main", "ask", "context"})

      refute inspect(warnings) =~ @sentinel
    end
  end
end

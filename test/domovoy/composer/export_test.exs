defmodule Domovoy.Composer.ExportTest do
  # Not async: one test sets the Application env `Composer.validate/1` reads.
  use ExUnit.Case, async: false

  import Domovoy.ComposerFixtures, only: [edit_all: 2, scenario_a: 0]

  alias Domovoy.Composer
  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.CoreBridge
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Export
  alias Domovoy.Composer.Issue
  alias DomovoyCore.Definition
  alias DomovoyCore.Workflow

  @string "DomovoyCore.Type.String"
  @ask "DomovoyClaudeCodePlugin.Runner.AskClaude"
  @detect "DomovoyMisePlugin.Runner.Detect"
  @write_file "DomovoyCore.Runner.WriteFile"
  @sentinel "sentinel-secret-value"

  defp valid!(document) do
    assert {:valid, result} = Export.validate(document)
    result
  end

  defp invalid!(document, steps \\ %{}) do
    assert {:invalid, [%Issue{} | _rest] = issues} = Export.validate(document, steps)
    issues
  end

  defp to_json(workflow), do: Workflow.to_json(workflow, pretty: true)

  describe "scenario A" do
    test "is valid, and its JSON reads back equal, with the layout in the metadata" do
      document = scenario_a()
      %{workflow: workflow, json: json, fingerprint: fingerprint} = valid!(document)

      assert {:ok, decoded} = Workflow.from_json(json)
      assert decoded == workflow
      assert decoded.metadata["domovoy_editor"] == document["layout"]
      assert Definition.fingerprint(decoded).root == fingerprint
      assert to_json(decoded) == {:ok, json}
    end
  end

  describe "identity" do
    setup do
      document = scenario_a()
      %{document: document, root: valid!(document).fingerprint}
    end

    test "a move keeps the fingerprint root and changes the bytes", %{
      document: document,
      root: root
    } do
      moved = edit_all(document, [{:move, {:stage, "prepare"}, "ask_claude", 7, 9}])
      result = valid!(moved)

      assert result.fingerprint == root
      refute result.json == valid!(document).json

      assert result.workflow.metadata["domovoy_editor"]["stages"]["prepare"]["ask_claude"] ==
               %{"x" => 7, "y" => 9}
    end

    test "a reload after a move keeps the root", %{document: document, root: root} do
      moved = edit_all(document, [{:move, :workflow, "prepare", 7, 9}])
      reloaded = moved |> Jason.encode!() |> Jason.decode!()

      assert valid!(reloaded).fingerprint == root
    end

    test "a bind edit changes it", %{document: document, root: root} do
      edited =
        edit_all(document, [
          {:bind, "prepare", "ask_claude", "context", "worktree_name", replace_literal: false}
        ])

      refute valid!(edited).fingerprint == root
    end

    test "set_execution keeps it", %{document: document, root: root} do
      edited = edit_all(document, [{:set_execution, "prepare", "ask_claude", 3, false}])
      result = valid!(edited)

      assert result.fingerprint == root
      assert result.workflow.vertices["prepare"].graph.nodes_by_name["ask_claude"].store? == false
    end
  end

  describe "literals" do
    test "a Path exports unchanged" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", @write_file, "write"},
          {:set_literal, "main", "write", "path", "~/x", replace_binding: false}
        ])

      %{workflow: workflow, json: json} = valid!(document)

      assert workflow.vertices["main"].graph.nodes_by_name["write"].args.path ==
               {"~/x", DomovoyCore.Type.Path}

      assert json =~ "~/x"
    end

    test "every allowlisted value round-trips" do
      for {type, raw} <- [
            {"DomovoyCore.Type.String", "text"},
            {"DomovoyCore.Type.Integer", "1"},
            {"DomovoyCore.Type.Float", "1"},
            {"DomovoyCore.Type.Float", "1.5"},
            {"DomovoyCore.Type.Number", "2"},
            {"DomovoyCore.Type.Number", "2.5"},
            {"DomovoyCore.Type.Boolean", "true"},
            {"DomovoyCore.Type.UUID", "018f4e3a-7b1c-4d2e-8f3a-9c0d1e2f3a4b"},
            {"DomovoyCore.Type.URI", "https://example.com/a"},
            {"DomovoyCore.Type.Email", "a@example.com"},
            {"DomovoyCore.Type.Path", "~/x"},
            {"DomovoyCore.Type.File", "~/x.txt"},
            {"DomovoyCore.Type.Directory", "~/x"},
            {"DomovoyCore.Type.Map", ~s({"a": {"b": [1, 2.5, null]}})},
            {"DomovoyCore.Type.Any", "null"},
            {"DomovoyCore.Type.Any", ~s([1, "two", {"three": 3.5}])}
          ] do
        document =
          edit_all(Document.new("w"), [{:put_input, "x", %{"type" => type, "default" => raw}}])

        assert {:valid, _result} = Export.validate(document), "#{type} #{raw}"
      end
    end

    test "null default on Integer, null on a required Any and a bad Integer are invalid" do
      for {ops, code} <- [
            {[{:put_input, "x", %{"type" => "DomovoyCore.Type.Integer", "default" => nil}}],
             :null_default},
            {[
               {:add_node, "main", "DomovoyMisePlugin.Runner.Trust", "trust"},
               {:set_literal, "main", "trust", "worktree", "null", replace_binding: false}
             ], :null_required},
            {[
               {:add_node, "main", "DomovoyClaudeCodePlugin.Runner.ListSessions", "list"},
               {:set_literal, "main", "list", "limit", "not an int", replace_binding: false}
             ], :invalid_literal}
          ] do
        assert code in (invalid!(edit_all(Document.new("w"), ops)) |> Enum.map(& &1.code))
      end
    end
  end

  describe "the one-way guarantee" do
    test "stricter rules stay invalid though Core builds" do
      document =
        edit_all(Document.new("w"), [
          {:put_input, "gone", %{"type" => @string}},
          {:add_stage, "orphan"},
          {:add_node, "orphan", "DomovoyGitPlugin.Runner.WorktreeResolve", "resolve"},
          {:bind, "orphan", "resolve", "worktree_name", "gone", replace_literal: false},
          {:remove_input, "gone"}
        ])

      assert {:ok, %Workflow{}} = CoreBridge.build(document)
      assert [%Issue{code: :unresolved_source}] = invalid!(document)
    end

    test "deleting a producer makes the draft invalid" do
      deleted = edit_all(scenario_a(), [{:remove_node, "prepare", "worktree_directory"}])

      assert :unresolved_source in Enum.map(invalid!(deleted), & &1.code)
    end

    test "Core rejecting what the analyzer missed surfaces its identifier" do
      failing = %{
        build: fn _document -> {:error, DomovoyCore.Error.not_an_adapter(X, Y, "w")} end
      }

      assert [%Issue{code: :core_rejected, core_id: :not_an_adapter}] =
               invalid!(scenario_a(), failing)
    end
  end

  describe "failure injection" do
    setup do
      document = scenario_a()
      {:ok, workflow} = CoreBridge.build(document)
      {:ok, json} = to_json(workflow)
      %{document: document, workflow: workflow, json: json}
    end

    test "build", %{document: document} do
      assert [%Issue{code: :core_rejected, core_id: :invalid_node, target: :workflow}] =
               invalid!(document, %{
                 build: fn _doc -> raise ArgumentError, "invalid_node: %{}" end
               })

      assert [%Issue{code: :core_rejected, core_id: nil}] =
               invalid!(document, %{build: fn _doc -> raise "boom #{@sentinel}" end})

      assert [%Issue{core_id: nil}] = invalid!(document, %{build: fn _doc -> throw(:boom) end})
      assert [%Issue{core_id: nil}] = invalid!(document, %{build: fn _doc -> exit(:boom) end})

      issue = %Issue{code: :core_rejected, target: {:vertex, "a"}, message: "m"}
      assert [^issue] = invalid!(document, %{build: fn _doc -> {:error, [issue]} end})
    end

    test "to_json", %{document: document} do
      error = DomovoyCore.Error.workflow_not_encodable(["x"], :pid)

      assert [%Issue{core_id: :workflow_not_encodable}] =
               invalid!(document, %{to_json: fn _workflow -> {:error, error} end})

      assert [%Issue{core_id: nil}] =
               invalid!(document, %{to_json: fn _workflow -> raise "boom" end})
    end

    test "from_json", %{document: document} do
      error = DomovoyCore.Error.invalid_workflow_json([], :not_json)

      assert [%Issue{core_id: :invalid_workflow_json}] =
               invalid!(document, %{from_json: fn _json -> {:error, error} end})

      assert [%Issue{core_id: nil}] =
               invalid!(document, %{from_json: fn _json -> raise "boom" end})

      assert [%Issue{core_id: nil}] =
               invalid!(document, %{from_json: fn _json -> {:ok, :junk} end})
    end

    test "a second encode failing", %{document: document, json: json} do
      to_json = fn workflow ->
        if Process.put(:encoded?, true), do: {:error, :second}, else: to_json(workflow)
      end

      assert json != ""
      assert [%Issue{core_id: nil}] = invalid!(document, %{to_json: to_json})
    end

    test "a struct mismatch alone", %{document: document, workflow: workflow, json: json} do
      # Metadata is outside the fingerprint, and a fixed encoder keeps the bytes equal.
      changed = %{workflow | metadata: %{"other" => true}}

      issues =
        invalid!(document, %{
          to_json: fn _workflow -> {:ok, json} end,
          from_json: fn _json -> {:ok, changed} end
        })

      assert [%Issue{code: :round_trip_mismatch, core_id: nil, target: :workflow} = issue] =
               issues

      assert issue.message =~ "workflow"
    end

    test "a fingerprint mismatch", %{document: document, workflow: workflow, json: json} do
      changed = %{workflow | start: "review"}

      messages =
        invalid!(document, %{
          to_json: fn _workflow -> {:ok, json} end,
          from_json: fn _json -> {:ok, changed} end
        })
        |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 =~ "fingerprint"))
      refute Enum.any?(messages, &(&1 =~ "JSON"))
    end

    test "a bytes mismatch alone", %{document: document} do
      to_json = fn workflow ->
        {:ok, json} = to_json(workflow)
        if Process.put(:encoded?, true), do: {:ok, json <> " "}, else: {:ok, json}
      end

      assert [%Issue{code: :round_trip_mismatch} = issue] =
               invalid!(document, %{to_json: to_json})

      assert issue.message =~ "JSON"
    end
  end

  describe "a hand-built document" do
    test "any term is invalid, and nothing raises" do
      for term <- [nil, 1, "x", [], %{}, {:a}, %{"vertices" => 1}, Date.utc_today()] do
        assert [%Issue{code: :malformed_document} | _rest] = Analyzer.issues(term)
        assert {:invalid, [%Issue{} | _rest]} = Export.validate(term)
        assert {:error, [%Issue{} | _rest]} = CoreBridge.build(term)
      end
    end

    test "junk at any path of scenario A raises nothing" do
      document = scenario_a()

      for path <- paths(document), junk <- junk() do
        mutated = replace_at(document, path, junk)
        assert_no_raise(mutated)
      end

      for path <- paths(document), path != [] do
        assert_no_raise(delete_at(document, path))
      end
    end

    test "NUL and broken UTF-8 are malformed, with nothing echoed" do
      for bad <- ["a\0b", <<0xFF>>] do
        document = put_in(scenario_a(), ["vertices", "review", "prompt"], bad)

        assert [%Issue{code: :malformed_document}] = Analyzer.issues(document)
        assert {:invalid, [%Issue{}]} = Export.validate(document)
      end
    end

    test "no message holds a sentinel literal" do
      document =
        edit_all(Document.new("w"), [
          {:add_node, "main", "DomovoyClaudeCodePlugin.Runner.ListSessions", "list"},
          {:set_literal, "main", "list", "limit", @sentinel, replace_binding: false},
          {:put_input, "n", %{"type" => "DomovoyCore.Type.Integer", "default" => @sentinel}}
        ])

      issues = invalid!(document)
      assert length(issues) >= 2
      refute inspect(issues) =~ @sentinel

      {:error, core_issues} = CoreBridge.build(document)
      refute inspect(core_issues) =~ @sentinel
    end

    defp assert_no_raise(document) do
      issues = Analyzer.issues(document)
      assert Enum.all?(issues, &match?(%Issue{message: message} when is_binary(message), &1))

      case Export.validate(document) do
        {:valid, %{workflow: %Workflow{}}} -> assert issues == []
        {:invalid, [%Issue{} | _rest]} -> :ok
      end

      assert match?({:ok, %Workflow{}}, CoreBridge.build(document)) or
               match?({:error, [%Issue{} | _rest]}, CoreBridge.build(document))
    end

    defp junk do
      [
        nil,
        1,
        1.5,
        true,
        "x",
        "",
        "a\0b",
        <<0xFF>>,
        [],
        [1],
        %{},
        %{"x" => 1},
        %{1 => 2},
        {:a, 1},
        :atom,
        Date.utc_today()
      ]
    end

    defp paths(term) when is_map(term) and not is_struct(term) do
      for {key, value} <- term, rest <- [[] | paths(value)], do: [key | rest]
    end

    defp paths(term) when is_list(term) do
      for {value, index} <- Enum.with_index(term), rest <- [[] | paths(value)], do: [index | rest]
    end

    defp paths(_term), do: []

    defp replace_at(_term, [], value), do: value

    defp replace_at(term, [key | rest], value) when is_map(term),
      do: Map.put(term, key, replace_at(term[key], rest, value))

    defp replace_at(term, [index | rest], value) when is_list(term) do
      List.update_at(term, index, &replace_at(&1, rest, value))
    end

    defp delete_at(term, [key]) when is_map(term), do: Map.delete(term, key)
    defp delete_at(term, [index]) when is_list(term), do: List.delete_at(term, index)

    defp delete_at(term, [key | rest]) when is_map(term),
      do: Map.put(term, key, delete_at(term[key], rest))

    defp delete_at(term, [index | rest]) when is_list(term),
      do: List.update_at(term, index, &delete_at(&1, rest))
  end

  describe "Composer" do
    test "issues/1 and validate/1 use the analyzer and the real steps" do
      assert Composer.issues(scenario_a()) == []
      assert {:valid, %{fingerprint: "v1:" <> _hex}} = Composer.validate(scenario_a())

      incomplete = edit_all(Document.new("w"), [{:add_node, "main", @ask, "ask"}])
      assert [%Issue{code: :required_missing} | _rest] = Composer.issues(incomplete)
      assert {:invalid, [%Issue{code: :required_missing} | _rest]} = Composer.validate(incomplete)
    end

    test "validate/1 reads its steps from the Application env" do
      on_exit(fn -> Application.delete_env(:domovoy, :composer_export_steps) end)

      Application.put_env(:domovoy, :composer_export_steps, %{
        build: fn _document -> raise ArgumentError, "invalid_node: %{}" end
      })

      assert {:invalid, [%Issue{core_id: :invalid_node}]} = Composer.validate(scenario_a())
    end
  end

  test "an empty stage workflow is valid, since a draft starts that way" do
    assert {:valid, _result} = Export.validate(Document.new("w"))
  end

  test "a node with an optional-only runner is valid" do
    document = edit_all(Document.new("w"), [{:add_node, "main", @detect, "detect"}])
    assert {:valid, _result} = Export.validate(document)
  end
end

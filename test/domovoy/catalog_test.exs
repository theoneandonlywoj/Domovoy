defmodule Domovoy.CatalogTest do
  use ExUnit.Case, async: true

  alias Domovoy.Catalog
  alias Domovoy.Catalog.Curated

  @worktree "DomovoyGitPlugin.Type.Worktree"
  @directory "DomovoyCore.Type.Directory"
  @string "DomovoyCore.Type.String"

  defp plugin(name), do: Enum.find(Catalog.plugins(), &(&1.name == name))
  defp ids(entries), do: Enum.map(entries, & &1.id)

  describe "runner entries" do
    test "reflect runners from Core and each installed plugin" do
      plugins = %{} |> Catalog.search() |> Enum.map(& &1.plugin) |> Enum.uniq() |> Enum.sort()

      assert plugins == ["Claude Code", "Core", "Examples", "Git", "Mise"]
    end

    test "hold the runner's contract and fields" do
      assert {:ok, runner} = Catalog.runner("DomovoyMisePlugin.Runner.Trust")

      assert runner.label == "Mise Trust"
      assert runner.output == "DomovoyCore.Type.Map"
      assert runner.required == [:worktree, :mise]
      assert is_boolean(runner.extra?)

      assert {:ok, field} = Catalog.field(runner.id, "worktree")

      assert %{name: :worktree, id: "worktree", type: DomovoyCore.Type.Any, required: true} =
               field

      assert field.type_id == "DomovoyCore.Type.Any"
    end

    test "keep a field's default" do
      assert {:ok, %{default: ".", required: false}} =
               Catalog.field("DomovoyClaudeCodePlugin.Runner.AskClaude", "working_directory")
    end
  end

  describe "labels" do
    test "are unique among runners and among types" do
      labels = %{} |> Catalog.search() |> Enum.map(& &1.label)
      assert labels == Enum.uniq(labels)

      types =
        for %{app: app} <- Catalog.plugins(),
            {:ok, modules} <- [:application.get_key(app, :modules)],
            module <- modules,
            {:ok, type} <- [Catalog.type(inspect(module))] do
          type.label
        end

      assert length(types) > 20
      assert types == Enum.uniq(types)
    end

    test "prefix plugin entries and leave Core entries bare" do
      assert {:ok, %{label: "Git Worktree"}} = Catalog.type(@worktree)
      assert {:ok, %{label: "Mise Worktree"}} = Catalog.type("DomovoyMisePlugin.Type.Worktree")
      assert {:ok, %{label: "Directory"}} = Catalog.type(@directory)

      assert {:ok, %{label: "Claude Detect"}} =
               Catalog.runner("DomovoyClaudeCodePlugin.Runner.Detect")

      assert {:ok, %{label: "Mise Detect"}} = Catalog.runner("DomovoyMisePlugin.Runner.Detect")
      assert {:ok, %{label: "FileExists"}} = Catalog.runner("DomovoyCore.Runner.FileExists")
    end
  end

  describe "plugins" do
    test "show installed plugins as not verified" do
      for name <- ["Core", "Git", "Mise", "Claude Code", "Examples"] do
        assert %{installed?: true, verified?: false} = plugin(name)
      end
    end

    test "show plugins with no application as not installed" do
      for name <- ["GitHub", "Linear", "Slack"] do
        assert %{installed?: false, verified?: false} = plugin(name)
      end
    end
  end

  describe "hidden entries" do
    test "can't be resolved or found" do
      all = ids(Catalog.search(%{}))

      for module <- Curated.hidden(), id = inspect(module) do
        assert Catalog.runner(id) == :error
        assert Catalog.type(id) == :error
        refute id in all
      end
    end

    test "strings that aren't catalog ids resolve to nothing" do
      for id <- ["Elixir.System", "System", "", :atom, nil, 1, DomovoyCore.Runner.FileExists] do
        assert Catalog.runner(id) == :error
        assert Catalog.type(id) == :error
        assert Catalog.validator(id) == :error
      end
    end
  end

  describe "search/1" do
    test "finds a runner by exact output type" do
      assert ids(Catalog.search(%{output: @directory})) == [
               "DomovoyGitPlugin.Runner.WorktreeDirectory"
             ]
    end

    test "finds runners by exact input type" do
      assert "DomovoyGitPlugin.Runner.WorktreeDirectory" in ids(
               Catalog.search(%{input: @worktree})
             )
    end

    test "finds runners by part of a label, module or plugin, ignoring case" do
      assert "DomovoyGitPlugin.Runner.WorktreeResolve" in ids(
               Catalog.search(%{label: "worktreeres"})
             )

      assert "DomovoyMisePlugin.Runner.Trust" in ids(
               Catalog.search(%{module: "miseplugin.runner"})
             )

      assert "DomovoyMisePlugin.Runner.Trust" in ids(Catalog.search(%{plugin: "mise"}))
      assert Enum.all?(Catalog.search(%{plugin: "mise"}), &(&1.plugin == "Mise"))
    end

    test "matches free text against labels, plugins and type labels" do
      assert "DomovoyGitPlugin.Runner.WorktreeDirectory" in ids(
               Catalog.search(%{text: "git worktree"})
             )
    end

    test "requires every filter" do
      assert Catalog.search(%{plugin: "core", output: @directory}) == []
    end

    test "a filter of an unknown key or shape matches nothing" do
      assert Catalog.search(%{"output" => @directory}) == []
      assert Catalog.search(%{label: 1}) == []
    end
  end

  describe "adapters/2" do
    test "returns runners whose output and field match exactly" do
      assert ids(Catalog.adapters(@worktree, @directory)) == [
               "DomovoyGitPlugin.Runner.WorktreeDirectory"
             ]
    end

    test "returns nothing when no installed runner converts" do
      assert Catalog.adapters("DomovoyClaudeCodePlugin.Type.ClaudeAnswer", @string) == []
    end

    test "ignores Any fields" do
      refute "DomovoyMisePlugin.Runner.Trust" in ids(
               Catalog.adapters(@worktree, "DomovoyCore.Type.Map")
             )

      assert Catalog.adapters("DomovoyCore.Type.Any", "DomovoyCore.Type.Map") == []
    end
  end

  describe "validators" do
    test "curate every installed plugin and example validator except the hidden runner's" do
      installed =
        for app <- [
              :domovoy_git_plugin,
              :domovoy_mise_plugin,
              :domovoy_claude_code_plugin,
              :domovoy
            ],
            {:ok, modules} <- [:application.get_key(app, :modules)],
            module <- modules,
            Code.ensure_loaded?(module),
            DomovoyCore.Validator in behaviours(module) do
          module
        end

      curated = Enum.map(Curated.validators(), & &1.module)

      # The raising validator is a test fixture that only hand-built Core workflows name.
      uncurated = [
        DomovoyClaudeCodePlugin.Reflect.Validator.WindowIsValid,
        Domovoy.RaisingValidator
      ]

      assert Enum.sort(installed -- uncurated) == Enum.sort(curated)
    end

    test "name real fields in requires" do
      for %{requires: requires} = validator <- Curated.validators() do
        fits? =
          Enum.any?(Catalog.search(%{}), fn runner ->
            fields = Enum.map(runner.fields, & &1.id)
            Enum.all?(requires, &(&1 in fields))
          end)

        assert fits?, "no runner has the fields of #{inspect(validator.module)}"
      end
    end

    test "split a runner's own from the curated ones it can add" do
      %{inherited: inherited, curated: curated} =
        Catalog.validators_for("DomovoyClaudeCodePlugin.Runner.AskClaude")

      assert "DomovoyClaudeCodePlugin.Validator.AskOptionsAreValid" in ids(inherited)
      refute "DomovoyClaudeCodePlugin.Validator.AskOptionsAreValid" in ids(curated)
      assert "DomovoyClaudeCodePlugin.Validator.SessionOptionsAreValid" in ids(curated)
      refute "DomovoyGitPlugin.Validator.RemotePresent" in ids(curated)
    end

    test "list a Core runner's own validator with no description" do
      %{inherited: [inherited]} = Catalog.validators_for("DomovoyCore.Runner.WriteFile")

      assert inherited.id == "DomovoyCore.Runner.WriteFile.DataPresent"
      assert inherited.description == nil
    end

    test "are empty for an unknown runner" do
      assert Catalog.validators_for("Elixir.System") == %{inherited: [], curated: []}
    end
  end

  test "deciders are the curated list" do
    assert ids(Catalog.deciders()) == [
             "DomovoyCore.Decider.Person",
             "Domovoy.Examples.Worktree.WorktreeRouteDecider"
           ]
  end

  defp behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end
end

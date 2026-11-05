defmodule Domovoy.Composer.LiteralPolicyTest do
  use Domovoy.DataCase, async: true

  alias Domovoy.Catalog
  alias Domovoy.Catalog.Curated
  alias Domovoy.Composer
  alias Domovoy.Composer.LiteralPolicy
  alias Domovoy.ComposerFixtures

  # A real field for each type that has one. No installed runner declares the other
  # editor types, so they reach storage through a workflow input's default instead.
  @fields %{
    "DomovoyCore.Type.String" => {"DomovoyClaudeCodePlugin.Runner.AskClaude", "context"},
    "DomovoyCore.Type.Integer" => {"DomovoyClaudeCodePlugin.Runner.ListSessions", "limit"},
    "DomovoyCore.Type.Boolean" =>
      {"DomovoyClaudeCodePlugin.Runner.DescribeClaudeCode", "include_account?"},
    "DomovoyCore.Type.Path" => {"DomovoyCore.Runner.AppendFile", "path"},
    "DomovoyCore.Type.Directory" =>
      {"DomovoyClaudeCodePlugin.Runner.AskClaude", "working_directory"},
    "DomovoyCore.Type.Map" => {"DomovoyClaudeCodePlugin.Runner.AskClaude", "options"},
    "DomovoyCore.Type.Any" => {"DomovoyMisePlugin.Runner.Trust", "worktree"},
    "DomovoyCore.Type.UUID" => {"DomovoyClaudeCodePlugin.Runner.SessionSummary", "session_id"}
  }

  @samples [
    {"DomovoyCore.Type.String", "any text", "any text"},
    {"DomovoyCore.Type.String", ~s( "quoted" \u00E9\n), ~s( "quoted" \u00E9\n)},
    {"DomovoyCore.Type.Integer", "42", 42},
    {"DomovoyCore.Type.Integer", "-7", -7},
    {"DomovoyCore.Type.Float", "1.5", 1.5},
    {"DomovoyCore.Type.Float", "1", 1.0},
    {"DomovoyCore.Type.Number", "3", 3},
    {"DomovoyCore.Type.Number", "3.5", 3.5},
    {"DomovoyCore.Type.Boolean", "true", true},
    {"DomovoyCore.Type.Boolean", "false", false},
    {"DomovoyCore.Type.Path", "~/x", "~/x"},
    {"DomovoyCore.Type.File", "/no/such/file", "/no/such/file"},
    {"DomovoyCore.Type.Directory", "/no/such/dir", "/no/such/dir"},
    {"DomovoyCore.Type.Map", ~s({"a":1}), %{"a" => 1}},
    {"DomovoyCore.Type.Map", "{}", %{}},
    {"DomovoyCore.Type.Any", "null", nil},
    {"DomovoyCore.Type.Any", "[1]", [1]},
    {"DomovoyCore.Type.UUID", "a1b2c3d4-0000-0000-0000-00000000000f",
     "a1b2c3d4-0000-0000-0000-00000000000f"},
    {"DomovoyCore.Type.URI", "https://example.com/a?b=1", "https://example.com/a?b=1"},
    {"DomovoyCore.Type.Email", "dev@example.com", "dev@example.com"}
  ]

  @rejected [
    {"DomovoyCore.Type.Integer", "not an int"},
    {"DomovoyCore.Type.Integer", "1.5"},
    {"DomovoyCore.Type.Integer", "1 "},
    {"DomovoyCore.Type.Integer", ""},
    {"DomovoyCore.Type.Float", "1.5x"},
    {"DomovoyCore.Type.Float", "1e999"},
    {"DomovoyCore.Type.Number", "two"},
    {"DomovoyCore.Type.Boolean", "yes"},
    {"DomovoyCore.Type.Boolean", "TRUE"},
    {"DomovoyCore.Type.Path", ""},
    {"DomovoyCore.Type.File", "   "},
    {"DomovoyCore.Type.Directory", ""},
    {"DomovoyCore.Type.Map", "[1]"},
    {"DomovoyCore.Type.Map", "{"},
    {"DomovoyCore.Type.Any", "{"},
    {"DomovoyCore.Type.UUID", "abcdefghijklmnop"},
    {"DomovoyCore.Type.URI", "../relative"},
    {"DomovoyCore.Type.Email", "nobody"}
  ]

  test "every Core type is an editor, bind-only or hidden, catching list drift" do
    {:ok, modules} = :application.get_key(:domovoy_core, :modules)
    hidden = Enum.map(Curated.hidden(), &inspect/1)
    known = LiteralPolicy.editor_types() ++ LiteralPolicy.bind_only_types() ++ hidden

    core_types = for module <- modules, DomovoyCore.Type.type?(module), do: inspect(module)

    assert core_types != []
    assert core_types -- known == []
  end

  test "an editor exists only on the allowlist" do
    for type <- LiteralPolicy.editor_types(), do: refute(LiteralPolicy.editor(type) == :bind_only)

    for type <- LiteralPolicy.bind_only_types(),
        do: assert(LiteralPolicy.editor(type) == :bind_only)
  end

  test "plugin types, unknown types and non-strings are bind-only" do
    for type <- ["DomovoyGitPlugin.Type.Worktree", "Elixir.System", nil, 1] do
      assert LiteralPolicy.editor(type) == :bind_only
      assert LiteralPolicy.parse(type, "x") == :error
    end
  end

  test "bind-only types parse nothing, so no cast runs" do
    for type <- LiteralPolicy.bind_only_types() do
      assert LiteralPolicy.parse(type, "2026-10-30") == :error
    end
  end

  test "parses each allowlisted sample" do
    for {type, raw, value} <- @samples do
      assert LiteralPolicy.parse(type, raw) == {:ok, value}, "#{type} #{raw}"
    end
  end

  test "parses a URI through Core" do
    assert {:ok, parsed} = LiteralPolicy.parse("DomovoyCore.Type.URI", "https://example.com")
    assert to_string(parsed) == "https://example.com"
  end

  test "an uppercase UUID parses to Core's form" do
    assert LiteralPolicy.parse("DomovoyCore.Type.UUID", "A1B2C3D4-0000-0000-0000-00000000000F") ==
             {:ok, "a1b2c3d4-0000-0000-0000-00000000000f"}
  end

  test "refuses bad text with a bare :error, never the value" do
    for {type, raw} <- @rejected do
      assert LiteralPolicy.parse(type, raw) == :error, "#{type} #{raw}"
    end
  end

  test "refuses a raw value that isn't text" do
    assert LiteralPolicy.parse("DomovoyCore.Type.Integer", 1) == :error
    assert LiteralPolicy.parse("DomovoyCore.Type.String", nil) == :error
  end

  test "the samples cover every editor type, and a type with no real field has no runner" do
    types = @samples |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert Enum.sort(types) == Enum.sort(LiteralPolicy.editor_types())

    for type <- types, not is_map_key(@fields, type) do
      assert Catalog.search(%{input: type}) == [], "#{type} has a real field now"
    end
  end

  test "every sample is stored by real ops, unchanged through a save and reload, then parses" do
    {:ok, draft} = Composer.create_draft(%{title: "Literals"})
    samples = Enum.with_index(@samples)

    document =
      ComposerFixtures.edit_all(draft.document, Enum.flat_map(samples, &store_ops/1))

    assert document |> Jason.encode!() |> Jason.decode!() == document
    assert {:ok, _saved} = Composer.save_document(draft, document)
    assert {:ok, %{document: reloaded}} = Composer.get_draft(draft.id)

    for {{type, raw, value}, _index} = sample <- samples do
      stored = stored_raw(reloaded, sample)

      assert stored === raw, "#{type} #{raw}"
      assert LiteralPolicy.parse(type, stored) == {:ok, value}, "#{type} #{raw}"
    end
  end

  defp store_ops({{type, raw, _value}, index}) do
    name = "sample_#{index}"

    case @fields do
      %{^type => {runner, field}} ->
        [
          {:add_node, "main", runner, name},
          {:set_literal, "main", name, field, raw, replace_binding: false}
        ]

      _no_field ->
        [{:put_input, name, %{"type" => type, "default" => raw}}]
    end
  end

  defp stored_raw(document, {{type, _raw, _value}, index}) do
    name = "sample_#{index}"

    case @fields do
      %{^type => {_runner, field}} ->
        document["vertices"]["main"]["nodes"][name]["inputs"][field]["literal"]

      _no_field ->
        document["inputs"][name]["default"]
    end
  end
end

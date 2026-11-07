defmodule Domovoy.Composer.RunInputsTest do
  # Not async: trace patterns are global.
  use ExUnit.Case, async: false

  import Domovoy.ComposerFixtures, only: [edit_all: 2]

  alias Domovoy.Catalog
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Examples.Definitions
  alias Domovoy.NoExecutionTrace

  @string "DomovoyCore.Type.String"
  @integer "DomovoyCore.Type.Integer"
  @boolean "DomovoyCore.Type.Boolean"
  @directory "DomovoyCore.Type.Directory"
  @date "DomovoyCore.Type.Date"
  @float "Domovoy.Examples.Cracow.Float"

  defp inputs(attrs) do
    edit_all(
      Document.new("inputs"),
      Enum.map(attrs, fn {name, input} -> {:put_input, name, input} end)
    )
  end

  defp bound_string do
    edit_all(inputs(%{"name" => %{"type" => @string}}), [
      {:add_node, "main", "DomovoyGitPlugin.Runner.WorktreeName", "worktree_name"},
      {:bind, "main", "worktree_name", "target_branch", "name", replace_literal: false}
    ])
  end

  defp code(document, params) do
    assert {:error, [%{code: code}]} = RunInputs.parse(document, params)
    code
  end

  describe "fields/1" do
    test "gives each input's name, type label, editor, default, required and bound" do
      document = hd(Definitions.all()).document

      assert %{
               name: "base_branch",
               type: "String",
               editor: :text,
               default: "main",
               required: false,
               bound: true
             } = Enum.find(RunInputs.fields(document), &(&1.name == "base_branch"))
    end

    test "reads a bind-only type by its primitive, and a required Date as none" do
      document =
        inputs(%{
          "area" => %{"type" => @float},
          "day" => %{"type" => @date, "required" => true}
        })

      assert [%{name: "area", editor: :float}, %{name: "day", editor: :none, required: true}] =
               RunInputs.fields(document)
    end
  end

  describe "parse/2" do
    test "coerces by type" do
      document =
        inputs(%{
          "rooms" => %{"type" => @integer},
          "area" => %{"type" => @float},
          "balcony" => %{"type" => @boolean},
          "district" => %{"type" => @string}
        })

      assert RunInputs.parse(document, %{
               "rooms" => "3",
               "area" => "58.5",
               "balcony" => "false",
               "district" => "Krowodrza"
             }) ==
               {:ok,
                %{"rooms" => 3, "area" => 58.5, "balcony" => false, "district" => "Krowodrza"}}
    end

    test "refuses a map, a list, broken UTF-8 and NUL, and text that doesn't parse" do
      document = inputs(%{"note" => %{"type" => @string}})
      number = inputs(%{"rooms" => %{"type" => @integer}})

      for bad <- [%{"a" => "b"}, ["a"], <<0xFF>>, "a" <> <<0>>] do
        assert code(document, %{"note" => bad}) == :invalid
      end

      assert code(number, %{"rooms" => "three"}) == :invalid
    end

    test "never holds a value in an error" do
      document = inputs(%{"rooms" => %{"type" => @integer}})

      assert RunInputs.parse(document, %{"rooms" => "secret"}) ==
               {:error, [%{name: "rooms", code: :invalid}]}
    end

    test "a blank field with a default is left to Core, and an optional unbound one omitted" do
      document =
        inputs(%{
          "floor" => %{"type" => @integer, "default" => "1"},
          "note" => %{"type" => @string}
        })

      assert RunInputs.parse(document, %{"floor" => " ", "note" => ""}) == {:ok, %{}}
      assert RunInputs.parse(document, %{}) == {:ok, %{}}
    end

    test "a blank required input, or a blank bound one, with no default is missing" do
      assert code(inputs(%{"name" => %{"type" => @string, "required" => true}}), %{}) == :missing
      assert code(bound_string(), %{"name" => ""}) == :missing
    end

    test "a required Date can't be typed: blank is missing and text is invalid" do
      document = inputs(%{"day" => %{"type" => @date, "required" => true}})

      assert code(document, %{"day" => ""}) == :missing
      assert code(document, %{"day" => "2026-11-06"}) == :invalid
    end

    test "a path must be absolute, also through a default" do
      document = inputs(%{"repo" => %{"type" => @directory}})
      dotted = inputs(%{"repo" => %{"type" => @directory, "default" => "."}})
      absolute = inputs(%{"repo" => %{"type" => @directory, "default" => "/srv"}})

      assert code(document, %{"repo" => "relative/path"}) == :relative
      assert code(document, %{"repo" => "~/repo"}) == :relative
      assert code(dotted, %{"repo" => ""}) == :relative
      assert RunInputs.parse(dotted, %{"repo" => "/srv"}) == {:ok, %{"repo" => "/srv"}}
      assert RunInputs.parse(absolute, %{"repo" => ""}) == {:ok, %{}}
    end

    test "makes no file-system call, and the trace sees one when there is one" do
      document = inputs(%{"repo" => %{"type" => @directory}})

      calls =
        file_calls(fn ->
          assert RunInputs.parse(document, %{"repo" => "/no/such/directory"}) ==
                   {:ok, %{"repo" => "/no/such/directory"}}
        end)

      assert calls == []
      assert file_calls(fn -> File.exists?("/no/such/directory") end) != []
    end
  end

  describe "a choice" do
    @choice %{"inputs" => %{"district" => @string, "rooms" => @integer}}

    test "shows its fields, neither required nor bound" do
      assert [
               %{name: "district", editor: :text, required: false, bound: false, default: nil},
               %{name: "rooms", editor: :integer}
             ] = RunInputs.choice_fields(@choice)
    end

    test "omits a blank field, since Core keeps the earlier value" do
      assert RunInputs.parse_choice(@choice, %{"district" => "", "rooms" => "4"}) ==
               {:ok, %{"rooms" => 4}}
    end

    test "refuses text that doesn't parse, and what isn't text" do
      assert RunInputs.parse_choice(@choice, %{"rooms" => "x"}) ==
               {:error, [%{name: "rooms", code: :invalid}]}

      assert RunInputs.parse_choice(@choice, %{"district" => ["x"]}) ==
               {:error, [%{name: "district", code: :invalid}]}
    end
  end

  describe "effects/1" do
    test "lists undeclared runners and leaves out pure ones" do
      document =
        edit_all(Document.new("effects"), [
          {:add_node, "main", "DomovoyCore.Runner.ReadFile", "read"},
          {:add_node, "main", "DomovoyCore.Runner.BinaryToString", "text"},
          {:add_node, "main", "DomovoyCore.Runner.WriteFile", "write"},
          {:add_node, "main", "Domovoy.Examples.Cracow.Normalize", "normalize"}
        ])

      ids = document |> RunInputs.effects() |> Enum.map(& &1.id)

      assert "Domovoy.Examples.Cracow.Normalize" in ids
      assert "DomovoyCore.Runner.WriteFile" in ids
      refute "DomovoyCore.Runner.ReadFile" in ids
      refute "DomovoyCore.Runner.BinaryToString" in ids
    end

    test "skips a runner the catalog doesn't know, and lists one runner once" do
      document =
        edit_all(Document.new("effects"), [
          {:add_node, "main", "DomovoyCore.Runner.WriteFile", "one"},
          {:add_node, "main", "DomovoyCore.Runner.WriteFile", "two"}
        ])

      gone = put_in(document["vertices"]["main"]["nodes"]["two"]["runner"], "Gone.Runner")

      assert [%{id: "DomovoyCore.Runner.WriteFile"}] = RunInputs.effects(document)
      assert [%{id: "DomovoyCore.Runner.WriteFile"}] = RunInputs.effects(gone)
    end

    test "Core 0.3.3's file runners are in the catalog with labels of their own" do
      labels = %{} |> Catalog.search() |> Enum.map(& &1.label)

      assert {:ok, %{label: read}} = Catalog.runner("DomovoyCore.Runner.ReadFile")
      assert {:ok, %{label: text}} = Catalog.runner("DomovoyCore.Runner.BinaryToString")

      assert Enum.count(labels, &(&1 == read)) == 1
      assert Enum.count(labels, &(&1 == text)) == 1
    end
  end

  defp file_calls(fun), do: NoExecutionTrace.calls_to([File, :file, :prim_file], fun)
end

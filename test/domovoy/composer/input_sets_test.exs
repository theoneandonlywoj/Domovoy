defmodule Domovoy.Composer.InputSetsTest do
  use Domovoy.RunCase

  import Domovoy.ComposerFixtures
  import Ecto.Query

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.InputSet
  alias Domovoy.Composer.InputSets
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs

  @float "Domovoy.Examples.Cracow.Float"
  @string "DomovoyCore.Type.String"
  @uuid "DomovoyCore.Type.UUID"
  @directory "DomovoyCore.Type.Directory"
  @date "DomovoyCore.Type.Date"

  @typed %{
    "area" => "58.5",
    "district" => "Krowodrza",
    "id" => "5f0c1c43-31a4-4c8e-9a43-7d6f3b1d2a10",
    "repo" => "/secret/path",
    "day" => "2026-11-08"
  }

  @inputs [
    {"area", @float},
    {"district", @string},
    {"id", @uuid},
    {"repo", @directory},
    {"day", @date}
  ]

  defp document do
    edit_all(
      Document.new("sets"),
      for({name, type} <- @inputs, do: {:put_input, name, %{"type" => type}})
    )
  end

  defp sets(draft), do: Repo.all(from(set in InputSet, where: set.draft_id == ^draft.id))

  describe "storage policy" do
    test "keeps a bind-only float as its primitive, and a uuid or path only when asked" do
      draft = draft!(document())
      fields = RunInputs.fields(draft.document)

      assert {:ok, plain} = InputSets.save(draft.id, "Plain", fields, @typed, [])

      assert plain.values == %{
               "area" => %{"type" => @float, "text" => "58.5"},
               "district" => %{"type" => @string, "text" => "Krowodrza"}
             }

      assert {:ok, opted} =
               InputSets.save(draft.id, "Opted", fields, @typed, ["id", "repo", "day"])

      assert opted.values["id"] == %{"type" => @uuid, "text" => @typed["id"]}
      assert opted.values["repo"] == %{"type" => @directory, "text" => "/secret/path"}
      refute is_map_key(opted.values, "day")
    end

    test "leaves out blank and unsafe text, and refuses a blank or unsafe name" do
      draft = draft!(document())
      fields = RunInputs.fields(draft.document)
      params = %{"area" => " ", "district" => "a\0b"}

      assert {:ok, %InputSet{values: values}} = InputSets.save(draft.id, "x", fields, params, [])
      assert values == %{}

      for name <- ["", "  ", "a\0b", <<0xFF>>, nil, %{}] do
        assert InputSets.save(draft.id, name, fields, @typed, []) == {:error, :invalid_name}
      end
    end
  end

  describe "load/2" do
    test "fills eligible text, holds opt-in text apart, and names what drifted" do
      draft = draft!(document())
      fields = RunInputs.fields(draft.document)
      {:ok, set} = InputSets.save(draft.id, "Sample", fields, @typed, ["repo"])

      changed =
        edit_all(draft.document, [
          {:remove_input, "district"},
          {:put_input, "area", %{"type" => @string}}
        ])

      assert InputSets.load(set, fields) == %{
               params: %{"area" => "58.5", "district" => "Krowodrza"},
               reused: %{"repo" => "/secret/path"},
               drift: [],
               blank: ["day", "id"]
             }

      assert %{params: params, reused: reused, drift: drift} =
               InputSets.load(set, RunInputs.fields(changed))

      assert params == %{}
      assert reused == %{"repo" => "/secret/path"}

      assert drift == [
               %{name: "area", kind: :type_changed},
               %{name: "district", kind: :removed}
             ]
    end
  end

  describe "names" do
    test "a second save under a name changes nothing, and two at once leave one row" do
      draft = draft!(document())
      fields = RunInputs.fields(draft.document)

      assert {:ok, first} = InputSets.save(draft.id, "Sample", fields, @typed, [])

      assert InputSets.save(draft.id, "Sample", fields, %{"area" => "1"}, []) ==
               {:error, :name_taken}

      assert [^first] = sets(draft)

      results =
        1..2
        |> Enum.map(fn _n ->
          Task.async(fn -> InputSets.save(draft.id, "Racing", fields, @typed, []) end)
        end)
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, _set}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :name_taken})) == 1
      assert length(sets(draft)) == 2
    end

    test "another draft may use the same name, and a missing draft has none" do
      fields = RunInputs.fields(document())
      assert {:ok, _set} = InputSets.save(draft!(document()).id, "Sample", fields, @typed, [])
      assert {:ok, _set} = InputSets.save(draft!(document()).id, "Sample", fields, @typed, [])

      assert InputSets.save(Ecto.UUID.generate(), "Sample", fields, @typed, []) ==
               {:error, :not_found}

      assert InputSets.save("not-a-uuid", "Sample", fields, @typed, []) == {:error, :not_found}
    end
  end

  describe "ids" do
    test "fetch and delete refuse a malformed id and another draft's set" do
      draft = draft!(document())
      other = draft!(document())
      fields = RunInputs.fields(draft.document)
      {:ok, set} = InputSets.save(draft.id, "Sample", fields, @typed, [])

      for {draft_id, id} <- [{draft.id, "not-a-uuid"}, {other.id, set.id}, {draft.id, 7}] do
        assert InputSets.fetch(draft_id, id) == {:error, :not_found}
        assert InputSets.delete(draft_id, id) == {:error, :not_found}
      end

      assert InputSets.list(other.id) == []
      assert InputSets.list("not-a-uuid") == []
      assert {:ok, ^set} = InputSets.fetch(draft.id, set.id)
      assert InputSets.list(draft.id) == [set]
      assert InputSets.delete(draft.id, set.id) == :ok
      assert InputSets.fetch(draft.id, set.id) == {:error, :not_found}
    end
  end

  describe "deleting" do
    test "a draft deletes its sets, and its run keeps a nil input_set_id" do
      draft = draft!(leak_run(), "Leak")
      fields = RunInputs.fields(draft.document)
      {:ok, set} = InputSets.save(draft.id, "Sample", fields, %{"mode" => "succeed"}, [])

      {:ok, values} = RunInputs.parse(draft.document, %{"secret" => "s", "mode" => "succeed"})
      attrs = Map.put(start_attrs(draft, values), :input_set_id, set.id)
      assert {:ok, run_id} = Composer.start_run(attrs)
      assert %Run{input_set_id: set_id} = Repo.get!(Run, run_id)
      assert set_id == set.id
      await_phase(open!(run_id), "finished")

      assert {:ok, _deleted} = Composer.delete_draft(draft)
      assert sets(draft) == []
      assert %Run{draft_id: nil, input_set_id: nil} = Repo.get!(Run, run_id)
    end
  end

  describe "with the flag off" do
    setup do
      Application.put_env(:domovoy, :composer_runs_enabled, false)
    end

    test "every function refuses, and so do the composer's delegates" do
      for {name, arity} <- InputSets.__info__(:functions) do
        args = List.duplicate(:junk, arity)
        assert apply(InputSets, name, args) == {:error, :runs_disabled}, "#{name}/#{arity}"
      end

      assert Composer.list_input_sets(:junk) == {:error, :runs_disabled}
      assert Composer.save_input_set(:a, :b, :c, :d, :e) == {:error, :runs_disabled}
      assert Composer.fetch_input_set(:a, :b) == {:error, :runs_disabled}
      assert Composer.delete_input_set(:a, :b) == {:error, :runs_disabled}
      assert Composer.load_input_set(:a, :b) == {:error, :runs_disabled}
    end
  end
end

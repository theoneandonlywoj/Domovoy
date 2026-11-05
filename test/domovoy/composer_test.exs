defmodule Domovoy.ComposerTest do
  use Domovoy.DataCase, async: true

  alias Domovoy.ComposerFixtures
  alias Domovoy.Composer
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Issue
  alias DomovoyCore.Name

  defp draft!(title \\ "My draft") do
    {:ok, draft} = Composer.create_draft(%{title: title})
    draft
  end

  defp moved(document, x) do
    {:ok, updated, :layout} = Composer.edit(document, {:move, :workflow, "main", x, 0})
    updated
  end

  describe "create_draft/1" do
    test "stores a starter stage as the start" do
      draft = draft!()

      assert draft.title == "My draft"
      assert draft.document["start"] == "main"
      assert draft.document["vertices"]["main"]["kind"] == "stage"
    end

    test "accepts form params" do
      assert {:ok, %Draft{title: "Form"}} = Composer.create_draft(%{"title" => "Form"})
    end

    test "slugifies the name, with a suffix keeping names apart" do
      name = draft!("My Draft! #1").document["name"]

      assert name =~ ~r/\Amy_draft_1_[0-9a-f]{6}\z/
      refute draft!("My Draft! #1").document["name"] == name
    end

    test "falls back to workflow when the title has no usable characters" do
      assert draft!("!!!").document["name"] =~ ~r/\Aworkflow_[0-9a-f]{6}\z/
    end

    test "keeps the name within the engine's limit" do
      name = draft!(String.duplicate("a", 255)).document["name"]

      assert String.length(name) == 128
      assert Name.valid?(name)
    end

    test "refuses a blank, overlong or NUL title without raising" do
      for title <- ["", "   ", nil, String.duplicate("a", 256), "a\0b", <<0xFF>>, 1] do
        assert {:error, %Ecto.Changeset{} = changeset} = Composer.create_draft(%{title: title})
        assert errors_on(changeset)[:title]
      end
    end

    test "counts a title in codepoints, as its varchar(255) column does" do
      combining = String.duplicate("e\u0301", 200)
      assert String.length(combining) == 200

      assert {:error, %Ecto.Changeset{} = changeset} = Composer.create_draft(%{title: combining})
      assert errors_on(changeset)[:title]

      longest = String.duplicate("\u00E9", 255)
      assert %Draft{title: ^longest} = draft!(longest)
    end
  end

  describe "get_draft/1" do
    test "finds a draft by id" do
      draft = draft!()
      assert {:ok, %Draft{id: id}} = Composer.get_draft(draft.id)
      assert id == draft.id
    end

    test "treats malformed and unknown ids alike" do
      for id <- ["nope", "", nil, 1, %{}, Ecto.UUID.generate()] do
        assert Composer.get_draft(id) == {:error, :not_found}
      end
    end
  end

  describe "list_drafts/0" do
    defp saved_at!(draft, updated_at) do
      Repo.update_all(from(row in Draft, where: row.id == ^draft.id),
        set: [updated_at: updated_at]
      )

      draft
    end

    test "lists saved drafts" do
      draft = draft!()
      assert draft.id in Enum.map(Composer.list_drafts(), & &1.id)
    end

    test "breaks a same-second tie by title, not by the random id" do
      second = ~U[2030-01-01 00:00:00Z]

      # Many pairs, because a tie on a random id only sometimes gives the wrong order.
      pairs =
        for index <- 1..8 do
          {saved_at!(draft!("Beta #{index}"), second),
           saved_at!(draft!("Alpha #{index}"), second)}
        end

      ids = Enum.map(Composer.list_drafts(), & &1.id)

      for {beta, alpha} <- pairs do
        assert Enum.find_index(ids, &(&1 == alpha.id)) < Enum.find_index(ids, &(&1 == beta.id))
      end
    end

    test "the most recent save still comes first" do
      older = saved_at!(draft!("Alpha"), ~U[2030-01-01 00:00:00Z])
      newer = saved_at!(draft!("Beta"), ~U[2030-01-01 00:00:01Z])

      ids = Enum.map(Composer.list_drafts(), & &1.id)

      assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))
    end
  end

  describe "save_document/2" do
    test "persists an incomplete draft" do
      draft = draft!()

      {:ok, document, :definition} =
        Composer.edit(
          draft.document,
          {:add_node, "main", "DomovoyMisePlugin.Runner.Trust", "trust"}
        )

      assert {:ok, saved} = Composer.save_document(draft, document)
      assert saved.lock_version > draft.lock_version

      assert {:ok, %Draft{document: ^document}} = Composer.get_draft(draft.id)
    end

    test "round-trips scenario A through Postgres unchanged" do
      document = ComposerFixtures.scenario_a()

      assert {:ok, _saved} = Composer.save_document(draft!(), document)
      assert [%Draft{document: ^document} | _rest] = Composer.list_drafts()
    end

    test "gives a stale tab :conflict and leaves the other save intact" do
      draft = draft!()
      {:ok, tab_a} = Composer.get_draft(draft.id)
      {:ok, tab_b} = Composer.get_draft(draft.id)
      saved = moved(draft.document, 100)

      assert {:ok, _saved} = Composer.save_document(tab_a, saved)
      assert {:error, :conflict} = Composer.save_document(tab_b, moved(draft.document, 200))
      assert {:ok, %Draft{document: ^saved}} = Composer.get_draft(draft.id)
    end

    test "after a conflict, loading the latest row and resetting history can save again" do
      draft = draft!()
      {:ok, tab_a} = Composer.get_draft(draft.id)
      {:ok, tab_b} = Composer.get_draft(draft.id)
      saved = moved(draft.document, 100)

      {:ok, _saved} = Composer.save_document(tab_a, saved)
      {:error, :conflict} = Composer.save_document(tab_b, moved(draft.document, 200))

      {:ok, latest} = Composer.get_draft(draft.id)
      assert latest.document == saved
      assert Composer.undo(Composer.reset_history()) == :empty
      assert {:ok, _saved} = Composer.save_document(latest, moved(latest.document, 300))
    end

    test "gives :gone for a deleted row" do
      draft = draft!()
      assert {:ok, _deleted} = Composer.delete_draft(draft)

      assert {:error, :gone} = Composer.save_document(draft, moved(draft.document, 100))
    end

    test "gives :conflict for a stale struct saving its own unchanged document" do
      draft = draft!()
      newer = moved(draft.document, 100)
      {:ok, _saved} = Composer.save_document(draft, newer)

      assert {:error, :conflict} = Composer.save_document(draft, draft.document)
      assert {:ok, %Draft{document: ^newer}} = Composer.get_draft(draft.id)
    end

    test "gives :gone for a deleted row saving its own unchanged document" do
      draft = draft!()
      {:ok, _deleted} = Composer.delete_draft(draft)

      assert {:error, :gone} = Composer.save_document(draft, draft.document)
    end

    test "an unchanged document on a current struct saves and bumps the lock" do
      draft = draft!()

      assert {:ok, saved} = Composer.save_document(draft, draft.document)
      assert saved.lock_version == draft.lock_version + 1
      assert saved.document == draft.document

      assert {:ok, %Draft{lock_version: lock_version}} = Composer.get_draft(draft.id)
      assert lock_version == saved.lock_version
      assert {:ok, _saved} = Composer.save_document(saved, saved.document)
    end
  end

  describe "delete_draft/1" do
    test "removes the row" do
      draft = draft!()

      assert {:ok, _deleted} = Composer.delete_draft(draft)
      assert Composer.get_draft(draft.id) == {:error, :not_found}
    end

    test "gives :gone the second time" do
      draft = draft!()

      assert {:ok, _deleted} = Composer.delete_draft(draft)
      assert Composer.delete_draft(draft) == {:error, :gone}
    end
  end

  describe "delegates" do
    test "edit a document and undo it through history" do
      document = draft!().document
      {:ok, updated, kind} = Composer.edit(document, {:add_stage, "second"})

      history = Composer.push_history(Composer.reset_history(), document, kind)

      refute Composer.history_empty?(history)
      assert {^document, :definition, rest} = Composer.undo(history)
      assert Composer.history_empty?(rest)
      assert %{document: ^updated} = Composer.preview(document, {:add_stage, "second"})
    end

    test "a rejected edit is an Issue" do
      assert {:error, %Issue{}} = Composer.edit(draft!().document, {:add_stage, "main"})
    end
  end
end

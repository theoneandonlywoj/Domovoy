defmodule Domovoy.Examples.SeedsTest do
  use Domovoy.DataCase, async: false

  import ExUnit.CaptureIO

  alias Domovoy.Composer
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Issue
  alias Domovoy.Examples.Seeds

  @engine_names ["cracow_prices", "cracow_review", "create_worktree"]

  # `make db-seed-test` commits the seeds to this database, outside the sandbox. These
  # tests count on starting without them; the delete rolls back with the test.
  setup do
    Repo.delete_all(Draft)
    :ok
  end

  # The real file, as `mix run priv/repo/seeds.exs` reads it.
  defp run_seeds do
    capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
  end

  defp drafts, do: Composer.list_drafts()

  defp draft(name), do: Enum.find(drafts(), &(&1.document["name"] == name))

  defp engine_names, do: drafts() |> Enum.map(& &1.document["name"]) |> Enum.sort()

  test "two runs leave exactly the three titled drafts" do
    assert run_seeds() =~ "create_worktree: created"
    first = drafts()

    assert Enum.sort(Enum.map(first, & &1.title)) == [
             "Cracow house price",
             "Cracow house price review",
             "Create a worktree"
           ]

    assert engine_names() == @engine_names

    assert run_seeds() =~ "create_worktree: kept"
    assert drafts() == first
  end

  test "an edited draft survives a re-run" do
    run_seeds()
    seeded = draft("create_worktree")

    edited = put_in(seeded.document, ["inputs", "base_branch", "default"], "develop")
    {:ok, saved} = Composer.save_document(seeded, edited)
    {:ok, renamed} = Composer.save_title(saved, "My worktree flow")

    run_seeds()

    assert draft("create_worktree") == renamed
    assert length(drafts()) == 3
  end

  test "a run interrupted between the drafts converges, leaving the first alone" do
    assert [
             {"create_worktree", :created},
             {"cracow_prices", :created},
             {"cracow_review", :created}
           ] = Seeds.run()

    {:ok, _deleted} = Composer.delete_draft(draft("cracow_prices"))
    kept = draft("create_worktree")

    assert [
             {"create_worktree", :kept},
             {"cracow_prices", :created},
             {"cracow_review", :kept}
           ] = Seeds.run()

    assert engine_names() == @engine_names
    assert draft("create_worktree") == kept
  end

  test "another draft with the same title is neither touched nor taken for a seed" do
    {:ok, user_draft} = Composer.create_draft(%{title: "Create a worktree"})

    run_seeds()

    assert length(drafts()) == 4
    assert {:ok, ^user_draft} = Composer.get_draft(user_draft.id)
  end

  test "a kept draft without descriptions isn't backfilled" do
    {:ok, created} = Composer.create_draft("Mine", Document.new("create_worktree"))
    {:ok, kept} = Composer.save_document(created, created.document)

    assert {"create_worktree", :kept} in Seeds.run()

    assert {:ok, ^kept} = Composer.get_draft(kept.id)
    assert Jason.encode!(draft("create_worktree").document) == Jason.encode!(kept.document)
  end

  describe "a definition failing validation" do
    setup do
      on_exit(fn -> Application.delete_env(:domovoy, :composer_export_steps) end)

      Application.put_env(:domovoy, :composer_export_steps, %{
        build: fn _document ->
          {:error, [%Issue{code: :core_rejected, core_id: :invalid_node, target: :workflow}]}
        end
      })
    end

    test "raises with its issue codes and writes nothing" do
      assert_raise RuntimeError, ~r/create_worktree.*core_rejected.*invalid_node/, fn ->
        Seeds.run()
      end

      assert drafts() == []
    end
  end
end

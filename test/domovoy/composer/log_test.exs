defmodule Domovoy.Composer.LogTest do
  # Not async: the Logger level is global.
  use Domovoy.DataCase, async: false

  import ExUnit.CaptureLog

  alias Domovoy.Composer
  alias Domovoy.Composer.Draft
  alias Domovoy.Composer.Run
  alias Domovoy.Composer.RunInputs
  alias Domovoy.ComposerFixtures
  alias Domovoy.Repo

  require Logger

  @sentinel "sentinel-secret-value"
  @table "composer_drafts"

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp with_sentinel do
    ComposerFixtures.edit_all(ComposerFixtures.scenario_a(), [
      {:set_literal, "prepare", "ask_claude", "context", @sentinel, replace_binding: true}
    ])
  end

  test "the controls prove debug logs and Repo queries are captured" do
    log =
      capture_log(fn ->
        Logger.debug("positive-control")
        Repo.all(Draft)
        Repo.insert!(%Draft{title: "t", document: with_sentinel()})
      end)

    assert log =~ "positive-control"
    assert log =~ @table
    assert log =~ @sentinel
  end

  test "draft reads and writes log no query, so no literal" do
    document = with_sentinel()

    log =
      capture_log(fn ->
        {:ok, draft} = Composer.create_draft(%{title: "title"})
        {:ok, saved} = Composer.save_document(draft, document)
        {:ok, ^saved} = reread(saved)
        [_ | _] = Composer.list_drafts()
        {:error, :conflict} = Composer.save_document(draft, document)
        {:ok, deleted} = Composer.delete_draft(saved)
        {:error, :gone} = Composer.save_document(saved, document)
        {:error, :gone} = Composer.delete_draft(deleted)
        Logger.debug("positive-control")
      end)

    assert log =~ "positive-control"
    refute log =~ @table
    refute log =~ @sentinel
  end

  test "a refused delete and the run table's queries log nothing either" do
    {:ok, draft} = Composer.create_draft(%{title: "title"})

    %Run{
      id: Ecto.UUID.generate(),
      draft_id: draft.id,
      workflow_name: "scenario_a",
      document: with_sentinel(),
      fingerprint: "unstarted",
      start_command_id: "start"
    }
    |> Repo.insert!(log: false)

    log =
      capture_log(fn ->
        {:error, :runs_unfinished} = Composer.delete_draft(draft)
        Logger.debug("positive-control")
      end)

    assert log =~ "positive-control"
    refute log =~ "composer_runs"
    refute log =~ @table
    refute log =~ @sentinel
  end

  test "input set queries log nothing, so no typed value" do
    previous = Application.get_env(:domovoy, :composer_runs_enabled)
    Application.put_env(:domovoy, :composer_runs_enabled, true)
    on_exit(fn -> Application.put_env(:domovoy, :composer_runs_enabled, previous) end)

    {:ok, draft} = Composer.create_draft(%{title: "title"})

    {:ok, draft} =
      Composer.save_document(
        draft,
        ComposerFixtures.edit_all(draft.document, [
          {:put_input, "note", %{"type" => "DomovoyCore.Type.String"}}
        ])
      )

    fields = RunInputs.fields(draft.document)

    log =
      capture_log(fn ->
        {:ok, set} =
          Composer.save_input_set(draft.id, "Sample", fields, %{"note" => @sentinel}, [])

        {:error, :name_taken} = Composer.save_input_set(draft.id, "Sample", fields, %{}, [])
        [_set] = Composer.list_input_sets(draft.id)
        {:ok, ^set} = Composer.fetch_input_set(draft.id, set.id)
        %{params: %{"note" => @sentinel}} = Composer.load_input_set(set, fields)
        :ok = Composer.delete_input_set(draft.id, set.id)
        {:ok, _deleted} = Composer.delete_draft(draft)
        Logger.debug("positive-control")
      end)

    assert log =~ "positive-control"
    refute log =~ "composer_input_sets"
    refute log =~ @sentinel
  end

  test "analysis and export log no literal" do
    invalid =
      ComposerFixtures.edit_all(with_sentinel(), [
        {:add_node, "prepare", "DomovoyClaudeCodePlugin.Runner.ListSessions", "list"},
        {:set_literal, "prepare", "list", "limit", @sentinel, replace_binding: false}
      ])

    blank_context =
      {:set_literal, "prepare", "ask_claude", "context", " ", replace_binding: true}

    log =
      capture_log(fn ->
        assert [] = Composer.issues(with_sentinel())
        assert {:valid, _result} = Composer.validate(with_sentinel())
        assert [_ | _] = Composer.issues(invalid)
        assert {:invalid, _issues} = Composer.validate(invalid)
        assert %{new_issues: [_ | _]} = Composer.preview(with_sentinel(), blank_context)
        Logger.debug("positive-control")
      end)

    assert log =~ "positive-control"
    refute log =~ @sentinel
  end

  defp reread(saved) do
    case Composer.get_draft(saved.id) do
      {:ok, draft} when draft == saved -> {:ok, saved}
      other -> other
    end
  end
end

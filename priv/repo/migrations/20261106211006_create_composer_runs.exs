defmodule Domovoy.Repo.Migrations.CreateComposerRuns do
  use Ecto.Migration

  def change do
    create table(:composer_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :draft_id, references(:composer_drafts, type: :binary_id, on_delete: :nilify_all)
      add :workflow_name, :string, null: false
      add :document, :map, null: false
      add :fingerprint, :string, null: false
      add :start_command_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:composer_runs, [:draft_id, :inserted_at])
  end
end

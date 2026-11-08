defmodule Domovoy.Repo.Migrations.CreateComposerRunSummaries do
  use Ecto.Migration

  def change do
    create table(:composer_run_summaries, primary_key: false) do
      add :run_id, references(:composer_runs, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :committed_phase, :string
      add :outcome, :string
      add :generation, :integer
      add :committed_seq, :integer, null: false, default: 0
      add :pending_decisions, {:array, :string}, null: false, default: []
      add :error_type, :string
      add :terminal, :boolean, null: false, default: false
      add :projection_version, :integer, null: false
      add :refreshed_at, :utc_datetime_usec, null: false
    end

    create index(:composer_run_summaries, [:terminal, :refreshed_at])
    create index(:composer_runs, [:inserted_at, :id])
  end
end

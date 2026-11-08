defmodule Domovoy.Repo.Migrations.AddSourceRunIdToComposerRuns do
  use Ecto.Migration

  def change do
    alter table(:composer_runs) do
      add :source_run_id, references(:composer_runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:composer_runs, [:source_run_id])
  end
end

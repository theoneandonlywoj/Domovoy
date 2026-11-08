defmodule Domovoy.Repo.Migrations.CreateComposerInputSets do
  use Ecto.Migration

  def change do
    create table(:composer_input_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :draft_id, references(:composer_drafts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :values, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:composer_input_sets, [:draft_id, :name])

    alter table(:composer_runs) do
      add :input_set_id,
          references(:composer_input_sets, type: :binary_id, on_delete: :nilify_all)
    end
  end
end

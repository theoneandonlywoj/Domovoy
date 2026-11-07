defmodule Domovoy.Repo.Migrations.CreateComposerDrafts do
  use Ecto.Migration

  def change do
    create table(:composer_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :document, :map, null: false
      add :lock_version, :integer, default: 1, null: false

      timestamps(type: :utc_datetime)
    end
  end
end

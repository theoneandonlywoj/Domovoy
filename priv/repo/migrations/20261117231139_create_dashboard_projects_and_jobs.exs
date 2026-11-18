defmodule Domovoy.Repo.Migrations.CreateDashboardProjectsAndJobs do
  use Ecto.Migration

  def change do
    create table(:dashboard_projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :string, null: false, default: ""
      add :path, :string, null: false
      add :status, :string, null: false, default: "idle"
      add :repos, :integer, null: false, default: 0
      add :worktrees, :integer, null: false, default: 0
      add :jobs, :integer, null: false, default: 0
      add :workflows, :integer, null: false, default: 0
      add :activity, {:array, :integer}, null: false, default: List.duplicate(0, 14)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dashboard_projects, [:slug])

    create table(:dashboard_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :number, :serial, null: false
      add :title, :string, null: false
      add :workflow, :string, null: false
      add :draft_id, references(:composer_drafts, type: :binary_id, on_delete: :nilify_all)

      add :project_id,
          references(:dashboard_projects, type: :binary_id, on_delete: :restrict),
          null: false

      add :branch, :string, null: false, default: ""
      add :trigger, :string, null: false, default: "manual"
      add :status, :string, null: false, default: "queued"
      add :duration, :string, null: false, default: "—"
      add :when_label, :string, null: false, default: "queued"
      add :progress, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dashboard_jobs, [:number])
    create index(:dashboard_jobs, [:project_id])
    create index(:dashboard_jobs, [:draft_id])
  end
end

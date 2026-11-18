defmodule Domovoy.Dashboard.Job do
  @moduledoc """
  One dashboard job: a title on a branch, the workflow it runs and the project it
  belongs to.

  `number` comes from a Postgres sequence, so a new job never sends one. `workflow`
  snapshots the draft's title: deleting the draft clears `draft_id` and keeps the
  name. The project and the draft are looked up by the context and never cast.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Domovoy.Composer.Draft
  alias Domovoy.Dashboard.Project

  @type status :: :running | :queued | :succeeded | :failed | :cancelled
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @text_fields [:title, :branch]
  @seed_fields [
    :project_id,
    :number,
    :workflow,
    :trigger,
    :status,
    :duration,
    :when_label,
    :progress
  ]

  schema "dashboard_jobs" do
    field :number, :integer, read_after_writes: true
    field :title, :string
    field :workflow, :string
    field :branch, :string, default: ""
    field :trigger, :string, default: "manual"

    field :status, Ecto.Enum,
      values: [:running, :queued, :succeeded, :failed, :cancelled],
      default: :queued

    field :duration, :string, default: "—"
    field :when_label, :string, default: "queued"
    field :progress, :integer

    belongs_to :project, Project
    belongs_to :draft, Draft

    timestamps()
  end

  @doc """
  Casts a title and a branch, refusing text Postgres can't store. A `nil` branch
  falls back to `""`. The project and workflow are put by the caller afterwards.
  """
  @spec changeset(job :: t(), attrs :: map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = job, attrs) do
    job
    |> cast(attrs, @text_fields, empty_values: [nil | Ecto.Changeset.empty_values()])
    |> validate_required([:title])
    |> Project.validate_text(@text_fields)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:draft_id, message: "is not a workflow")
    |> unique_constraint(:number)
  end

  @doc """
  The seeds' changeset: `changeset/2`, then the project, number, workflow and run
  details as given.
  """
  @spec seed_changeset(job :: t(), attrs :: map()) :: Ecto.Changeset.t()
  def seed_changeset(%__MODULE__{} = job, attrs) do
    job
    |> changeset(attrs)
    |> change(Map.take(attrs, @seed_fields))
    |> validate_required([:project_id, :workflow])
  end
end

defmodule Domovoy.Dashboard do
  @moduledoc """
  The dashboard's projects and jobs, stored in Postgres.

  A job's project and draft ids come from the user, but this context owns them: it
  looks each one up and puts the key itself, so a tampered id is a field error, never
  a constraint crash.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Domovoy.Composer
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project
  alias Domovoy.Repo

  @doc "Lists projects by name, then by id."
  @spec list_projects() :: [Project.t()]
  def list_projects,
    do: Repo.all(from(project in Project, order_by: [asc: project.name, asc: project.id]))

  @doc "How many projects there are."
  @spec count_projects() :: non_neg_integer()
  def count_projects, do: Repo.aggregate(Project, :count)

  @doc """
  Finds a project. A malformed id is the same as an unknown one.
  """
  @spec get_project(id :: term()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Project{} = project <- Repo.get(Project, uuid) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "An empty project changeset, for a form."
  @spec change_project() :: Ecto.Changeset.t()
  def change_project, do: Project.changeset(%Project{}, %{})

  @doc """
  Creates an idle project with zero stats from a name, a path and a description.
  """
  @spec create_project(attrs :: map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) when is_map(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists jobs, newest number first, each with its project."
  @spec list_jobs() :: [Job.t()]
  def list_jobs,
    do: Repo.all(from(job in Job, preload: :project, order_by: [desc: job.number]))

  @doc "How many jobs are running or queued."
  @spec count_active_jobs() :: non_neg_integer()
  def count_active_jobs,
    do: Repo.aggregate(from(job in Job, where: job.status in ^[:running, :queued]), :count)

  @doc "An empty job changeset, for a form."
  @spec change_job() :: Ecto.Changeset.t()
  def change_job, do: Job.changeset(%Job{}, %{})

  @doc """
  Creates a queued job from string-keyed params: `title`, `branch`, `project_id` and
  `draft_id`. The workflow name is the draft's title. Returns the job with its project.
  """
  @spec create_job(attrs :: map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create_job(attrs) when is_map(attrs) do
    changeset = Job.changeset(%Job{}, attrs)

    changeset =
      case get_project(attrs["project_id"]) do
        {:ok, project} -> put_change(changeset, :project_id, project.id)
        {:error, :not_found} -> add_error(changeset, :project_id, "choose a project")
      end

    changeset =
      case Composer.get_draft(attrs["draft_id"]) do
        {:ok, draft} ->
          changeset |> put_change(:draft_id, draft.id) |> put_change(:workflow, draft.title)

        {:error, :not_found} ->
          add_error(changeset, :draft_id, "choose a workflow")
      end

    # :project_id already carries "choose a project" when the lookup failed.
    changeset = validate_required(changeset, [:workflow])

    with {:ok, job} <- Repo.insert(changeset), do: {:ok, Repo.preload(job, :project)}
  end
end

defmodule Domovoy.DashboardFixtures do
  @moduledoc """
  Dashboard projects and jobs, created through `Domovoy.Dashboard` with string keys,
  as a form would send them.
  """

  alias Domovoy.Composer
  alias Domovoy.Dashboard
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project

  @doc """
  Creates a project. The default name is unique, so two calls never share a slug.
  """
  @spec project!(attrs :: map()) :: Project.t()
  def project!(attrs \\ %{}) do
    defaults = %{
      "name" => "Fixture #{System.unique_integer([:positive])}",
      "path" => "~/fixture"
    }

    {:ok, project} = Dashboard.create_project(Map.merge(defaults, attrs))
    project
  end

  @doc """
  Creates a job in a project, on a new draft titled "Release" unless a `draft_id` is
  given.
  """
  @spec job!(project :: Project.t(), attrs :: map()) :: Job.t()
  def job!(%Project{} = project, attrs \\ %{}) do
    draft_id =
      Map.get_lazy(attrs, "draft_id", fn ->
        {:ok, draft} = Composer.create_draft(%{title: "Release"})
        draft.id
      end)

    defaults = %{"title" => "Ship it", "project_id" => project.id, "draft_id" => draft_id}
    {:ok, job} = Dashboard.create_job(Map.merge(defaults, attrs))
    job
  end
end

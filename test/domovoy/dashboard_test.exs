defmodule Domovoy.DashboardTest do
  use Domovoy.DataCase, async: false

  import Domovoy.DashboardFixtures

  alias Domovoy.Composer
  alias Domovoy.Dashboard
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project

  # `make db-seed-test` commits the seeds to this database, outside the sandbox. These
  # tests count on starting without them; the delete rolls back with the test.
  setup do
    Repo.delete_all(Job)
    Repo.delete_all(Project)
    :ok
  end

  @hostile [<<0>>, "a" <> <<0>> <> "b", <<0xFF, ?a>>, String.duplicate("a", 256)]

  defp project_params(overrides \\ %{}),
    do: Map.merge(%{"name" => "Nova", "path" => "~/Repos/Nova"}, overrides)

  defp job_params(project, overrides \\ %{}) do
    {:ok, draft} = Composer.create_draft(%{title: "Release"})

    Map.merge(
      %{
        "title" => "Ship it",
        "branch" => "main",
        "project_id" => project.id,
        "draft_id" => draft.id
      },
      overrides
    )
  end

  defp error_on?(changeset, field), do: Keyword.has_key?(changeset.errors, field)

  describe "projects" do
    test "a new project is idle with zero stats and is read back" do
      assert {:ok, project} = Dashboard.create_project(project_params())

      assert %Project{
               slug: "nova",
               status: :idle,
               repos: 0,
               worktrees: 0,
               jobs: 0,
               workflows: 0,
               description: ""
             } = project

      assert project.activity == List.duplicate(0, 14)
      assert [read] = Dashboard.list_projects()
      assert read.id == project.id and read.activity == List.duplicate(0, 14)
      assert Dashboard.count_projects() == 1
      assert {:ok, ^read} = Dashboard.get_project(project.id)
    end

    test "a blank name and path are refused on both fields" do
      assert {:error, changeset} = Dashboard.create_project(%{"name" => "", "path" => " "})
      assert error_on?(changeset, :name) and error_on?(changeset, :path)
      assert Dashboard.count_projects() == 0
    end

    test "a duplicate slug is refused on the name" do
      project!(%{"name" => "Borg"})

      assert {:error, changeset} = Dashboard.create_project(project_params(%{"name" => "borg"}))
      assert {"has already been taken", _opts} = changeset.errors[:name]
      assert Dashboard.count_projects() == 1
    end

    test "NUL, broken UTF-8 and over-long text are field errors, never a raise" do
      for field <- ~w(name path description), value <- @hostile do
        assert {:error, changeset} = Dashboard.create_project(project_params(%{field => value}))
        assert error_on?(changeset, String.to_existing_atom(field)), "#{field}: #{inspect(value)}"
      end

      assert Dashboard.count_projects() == 0
    end

    test "a name whose slug outgrows the column is refused on the name" do
      name = String.duplicate("İ", 255)

      assert {:error, changeset} = Dashboard.create_project(project_params(%{"name" => name}))
      assert {"is too long", _opts} = changeset.errors[:name]
      assert Dashboard.count_projects() == 0
    end

    test "an over-long name gives exactly one error" do
      for name <- [String.duplicate("a", 256), String.duplicate("!", 256)] do
        assert {:error, changeset} = Dashboard.create_project(project_params(%{"name" => name}))
        assert length(Keyword.get_values(changeset.errors, :name)) == 1, name
      end

      name = String.duplicate("İ", 255)
      assert {:error, changeset} = Dashboard.create_project(project_params(%{"name" => name}))
      assert [{"is too long", _opts}] = Keyword.get_values(changeset.errors, :name)
    end

    test "a name of symbols only has no slug" do
      assert {:error, changeset} = Dashboard.create_project(project_params(%{"name" => "!!!"}))
      assert {"must contain a letter or digit", _opts} = changeset.errors[:name]
    end

    test "a nil description is stored as empty" do
      assert {:ok, project} = Dashboard.create_project(project_params(%{"description" => nil}))
      assert project.description == ""
    end

    test "a malformed or unknown id is not found" do
      for id <- ["nope", 1, nil, Ecto.UUID.generate()],
          do: assert(Dashboard.get_project(id) == {:error, :not_found})
    end
  end

  describe "jobs" do
    test "a new job is queued, numbered, named after its draft and read back" do
      project = project!()

      assert {:ok, job} = Dashboard.create_job(job_params(project))
      assert %Job{status: :queued, workflow: "Release", branch: "main", progress: nil} = job
      assert is_integer(job.number)
      assert job.project.id == project.id

      assert [read] = Dashboard.list_jobs()
      assert read.id == job.id and read.number == job.number
      assert read.project.name == project.name
    end

    test "a nil branch is stored as empty" do
      assert {:ok, job} = Dashboard.create_job(job_params(project!(), %{"branch" => nil}))
      assert job.branch == ""
    end

    test "NUL, broken UTF-8 and over-long text are field errors, never a raise" do
      project = project!()

      for field <- ~w(title branch), value <- @hostile do
        assert {:error, changeset} = Dashboard.create_job(job_params(project, %{field => value}))
        assert error_on?(changeset, String.to_existing_atom(field)), "#{field}: #{inspect(value)}"
      end

      assert {:error, changeset} = Dashboard.create_job(job_params(project, %{"title" => ""}))
      assert error_on?(changeset, :title)
      assert Repo.aggregate(Job, :count) == 0
    end

    test "a malformed, unknown or non-binary id is a field error and writes nothing" do
      project = project!()

      for field <- ~w(project_id draft_id),
          value <- ["not-a-uuid", Ecto.UUID.generate(), 42, nil, %{"id" => "x"}] do
        assert {:error, changeset} = Dashboard.create_job(job_params(project, %{field => value}))
        assert error_on?(changeset, String.to_existing_atom(field)), "#{field}: #{inspect(value)}"
      end

      assert {:error, changeset} =
               Dashboard.create_job(project |> job_params() |> Map.delete("project_id"))

      assert error_on?(changeset, :project_id)
      assert Repo.aggregate(Job, :count) == 0
    end

    test "deleting a referenced draft keeps the job and its workflow name" do
      job = job!(project!())
      {:ok, draft} = Composer.get_draft(job.draft_id)

      assert {:ok, _deleted} = Composer.delete_draft(draft)

      assert %Job{draft_id: nil, workflow: "Release"} = Repo.get!(Job, job.id)
    end

    test "active jobs are the running and queued ones" do
      project = project!()

      for status <- [:running, :queued, :succeeded, :failed, :cancelled] do
        job = job!(project)
        job |> Ecto.Changeset.change(status: status) |> Repo.update!()
      end

      assert Dashboard.count_active_jobs() == 2
    end

    test "the empty changesets back a form" do
      assert %Ecto.Changeset{} = Dashboard.change_project()
      assert %Ecto.Changeset{} = Dashboard.change_job()
    end
  end
end

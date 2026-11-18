defmodule Domovoy.Examples.DashboardSeedsTest do
  use Domovoy.DataCase, async: false

  import Domovoy.DashboardFixtures
  import Ecto.Query

  alias Domovoy.Dashboard
  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project
  alias Domovoy.Examples.DashboardSeeds

  # `make db-seed-test` commits the seeds to this database, outside the sandbox. These
  # tests count on starting without them; the delete rolls back with the test.
  setup do
    Repo.delete_all(Job)
    Repo.delete_all(Project)
    :ok
  end

  @numbers Enum.to_list(1027..1042)

  defp sequence_value,
    do: Repo.query!("SELECT last_value FROM dashboard_jobs_number_seq").rows |> hd() |> hd()

  defp projects, do: Repo.all(from(project in Project, order_by: project.slug))
  defp jobs, do: Repo.all(from(job in Job, order_by: job.number))
  defp numbers, do: Enum.map(jobs(), & &1.number)

  test "the rows hold the dashboard's guarantees" do
    DashboardSeeds.run()

    slugs = Enum.map(projects(), & &1.slug)
    assert length(slugs) == 6
    assert "borg" in slugs and "domovoy" in slugs
    assert numbers() == @numbers

    jobs = Dashboard.list_jobs()

    assert MapSet.new(jobs, & &1.status) ==
             MapSet.new([:running, :queued, :succeeded, :failed, :cancelled])

    running = Enum.filter(jobs, &(&1.status == :running))
    assert length(running) == 2
    assert Enum.count(running, &(&1.project.slug == "borg")) == 1

    for job <- jobs do
      if job.status == :running,
        do: assert(is_integer(job.progress)),
        else: assert(is_nil(job.progress))
    end

    for project <- projects() do
      assert length(project.activity) == 14
      assert Enum.all?(project.activity, &(&1 in 0..100))
    end

    {borg, others} = Enum.split_with(jobs, &(&1.project.slug == "borg"))
    assert borg |> MapSet.new(& &1.status) |> MapSet.size() >= 2

    mentions? = fn fields ->
      Enum.any?(fields, &(&1 |> String.downcase() |> String.contains?("borg")))
    end

    refute Enum.any?(others, &mentions?.([&1.title, &1.workflow, &1.branch, &1.project.name]))

    refute projects()
           |> Enum.reject(&(&1.slug == "borg"))
           |> Enum.any?(&mentions?.([&1.name, &1.description, &1.path]))
  end

  test "a second run keeps every row and changes nothing" do
    first = DashboardSeeds.run()
    assert Enum.all?(first, &match?({_key, :created}, &1))
    assert length(first) == 22
    rows = {projects(), jobs()}
    sequence = sequence_value()

    second = DashboardSeeds.run()
    assert Enum.map(second, &elem(&1, 0)) == Enum.map(first, &elem(&1, 0))
    assert Enum.all?(second, &match?({_key, :kept}, &1))
    assert {projects(), jobs()} == rows
    assert sequence_value() == sequence
  end

  test "an edited project survives a re-run" do
    DashboardSeeds.run()
    borg = Repo.get_by!(Project, slug: "borg")
    edited = borg |> Ecto.Changeset.change(description: "Mine now", repos: 99) |> Repo.update!()

    assert {"project borg", :kept} in DashboardSeeds.run()
    assert Repo.get_by!(Project, slug: "borg") == edited
  end

  test "the next job continues after the seeds and the earlier sequence value" do
    prev = sequence_value()
    DashboardSeeds.run()

    job = job!(Repo.get_by!(Project, slug: "borg"))
    assert job.number == max(1042, prev) + 1

    Repo.delete!(job)
    DashboardSeeds.run()

    next = job!(Repo.get_by!(Project, slug: "borg"))
    assert next.number == job.number + 1
  end

  test "an interrupted run converges, recreating exactly the missing rows" do
    DashboardSeeds.run()

    Repo.delete_all(from(job in Job, where: job.number in ^Enum.to_list(1027..1030)))
    harbor = Repo.get_by!(Project, slug: "harbor")
    Repo.delete_all(from(job in Job, where: job.project_id == ^harbor.id))
    Repo.delete!(harbor)

    created = for {key, :created} <- DashboardSeeds.run(), do: key

    assert created ==
             ["project harbor" | Enum.map([1037, 1036, 1030, 1029, 1028, 1027], &"job ##{&1}")]

    assert length(projects()) == 6
    assert numbers() == @numbers
  end
end

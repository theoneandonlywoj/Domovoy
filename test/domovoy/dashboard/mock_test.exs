defmodule Domovoy.Dashboard.MockTest do
  use ExUnit.Case, async: true

  alias Domovoy.Dashboard.Mock

  test "project and job ids are unique" do
    project_ids = Enum.map(Mock.projects(), & &1.id)
    job_ids = Enum.map(Mock.jobs(), & &1.id)

    assert length(project_ids) == 6
    assert Enum.uniq(project_ids) == project_ids
    assert "borg" in project_ids and "domovoy" in project_ids
    assert length(job_ids) == 16
    assert Enum.uniq(job_ids) == job_ids
  end

  test "every status is present, with exactly two running, one in borg" do
    statuses = MapSet.new(Mock.jobs(), & &1.status)
    assert statuses == MapSet.new([:running, :queued, :succeeded, :failed, :cancelled])

    running = Enum.filter(Mock.jobs(), &(&1.status == :running))
    assert length(running) == 2
    assert Enum.count(running, &(&1.project == "borg")) == 1
  end

  test "only running jobs have a progress, and it is an integer" do
    for job <- Mock.jobs() do
      if job.status == :running,
        do: assert(is_integer(job.progress)),
        else: assert(is_nil(job.progress))
    end
  end

  test "every project has 14 activity values in 0..100" do
    for project <- Mock.projects() do
      assert length(project.activity) == 14
      assert Enum.all?(project.activity, &(&1 in 0..100))
    end
  end

  test "borg has jobs in two statuses, and its name appears only in borg's data" do
    {borg, others} = Enum.split_with(Mock.jobs(), &(&1.project == "borg"))
    assert borg |> MapSet.new(& &1.status) |> MapSet.size() >= 2

    mentions? = fn fields ->
      Enum.any?(fields, &(&1 |> String.downcase() |> String.contains?("borg")))
    end

    refute Enum.any?(others, &mentions?.([&1.title, &1.workflow, &1.branch, &1.project]))

    refute Mock.projects()
           |> Enum.reject(&(&1.id == "borg"))
           |> Enum.any?(&mentions?.([&1.name, &1.description, &1.path]))
  end
end

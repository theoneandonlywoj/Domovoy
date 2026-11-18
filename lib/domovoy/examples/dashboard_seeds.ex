defmodule Domovoy.Examples.DashboardSeeds do
  @moduledoc """
  Reconciles the example dashboard projects and jobs: reads the saved slugs and job
  numbers, then inserts each example whose key no row holds. An existing row is left
  alone, whatever it now says, because it may hold a person's edits. Each insert is
  one whole row, so an interrupted run leaves whole rows only and the next run adds
  the missing ones; the job sequence is then moved past the highest number, never
  back. A person's job holding a seeded number counts as that seed, kept.

  The data guarantees what the dashboard's filters and tests lean on:

    * 6 projects, with slugs including `borg` and `domovoy`; every project has exactly
      14 `activity` values in `0..100`, one per day, oldest first.
    * 16 jobs, numbered 1027 to 1042, covering every status in
      `running | queued | succeeded | failed | cancelled` at least once.
    * Exactly 2 jobs are running, one in `borg` and one elsewhere. Every running job has
      an integer `progress`, and every other job has `nil`.
    * `borg` has jobs in at least two statuses.
    * The substring "borg" (any case) appears only in project `borg`'s name, description
      and path, and only in jobs whose `project` is `borg`, so a search for it narrows to
      that project alone.
  """

  import Ecto.Query

  alias Domovoy.Dashboard.Job
  alias Domovoy.Dashboard.Project
  alias Domovoy.Repo

  @type outcome :: {key :: String.t(), :created | :kept}

  @projects [
    %{
      slug: "borg",
      name: "Borg",
      description: "Borg coding dashboard: worktrees, agents and pull requests in one place.",
      status: :running,
      repos: 10,
      worktrees: 24,
      jobs: 5,
      workflows: 4,
      path: "~/Desktop/Repos/Borg",
      activity: [12, 30, 45, 20, 60, 75, 40, 55, 80, 65, 90, 70, 85, 95]
    },
    %{
      slug: "domovoy",
      name: "Domovoy",
      description: "Workflow composer and run viewer for the agent engine.",
      status: :healthy,
      repos: 2,
      worktrees: 6,
      jobs: 4,
      workflows: 7,
      path: "~/Desktop/Repos/Domovoy",
      activity: [40, 35, 50, 65, 30, 20, 55, 70, 60, 45, 80, 75, 50, 65]
    },
    %{
      slug: "atlas",
      name: "Atlas",
      description: "Map tiles and geocoding service behind the field apps.",
      status: :failing,
      repos: 3,
      worktrees: 4,
      jobs: 2,
      workflows: 2,
      path: "~/Desktop/Repos/Atlas",
      activity: [10, 0, 25, 30, 15, 5, 40, 20, 10, 35, 0, 15, 25, 30]
    },
    %{
      slug: "ledger",
      name: "Ledger",
      description: "Billing exports and monthly invoice reconciliation.",
      status: :attention,
      repos: 1,
      worktrees: 2,
      jobs: 2,
      workflows: 1,
      path: "~/Desktop/Repos/Ledger",
      activity: [5, 10, 0, 0, 20, 15, 30, 25, 10, 5, 40, 35, 20, 10]
    },
    %{
      slug: "harbor",
      name: "Harbor",
      description: "Container images and deploy pipelines for staging.",
      status: :running,
      repos: 4,
      worktrees: 5,
      jobs: 2,
      workflows: 3,
      path: "~/Desktop/Repos/Harbor",
      activity: [60, 55, 70, 65, 50, 45, 80, 85, 75, 90, 60, 70, 100, 80]
    },
    %{
      slug: "quill",
      name: "Quill",
      description: "Docs site and changelog generator.",
      status: :idle,
      repos: 1,
      worktrees: 1,
      jobs: 1,
      workflows: 1,
      path: "~/Desktop/Repos/Quill",
      activity: [0, 0, 5, 0, 0, 10, 0, 0, 0, 5, 0, 0, 0, 0]
    }
  ]

  @jobs [
    %{
      number: 1042,
      title: "Port worktree cards to the new chrome",
      workflow: "implement-phase",
      project: "borg",
      branch: "borg-worktree-cards",
      trigger: "manual",
      status: :running,
      duration: "12m",
      when_label: "now",
      progress: 64
    },
    %{
      number: 1041,
      title: "Review pull request filters",
      workflow: "review",
      project: "borg",
      branch: "borg-pr-filters",
      trigger: "schedule",
      status: :queued,
      duration: "—",
      when_label: "queued",
      progress: nil
    },
    %{
      number: 1040,
      title: "Fix agent log scroll",
      workflow: "fix-bug",
      project: "borg",
      branch: "borg-log-scroll",
      trigger: "manual",
      status: :succeeded,
      duration: "8m",
      when_label: "1h ago",
      progress: nil
    },
    %{
      number: 1039,
      title: "Upgrade the Phoenix dependency",
      workflow: "upgrade-deps",
      project: "borg",
      branch: "borg-phoenix-1-8",
      trigger: "schedule",
      status: :failed,
      duration: "21m",
      when_label: "3h ago",
      progress: nil
    },
    %{
      number: 1038,
      title: "Split the keymap module",
      workflow: "refactor",
      project: "borg",
      branch: "borg-keymap-split",
      trigger: "manual",
      status: :cancelled,
      duration: "2m",
      when_label: "yesterday",
      progress: nil
    },
    %{
      number: 1037,
      title: "Build the deploy image",
      workflow: "release",
      project: "harbor",
      branch: "main",
      trigger: "push",
      status: :running,
      duration: "4m",
      when_label: "now",
      progress: 30
    },
    %{
      number: 1036,
      title: "Roll staging back",
      workflow: "rollback",
      project: "harbor",
      branch: "main",
      trigger: "manual",
      status: :succeeded,
      duration: "3m",
      when_label: "2h ago",
      progress: nil
    },
    %{
      number: 1035,
      title: "Restyle the composer",
      workflow: "implement-phase",
      project: "domovoy",
      branch: "project-management",
      trigger: "manual",
      status: :succeeded,
      duration: "34m",
      when_label: "30m ago",
      progress: nil
    },
    %{
      number: 1034,
      title: "Seed example drafts",
      workflow: "fix-bug",
      project: "domovoy",
      branch: "seed-names",
      trigger: "manual",
      status: :succeeded,
      duration: "6m",
      when_label: "yesterday",
      progress: nil
    },
    %{
      number: 1033,
      title: "Run history pagination",
      workflow: "review",
      project: "domovoy",
      branch: "runs-paging",
      trigger: "push",
      status: :queued,
      duration: "—",
      when_label: "queued",
      progress: nil
    },
    %{
      number: 1032,
      title: "Canvas auto-fit regression",
      workflow: "fix-bug",
      project: "domovoy",
      branch: "canvas-fit",
      trigger: "schedule",
      status: :failed,
      duration: "11m",
      when_label: "2 days ago",
      progress: nil
    },
    %{
      number: 1031,
      title: "Refresh map tiles",
      workflow: "nightly",
      project: "atlas",
      branch: "main",
      trigger: "schedule",
      status: :failed,
      duration: "45m",
      when_label: "6h ago",
      progress: nil
    },
    %{
      number: 1030,
      title: "Geocoder cache warm-up",
      workflow: "nightly",
      project: "atlas",
      branch: "main",
      trigger: "schedule",
      status: :cancelled,
      duration: "1m",
      when_label: "yesterday",
      progress: nil
    },
    %{
      number: 1029,
      title: "Monthly invoice export",
      workflow: "export",
      project: "ledger",
      branch: "main",
      trigger: "schedule",
      status: :queued,
      duration: "—",
      when_label: "queued",
      progress: nil
    },
    %{
      number: 1028,
      title: "Reconcile October",
      workflow: "reconcile",
      project: "ledger",
      branch: "october-close",
      trigger: "manual",
      status: :succeeded,
      duration: "18m",
      when_label: "3 days ago",
      progress: nil
    },
    %{
      number: 1027,
      title: "Publish the changelog",
      workflow: "release",
      project: "quill",
      branch: "main",
      trigger: "push",
      status: :succeeded,
      duration: "2m",
      when_label: "4 days ago",
      progress: nil
    }
  ]

  @doc """
  Runs the reconciliation, projects first. Raises on a failed insert or a job naming an
  unknown project, with the failing fields only, never a value.
  """
  @spec run() :: [outcome()]
  def run do
    slugs = MapSet.new(Repo.all(from(project in Project, select: project.slug)))

    projects =
      for %{slug: slug} = project <- @projects do
        key = "project " <> slug
        if slug in slugs, do: {key, :kept}, else: {key, create_project!(project)}
      end

    project_ids = Map.new(Repo.all(from(project in Project, select: {project.slug, project.id})))
    numbers = MapSet.new(Repo.all(from(job in Job, select: job.number)))

    jobs =
      for %{number: number} = job <- @jobs do
        key = "job #" <> Integer.to_string(number)
        if number in numbers, do: {key, :kept}, else: {key, create_job!(job, project_ids)}
      end

    # The sequence moves past the seeded numbers, and never below where it already is.
    Repo.query!("""
    SELECT setval(pg_get_serial_sequence('dashboard_jobs', 'number'),
                  GREATEST(COALESCE((SELECT MAX(number) FROM dashboard_jobs), 1),
                           (SELECT last_value FROM dashboard_jobs_number_seq)))
    """)

    projects ++ jobs
  end

  @spec create_project!(project :: map()) :: :created
  defp create_project!(%{slug: slug} = project) do
    changeset = Project.seed_changeset(%Project{}, project)

    if Ecto.Changeset.get_change(changeset, :slug) != slug,
      do: raise("Seed project #{slug}: its name does not slugify to its key")

    insert!(changeset, "project #{slug}")
  end

  @spec create_job!(job :: map(), project_ids :: %{String.t() => String.t()}) :: :created
  defp create_job!(%{number: number, project: slug} = job, project_ids) do
    project_id =
      Map.get(project_ids, slug) || raise "Seed job ##{number}: unknown project #{slug}"

    %Job{}
    |> Job.seed_changeset(Map.put(job, :project_id, project_id))
    |> insert!("job ##{number}")
  end

  @spec insert!(changeset :: Ecto.Changeset.t(), key :: String.t()) :: :created
  defp insert!(changeset, key) do
    case Repo.insert(changeset) do
      {:ok, _row} ->
        :created

      {:error, changeset} ->
        raise "Seed #{key} could not be saved: #{inspect(Keyword.keys(changeset.errors))}"
    end
  end
end

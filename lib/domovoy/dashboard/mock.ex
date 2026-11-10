defmodule Domovoy.Dashboard.Mock do
  @moduledoc """
  Static, in-memory projects and jobs for the `/dashboard` prototype. Nothing here is
  persisted or fetched.

  The data guarantees what the dashboard's filters and tests lean on:

    * 6 projects, with ids including `borg` and `domovoy`; every project has exactly 14
      `activity` values in `0..100`, one per day, oldest first.
    * 16 jobs, covering every status in `running | queued | succeeded | failed | cancelled`
      at least once.
    * Exactly 2 jobs are running, one in `borg` and one elsewhere. Every running job has
      an integer `progress`, and every other job has `nil`.
    * `borg` has jobs in at least two statuses.
    * The substring "borg" (any case) appears only in project `borg`'s name, description
      and path, and only in jobs whose `project` is `borg`, so a search for it narrows to
      that project alone.
  """

  @type job_status :: :running | :queued | :succeeded | :failed | :cancelled
  @type project_status :: :running | :healthy | :failing | :attention | :idle

  @type project :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          status: project_status(),
          repos: non_neg_integer(),
          worktrees: non_neg_integer(),
          jobs: non_neg_integer(),
          workflows: non_neg_integer(),
          path: String.t(),
          activity: [0..100]
        }

  @type job :: %{
          id: pos_integer(),
          title: String.t(),
          workflow: String.t(),
          project: String.t(),
          branch: String.t(),
          trigger: String.t(),
          status: job_status(),
          duration: String.t(),
          when: String.t(),
          progress: 0..100 | nil
        }

  @projects [
    %{
      id: "borg",
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
      id: "domovoy",
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
      id: "atlas",
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
      id: "ledger",
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
      id: "harbor",
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
      id: "quill",
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
      id: 1042,
      title: "Port worktree cards to the new chrome",
      workflow: "implement-phase",
      project: "borg",
      branch: "borg-worktree-cards",
      trigger: "manual",
      status: :running,
      duration: "12m",
      when: "now",
      progress: 64
    },
    %{
      id: 1041,
      title: "Review pull request filters",
      workflow: "review",
      project: "borg",
      branch: "borg-pr-filters",
      trigger: "schedule",
      status: :queued,
      duration: "—",
      when: "queued",
      progress: nil
    },
    %{
      id: 1040,
      title: "Fix agent log scroll",
      workflow: "fix-bug",
      project: "borg",
      branch: "borg-log-scroll",
      trigger: "manual",
      status: :succeeded,
      duration: "8m",
      when: "1h ago",
      progress: nil
    },
    %{
      id: 1039,
      title: "Upgrade the Phoenix dependency",
      workflow: "upgrade-deps",
      project: "borg",
      branch: "borg-phoenix-1-8",
      trigger: "schedule",
      status: :failed,
      duration: "21m",
      when: "3h ago",
      progress: nil
    },
    %{
      id: 1038,
      title: "Split the keymap module",
      workflow: "refactor",
      project: "borg",
      branch: "borg-keymap-split",
      trigger: "manual",
      status: :cancelled,
      duration: "2m",
      when: "yesterday",
      progress: nil
    },
    %{
      id: 1037,
      title: "Build the deploy image",
      workflow: "release",
      project: "harbor",
      branch: "main",
      trigger: "push",
      status: :running,
      duration: "4m",
      when: "now",
      progress: 30
    },
    %{
      id: 1036,
      title: "Roll staging back",
      workflow: "rollback",
      project: "harbor",
      branch: "main",
      trigger: "manual",
      status: :succeeded,
      duration: "3m",
      when: "2h ago",
      progress: nil
    },
    %{
      id: 1035,
      title: "Restyle the composer",
      workflow: "implement-phase",
      project: "domovoy",
      branch: "project-management",
      trigger: "manual",
      status: :succeeded,
      duration: "34m",
      when: "30m ago",
      progress: nil
    },
    %{
      id: 1034,
      title: "Seed example drafts",
      workflow: "fix-bug",
      project: "domovoy",
      branch: "seed-names",
      trigger: "manual",
      status: :succeeded,
      duration: "6m",
      when: "yesterday",
      progress: nil
    },
    %{
      id: 1033,
      title: "Run history pagination",
      workflow: "review",
      project: "domovoy",
      branch: "runs-paging",
      trigger: "push",
      status: :queued,
      duration: "—",
      when: "queued",
      progress: nil
    },
    %{
      id: 1032,
      title: "Canvas auto-fit regression",
      workflow: "fix-bug",
      project: "domovoy",
      branch: "canvas-fit",
      trigger: "schedule",
      status: :failed,
      duration: "11m",
      when: "2 days ago",
      progress: nil
    },
    %{
      id: 1031,
      title: "Refresh map tiles",
      workflow: "nightly",
      project: "atlas",
      branch: "main",
      trigger: "schedule",
      status: :failed,
      duration: "45m",
      when: "6h ago",
      progress: nil
    },
    %{
      id: 1030,
      title: "Geocoder cache warm-up",
      workflow: "nightly",
      project: "atlas",
      branch: "main",
      trigger: "schedule",
      status: :cancelled,
      duration: "1m",
      when: "yesterday",
      progress: nil
    },
    %{
      id: 1029,
      title: "Monthly invoice export",
      workflow: "export",
      project: "ledger",
      branch: "main",
      trigger: "schedule",
      status: :queued,
      duration: "—",
      when: "queued",
      progress: nil
    },
    %{
      id: 1028,
      title: "Reconcile October",
      workflow: "reconcile",
      project: "ledger",
      branch: "october-close",
      trigger: "manual",
      status: :succeeded,
      duration: "18m",
      when: "3 days ago",
      progress: nil
    },
    %{
      id: 1027,
      title: "Publish the changelog",
      workflow: "release",
      project: "quill",
      branch: "main",
      trigger: "push",
      status: :succeeded,
      duration: "2m",
      when: "4 days ago",
      progress: nil
    }
  ]

  @doc "The mock projects, in display order."
  @spec projects() :: [project()]
  def projects, do: @projects

  @doc "The mock jobs, newest first."
  @spec jobs() :: [job()]
  def jobs, do: @jobs
end

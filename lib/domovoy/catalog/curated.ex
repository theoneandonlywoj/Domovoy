defmodule Domovoy.Catalog.Curated do
  @moduledoc """
  The hand-kept facts `Domovoy.Catalog` can't reflect: plugin names, what stays
  hidden, and what each validator needs. Plain data, with no logic.
  """

  @doc """
  Every plugin the composer knows of, whether or not it is installed.

  `prefix` starts the label of each plugin entry, because Git and Mise share
  `Worktree`, and Claude Code and Mise share `Detect` and `Executable`.
  """
  @spec plugins() :: [map()]
  def plugins do
    [
      %{id: "core", name: "Core", app: :domovoy_core, prefix: nil},
      %{id: "git", name: "Git", app: :domovoy_git_plugin, prefix: "Git"},
      %{id: "mise", name: "Mise", app: :domovoy_mise_plugin, prefix: "Mise"},
      %{
        id: "claude_code",
        name: "Claude Code",
        app: :domovoy_claude_code_plugin,
        prefix: "Claude"
      },
      %{id: "github", name: "GitHub", app: :domovoy_github_plugin, prefix: "GitHub"},
      %{id: "linear", name: "Linear", app: :domovoy_linear_plugin, prefix: "Linear"},
      %{id: "slack", name: "Slack", app: :domovoy_slack_plugin, prefix: "Slack"}
    ]
  end

  @doc """
  Modules that never appear in the catalog, so no browser value can name them.
  """
  @spec hidden() :: [module()]
  def hidden do
    [
      DomovoyCore.Type.Choice,
      DomovoyClaudeCodePlugin.Monitoring.Runner.Fold,
      DomovoyClaudeCodePlugin.Reflect.Runner.CollectTranscripts
    ]
  end

  @doc """
  Fields no runner entry shows. Core adds `:extra` to a runner with `extra?: true`.
  """
  @spec hidden_fields() :: [atom()]
  def hidden_fields, do: [:extra]

  @doc """
  The validators a node may add. `requires` names the fields each one reads.

  `DomovoyClaudeCodePlugin.Reflect.Validator.WindowIsValid` is left out because
  it serves only the hidden `CollectTranscripts`. The Mise plugin has none.
  """
  @spec validators() :: [map()]
  def validators do
    [
      %{
        module: DomovoyGitPlugin.Validator.CommitMessagePresent,
        description: "Refuses a message that is blank after trimming.",
        requires: ["message"]
      },
      %{
        module: DomovoyGitPlugin.Validator.DiffRefsPresent,
        description: "Refuses a blank base or target ref for a branch diff.",
        requires: ["base_branch", "target_branch"]
      },
      %{
        module: DomovoyGitPlugin.Validator.PathsPresent,
        description: "Refuses an empty path list or a blank path.",
        requires: ["paths"]
      },
      %{
        module: DomovoyGitPlugin.Validator.RemotePresent,
        description: "Refuses a blank remote name.",
        requires: ["remote"]
      },
      %{
        module: DomovoyGitPlugin.Validator.WorktreeNameIsSafe,
        description: "Refuses a worktree name that is not one safe path segment.",
        requires: ["worktree_name"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.AskOptionsAreValid,
        description: "Refuses options an AskClaude session does not accept.",
        requires: ["options"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.ConversationFiltersAreValid,
        description: "Refuses conversation filters the capability does not read.",
        requires: ["filters"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.DescribeOptionsAreValid,
        description: "Refuses options a DescribeClaudeCode session does not accept.",
        requires: ["options"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.SessionDirectoryIsValid,
        description: "Refuses an explicit nil working directory.",
        requires: ["working_directory"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.SessionMatchesWorktree,
        description: "Refuses a prior session from another worktree, branch or directory.",
        requires: ["session", "worktree_name", "branch_name", "working_directory"]
      },
      %{
        module: DomovoyClaudeCodePlugin.Validator.SessionOptionsAreValid,
        description: "Refuses options a Claude session does not accept.",
        requires: ["options"]
      }
    ]
  end

  @doc """
  The deciders a Decision may name.
  """
  @spec deciders() :: [module()]
  def deciders, do: [DomovoyCore.Decider.Person]
end

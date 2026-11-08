defmodule Domovoy.MissingWorktreeRunner do
  @moduledoc """
  Answers, without Git, that the worktree for a branch doesn't exist yet, so
  `Domovoy.Examples.Worktree.WorktreeRouteDecider` picks `create`. A test-only runner,
  reaching the catalog through the Examples plugin's app.
  """

  use DomovoyCore.Runner, effect: :pure

  alias DomovoyCore.Type

  input do
    field(:branch_name, Type.String)
  end

  output(DomovoyGitPlugin.Type.Worktree)

  @impl DomovoyCore.Runner
  def run(%Input{branch_name: branch}, _context) do
    {:ok,
     %{
       repo_root: "/nowhere",
       name: "missing",
       path: "/nowhere/.worktrees/missing",
       exists?: false,
       created?: false,
       branch: branch
     }}
  end
end

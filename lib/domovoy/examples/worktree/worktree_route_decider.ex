defmodule Domovoy.Examples.Worktree.WorktreeRouteDecider do
  @moduledoc """
  Picks `create` for a missing worktree and `existing` for one on the wanted branch.
  It reads the worktree from the node that the `:node` option names.
  Ported from Core's `ensure_worktree` notebook.
  """

  use DomovoyCore.Decider, effect: :pure

  alias DomovoyCore.Context
  alias DomovoyCore.Value

  @impl DomovoyCore.Decider
  def decide(_decision, %Context{} = context, opts) do
    with {:ok, node} when is_binary(node) <- Keyword.fetch(opts, :node),
         {:ok, %Value{value: wanted}} <- Context.read(context, "branch_name"),
         {:ok, %Value{value: %{} = worktree}} <- Context.read(context, node) do
      route(worktree, wanted)
    else
      _other -> {:error, :resolve_missing}
    end
  end

  @spec route(worktree :: map(), wanted :: term()) ::
          {:ok, String.t()} | {:error, :branch_mismatch}
  defp route(%{exists?: false}, _wanted), do: {:ok, "create"}
  defp route(%{branch: wanted}, wanted), do: {:ok, "existing"}
  defp route(_worktree, _wanted), do: {:error, :branch_mismatch}
end

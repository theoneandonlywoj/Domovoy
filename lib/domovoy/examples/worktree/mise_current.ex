defmodule Domovoy.Examples.Worktree.MiseCurrent do
  @moduledoc """
  Runs `mise current` in the worktree, so it shows the versions that the worktree's
  Mise config resolves to. Without Mise it gives no tools, as
  `DomovoyMisePlugin.Runner.Trust` skips the trust. Ported from Core's
  `ensure_worktree` notebook, because the Mise plugin has no such runner.
  """

  use DomovoyCore.Runner, effect: :pure

  alias Domovoy.Examples.Worktree.MiseCurrentVersions
  alias DomovoyCore.Context
  alias DomovoyCore.Error
  alias DomovoyCore.Shell
  alias DomovoyCore.Type
  alias DomovoyMisePlugin.Capabilities
  alias DomovoyMisePlugin.Type.Executable

  input do
    field(:worktree, Type.Any)
    field(:mise, Executable)
  end

  required([:worktree, :mise])
  output(MiseCurrentVersions)

  @impl DomovoyCore.Runner
  def run(%Input{mise: %{available?: false}}, _context), do: {:ok, %{}}

  def run(%Input{worktree: worktree, mise: %{executable: mise}}, %Context{node: node}) do
    with {:ok, path} <- worktree_path(worktree, node) do
      # Shell merges stderr into the output; --quiet keeps Mise's warnings out.
      case Shell.run(mise, ["current", "--quiet"], cd: path, timeout: 30_000) do
        {:ok, output} -> {:ok, parse(output)}
        {:error, reason} -> {:error, failed(reason, path, node)}
      end
    end
  end

  @spec worktree_path(worktree :: term(), node :: String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp worktree_path(worktree, node) do
    case Capabilities.worktree_path(worktree) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, Capabilities.invalid_worktree_error(node)}
    end
  end

  # One line per tool: the tool, then its active versions.
  @spec parse(output :: String.t()) :: %{String.t() => [String.t()]}
  defp parse(output) do
    for line <- String.split(output, "\n"),
        [tool | versions] <- [String.split(line)],
        versions != [],
        into: %{},
        do: {tool, versions}
  end

  @spec failed(reason :: term(), path :: String.t(), node :: String.t() | nil) :: Error.t()
  defp failed(reason, path, node) do
    Error.new(%{
      type: :mise_current_failed,
      reason: %{"node_name" => node, "path" => path, "cause" => reason},
      retryable?: false
    })
  end
end

defmodule Domovoy.Examples.Worktree.WorktreeSyncFolder do
  @moduledoc """
  Makes `<worktree>/<folder>` equal to `<main checkout>/<folder>`: copies it when it
  is missing or differs. A main checkout without the folder fails the node and never
  deletes the worktree's copy. Ported from Core's `ensure_worktree` notebook.
  """

  use DomovoyCore.Runner, effect: :non_idempotent

  alias DomovoyCore.Error
  alias DomovoyCore.FileSystem
  alias DomovoyCore.Type
  alias DomovoyCore.Value
  alias DomovoyGitPlugin.Type.Worktree, as: WorktreeType

  input do
    field(:worktree, WorktreeType)
    field(:folder, Type.String)
  end

  required([:worktree, :folder])
  output(Type.Map)

  @impl DomovoyCore.Runner
  def run(%Input{worktree: worktree, folder: folder}, _context) do
    {:ok, source} = Value.cast(Path.join(worktree.repo_root, folder), Type.Path)
    {:ok, destination} = Value.cast(Path.join(worktree.path, folder), Type.Path)

    with {:ok, action} <- sync(source, destination) do
      {:ok,
       %{
         "folder" => folder,
         "source" => source.value,
         "destination" => destination.value,
         "action" => action
       }}
    end
  end

  @spec sync(source :: Value.t(), destination :: Value.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp sync(source, destination) do
    cond do
      not FileSystem.folder_exists?(source) ->
        failed(:source_folder_missing, source, :enoent)

      not FileSystem.folder_exists?(destination) ->
        copy(source, destination, "created")

      true ->
        case FileSystem.compare_folders(source, destination) do
          {:ok, true} -> {:ok, "unchanged"}
          {:ok, false} -> copy(source, destination, "overwritten")
          {:error, cause} -> failed(:folder_compare_failed, destination, cause)
        end
    end
  end

  @spec copy(source :: Value.t(), destination :: Value.t(), action :: String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp copy(source, destination, action) do
    case FileSystem.copy_folder(source, destination) do
      :ok -> {:ok, action}
      {:error, cause} -> failed(:folder_copy_failed, destination, cause)
    end
  end

  @spec failed(type :: atom(), path :: Value.t(), cause :: term()) :: {:error, Error.t()}
  defp failed(type, %Value{value: path}, cause) do
    {:error,
     Error.new(%{
       type: type,
       reason: %{"path" => path, "cause" => inspect(cause)},
       retryable?: false
     })}
  end
end

defmodule Domovoy.Examples.Worktree.MiseCurrentVersions do
  @moduledoc """
  The output of `mise current`: the active versions of each tool, keyed by tool.
  Ported from Core's `ensure_worktree` notebook.
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :map

  @impl DomovoyCore.Type
  def cast(tools, _metadata) when is_map(tools) do
    valid? =
      Enum.all?(tools, fn {tool, versions} ->
        is_binary(tool) and is_list(versions) and Enum.all?(versions, &is_binary/1)
      end)

    if valid?, do: {:ok, tools}, else: :error
  end

  def cast(_raw, _metadata), do: :error

  @impl Ecto.Type
  def load(document), do: cast(document)
end

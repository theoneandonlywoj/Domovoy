defmodule Domovoy.Composer.Cycles do
  @moduledoc """
  Finds the waiting cycles in a stage's graph.

  Core's own error also names every node waiting behind a cycle. This names only
  the nodes on it, so the message points at what the user must change.
  """

  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue

  @doc """
  Each cycle in a stage as a sorted list of node names. A node waiting on itself
  is a cycle of one: `:digraph_utils.cyclic_strong_components/1` keeps a
  singleton only when it has a self-edge, and `:digraph.new/0` allows those.
  """
  @spec find(document :: Document.t(), stage :: String.t()) :: [[String.t()]]
  def find(document, stage) do
    nodes = Document.nodes(document, stage)
    graph = :digraph.new()

    try do
      Enum.each(nodes, fn {name, _node} -> :digraph.add_vertex(graph, name) end)

      for {name, node} <- nodes, source <- sources(node), is_map_key(nodes, source) do
        :digraph.add_edge(graph, source, name)
      end

      graph
      |> :digraph_utils.cyclic_strong_components()
      |> Enum.map(&Enum.sort/1)
      |> Enum.sort()
    after
      :digraph.delete(graph)
    end
  end

  @doc """
  Fails when a stage has a cycle, naming the nodes on it.
  """
  @spec check(document :: Document.t(), stage :: String.t()) :: :ok | {:error, Issue.t()}
  def check(document, stage) do
    case find(document, stage) do
      [] ->
        :ok

      cycles ->
        names = cycles |> List.flatten() |> Enum.join(", ")

        {:error,
         %Issue{
           code: :cycle,
           core_id: :graph_has_cycle,
           target: {:vertex, stage},
           message:
             "That would make #{names} wait on each other. " <>
               "To loop, use a workflow Decision with a Rerun choice."
         }}
    end
  end

  @doc """
  Whether `node` reading or waiting on `source` would close a cycle: `source` is
  `node`, or already waits on it. A stage with no cycle stays so exactly when this is
  false, so a list of targets can ask it without building a graph per target.
  """
  @spec closes?(
          document :: Document.t(),
          stage :: String.t(),
          node :: String.t(),
          source :: String.t()
        ) :: boolean()
  def closes?(document, stage, node, source) do
    nodes = Document.nodes(document, stage)
    node in upstream(nodes, [source], [])
  end

  @spec upstream(nodes :: map(), pending :: [String.t()], seen :: [String.t()]) :: [String.t()]
  defp upstream(_nodes, [], seen), do: seen

  defp upstream(nodes, [name | pending], seen) do
    case nodes do
      %{^name => node} ->
        if name in seen,
          do: upstream(nodes, pending, seen),
          else: upstream(nodes, sources(node) ++ pending, [name | seen])

      _not_a_node ->
        upstream(nodes, pending, seen)
    end
  end

  @spec sources(node :: map()) :: [String.t()]
  defp sources(node) do
    binds = for {_field, %{"bind" => source}} <- node["inputs"], do: source
    binds ++ node["after"]
  end
end

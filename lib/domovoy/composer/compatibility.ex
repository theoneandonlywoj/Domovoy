defmodule Domovoy.Composer.Compatibility do
  @moduledoc """
  Whether a field may read a source, using Core's own type rules.

  Within one graph a field accepts an exact type, or anything when it is Any.
  Across stages types match exactly, so Any matches only Any, except when a
  sibling binding in that stage reads the same source with its concrete type:
  Core then types the stage's graph input from the sibling.

  `check/4` is about types only: it sees every source in the document. Core counts
  a source only where it precedes the stage, which `visibility/3` answers.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue

  @any "DomovoyCore.Type.Any"

  @type visibility :: :visible | :not_visible | :stage_unreachable

  @doc """
  Checks binding `source` to a field of `field_type` in `stage`, by type alone.

  Neither `:exact` nor `:accepted_by_any` means Core accepts the binding: a source
  that doesn't precede the stage passes here and Core still refuses it. A caller
  stating that a binding is acceptable combines this with `visibility/3`.
  """
  @spec check(
          document :: Document.t(),
          stage :: String.t(),
          field_type :: String.t(),
          source :: String.t()
        ) :: {:ok, :exact | :accepted_by_any} | {:error, Issue.t()}
  def check(document, stage, field_type, source) do
    case source_type(document, stage, source) do
      {_scope, ^field_type} ->
        {:ok, :exact}

      {:same_graph, _type} when field_type == @any ->
        {:ok, :accepted_by_any}

      {:same_graph, type} ->
        {:error, mismatch(:binding_type_mismatch, stage, source, type, field_type)}

      {:external, type} when field_type == @any ->
        across_stages_any(document, stage, source, type)

      {:external, type} ->
        {:error, mismatch(:stage_input_type_mismatch, stage, source, type, field_type)}

      :error ->
        {:error, unknown_source(stage)}
    end
  end

  @doc """
  The type a source name gives to `stage`, and whether it comes from that stage's
  own graph. Nodes, workflow inputs and choice inputs are sources.
  """
  @spec source_type(document :: Document.t(), stage :: String.t(), source :: String.t()) ::
          {:same_graph | :external, String.t()} | :error
  def source_type(document, stage, source) do
    case output_type(Document.nodes(document, stage)[source]) do
      nil -> external_type(document, source)
      type -> {:same_graph, type}
    end
  end

  @doc """
  Whether Core lets `stage` read `source`, by the rule of Core's stage input check.

    * `:visible` - the stage's own node, a workflow input, or a node or choice input
      of a vertex that `start` reaches and that a path of one or more arrows leads
      from to the stage. A cycle through the stage counts, because a rerun reads it.
    * `:not_visible` - Core reports `stage_input_unbound`. An unknown name is too.
    * `:stage_unreachable` - nothing can precede the stage, since `start` doesn't
      reach it, but Core never checks such a stage, so it reports nothing.

  This reads control flow only. Core also drops the nodes of a stage whose graph
  fails to build; such a stage has its own error, and this answers as if it built.
  """
  @spec visibility(document :: Document.t(), stage :: String.t(), source :: String.t()) ::
          visibility()
  def visibility(document, stage, source) do
    successors = successors(document)
    start = document["start"]
    reached = Map.put(reachable(successors, start, %{}), start, true)

    cond do
      is_map_key(Document.nodes(document, stage), source) or
          is_map_key(document["inputs"], source) ->
        :visible

      not is_map_key(reached, stage) ->
        :stage_unreachable

      Enum.any?(Map.keys(reached), &gives_before?(document, successors, &1, source, stage)) ->
        :visible

      true ->
        :not_visible
    end
  end

  @doc """
  The bindings of a stage that give an external source a second concrete type,
  the first in Core's order of node then field being the one the others conflict
  with. Any never conflicts.
  """
  @spec conflicting_inputs(document :: Document.t(), stage :: String.t()) :: [Issue.t()]
  def conflicting_inputs(document, stage) do
    nodes = Document.nodes(document, stage)

    readings =
      for {name, node} <- Enum.sort(nodes),
          {field, %{"bind" => source}} <- Enum.sort(node["inputs"]),
          not is_map_key(nodes, source),
          {:ok, %{type_id: type}} when type != @any <- [Catalog.field(node["runner"], field)] do
        {source, name, field, type}
      end

    readings
    |> Enum.group_by(fn {source, _name, _field, _type} -> source end)
    |> Enum.sort()
    |> Enum.flat_map(fn {_source, [{_source_name, _name, _field, first} | rest]} ->
      for {source, name, field, type} <- rest, type != first do
        conflict(stage, name, field, source, first, type)
      end
    end)
  end

  @spec conflict(
          stage :: String.t(),
          node :: String.t(),
          field :: String.t(),
          source :: String.t(),
          first :: String.t(),
          type :: String.t()
        ) :: Issue.t()
  defp conflict(stage, node, field, source, first, type) do
    %Issue{
      code: :conflicting_input_types,
      core_id: :conflicting_input_types,
      target: {:field, stage, node, field},
      message:
        "This stage reads #{source} as #{Catalog.type_label(first)}, " <>
          "but #{node}.#{field} reads it as #{Catalog.type_label(type)}."
    }
  end

  @doc """
  Whether any vertex leads back to itself, so a run may reach Core's generation limits.
  """
  @spec loop?(document :: Document.t()) :: boolean()
  def loop?(document) do
    successors = successors(document)
    Enum.any?(Map.keys(successors), &is_map_key(reachable(successors, &1, %{}), &1))
  end

  @spec gives_before?(
          document :: Document.t(),
          successors :: map(),
          vertex :: String.t(),
          source :: String.t(),
          stage :: String.t()
        ) :: boolean()
  defp gives_before?(document, successors, vertex, source, stage) do
    gives?(document, vertex, source) and
      is_map_key(reachable(successors, vertex, %{}), stage)
  end

  @spec gives?(document :: Document.t(), vertex :: String.t(), source :: String.t()) :: boolean()
  defp gives?(document, vertex, source) do
    is_map_key(Document.nodes(document, vertex), source) or
      Enum.any?(Document.choice_inputs(document), &match?({^vertex, _choice, ^source, _type}, &1))
  end

  @spec successors(document :: Document.t()) :: %{String.t() => [String.t()]}
  defp successors(document) do
    Map.new(document["vertices"], fn {name, vertex} -> {name, targets(vertex)} end)
  end

  @spec targets(vertex :: map()) :: [String.t()]
  defp targets(%{"kind" => "stage", "next" => nil}), do: []
  defp targets(%{"kind" => "stage", "next" => next}), do: [next]

  defp targets(%{"kind" => "decision", "choices" => choices}) do
    for %{"target" => [_kind, vertex]} <- choices, do: vertex
  end

  @spec reachable(successors :: map(), from :: String.t(), seen :: map()) :: map()
  defp reachable(successors, from, seen) do
    successors
    |> Map.get(from, [])
    |> Enum.reduce(seen, fn next, seen ->
      if is_map_key(seen, next),
        do: seen,
        else: reachable(successors, next, Map.put(seen, next, true))
    end)
  end

  @spec external_type(document :: Document.t(), source :: String.t()) ::
          {:external, String.t()} | :error
  defp external_type(document, source) do
    node_types =
      for {_stage, ^source, node} <- Document.all_nodes(document), do: output_type(node)

    input_types = for {^source, %{"type" => type}} <- document["inputs"], do: type

    choice_types =
      for {_decision, _choice, ^source, type} <- Document.choice_inputs(document), do: type

    case Enum.reject(node_types ++ input_types ++ choice_types, &is_nil/1) do
      [type | _rest] -> {:external, type}
      [] -> :error
    end
  end

  @spec output_type(node :: map() | nil) :: String.t() | nil
  defp output_type(nil), do: nil

  defp output_type(node) do
    case Catalog.runner(node["runner"]) do
      {:ok, runner} -> runner.output
      :error -> nil
    end
  end

  @spec across_stages_any(
          document :: Document.t(),
          stage :: String.t(),
          source :: String.t(),
          type :: String.t()
        ) :: {:ok, :accepted_by_any} | {:error, Issue.t()}
  defp across_stages_any(document, stage, source, type) do
    if sibling_reads?(document, stage, source, type) do
      {:ok, :accepted_by_any}
    else
      {:error,
       %Issue{
         code: :type_mismatch,
         core_id: :stage_input_type_mismatch,
         target: {:vertex, stage},
         message:
           "Across stages Any matches only Any, and #{source} gives #{Catalog.type_label(type)}. " <>
             "This field is accepted only while another field of this stage reads #{source} with that type."
       }}
    end
  end

  @spec sibling_reads?(
          document :: Document.t(),
          stage :: String.t(),
          source :: String.t(),
          type :: String.t()
        ) :: boolean()
  defp sibling_reads?(document, stage, source, type) do
    Enum.any?(Document.nodes(document, stage), fn {_name, node} ->
      Enum.any?(node["inputs"], fn
        {field, %{"bind" => ^source}} ->
          match?({:ok, %{type_id: ^type}}, Catalog.field(node["runner"], field))

        _other ->
          false
      end)
    end)
  end

  @spec mismatch(
          core_id :: atom(),
          stage :: String.t(),
          source :: String.t(),
          from :: String.t(),
          to :: String.t()
        ) :: Issue.t()
  defp mismatch(core_id, stage, source, from, to) do
    adapters = for runner <- Catalog.adapters(from, to), do: %{id: runner.id, label: runner.label}
    from_label = Catalog.type_label(from)
    to_label = Catalog.type_label(to)

    gap =
      if adapters == [],
        do: "No installed runner converts #{from_label} to #{to_label}.",
        else: "An installed runner can convert it."

    %Issue{
      code: :type_mismatch,
      core_id: core_id,
      target: {:vertex, stage},
      adapters: adapters,
      message: "#{source} gives #{from_label}, but this field takes #{to_label}. #{gap}"
    }
  end

  @spec unknown_source(stage :: String.t()) :: Issue.t()
  defp unknown_source(stage) do
    %Issue{
      code: :unknown_source,
      target: {:vertex, stage},
      message: "That source does not exist."
    }
  end
end

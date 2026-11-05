defmodule Domovoy.Composer.Projection do
  @moduledoc """
  What a stage or the workflow looks like to a person: cards, input rows, compatible
  sources, relationship rows, routes, and issues by target. Pure, and it owns the
  accessible names.

  It reads a document that passed `Document.shape_issues/1`. An unknown runner or
  field shows as such, with its issue, rather than raising.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Cycles
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.LiteralPolicy

  @typep context :: %{
           document: Document.t(),
           stage: String.t() | nil,
           by_target: %{Issue.target() => [Issue.t()]},
           visible: [String.t()]
         }

  @doc """
  The view of one stage. A `nil` stage has no cards, for a draft with no stage.
  """
  @spec stage_view(document :: Document.t(), stage :: String.t() | nil) :: map()
  def stage_view(document, stage) do
    issues = Analyzer.issues(document)

    context = %{
      document: document,
      stage: stage,
      by_target: Enum.group_by(issues, & &1.target),
      visible: visible_sources(document, stage)
    }

    nodes = Enum.sort(Document.nodes(document, stage))
    relationships = Enum.flat_map(nodes, &relationships(context, &1))

    %{
      stage: stage,
      issues: issues,
      issues_by_target: context.by_target,
      cards: Enum.map(nodes, &card(context, &1)),
      inputs: document["inputs"] |> Enum.sort() |> Enum.map(&input_row(context, &1)),
      prior_sources: prior_sources(context),
      relationships: relationships,
      edges: Enum.map(relationships, &edge/1)
    }
  end

  @doc """
  The view of the workflow, with the same keys as `stage_view/2` plus `loop?`: its cards
  are the vertices and its edges are their routes.
  """
  @spec workflow_view(document :: Document.t()) :: map()
  def workflow_view(document) do
    issues = Analyzer.issues(document)

    context = %{
      document: document,
      stage: nil,
      by_target: Enum.group_by(issues, & &1.target),
      visible: []
    }

    cards = document["vertices"] |> Enum.sort() |> Enum.map(&vertex_card(context, &1))

    %{
      stage: nil,
      issues: issues,
      issues_by_target: context.by_target,
      cards: cards,
      inputs: document["inputs"] |> Enum.sort() |> Enum.map(&input_row(context, &1)),
      prior_sources: [],
      relationships: [],
      edges: Enum.flat_map(cards, &vertex_edges/1),
      loop?: Compatibility.loop?(document)
    }
  end

  @doc """
  Every other vertex as the next of stage `source`, for a route being dragged. A source
  that isn't a stage has none.
  """
  @spec route_targets(document :: Document.t(), source :: term()) :: [map()]
  def route_targets(document, source) do
    case document["vertices"] do
      %{^source => %{"kind" => "stage"}} ->
        for {name, _vertex} <- Enum.sort(document["vertices"]), name != source do
          %{socket: after_in_socket(name), fit: :exact, label: "#{name} runs after #{source}"}
        end

      _other ->
        []
    end
  end

  @doc """
  Every field of the stage as a Connect-to target for `source`. Incompatible fields
  stay in the list, because selecting one explains why it doesn't fit.
  """
  @spec connect_targets(document :: Document.t(), stage :: String.t(), source :: String.t()) ::
          [map()]
  def connect_targets(document, stage, source) do
    for {name, node} <- Enum.sort(Document.nodes(document, stage)),
        {:ok, runner} <- [Catalog.runner(node["runner"])],
        field <- runner.fields do
      fit = fit(document, stage, name, field.type_id, source)

      %{
        dom_id: "connect-#{dom_key(name, field.id)}",
        socket: input_socket(name, field.id),
        node: name,
        field: field.id,
        type_label: Catalog.type_label(field.type_id),
        fit: fit,
        label: bind_label(document, stage, name, field.id, source, fit)
      }
    end
  end

  @doc """
  Every node of the stage as a target for an After edge from `source`. One that would
  wait on itself stays in the list marked `fit: :incompatible`, as in `connect_targets/3`.
  """
  @spec after_targets(document :: Document.t(), stage :: String.t(), source :: String.t()) ::
          [map()]
  def after_targets(document, stage, source) do
    for {name, _node} <- Enum.sort(Document.nodes(document, stage)) do
      %{
        socket: after_in_socket(name),
        fit: if(Cycles.closes?(document, stage, name, source), do: :incompatible, else: :exact),
        label: "#{name} runs after #{source}"
      }
    end
  end

  @doc """
  The runners with a field of the type `source` makes, for a connection dropped on
  empty canvas. An unknown source has none.
  """
  @spec runners_reading(document :: Document.t(), stage :: String.t(), source :: String.t()) ::
          [map()]
  def runners_reading(document, stage, source) do
    case Compatibility.source_type(document, stage, source) do
      {_origin, type} -> Catalog.search(%{input: type})
      :error -> []
    end
  end

  @doc """
  The `node.field` names reading `node` as a source, in any stage.
  """
  @spec consumers(document :: Document.t(), node :: String.t()) :: [String.t()]
  def consumers(document, node) do
    for {_stage, name, consumer} <- Document.all_nodes(document),
        {field, %{"bind" => ^node}} <- consumer["inputs"] do
      "#{name}.#{field}"
    end
    |> Enum.sort()
  end

  @doc """
  Issues as list rows: where each one's link leads from `stage`, and the node to
  select. An issue about another stage patches there.
  """
  @spec issue_rows(document :: Document.t(), issues :: [Issue.t()], stage :: String.t() | nil) ::
          [map()]
  def issue_rows(document, issues, stage) do
    issues
    |> Enum.with_index()
    |> Enum.map(fn {issue, key} ->
      %{
        key: key,
        issue: issue,
        anchor: anchor(issue.target),
        node: target_node(issue.target, stage),
        patch_stage: other_stage(document, issue.target, stage),
        patch_workflow: stage != nil and decision_target?(document, issue.target)
      }
    end)
  end

  @spec anchor(target :: Issue.target()) :: String.t()
  defp anchor({:node, _stage, name}), do: "node-#{dom_part(name)}-select"
  defp anchor({:field, _stage, name, field}), do: "field-#{dom_key(name, field)}"
  defp anchor({:after, _stage, name, source}), do: "rel-after-#{dom_key(name, source)}"
  defp anchor({:input, name}), do: "input-#{dom_part(name)}"
  defp anchor({:vertex, _vertex}), do: "stage-canvas"
  defp anchor({:choice, decision, choice}), do: choice_dom_id(decision, choice)
  defp anchor(_workflow_or_choice), do: "workflow-settings"

  # What to select. On the workflow view that is a vertex.
  @spec target_node(target :: Issue.target(), stage :: String.t() | nil) :: String.t() | nil
  defp target_node({:node, _stage, name}, _view), do: name
  defp target_node({:field, _stage, name, _field}, _view), do: name
  defp target_node({:after, _stage, name, _source}, _view), do: name
  defp target_node({:vertex, vertex}, nil), do: vertex
  defp target_node({:choice, decision, _choice}, nil), do: decision
  defp target_node(_target, _view), do: nil

  # What only the workflow view can show.
  @spec decision_target?(document :: Document.t(), target :: Issue.target()) :: boolean()
  defp decision_target?(_document, {:choice, _decision, _choice}), do: true

  defp decision_target?(document, {:vertex, vertex}) do
    match?(%{"kind" => "decision"}, document["vertices"][vertex])
  end

  defp decision_target?(_document, _target), do: false

  @spec other_stage(document :: Document.t(), target :: Issue.target(), stage :: String.t() | nil) ::
          String.t() | nil
  defp other_stage(document, target, stage) do
    case target do
      {:vertex, _vertex} when stage == nil -> nil
      {:vertex, vertex} -> stage_unless_current(document, vertex, stage)
      {:node, vertex, _name} -> stage_unless_current(document, vertex, stage)
      {:field, vertex, _name, _field} -> stage_unless_current(document, vertex, stage)
      {:after, vertex, _name, _source} -> stage_unless_current(document, vertex, stage)
      _other -> nil
    end
  end

  @spec stage_unless_current(
          document :: Document.t(),
          vertex :: String.t(),
          stage :: String.t() | nil
        ) :: String.t() | nil
  defp stage_unless_current(document, vertex, stage) do
    if vertex != stage and match?(%{"kind" => "stage"}, document["vertices"][vertex]),
      do: vertex
  end

  # Identifiers

  # A hyphen is legal in a name and also separates the parts of a DOM id, so `a-select`
  # would read as node `a`'s select button. No name holds this character, which CSS
  # takes unescaped, so every hyphen left in an id is a separator.
  @spec dom_part(name :: String.t()) :: String.t()
  defp dom_part(name), do: String.replace(name, "-", "‿")

  @spec dom_key(first :: String.t(), second :: String.t()) :: String.t()
  defp dom_key(first, second), do: "#{dom_part(first)}-#{dom_part(second)}"

  # What the wires attach to. Names hold neither `:` nor `.`, so these need no encoding.
  @spec output_socket(name :: String.t()) :: String.t()
  defp output_socket(name), do: "out:#{name}"

  @spec input_socket(name :: String.t(), field :: String.t()) :: String.t()
  defp input_socket(name, field), do: "in:#{name}.#{field}"

  @spec after_out_socket(name :: String.t()) :: String.t()
  defp after_out_socket(name), do: "after-out:#{name}"

  @spec after_in_socket(name :: String.t()) :: String.t()
  defp after_in_socket(name), do: "after-in:#{name}"

  @spec edge(row :: map()) :: map()
  defp edge(%{kind: :after} = row) do
    %{
      from: after_out_socket(row.source),
      to: after_in_socket(row.node),
      kind: :after,
      problem: row.problem?
    }
  end

  defp edge(%{kind: :binding} = row) do
    %{
      from: output_socket(row.source),
      to: input_socket(row.node, row.field),
      kind: :value,
      problem: row.problem?
    }
  end

  # Cards

  @spec card(context :: context(), entry :: {String.t(), map()}) :: map()
  defp card(context, {name, node}) do
    runner =
      case Catalog.runner(node["runner"]) do
        {:ok, runner} -> runner
        :error -> nil
      end

    {required, optional} =
      context |> field_rows(name, node, runner) |> Enum.split_with(& &1.required)

    {configured, unset} = Enum.split_with(optional, &(&1.value != :empty))
    validators = Catalog.validators_for(node["runner"])
    added = Enum.map(node["validators"], &validator_row/1)
    added_ids = node["validators"]

    %{
      name: name,
      dom_id: "node-#{dom_part(name)}",
      output_socket: output_socket(name),
      after_out_socket: after_out_socket(name),
      after_in_socket: after_in_socket(name),
      runner_id: node["runner"],
      label: if(runner, do: runner.label, else: node["runner"]),
      plugin: runner && runner.plugin,
      output: runner && Catalog.type_label(runner.output),
      x: coordinate(context.document, ["layout", "stages", context.stage, name, "x"]),
      y: coordinate(context.document, ["layout", "stages", context.stage, name, "y"]),
      required: required,
      configured: configured,
      unset: unset,
      inherited: validators.inherited,
      added: added,
      available: Enum.reject(validators.curated, &(&1.id in added_ids)),
      policy: policy(node, runner),
      after: node["after"],
      after_options: Map.keys(Document.nodes(context.document, context.stage)) -- [name],
      issues: context.by_target[{:node, context.stage, name}] || [],
      issue_count: issue_count(context, name)
    }
  end

  @spec coordinate(document :: Document.t(), path :: [String.t() | nil]) :: integer()
  defp coordinate(document, path) do
    case get_in(document, path) do
      value when is_integer(value) -> value
      _absent -> 0
    end
  end

  @spec policy(node :: map(), runner :: map() | nil) :: map()
  defp policy(node, runner) do
    %{
      override: node["retry"]["max_attempts"],
      max_attempts: node["retry"]["max_attempts"] || (runner && runner.retry.max_attempts),
      effect: runner && Atom.to_string(runner.effect.class),
      store: node["store"]
    }
  end

  @spec validator_row(id :: String.t()) :: map()
  defp validator_row(id) do
    case Catalog.validator(id) do
      {:ok, validator} -> validator
      :error -> %{id: id, label: id, plugin: nil, description: nil}
    end
  end

  @spec issue_count(context :: context(), name :: String.t()) :: non_neg_integer()
  defp issue_count(context, name) do
    stage = context.stage

    context.by_target
    |> Enum.filter(fn {target, _issues} ->
      match?({:node, ^stage, ^name}, target) or match?({:field, ^stage, ^name, _field}, target) or
        match?({:after, ^stage, ^name, _source}, target)
    end)
    |> Enum.map(fn {_target, issues} -> length(issues) end)
    |> Enum.sum()
  end

  # Fields

  @spec field_rows(
          context :: context(),
          name :: String.t(),
          node :: map(),
          runner :: map() | nil
        ) :: [map()]
  defp field_rows(context, name, node, runner) do
    fields = if runner, do: runner.fields, else: []
    known = Enum.map(fields, &field_row(context, name, node, &1))

    unknown =
      for {id, _input} <- Enum.sort(node["inputs"]), id not in Enum.map(fields, & &1.id) do
        unknown_row(context, name, node, id)
      end

    known ++ unknown
  end

  @spec field_row(context :: context(), name :: String.t(), node :: map(), field :: map()) ::
          map()
  defp field_row(context, name, node, field) do
    value = value(node["inputs"][field.id])

    %{
      id: field.id,
      key: dom_key(name, field.id),
      dom_id: "field-#{dom_key(name, field.id)}",
      socket: input_socket(name, field.id),
      type_label: Catalog.type_label(field.type_id),
      required: field.required,
      editor: LiteralPolicy.editor(field.type_id),
      value: value,
      unresolved?: unresolved?(context, value),
      sources: compatible_sources(context, name, field.type_id),
      issues: context.by_target[{:field, context.stage, name, field.id}] || []
    }
  end

  @spec unknown_row(context :: context(), name :: String.t(), node :: map(), id :: String.t()) ::
          map()
  defp unknown_row(context, name, node, id) do
    value = value(node["inputs"][id])

    %{
      id: id,
      key: dom_key(name, id),
      dom_id: "field-#{dom_key(name, id)}",
      socket: input_socket(name, id),
      type_label: "Unknown field",
      required: false,
      editor: :bind_only,
      value: value,
      unresolved?: unresolved?(context, value),
      sources: [],
      issues: context.by_target[{:field, context.stage, name, id}] || []
    }
  end

  @spec value(input :: map() | nil) :: :empty | {:bind, String.t()} | {:literal, String.t()}
  defp value(nil), do: :empty
  defp value(%{"bind" => source}), do: {:bind, source}
  defp value(%{"literal" => raw}) when is_binary(raw), do: {:literal, raw}
  defp value(%{"literal" => _raw}), do: {:literal, ""}

  @spec unresolved?(context :: context(), value :: term()) :: boolean()
  defp unresolved?(context, {:bind, source}) do
    Compatibility.source_type(context.document, context.stage, source) == :error
  end

  defp unresolved?(_context, _value), do: false

  @spec compatible_sources(context :: context(), name :: String.t(), type :: String.t()) ::
          [String.t()]
  defp compatible_sources(context, name, type) do
    Enum.filter(
      context.visible,
      &(fit(context.document, context.stage, name, type, &1) != :incompatible)
    )
  end

  # Once per stage, since a visibility check walks the routes.
  @spec visible_sources(document :: Document.t(), stage :: String.t() | nil) :: [String.t()]
  defp visible_sources(_document, nil), do: []

  defp visible_sources(document, stage) do
    nodes = for {_stage, name, _node} <- Document.all_nodes(document), do: name
    choices = for {_decision, _choice, key, _type} <- Document.choice_inputs(document), do: key

    (nodes ++ Map.keys(document["inputs"]) ++ choices)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&(Compatibility.visibility(document, stage, &1) == :visible))
  end

  # `check/4` is about types only, so a fit also needs the source to be readable here,
  # and the bind not to be refused as a cycle.
  @spec fit(
          document :: Document.t(),
          stage :: String.t(),
          node :: String.t(),
          type :: String.t(),
          source :: String.t()
        ) :: :exact | :accepted_by_any | :incompatible
  defp fit(document, stage, node, type, source) do
    with false <- Cycles.closes?(document, stage, node, source),
         :visible <- Compatibility.visibility(document, stage, source),
         {:ok, fit} <- Compatibility.check(document, stage, type, source) do
      fit
    else
      _rejected -> :incompatible
    end
  end

  # Vertices

  @spec vertex_card(context :: context(), entry :: {String.t(), map()}) :: map()
  defp vertex_card(context, {name, vertex}) do
    %{
      name: name,
      kind: vertex["kind"],
      dom_id: "vertex-#{dom_part(name)}",
      in_socket: after_in_socket(name),
      out_socket: if(vertex["kind"] == "stage", do: after_out_socket(name)),
      x: coordinate(context.document, ["layout", "workflow", name, "x"]),
      y: coordinate(context.document, ["layout", "workflow", name, "y"]),
      start?: name == context.document["start"],
      node_count: map_size(Document.nodes(context.document, name)),
      next: vertex["next"],
      prompt: vertex["prompt"],
      decider: vertex["decider"],
      choices: Enum.map(vertex["choices"] || [], &route_row(context, name, &1)),
      issues: context.by_target[{:vertex, name}] || [],
      issue_count: vertex_issue_count(context, name)
    }
  end

  @spec route_row(context :: context(), decision :: String.t(), choice :: map()) :: map()
  defp route_row(context, decision, choice) do
    name = choice["name"]

    {kind, label, target} =
      case choice["target"] do
        ["run", vertex] -> {:run, "Run", vertex}
        ["rerun", vertex] -> {:rerun, "Rerun / next generation", vertex}
        ["halt"] -> {:halt, "Halt", nil}
      end

    %{
      name: name,
      dom_id: choice_dom_id(decision, name),
      key: dom_key(decision, name),
      socket: "choice-out:#{decision}.#{name}",
      kind: kind,
      label: label,
      target: target,
      description: choice["description"],
      inputs:
        Enum.map(Enum.sort(choice["inputs"]), fn {key, type} ->
          {key, Catalog.type_label(type)}
        end),
      issues: context.by_target[{:choice, decision, name}] || []
    }
  end

  @spec choice_dom_id(decision :: String.t(), choice :: String.t()) :: String.t()
  defp choice_dom_id(decision, choice), do: "choice-#{dom_key(decision, choice)}"

  @spec vertex_issue_count(context :: context(), name :: String.t()) :: non_neg_integer()
  defp vertex_issue_count(context, name) do
    context.by_target
    |> Enum.filter(fn {target, _issues} -> in_vertex?(target, name) end)
    |> Enum.map(fn {_target, issues} -> length(issues) end)
    |> Enum.sum()
  end

  @spec in_vertex?(target :: Issue.target(), name :: String.t()) :: boolean()
  defp in_vertex?(target, name) when is_tuple(target) do
    elem(target, 0) in [:vertex, :choice, :node, :field, :after] and elem(target, 1) == name
  end

  defp in_vertex?(_target, _name), do: false

  # A route to a vertex that doesn't exist has no socket, and its issue says so.
  @spec vertex_edges(card :: map()) :: [map()]
  defp vertex_edges(%{kind: "stage", next: nil}), do: []

  defp vertex_edges(%{kind: "stage"} = card) do
    [%{from: card.out_socket, to: after_in_socket(card.next), kind: :next, problem: false}]
  end

  defp vertex_edges(%{kind: "decision"} = card) do
    for %{target: target} = route <- card.choices, target != nil do
      %{
        from: route.socket,
        to: after_in_socket(target),
        kind: route.kind,
        problem: route.issues != []
      }
    end
  end

  # Sources from other vertices

  @spec prior_sources(context :: context()) :: [map()]
  defp prior_sources(%{stage: nil}), do: []

  defp prior_sources(%{document: document, stage: stage, visible: visible}) do
    own = Document.nodes(document, stage)

    for name <- visible,
        not is_map_key(own, name),
        not is_map_key(document["inputs"], name),
        {_scope, type} <- [Compatibility.source_type(document, stage, name)] do
      %{
        name: name,
        dom_id: "prior-#{dom_part(name)}",
        socket: output_socket(name),
        origin: "#{origin(document, name)} / #{Catalog.type_label(type)}"
      }
    end
  end

  @spec origin(document :: Document.t(), name :: String.t()) :: String.t()
  defp origin(document, name) do
    case Enum.find(Document.all_nodes(document), &match?({_stage, ^name, _node}, &1)) do
      {stage, _name, _node} ->
        "From stage: #{stage} / node: #{name}"

      nil ->
        {decision, _choice, _key, _type} =
          document
          |> Document.choice_inputs()
          |> Enum.find(&match?({_decision, _choice, ^name, _type}, &1))

        "From decision: #{decision} / input: #{name}"
    end
  end

  # Inputs

  @spec input_row(context :: context(), entry :: {String.t(), map()}) :: map()
  defp input_row(context, {name, input}) do
    %{
      name: name,
      dom_id: "input-#{dom_part(name)}",
      socket: output_socket(name),
      type_label: Catalog.type_label(input["type"]),
      required: Map.get(input, "required", false),
      default_state: default_state(input),
      issues: context.by_target[{:input, name}] || []
    }
  end

  @spec default_state(input :: map()) :: :absent | :null | :value
  defp default_state(%{"default" => nil}), do: :null
  defp default_state(%{"default" => _default}), do: :value
  defp default_state(_input), do: :absent

  # Relationships

  @spec relationships(context :: context(), entry :: {String.t(), map()}) :: [map()]
  defp relationships(context, {name, node}) do
    bindings =
      for {field, %{"bind" => source}} <- Enum.sort(node["inputs"]) do
        binding_row(context, name, node, field, source)
      end

    waits =
      for source <- node["after"] do
        %{
          dom_id: "rel-after-#{dom_key(name, source)}",
          kind: :after,
          node: name,
          source: source,
          field: nil,
          label: "#{name} runs after #{source}",
          problem?: is_map_key(context.by_target, {:after, context.stage, name, source})
        }
      end

    bindings ++ waits
  end

  @spec binding_row(
          context :: context(),
          name :: String.t(),
          node :: map(),
          field :: String.t(),
          source :: String.t()
        ) :: map()
  defp binding_row(context, name, node, field, source) do
    problem? = is_map_key(context.by_target, {:field, context.stage, name, field})

    fit =
      case Catalog.field(node["runner"], field) do
        {:ok, entry} when not problem? ->
          fit(context.document, context.stage, name, entry.type_id, source)

        _other ->
          :incompatible
      end

    %{
      dom_id: "rel-bind-#{dom_key(name, field)}",
      kind: :binding,
      node: name,
      source: source,
      field: field,
      label: bind_label(context.document, context.stage, name, field, source, fit),
      problem?: problem?
    }
  end

  @spec bind_label(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          field :: String.t(),
          source :: String.t(),
          fit :: :exact | :accepted_by_any | :incompatible
        ) :: String.t()
  defp bind_label(document, stage, name, field, source, fit) do
    origin =
      if is_map_key(Document.nodes(document, stage), source),
        do: "#{source} output",
        else: source

    "Bind #{origin} to #{name}.#{field}" <>
      if(fit == :accepted_by_any, do: "; accepted by Any", else: "")
  end
end

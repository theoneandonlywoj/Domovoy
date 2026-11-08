defmodule Domovoy.Composer.Analyzer do
  @moduledoc """
  Lists every problem with a document at once, without calling Core.

  This restates Core's rules because Core reports only the first error, and it is
  deliberately stricter than Core. The guarantee is one-way: what Core rejects is
  reported here or surfaces as a Core error from `Domovoy.Composer.Export`.

  Core's `check_stage_inputs` runs before `check_graphs` and drops the nodes of a
  stage whose graph fails, so a stage reading such a node gets `stage_input_unbound`
  from Core and the graph error stays hidden. Here both are reported.

  A document that isn't shaped like one gets only its shape issues, since no other
  check can read it. Nothing here raises, whatever the term.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Cycles
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.LiteralPolicy
  alias DomovoyCore.Name

  @any "DomovoyCore.Type.Any"

  # Issues in nested lists, flattened once at the top.
  @typep found :: [Issue.t() | found()]

  @doc """
  Every issue of a document, in stable order: workflow, inputs, then each vertex.
  """
  @spec issues(document :: term()) :: [Issue.t()]
  def issues(document) do
    case Document.shape_issues(document) do
      [] -> checks(document)
      malformed -> malformed
    end
  end

  @spec checks(document :: Document.t()) :: [Issue.t()]
  defp checks(document) do
    graphs =
      for {name, %{"kind" => "stage"}} <- document["vertices"], into: %{} do
        {name, graph_issues(document, name)}
      end

    List.flatten([
      workflow_issues(document),
      document["inputs"] |> Enum.sort() |> Enum.map(&input_issues/1),
      input_key_issues(document),
      document["vertices"] |> Enum.sort() |> Enum.map(&vertex_issues(document, graphs, &1))
    ])
  end

  # Workflow

  @spec workflow_issues(document :: Document.t()) :: found()
  defp workflow_issues(document) do
    [
      name_issues(document["name"], :workflow, :invalid_workflow_name),
      vertex_exists(document, document["start"], :workflow, :unknown_start, "The start"),
      ref_issues(document, Document.outputs(document), :workflow, "The workflow's outputs name")
    ]
  end

  @spec input_issues(entry :: {String.t(), map()}) :: found()
  defp input_issues({name, input}) do
    target = {:input, name}

    [
      name_issues(name, target, :invalid_workflow_input),
      unknown_type(input["type"], target),
      default_issues(name, input, target),
      required_with_default(name, input, target)
    ]
  end

  @spec unknown_type(type :: String.t(), target :: Issue.target()) :: found()
  defp unknown_type(type, target) do
    case Catalog.type(type) do
      {:ok, _type} ->
        []

      :error ->
        issue(:unknown_type, nil, target, "This names a type that isn't installed.")
    end
  end

  @spec default_issues(name :: String.t(), input :: map(), target :: Issue.target()) :: found()
  defp default_issues(name, %{"type" => type, "default" => default}, target) do
    cond do
      LiteralPolicy.editor(type) == :bind_only ->
        message =
          "#{Catalog.type_label(type)} values come only through a binding, so #{name} can't have a default."

        issue(:default_bind_only, nil, target, message)

      is_nil(default) and type != @any ->
        issue(
          :null_default,
          nil,
          target,
          "The default of #{name} is null, which only Any accepts."
        )

      is_nil(default) ->
        []

      LiteralPolicy.parse(type, default) == :error ->
        issue(
          :invalid_default,
          nil,
          target,
          "The default of #{name} isn't a valid #{Catalog.type_label(type)}."
        )

      true ->
        []
    end
  end

  defp default_issues(_name, _input, _target), do: []

  @spec required_with_default(name :: String.t(), input :: map(), target :: Issue.target()) ::
          found()
  defp required_with_default(name, %{"required" => true, "default" => _default}, target) do
    issue(
      :required_with_default,
      :invalid_workflow_input,
      target,
      "#{name} is required and has a default. Keep one."
    )
  end

  defp required_with_default(_name, _input, _target), do: []

  # One record name holds one type, whether or not a stage reads it.
  @spec input_key_issues(document :: Document.t()) :: found()
  defp input_key_issues(document) do
    seen = Map.new(document["inputs"], fn {name, input} -> {name, input["type"]} end)

    document
    |> Document.choice_inputs()
    |> Enum.sort()
    |> Enum.map_reduce(seen, fn {decision, choice, key, type}, seen ->
      case seen do
        %{^key => ^type} ->
          {[], seen}

        %{^key => first} ->
          {choice_key_conflict(decision, choice, key, first, type), seen}

        _unseen ->
          {[], Map.put(seen, key, type)}
      end
    end)
    |> elem(0)
  end

  @spec choice_key_conflict(
          decision :: String.t(),
          choice :: String.t(),
          key :: String.t(),
          first :: String.t(),
          type :: String.t()
        ) :: found()
  defp choice_key_conflict(decision, choice, key, first, type) do
    issue(
      :choice_input_type_mismatch,
      :choice_input_type_mismatch,
      {:choice, decision, choice},
      "#{key} is #{Catalog.type_label(first)} elsewhere, but #{choice} declares it " <>
        "#{Catalog.type_label(type)}."
    )
  end

  # Vertices

  @spec vertex_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          entry :: {String.t(), map()}
        ) :: found()
  defp vertex_issues(document, graphs, {name, %{"kind" => "stage"} = stage}) do
    target = {:vertex, name}

    [
      name_issues(name, target, :invalid_name),
      if(stage["next"],
        do: vertex_exists(document, stage["next"], target, :unknown_next, "The next vertex"),
        else: []
      ),
      stage["nodes"] |> Enum.sort() |> Enum.map(&node_issues(document, graphs, name, &1)),
      graphs[name]
    ]
  end

  defp vertex_issues(document, _graphs, {name, %{"kind" => "decision"} = decision}) do
    target = {:vertex, name}

    [
      name_issues(name, target, :invalid_name),
      decision_collisions(document, name),
      if(String.trim(decision["prompt"]) == "",
        do: issue(:blank_prompt, nil, target, "Decision #{name} needs a prompt."),
        else: []
      ),
      if(Enum.any?(Catalog.deciders(), &(&1.id == decision["decider"])),
        do: [],
        else: issue(:unknown_decider, nil, target, "Decision #{name} names an unknown decider.")
      ),
      decider_node_issues(document, name, decision),
      ref_issues(
        document,
        Document.evidence(decision),
        target,
        "Decision #{name}'s evidence names"
      ),
      choices_issues(document, name, decision["choices"])
    ]
  end

  # A decider that reads a node needs a `node` option naming a node of the document.
  @spec decider_node_issues(document :: map(), name :: String.t(), decision :: map()) ::
          [Issue.t()]
  defp decider_node_issues(document, name, decision) do
    target = {:vertex, name}

    reads_node? =
      Enum.any?(Catalog.deciders(), &(&1.id == decision["decider"] and &1.reads_node?))

    case Document.decider_node(decision) do
      nil when reads_node? ->
        issue(
          :missing_decider_node,
          nil,
          target,
          "Decision #{name} needs the node its decider reads."
        )

      nil ->
        []

      node ->
        if Enum.any?(Document.all_nodes(document), &match?({_stage, ^node, _node}, &1)),
          do: [],
          else:
            issue(
              :unknown_decider_node,
              nil,
              target,
              "Decision #{name} reads node #{node}, which doesn't exist."
            )
    end
  end

  # Evidence and outputs are only shown, so a ref naming no node of the document would
  # show nothing; edits keep them current, and a hand-built one is reported here.
  @spec ref_issues(
          document :: Document.t(),
          refs :: [Document.ref()],
          target :: Issue.target(),
          owner :: String.t()
        ) :: found()
  defp ref_issues(document, refs, target, owner) do
    for %{"stage" => stage, "node" => node} <- refs,
        not is_map_key(Document.nodes(document, stage), node) do
      issue(
        :unknown_evidence_node,
        nil,
        target,
        "#{owner} node #{node} of #{stage}, which doesn't exist."
      )
    end
  end

  @spec decision_collisions(document :: Document.t(), name :: String.t()) :: found()
  defp decision_collisions(document, name) do
    keys = for {_decision, _choice, key, _type} <- Document.choice_inputs(document), do: key

    if is_map_key(document["inputs"], name) or name in keys,
      do: collision(name, {:vertex, name}),
      else: []
  end

  @spec choices_issues(document :: Document.t(), decision :: String.t(), choices :: [map()]) ::
          found()
  defp choices_issues(_document, decision, []) do
    issue(:no_choices, nil, {:vertex, decision}, "Decision #{decision} offers no choice.")
  end

  defp choices_issues(document, decision, choices) do
    names = Enum.map(choices, & &1["name"])

    [
      for name <- Enum.uniq(names -- Enum.uniq(names)) do
        issue(
          :duplicate_choice,
          nil,
          {:choice, decision, name},
          "Decision #{decision} offers #{name} more than once."
        )
      end,
      Enum.map(choices, &choice_issues(document, decision, &1))
    ]
  end

  @spec choice_issues(document :: Document.t(), decision :: String.t(), choice :: map()) ::
          found()
  defp choice_issues(document, decision, choice) do
    name = choice["name"]
    target = {:choice, decision, name}

    [
      name_issues(name, target, :invalid_name),
      description_issues(name, choice["description"], target),
      target_issues(document, target, choice["target"]),
      choice_input_issues(target, choice)
    ]
  end

  # Core refuses only the empty string, so whitespace is stricter than Core.
  @spec description_issues(
          name :: String.t(),
          description :: String.t(),
          target :: Issue.target()
        ) :: found()
  defp description_issues(name, description, target) do
    cond do
      description == "" ->
        issue(
          :blank_description,
          :invalid_choice_description,
          target,
          "Choice #{name} needs a description."
        )

      String.trim(description) == "" ->
        issue(:blank_description, nil, target, "Choice #{name} needs a description.")

      true ->
        []
    end
  end

  @spec target_issues(document :: Document.t(), target :: Issue.target(), goal :: [String.t()]) ::
          found()
  defp target_issues(_document, _target, ["halt"]), do: []

  defp target_issues(document, target, ["rerun", vertex]) do
    case document["vertices"] do
      %{^vertex => %{"kind" => "stage"}} ->
        []

      %{^vertex => _decision} ->
        issue(
          :rerun_target_not_a_stage,
          :rerun_target_not_a_stage,
          target,
          "Only a Stage can be re-run, and #{vertex} is a Decision."
        )

      _missing ->
        vertex_exists(document, vertex, target, :unknown_target, "The target")
    end
  end

  defp target_issues(document, target, ["run", vertex]) do
    vertex_exists(document, vertex, target, :unknown_target, "The target")
  end

  @spec choice_input_issues(target :: Issue.target(), choice :: map()) :: found()
  defp choice_input_issues(target, %{"inputs" => inputs} = choice) do
    [
      if(inputs != %{} and not match?(["rerun", _vertex], choice["target"]),
        do:
          issue(
            :choice_inputs_not_rerun,
            :choice_inputs_not_rerun,
            target,
            "Only a Rerun choice can declare inputs."
          ),
        else: []
      ),
      for {key, type} <- Enum.sort(inputs) do
        [name_issues(key, target, :invalid_name), unknown_type(type, target)]
      end
    ]
  end

  # Nodes

  @spec node_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          entry :: {String.t(), map()}
        ) :: found()
  defp node_issues(document, graphs, stage, {name, node}) do
    target = {:node, stage, name}

    [
      name_issues(name, target, :invalid_node),
      node_collisions(document, stage, name, target),
      case Catalog.runner(node["runner"]) do
        {:ok, runner} ->
          runner_issues(document, graphs, stage, name, node, runner)

        :error ->
          issue(:unknown_runner, nil, target, "#{name} names a runner that isn't installed.")
      end
    ]
  end

  @spec node_collisions(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          target :: Issue.target()
        ) :: found()
  defp node_collisions(document, stage, name, target) do
    keys = for {_decision, _choice, key, _type} <- Document.choice_inputs(document), do: key

    in_other_stage? =
      Enum.any?(Document.all_nodes(document), fn {other, node, _value} ->
        other != stage and node == name
      end)

    if in_other_stage? or is_map_key(document["inputs"], name) or name in keys or
         name in Document.decisions(document),
       do: collision(name, target),
       else: []
  end

  @spec runner_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          name :: String.t(),
          node :: map(),
          runner :: map()
        ) :: found()
  defp runner_issues(document, graphs, stage, name, node, runner) do
    [
      Enum.map(runner.fields, &required_missing(stage, name, node, &1)),
      node["inputs"]
      |> Enum.sort()
      |> Enum.map(&input_value_issues(document, graphs, stage, name, runner, &1)),
      max_attempts_issues(stage, name, node),
      validator_issues(stage, name, node, runner)
    ]
  end

  # Mirrors `default_present?/1` of `DomovoyCore.Node`.
  @spec required_missing(
          stage :: String.t(),
          name :: String.t(),
          node :: map(),
          field :: map()
        ) :: found()
  defp required_missing(stage, name, node, field) do
    if field.required and not is_map_key(node["inputs"], field.id) and
         not default_present?(field.default) do
      issue(
        :required_missing,
        :invalid_node,
        {:field, stage, name, field.id},
        "#{name}.#{field.id} is required and has no source."
      )
    else
      []
    end
  end

  @spec default_present?(default :: term()) :: boolean()
  defp default_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp default_present?(value) when is_map(value), do: map_size(value) > 0
  defp default_present?(value), do: value not in [nil, []]

  @spec input_value_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          node :: String.t(),
          runner :: map(),
          entry :: {String.t(), map()}
        ) :: found()
  defp input_value_issues(document, graphs, stage, node, runner, {id, input}) do
    target = {:field, stage, node, id}

    case {Catalog.field(runner.id, id), input} do
      {:error, _input} ->
        issue(:unknown_field, :invalid_node, target, "#{node} has no such field.")

      {{:ok, field}, %{"literal" => raw}} ->
        literal_issues(node, field, raw, target)

      {{:ok, field}, %{"bind" => source}} ->
        if is_map_key(Document.nodes(document, stage), source),
          do: [],
          else: external_issues(document, graphs, stage, node, field, source, target)
    end
  end

  @spec literal_issues(
          node :: String.t(),
          field :: map(),
          raw :: term(),
          target :: Issue.target()
        ) :: found()
  defp literal_issues(node, field, raw, target) do
    label = Catalog.type_label(field.type_id)

    case LiteralPolicy.parse(field.type_id, raw) do
      :error ->
        message =
          if LiteralPolicy.editor(field.type_id) == :bind_only,
            do: "#{label} values come only through a binding.",
            else: "#{node}.#{field.id} isn't a valid #{label}."

        issue(:invalid_literal, nil, target, message)

      {:ok, nil} when field.required ->
        issue(
          :null_required,
          nil,
          target,
          "#{node}.#{field.id} is required, so it can't be null."
        )

      {:ok, value} when field.required and is_binary(value) ->
        if String.trim(value) == "",
          do:
            issue(
              :blank_required,
              nil,
              target,
              "#{node}.#{field.id} is required, so it can't be blank."
            ),
          else: []

      {:ok, _value} ->
        []
    end
  end

  @spec external_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          node :: String.t(),
          field :: map(),
          source :: String.t(),
          target :: Issue.target()
        ) :: found()
  defp external_issues(document, graphs, stage, node, field, source, target) do
    known? = Compatibility.source_type(document, stage, source) != :error

    [
      visibility_issues(document, graphs, stage, node, field, source, known?, target),
      if(known?, do: type_issues(document, stage, field, source, target), else: []),
      unusable_default(document, node, field, source, target)
    ]
  end

  # Core builds this: its definition never looks at a default. A run omitting the
  # input then hands the default to the required field, which refuses it.
  @spec unusable_default(
          document :: Document.t(),
          node :: String.t(),
          field :: map(),
          source :: String.t(),
          target :: Issue.target()
        ) :: found()
  defp unusable_default(document, node, %{required: true} = field, source, target) do
    case document["inputs"][source] do
      %{"type" => type, "default" => default} ->
        if blank_default?(type, default) do
          issue(
            :unusable_input_default,
            nil,
            target,
            "#{node}.#{field.id} is required, but the default of #{source} is blank or null, " <>
              "so a run omitting #{source} fails."
          )
        else
          []
        end

      _no_default ->
        []
    end
  end

  defp unusable_default(_document, _node, _field, _source, _target), do: []

  @spec blank_default?(type :: String.t(), default :: term()) :: boolean()
  defp blank_default?(_type, nil), do: true

  defp blank_default?(type, default) do
    case LiteralPolicy.parse(type, default) do
      {:ok, nil} -> true
      {:ok, value} when is_binary(value) -> String.trim(value) == ""
      _other -> false
    end
  end

  # `:visible` reads control flow only, so a producer in a stage whose graph fails
  # is checked here: Core has dropped its nodes by the time this stage reads them.
  @spec visibility_issues(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          node :: String.t(),
          field :: map(),
          source :: String.t(),
          known? :: boolean(),
          target :: Issue.target()
        ) :: found()
  defp visibility_issues(document, graphs, stage, node, field, source, known?, target) do
    label = "#{node}.#{field.id}"

    case Compatibility.visibility(document, stage, source) do
      :visible ->
        case broken_producer(document, graphs, stage, source) do
          nil ->
            []

          producer ->
            issue(
              :source_not_visible,
              :stage_input_unbound,
              target,
              "#{label} reads #{source}, which isn't available until stage #{producer}'s graph is fixed."
            )
        end

      :not_visible when known? ->
        issue(
          :source_not_visible,
          :stage_input_unbound,
          target,
          "#{label} reads #{source}, which doesn't run before stage #{stage}."
        )

      :not_visible ->
        issue(
          :unresolved_source,
          :stage_input_unbound,
          target,
          "#{label} reads #{source}, which does not exist."
        )

      :stage_unreachable ->
        issue(
          :unresolved_source,
          nil,
          target,
          "#{label} reads #{source}, which can't run before stage #{stage}, " <>
            "since start doesn't reach it."
        )
    end
  end

  @spec broken_producer(
          document :: Document.t(),
          graphs :: %{String.t() => [Issue.t()]},
          stage :: String.t(),
          source :: String.t()
        ) :: String.t() | nil
  defp broken_producer(document, graphs, stage, source) do
    graphs
    |> Enum.sort()
    |> Enum.find_value(fn {other, issues} ->
      if other != stage and issues != [] and is_map_key(Document.nodes(document, other), source),
        do: other
    end)
  end

  @spec type_issues(
          document :: Document.t(),
          stage :: String.t(),
          field :: map(),
          source :: String.t(),
          target :: Issue.target()
        ) :: found()
  defp type_issues(document, stage, field, source, target) do
    case Compatibility.check(document, stage, field.type_id, source) do
      {:ok, _fit} -> []
      {:error, issue} -> [%{issue | target: target}]
    end
  end

  @spec max_attempts_issues(stage :: String.t(), name :: String.t(), node :: map()) :: found()
  defp max_attempts_issues(stage, name, %{"retry" => %{"max_attempts" => attempts}})
       when not is_integer(attempts) or attempts < 1 do
    issue(
      :invalid_max_attempts,
      :invalid_node,
      {:node, stage, name},
      "#{name} must try at least once."
    )
  end

  defp max_attempts_issues(_stage, _name, _node), do: []

  @spec validator_issues(stage :: String.t(), name :: String.t(), node :: map(), runner :: map()) ::
          found()
  defp validator_issues(stage, name, node, runner) do
    target = {:node, stage, name}
    %{inherited: inherited, curated: curated} = Catalog.validators_for(runner.id)
    inherited_ids = Enum.map(inherited, & &1.id)
    curated_ids = Enum.map(curated, & &1.id)
    repeated = node["validators"] -- Enum.uniq(node["validators"])

    [
      for id <- Enum.uniq(repeated) do
        issue(:duplicate_validator, nil, target, "#{name} adds #{validator_label(id)} twice.")
      end,
      for id <- Enum.uniq(node["validators"]), id not in curated_ids do
        cond do
          id in inherited_ids ->
            issue(
              :duplicate_validator,
              nil,
              target,
              "#{name} already inherits #{validator_label(id)} from its runner."
            )

          match?({:ok, _validator}, Catalog.validator(id)) ->
            issue(
              :validator_misfit,
              nil,
              target,
              "#{validator_label(id)} reads fields that #{name}'s runner doesn't have."
            )

          true ->
            issue(:unknown_validator, nil, target, "#{name} names an unknown validator.")
        end
      end
    ]
  end

  @spec validator_label(id :: String.t()) :: String.t()
  defp validator_label(id) do
    case Catalog.validator(id) do
      {:ok, validator} -> validator.label
      :error -> "a validator"
    end
  end

  # Graphs

  # What makes Core's `Graph.new` fail for a stage, leaving no nodes for later stages.
  @spec graph_issues(document :: Document.t(), stage :: String.t()) :: [Issue.t()]
  defp graph_issues(document, stage) do
    List.flatten([
      after_issues(document, stage),
      same_graph_mismatches(document, stage),
      Compatibility.conflicting_inputs(document, stage),
      cycle_issues(document, stage)
    ])
  end

  @spec after_issues(document :: Document.t(), stage :: String.t()) :: found()
  defp after_issues(document, stage) do
    nodes = Document.nodes(document, stage)

    for {name, node} <- Enum.sort(nodes),
        source <- Enum.uniq(node["after"]),
        not is_map_key(nodes, source) do
      %Issue{
        code: :after_source_not_found,
        core_id: :after_source_not_found,
        target: {:after, stage, name, source},
        message: "#{name} waits on #{source}, which does not exist in this stage."
      }
    end
  end

  @spec same_graph_mismatches(document :: Document.t(), stage :: String.t()) :: found()
  defp same_graph_mismatches(document, stage) do
    nodes = Document.nodes(document, stage)

    for {name, node} <- Enum.sort(nodes),
        {id, %{"bind" => source}} <- Enum.sort(node["inputs"]),
        is_map_key(nodes, source),
        {:ok, field} <- [Catalog.field(node["runner"], id)],
        match?({:same_graph, _type}, Compatibility.source_type(document, stage, source)),
        {:error, issue} <- [Compatibility.check(document, stage, field.type_id, source)] do
      %{issue | target: {:field, stage, name, id}}
    end
  end

  @spec cycle_issues(document :: Document.t(), stage :: String.t()) :: found()
  defp cycle_issues(document, stage) do
    case Cycles.check(document, stage) do
      :ok -> []
      {:error, issue} -> [issue]
    end
  end

  # Shared

  @spec vertex_exists(
          document :: Document.t(),
          vertex :: String.t(),
          target :: Issue.target(),
          code :: atom(),
          what :: String.t()
        ) :: found()
  defp vertex_exists(document, vertex, target, code, what) do
    if is_map_key(document["vertices"], vertex) do
      []
    else
      issue(code, :vertex_not_in_workflow, target, "#{what} #{vertex} does not exist.")
    end
  end

  @spec name_issues(name :: String.t(), target :: Issue.target(), core_id :: atom()) :: found()
  defp name_issues(name, target, core_id) do
    if Name.valid?(name) do
      []
    else
      issue(:invalid_name, core_id, target, "A name holds 1 to 128 letters, digits, _ or -.")
    end
  end

  @spec collision(name :: String.t(), target :: Issue.target()) :: found()
  defp collision(name, target) do
    issue(:name_collision, :name_collision, target, "#{name} is used for more than one thing.")
  end

  @spec issue(
          code :: atom(),
          core_id :: atom() | nil,
          target :: Issue.target(),
          message :: String.t()
        ) :: found()
  defp issue(code, core_id, target, message) do
    [%Issue{code: code, core_id: core_id, target: target, message: message}]
  end
end

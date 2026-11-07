defmodule Domovoy.Composer.Operations do
  @moduledoc """
  The one write path for a draft. Forms and pointer gestures send the same ops.

  An edit is pure and either applies whole or returns an `Issue` with the document
  untouched. Rejected here: unknown names, runners and types; wrong parameter
  shapes; NUL or broken UTF-8 in any string; invalid or colliding engine names;
  type mismatches; cycles. Anything else an incomplete draft may hold, such as a
  missing required input or an unresolved reference, is valid to save.

  Browser values only ever meet a map lookup, through `Domovoy.Catalog` or the
  document itself, so an unknown name creates no atom and loads no module.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Analyzer
  alias Domovoy.Composer.Compatibility
  alias Domovoy.Composer.Cycles
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.LiteralPolicy
  alias DomovoyCore.Name

  @coordinate_limit 100_000
  @grid_columns 4
  @grid_origin {60, 80}
  # Wide enough for a wire's curve beside both cards, and tall enough for a typical node.
  @grid_step {460, 420}
  @input_keys ["default", "required", "type"]
  @decision_keys ["decider", "decider_options", "prompt"]
  @choice_keys ["description", "inputs", "name", "target"]

  @type op :: tuple()
  @type kind :: :definition | :layout | :none
  @type preview :: %{
          document: Document.t(),
          dropped: [dropped()],
          warnings: [Issue.t()],
          new_issues: [Issue.t()]
        }
  @type dropped :: {:field, String.t()} | {:validator, String.t()}

  defguardp binaries(a, b) when is_binary(a) and is_binary(b)
  defguardp binaries(a, b, c) when binaries(a, b) and is_binary(c)
  defguardp binaries(a, b, c, d) when binaries(a, b, c) and is_binary(d)

  @doc """
  Applies one op. An edit that changes nothing returns `:none`, so a caller neither
  saves nor adds an undo entry.
  """
  @spec edit(document :: Document.t(), op :: term()) ::
          {:ok, Document.t(), kind()} | {:error, Issue.t()}
  def edit(document, op) when is_map(document) do
    with :ok <- check_text(op),
         {:ok, updated, kind} <- apply_op(document, op) do
      if updated == document, do: {:ok, document, :none}, else: {:ok, updated, kind}
    end
  end

  @doc """
  Shows what an op would do, without saving it: the fields and validators it
  drops, the warnings it causes, and the analyzer issues it adds. A warning is a
  reference the op breaks, such as an Any field losing its sibling concrete binding
  or a source no longer preceding its stage, or a dangling reference a new name
  re-resolves.
  """
  @spec preview(document :: Document.t(), op :: term()) :: preview() | {:error, Issue.t()}
  def preview(document, op) do
    with {:ok, updated, _kind} <- edit(document, op) do
      %{
        document: updated,
        dropped: dropped(document, updated, op),
        warnings: warnings(document, updated),
        new_issues: Analyzer.issues(updated) -- Analyzer.issues(document)
      }
    end
  end

  # Nodes

  @spec apply_op(document :: Document.t(), op :: term()) ::
          {:ok, Document.t(), kind()} | {:error, Issue.t()}
  defp apply_op(document, {:add_node, stage, runner_id, name})
       when binaries(stage, runner_id, name) do
    with {:ok, _vertex} <- fetch_stage(document, stage),
         {:ok, _runner} <- fetch_runner(runner_id),
         :ok <- check_name(name),
         :ok <- check_free_node_name(document, name) do
      {:ok, insert_node(document, stage, name, Document.new_node(runner_id)), :definition}
    end
  end

  defp apply_op(document, {:rename_node, stage, old, new}) when binaries(stage, old, new) do
    with {:ok, _node} <- fetch_node(document, stage, old),
         :ok <- check_rename(document, old, new),
         updated = rename_node(document, stage, old, new),
         :ok <- Cycles.check(updated, stage) do
      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:remove_node, stage, name}) when binaries(stage, name) do
    with {:ok, _node} <- fetch_node(document, stage, name) do
      updated =
        document
        |> update_in(["vertices", stage, "nodes"], &Map.delete(&1, name))
        |> update_placements(&Map.delete(&1, name))

      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:bind, stage, node, field, source, [replace_literal: replace]})
       when binaries(stage, node, field, source) and is_boolean(replace) do
    target = {:field, stage, node, field}

    with {:ok, current} <- fetch_node(document, stage, node),
         {:ok, entry} <- fetch_field(current, field),
         updated = put_input(document, stage, node, field, %{"bind" => source}),
         :ok <- Cycles.check(updated, stage),
         {:ok, _fit} <- check_compatible(updated, stage, entry.type_id, source, target),
         :ok <- check_no_literal(current, field, replace, target) do
      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:set_literal, stage, node, field, raw, [replace_binding: replace]})
       when binaries(stage, node, field, raw) and is_boolean(replace) do
    target = {:field, stage, node, field}

    with {:ok, current} <- fetch_node(document, stage, node),
         {:ok, entry} <- fetch_field(current, field),
         :ok <- check_editable(entry, target),
         :ok <- check_no_binding(current, field, replace, target) do
      {:ok, put_input(document, stage, node, field, %{"literal" => raw}), :definition}
    end
  end

  defp apply_op(document, {:clear_input, stage, node, field}) when binaries(stage, node, field) do
    with {:ok, current} <- fetch_node(document, stage, node),
         :ok <- check_clearable(current, field) do
      {:ok, update_in(document, node_path(stage, node, "inputs"), &Map.delete(&1, field)),
       :definition}
    end
  end

  defp apply_op(document, {:add_after, stage, node, source}) when binaries(stage, node, source) do
    with {:ok, _current} <- fetch_node(document, stage, node),
         {:ok, _source} <- fetch_node(document, stage, source),
         updated = update_in(document, node_path(stage, node, "after"), &add_once(&1, source)),
         :ok <- Cycles.check(updated, stage) do
      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:remove_after, stage, node, source})
       when binaries(stage, node, source) do
    with {:ok, _current} <- fetch_node(document, stage, node) do
      {:ok, update_in(document, node_path(stage, node, "after"), &List.delete(&1, source)),
       :definition}
    end
  end

  defp apply_op(document, {:replace_runner, stage, node, runner_id})
       when binaries(stage, node, runner_id) do
    with {:ok, current} <- fetch_node(document, stage, node),
         {:ok, runner} <- fetch_runner(runner_id) do
      {:ok, replace_runner(document, stage, node, current, runner), :definition}
    end
  end

  defp apply_op(document, {:insert_adapter, stage, source, node, field, runner_id})
       when binaries(stage, source, node, field) and is_binary(runner_id) do
    target = {:field, stage, node, field}

    with {:ok, current} <- fetch_node(document, stage, node),
         {:ok, entry} <- fetch_field(current, field),
         :ok <- check_adapter_slot(current, field, target),
         {:ok, adapter_field} <- fetch_adapter(document, stage, source, entry, runner_id, target),
         name = adapter_name(document, runner_id),
         adapter =
           put_in(Document.new_node(runner_id), ["inputs", adapter_field.id], %{"bind" => source}),
         updated =
           document
           |> insert_node(stage, name, adapter)
           |> put_input(stage, node, field, %{"bind" => name}),
         :ok <- Cycles.check(updated, stage) do
      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:set_validators, stage, node, ids})
       when binaries(stage, node) and is_list(ids) do
    with {:ok, _current} <- fetch_node(document, stage, node),
         :ok <- check_validators(ids) do
      {:ok, put_in(document, node_path(stage, node, "validators"), ids), :definition}
    end
  end

  defp apply_op(document, {:set_execution, stage, node, max_attempts, store})
       when binaries(stage, node) and (is_integer(max_attempts) or is_nil(max_attempts)) and
              is_boolean(store) do
    retry = if max_attempts, do: %{"max_attempts" => max_attempts}, else: %{}

    with {:ok, _current} <- fetch_node(document, stage, node) do
      updated =
        document
        |> put_in(node_path(stage, node, "retry"), retry)
        |> put_in(node_path(stage, node, "store"), store)

      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:set_description, target, text}) when is_binary(text) do
    with {:ok, path} <- metadata_path(document, target),
         :ok <- check_description(text) do
      {:ok, put_in(document, path, %{"description" => text}), :definition}
    end
  end

  # Layout

  defp apply_op(document, {:move, scope, name, x, y})
       when is_binary(name) and is_number(x) and is_number(y) do
    with {:ok, path} <- layout_path(document, scope),
         :ok <- check_placed(document, scope, name) do
      {:ok, put_in(document, path ++ [name], %{"x" => coordinate(x), "y" => coordinate(y)}),
       :layout}
    end
  end

  # Workflow

  defp apply_op(document, {:set_workflow_name, name}) when is_binary(name) do
    with :ok <- check_name(name), do: {:ok, Map.put(document, "name", name), :definition}
  end

  defp apply_op(document, {:set_start, vertex}) when is_binary(vertex) do
    with {:ok, _vertex} <- fetch_vertex(document, vertex) do
      {:ok, Map.put(document, "start", vertex), :definition}
    end
  end

  defp apply_op(document, {:put_input, name, attrs}) when is_binary(name) and is_map(attrs) do
    with :ok <- check_name(name),
         {:ok, input} <- normalize_input(attrs),
         :ok <- check_free_input_name(document, name, input["type"]) do
      {:ok, put_in(document, ["inputs", name], keep_metadata(document["inputs"][name], input)),
       :definition}
    end
  end

  defp apply_op(document, {:remove_input, name}) when is_binary(name) do
    if is_map_key(document["inputs"], name) do
      updated =
        document
        |> update_in(["inputs"], &Map.delete(&1, name))
        |> update_placements(&Map.delete(&1, name))

      {:ok, updated, :definition}
    else
      {:error, unknown(:unknown_input, "input")}
    end
  end

  # Vertices

  defp apply_op(document, {:add_stage, name}) when is_binary(name) do
    with :ok <- check_name(name),
         :ok <- check_free_vertex_name(document, name) do
      updated =
        document
        |> insert_vertex(name, Document.stage())
        |> put_in(["layout", "stages", name], %{})

      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:add_decision, name}) when is_binary(name) do
    with :ok <- check_name(name),
         :ok <- check_free_vertex_name(document, name),
         :ok <- check_free_decision_name(document, name) do
      {:ok, insert_vertex(document, name, Document.decision()), :definition}
    end
  end

  defp apply_op(document, {:remove_vertex, name}) when is_binary(name) do
    with {:ok, _vertex} <- fetch_vertex(document, name) do
      nodes = document |> Document.nodes(name) |> Map.keys()

      updated =
        document
        |> update_placements(&Map.drop(&1, nodes))
        |> update_in(["vertices"], &Map.delete(&1, name))
        |> update_in(["layout", "workflow"], &Map.delete(&1, name))
        |> update_in(["layout", "stages"], &Map.delete(&1, name))

      {:ok, updated, :definition}
    end
  end

  defp apply_op(document, {:set_next, stage, vertex})
       when is_binary(stage) and (is_binary(vertex) or is_nil(vertex)) do
    with {:ok, _stage} <- fetch_stage(document, stage),
         :ok <- check_next(document, vertex) do
      {:ok, put_in(document, ["vertices", stage, "next"], vertex), :definition}
    end
  end

  defp apply_op(document, {:put_decision, name, attrs}) when is_binary(name) and is_map(attrs) do
    with {:ok, decision} <- fetch_decision(document, name),
         :ok <- check_decision_attrs(attrs) do
      # Empty options are dropped, so clearing the node leaves no trace.
      decision =
        case Map.merge(decision, attrs) do
          %{"decider_options" => options} = merged when options == %{} ->
            Map.delete(merged, "decider_options")

          merged ->
            merged
        end

      {:ok, put_in(document, ["vertices", name], decision), :definition}
    end
  end

  defp apply_op(document, {:put_choice, decision, attrs})
       when is_binary(decision) and is_map(attrs) do
    with {:ok, current} <- fetch_decision(document, decision),
         {:ok, choice} <- normalize_choice(document, decision, attrs) do
      choices = upsert_choice(current["choices"], choice)
      {:ok, put_in(document, ["vertices", decision, "choices"], choices), :definition}
    end
  end

  defp apply_op(document, {:remove_choice, decision, name}) when binaries(decision, name) do
    with {:ok, current} <- fetch_decision(document, decision) do
      case Enum.split_with(current["choices"], &(&1["name"] == name)) do
        {[], _kept} ->
          {:error, unknown(:unknown_choice, "choice")}

        {_removed, kept} ->
          {:ok, put_in(document, ["vertices", decision, "choices"], kept), :definition}
      end
    end
  end

  defp apply_op(_document, _op), do: {:error, invalid_params()}

  # Descriptions

  @spec metadata_path(document :: Document.t(), target :: term()) ::
          {:ok, [String.t()]} | {:error, Issue.t()}
  defp metadata_path(document, {:node, stage, name}) when binaries(stage, name) do
    with {:ok, _node} <- fetch_node(document, stage, name) do
      {:ok, node_path(stage, name, "metadata")}
    end
  end

  defp metadata_path(document, {:vertex, name}) when is_binary(name) do
    with {:ok, _vertex} <- fetch_vertex(document, name) do
      {:ok, ["vertices", name, "metadata"]}
    end
  end

  defp metadata_path(document, {:input, name}) when is_binary(name) do
    if is_map_key(document["inputs"], name) do
      {:ok, ["inputs", name, "metadata"]}
    else
      {:error, unknown(:unknown_input, "input")}
    end
  end

  defp metadata_path(_document, _target), do: {:error, invalid_params()}

  # Refuses what `Document.description/1` calls malformed. Never echoes the text.
  @spec check_description(text :: String.t()) :: :ok | {:error, Issue.t()}
  defp check_description(text) do
    if String.trim(text) == "", do: {:error, invalid_params()}, else: :ok
  end

  @spec keep_metadata(current :: map() | nil, input :: map()) :: map()
  defp keep_metadata(%{"metadata" => metadata}, input), do: Map.put(input, "metadata", metadata)
  defp keep_metadata(_current, input), do: input

  # A description says what the runner does, so another runner makes it stale.
  @spec drop_stale_metadata(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          node :: map(),
          runner :: map()
        ) :: Document.t()
  defp drop_stale_metadata(document, _stage, _name, %{"runner" => same}, %{id: same}),
    do: document

  defp drop_stale_metadata(document, stage, name, _node, _runner) do
    update_in(document, ["vertices", stage, "nodes", name], &Map.delete(&1, "metadata"))
  end

  # Lookups

  @spec fetch_vertex(document :: Document.t(), name :: String.t()) ::
          {:ok, map()} | {:error, Issue.t()}
  defp fetch_vertex(document, name) do
    case document["vertices"] do
      %{^name => vertex} -> {:ok, vertex}
      _other -> {:error, unknown(:unknown_vertex, "vertex")}
    end
  end

  @spec fetch_stage(document :: Document.t(), name :: String.t()) ::
          {:ok, map()} | {:error, Issue.t()}
  defp fetch_stage(document, name) do
    case document["vertices"] do
      %{^name => %{"kind" => "stage"} = stage} -> {:ok, stage}
      _other -> {:error, unknown(:unknown_stage, "stage")}
    end
  end

  @spec fetch_decision(document :: Document.t(), name :: String.t()) ::
          {:ok, map()} | {:error, Issue.t()}
  defp fetch_decision(document, name) do
    case document["vertices"] do
      %{^name => %{"kind" => "decision"} = decision} -> {:ok, decision}
      _other -> {:error, unknown(:unknown_decision, "decision")}
    end
  end

  @spec fetch_node(document :: Document.t(), stage :: String.t(), name :: String.t()) ::
          {:ok, map()} | {:error, Issue.t()}
  defp fetch_node(document, stage, name) do
    with {:ok, _stage} <- fetch_stage(document, stage) do
      case Document.nodes(document, stage) do
        %{^name => node} -> {:ok, node}
        _other -> {:error, unknown(:unknown_node, "node")}
      end
    end
  end

  @spec fetch_runner(id :: String.t()) :: {:ok, map()} | {:error, Issue.t()}
  defp fetch_runner(id) do
    with :error <- Catalog.runner(id), do: {:error, unknown(:unknown_runner, "runner")}
  end

  @spec fetch_field(node :: map(), field :: String.t()) :: {:ok, map()} | {:error, Issue.t()}
  defp fetch_field(node, field) do
    with :error <- Catalog.field(node["runner"], field),
         do: {:error, unknown(:unknown_field, "field")}
  end

  @spec fetch_adapter(
          document :: Document.t(),
          stage :: String.t(),
          source :: String.t(),
          field :: map(),
          runner_id :: String.t(),
          target :: Issue.target()
        ) :: {:ok, map()} | {:error, Issue.t()}
  defp fetch_adapter(document, stage, source, field, runner_id, target) do
    with {:ok, runner} <- fetch_runner(runner_id),
         {_scope, from} <- Compatibility.source_type(document, stage, source),
         true <- runner.output == field.type_id,
         %{} = adapter_field <- Catalog.adapter_field(runner, from) do
      {:ok, adapter_field}
    else
      :error ->
        {:error, unknown(:unknown_source, "source")}

      {:error, %Issue{}} = error ->
        error

      _not_an_adapter ->
        {:error,
         %Issue{
           code: :invalid_adapter,
           target: target,
           message: "That runner can't convert this source."
         }}
    end
  end

  # Checks

  # Runs on the whole op, so no clause can forget a string: Postgres rejects NUL in
  # jsonb, and Jason can't encode broken UTF-8.
  @spec check_text(term :: term()) :: :ok | {:error, Issue.t()}
  defp check_text(term) do
    if Document.text_safe?(term) do
      :ok
    else
      {:error,
       %Issue{
         code: :invalid_text,
         target: :workflow,
         message: "Text can't hold NUL or broken UTF-8."
       }}
    end
  end

  @spec check_name(name :: String.t()) :: :ok | {:error, Issue.t()}
  defp check_name(name) do
    if Name.valid?(name) do
      :ok
    else
      {:error,
       %Issue{
         code: :invalid_name,
         target: :workflow,
         message: "A name holds 1 to 128 letters, digits, _ or -."
       }}
    end
  end

  @spec check_rename(document :: Document.t(), old :: String.t(), new :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_rename(_document, same, same), do: :ok

  defp check_rename(document, _old, new) do
    with :ok <- check_name(new), do: check_free_node_name(document, new)
  end

  @spec check_free_node_name(document :: Document.t(), name :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_free_node_name(document, name) do
    if name in node_names(document) or name in input_keys(document) or
         name in choice_keys(document) or
         name in Document.decisions(document),
       do: {:error, collision(name)},
       else: :ok
  end

  @spec check_free_decision_name(document :: Document.t(), name :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_free_decision_name(document, name) do
    if name in node_names(document) or name in input_keys(document) or
         name in choice_keys(document),
       do: {:error, collision(name)},
       else: :ok
  end

  @spec check_free_vertex_name(document :: Document.t(), name :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_free_vertex_name(document, name) do
    if is_map_key(document["vertices"], name), do: {:error, collision(name)}, else: :ok
  end

  # A workflow input and a choice input may share a key only with the same type.
  @spec check_free_input_name(document :: Document.t(), name :: String.t(), type :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_free_input_name(document, name, type) do
    choice_types =
      for {_decision, _choice, ^name, choice_type} <- Document.choice_inputs(document),
          do: choice_type

    if name in node_names(document) or name in Document.decisions(document) or
         Enum.any?(choice_types, &(&1 != type)),
       do: {:error, collision(name)},
       else: :ok
  end

  @spec check_free_choice_input(
          document :: Document.t(),
          decision :: String.t(),
          choice :: String.t(),
          key :: String.t(),
          type :: String.t()
        ) :: :ok | {:error, Issue.t()}
  defp check_free_choice_input(document, decision, choice, key, type) do
    other_types =
      for {other_decision, other_choice, ^key, other_type} <- Document.choice_inputs(document),
          {other_decision, other_choice} != {decision, choice} do
        other_type
      end

    input_types = for {^key, %{"type" => input_type}} <- document["inputs"], do: input_type

    if key in node_names(document) or key in Document.decisions(document) or
         Enum.any?(other_types ++ input_types, &(&1 != type)),
       do: {:error, collision(key)},
       else: :ok
  end

  @spec check_compatible(
          document :: Document.t(),
          stage :: String.t(),
          type :: String.t(),
          source :: String.t(),
          target :: Issue.target()
        ) :: {:ok, atom()} | {:error, Issue.t()}
  defp check_compatible(document, stage, type, source, target) do
    with {:error, issue} <- Compatibility.check(document, stage, type, source) do
      {:error, %{issue | target: target}}
    end
  end

  @spec check_no_literal(
          node :: map(),
          field :: String.t(),
          replace :: boolean(),
          target :: Issue.target()
        ) ::
          :ok | {:error, Issue.t()}
  defp check_no_literal(node, field, false, target) do
    case node["inputs"] do
      %{^field => %{"literal" => _raw}} ->
        {:error,
         %Issue{
           code: :literal_present,
           target: target,
           message: "#{field} holds a literal. Confirm replacing it."
         }}

      _other ->
        :ok
    end
  end

  defp check_no_literal(_node, _field, true, _target), do: :ok

  # Unlike a bind, this has no confirmation to offer, so it says what to do instead.
  @spec check_adapter_slot(node :: map(), field :: String.t(), target :: Issue.target()) ::
          :ok | {:error, Issue.t()}
  defp check_adapter_slot(node, field, target) do
    with {:error, issue} <- check_no_literal(node, field, false, target) do
      {:error,
       %{
         issue
         | code: :adapter_over_literal,
           message: "#{field} holds a literal. Clear it, then connect again."
       }}
    end
  end

  @spec check_no_binding(
          node :: map(),
          field :: String.t(),
          replace :: boolean(),
          target :: Issue.target()
        ) ::
          :ok | {:error, Issue.t()}
  defp check_no_binding(node, field, false, target) do
    case node["inputs"] do
      %{^field => %{"bind" => _source}} ->
        {:error,
         %Issue{
           code: :binding_present,
           target: target,
           message: "#{field} has a binding. Confirm replacing it."
         }}

      _other ->
        :ok
    end
  end

  defp check_no_binding(_node, _field, true, _target), do: :ok

  @spec check_editable(field :: map(), target :: Issue.target()) :: :ok | {:error, Issue.t()}
  defp check_editable(field, target) do
    if LiteralPolicy.editor(field.type_id) == :bind_only do
      {:error,
       %Issue{
         code: :bind_only,
         target: target,
         message: "#{Catalog.type_label(field.type_id)} values come only through a binding."
       }}
    else
      :ok
    end
  end

  # A field the current runner no longer declares can still be cleared.
  @spec check_clearable(node :: map(), field :: String.t()) :: :ok | {:error, Issue.t()}
  defp check_clearable(node, field) do
    if is_map_key(node["inputs"], field) do
      :ok
    else
      with {:ok, _entry} <- fetch_field(node, field), do: :ok
    end
  end

  @spec check_validators(ids :: [term()]) :: :ok | {:error, Issue.t()}
  defp check_validators(ids) do
    cond do
      Enum.uniq(ids) != ids -> {:error, invalid_params()}
      Enum.all?(ids, &match?({:ok, _validator}, Catalog.validator(&1))) -> :ok
      true -> {:error, unknown(:unknown_validator, "validator")}
    end
  end

  @spec check_next(document :: Document.t(), vertex :: String.t() | nil) ::
          :ok | {:error, Issue.t()}
  defp check_next(_document, nil), do: :ok

  defp check_next(document, vertex) do
    with {:ok, _vertex} <- fetch_vertex(document, vertex), do: :ok
  end

  @spec check_placed(document :: Document.t(), scope :: term(), name :: String.t()) ::
          :ok | {:error, Issue.t()}
  defp check_placed(document, :workflow, name) do
    with {:ok, _vertex} <- fetch_vertex(document, name), do: :ok
  end

  defp check_placed(document, {:stage, stage}, name) do
    if name in Compatibility.stage_sources(document, stage) do
      :ok
    else
      with {:ok, _node} <- fetch_node(document, stage, name), do: :ok
    end
  end

  @spec check_decision_attrs(attrs :: map()) :: :ok | {:error, Issue.t()}
  defp check_decision_attrs(attrs) do
    cond do
      attrs |> Map.keys() |> Enum.any?(&(&1 not in @decision_keys)) ->
        {:error, invalid_params()}

      not (is_binary(Map.get(attrs, "prompt", "")) and is_binary(Map.get(attrs, "decider", ""))) ->
        {:error, invalid_params()}

      not Document.decider_options?(Map.get(attrs, "decider_options", %{})) ->
        {:error, invalid_params()}

      is_map_key(attrs, "decider") and not decider?(attrs["decider"]) ->
        {:error, unknown(:unknown_decider, "decider")}

      true ->
        :ok
    end
  end

  @spec decider?(id :: String.t()) :: boolean()
  defp decider?(id), do: Enum.any?(Catalog.deciders(), &(&1.id == id))

  # Normalizing

  @spec normalize_input(attrs :: map()) :: {:ok, map()} | {:error, Issue.t()}
  defp normalize_input(attrs) do
    cond do
      attrs |> Map.keys() |> Enum.any?(&(&1 not in @input_keys)) ->
        {:error, invalid_params()}

      not is_boolean(Map.get(attrs, "required", false)) ->
        {:error, invalid_params()}

      not (is_binary(Map.get(attrs, "default", "")) or is_nil(Map.get(attrs, "default", ""))) ->
        {:error, invalid_params()}

      true ->
        with :ok <- check_type(attrs["type"]), do: {:ok, Map.put_new(attrs, "required", false)}
    end
  end

  @spec check_type(type :: term()) :: :ok | {:error, Issue.t()}
  defp check_type(type) do
    case Catalog.type(type) do
      {:ok, _type} -> :ok
      :error -> {:error, unknown(:unknown_type, "type")}
    end
  end

  @spec normalize_choice(document :: Document.t(), decision :: String.t(), attrs :: map()) ::
          {:ok, map()} | {:error, Issue.t()}
  defp normalize_choice(document, decision, attrs) do
    choice = Map.put_new(attrs, "inputs", %{})

    with :ok <- check_choice_shape(choice),
         :ok <- check_name(choice["name"]),
         :ok <- check_target(document, choice["target"]),
         :ok <- check_choice_inputs(document, decision, choice) do
      {:ok, choice}
    end
  end

  @spec check_choice_shape(choice :: map()) :: :ok | {:error, Issue.t()}
  defp check_choice_shape(
         %{"name" => name, "description" => description, "inputs" => inputs} = choice
       )
       when binaries(name, description) and is_map(inputs) do
    if choice |> Map.keys() |> Enum.all?(&(&1 in @choice_keys)),
      do: :ok,
      else: {:error, invalid_params()}
  end

  defp check_choice_shape(_choice), do: {:error, invalid_params()}

  @spec check_target(document :: Document.t(), target :: term()) :: :ok | {:error, Issue.t()}
  defp check_target(_document, ["halt"]), do: :ok

  defp check_target(document, [kind, vertex])
       when kind in ["run", "rerun"] and is_binary(vertex) do
    with {:ok, _vertex} <- fetch_vertex(document, vertex), do: :ok
  end

  defp check_target(_document, _target), do: {:error, invalid_params()}

  @spec check_choice_inputs(document :: Document.t(), decision :: String.t(), choice :: map()) ::
          :ok | {:error, Issue.t()}
  defp check_choice_inputs(document, decision, choice) do
    Enum.reduce_while(choice["inputs"], :ok, fn {key, type}, :ok ->
      with :ok <- check_name(key),
           :ok <- check_type(type),
           :ok <- check_free_choice_input(document, decision, choice["name"], key, type) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Building

  @spec node_path(stage :: String.t(), node :: String.t(), key :: String.t()) :: [String.t()]
  defp node_path(stage, node, key), do: ["vertices", stage, "nodes", node, key]

  @spec put_input(
          document :: Document.t(),
          stage :: String.t(),
          node :: String.t(),
          field :: String.t(),
          value :: map()
        ) :: Document.t()
  defp put_input(document, stage, node, field, value) do
    put_in(document, node_path(stage, node, "inputs") ++ [field], value)
  end

  @spec insert_node(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          node :: map()
        ) ::
          Document.t()
  defp insert_node(document, stage, name, node) do
    slot = next_slot(document["layout"]["stages"][stage])

    document
    |> put_in(["vertices", stage, "nodes", name], node)
    |> put_in(["layout", "stages", stage, name], slot)
  end

  @spec insert_vertex(document :: Document.t(), name :: String.t(), vertex :: map()) ::
          Document.t()
  defp insert_vertex(document, name, vertex) do
    slot = next_slot(document["layout"]["workflow"])

    document
    |> put_in(["vertices", name], vertex)
    |> put_in(["layout", "workflow", name], slot)
  end

  @spec next_slot(placed :: map()) :: map()
  defp next_slot(placed) do
    taken = Map.values(placed)

    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&grid_slot/1)
    |> Enum.find(fn slot -> not Enum.any?(taken, &crowds?(slot, &1)) end)
  end

  # Whatever is placed near a slot crowds it: the starter and dragged cards sit off the grid.
  @spec crowds?(slot :: map(), card :: map()) :: boolean()
  defp crowds?(slot, card) do
    {step_x, step_y} = @grid_step
    abs(slot["x"] - card["x"]) < step_x and abs(slot["y"] - card["y"]) < step_y
  end

  @spec grid_slot(index :: non_neg_integer()) :: map()
  defp grid_slot(index) do
    {origin_x, origin_y} = @grid_origin
    {step_x, step_y} = @grid_step

    %{
      "x" => origin_x + rem(index, @grid_columns) * step_x,
      "y" => origin_y + div(index, @grid_columns) * step_y
    }
  end

  @spec coordinate(value :: number()) :: integer()
  defp coordinate(value),
    do: value |> round() |> max(-@coordinate_limit) |> min(@coordinate_limit)

  @spec layout_path(document :: Document.t(), scope :: term()) ::
          {:ok, [String.t()]} | {:error, Issue.t()}
  defp layout_path(_document, :workflow), do: {:ok, ["layout", "workflow"]}

  defp layout_path(document, {:stage, stage}) when is_binary(stage) do
    with {:ok, _stage} <- fetch_stage(document, stage), do: {:ok, ["layout", "stages", stage]}
  end

  defp layout_path(_document, _scope), do: {:error, invalid_params()}

  @spec add_once(list :: [String.t()], value :: String.t()) :: [String.t()]
  defp add_once(list, value), do: if(value in list, do: list, else: list ++ [value])

  @spec rename_node(
          document :: Document.t(),
          stage :: String.t(),
          old :: String.t(),
          new :: String.t()
        ) ::
          Document.t()
  defp rename_node(document, _stage, same, same), do: document

  defp rename_node(document, stage, old, new) do
    renamed =
      Enum.reduce(Document.all_nodes(document), document, fn {node_stage, name, node}, acc ->
        inputs = Map.new(node["inputs"], &rename_binding(&1, old, new))

        waits =
          if node_stage == stage, do: replace_name(node["after"], old, new), else: node["after"]

        put_in(acc, ["vertices", node_stage, "nodes", name], %{
          node
          | "inputs" => inputs,
            "after" => waits
        })
      end)

    renamed
    |> update_in(["vertices", stage, "nodes"], &rename_key(&1, old, new))
    |> update_placements(&rename_key(&1, old, new))
  end

  # `layout` isn't validated when a draft loads, and removing an input must keep working
  # on a hand-built draft, so anything unexpected is left as it is.
  @spec update_placements(document :: Document.t(), fun :: (map() -> map())) :: Document.t()
  defp update_placements(%{"layout" => %{"stages" => stages}} = document, fun)
       when is_map(stages) do
    updated =
      Map.new(stages, fn
        {stage, placed} when is_map(placed) -> {stage, fun.(placed)}
        other -> other
      end)

    put_in(document, ["layout", "stages"], updated)
  end

  defp update_placements(document, _fun), do: document

  @spec rename_binding(input :: {String.t(), map()}, old :: String.t(), new :: String.t()) ::
          {String.t(), map()}
  defp rename_binding({field, %{"bind" => old}}, old, new), do: {field, %{"bind" => new}}
  defp rename_binding(input, _old, _new), do: input

  @spec replace_name(names :: [String.t()], old :: String.t(), new :: String.t()) :: [String.t()]
  defp replace_name(names, old, new) do
    names |> Enum.map(&if(&1 == old, do: new, else: &1)) |> Enum.uniq()
  end

  @spec rename_key(map :: map(), old :: String.t(), new :: String.t()) :: map()
  defp rename_key(map, old, new) do
    case Map.pop(map, old) do
      {nil, rest} -> rest
      {value, rest} -> Map.put(rest, new, value)
    end
  end

  # Keeps a same-name input only when the new field can still take it. A dangling
  # binding stays, so the reference stays visible as an analyzer issue.
  @spec replace_runner(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          node :: map(),
          runner :: map()
        ) :: Document.t()
  defp replace_runner(document, stage, name, node, runner) do
    swapped = put_in(document, node_path(stage, name, "runner"), runner.id)

    inputs =
      node["inputs"]
      |> Enum.filter(fn {field, value} ->
        input_kept?(swapped, stage, node, runner, field, value)
      end)
      |> Map.new()

    validators = Enum.filter(node["validators"], &validator_fits?(&1, runner))

    swapped
    |> put_in(node_path(stage, name, "inputs"), inputs)
    |> put_in(node_path(stage, name, "validators"), validators)
    |> drop_stale_metadata(stage, name, node, runner)
  end

  @spec input_kept?(
          document :: Document.t(),
          stage :: String.t(),
          node :: map(),
          runner :: map(),
          field :: String.t(),
          value :: map()
        ) :: boolean()
  defp input_kept?(document, stage, node, runner, field, value) do
    case Catalog.field(runner.id, field) do
      {:ok, entry} -> value_fits?(document, stage, node, entry, value)
      :error -> false
    end
  end

  @spec value_fits?(
          document :: Document.t(),
          stage :: String.t(),
          node :: map(),
          field :: map(),
          value :: map()
        ) ::
          boolean()
  defp value_fits?(document, stage, _node, field, %{"bind" => source}) do
    case Compatibility.check(document, stage, field.type_id, source) do
      {:ok, _fit} -> true
      {:error, issue} -> issue.code == :unknown_source
    end
  end

  defp value_fits?(_document, _stage, node, field, %{"literal" => _raw}) do
    match?(
      {:ok, %{type_id: type}} when type == field.type_id,
      Catalog.field(node["runner"], field.id)
    )
  end

  @spec validator_fits?(id :: String.t(), runner :: map()) :: boolean()
  defp validator_fits?(id, runner) do
    case Catalog.validator(id) do
      {:ok, validator} ->
        fields = Enum.map(runner.fields, & &1.id)
        Enum.all?(validator.requires, &(&1 in fields))

      :error ->
        false
    end
  end

  @spec adapter_name(document :: Document.t(), runner_id :: String.t()) :: String.t()
  defp adapter_name(document, runner_id) do
    {:ok, runner} = Catalog.runner(runner_id)
    base = runner.module |> Module.split() |> List.last() |> Macro.underscore()
    referenced = referenced_names(document)

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base}_#{&1}"))
    |> Enum.find(&(check_free_node_name(document, &1) == :ok and &1 not in referenced))
  end

  # Includes dangling names, which a generated name must not silently re-resolve.
  @spec referenced_names(document :: Document.t()) :: [String.t()]
  defp referenced_names(document) do
    Enum.flat_map(Document.all_nodes(document), fn {_stage, _name, node} ->
      node["after"] ++ for {_field, %{"bind" => source}} <- node["inputs"], do: source
    end)
  end

  @spec upsert_choice(choices :: [map()], choice :: map()) :: [map()]
  defp upsert_choice(choices, choice) do
    case Enum.find_index(choices, &(&1["name"] == choice["name"])) do
      nil -> choices ++ [choice]
      index -> List.replace_at(choices, index, choice)
    end
  end

  @spec node_names(document :: Document.t()) :: [String.t()]
  defp node_names(document),
    do: for({_stage, name, _node} <- Document.all_nodes(document), do: name)

  @spec input_keys(document :: Document.t()) :: [String.t()]
  defp input_keys(document), do: Map.keys(document["inputs"])

  @spec choice_keys(document :: Document.t()) :: [String.t()]
  defp choice_keys(document),
    do: for({_decision, _choice, key, _type} <- Document.choice_inputs(document), do: key)

  # Preview

  @spec dropped(before :: Document.t(), updated :: Document.t(), op :: term()) :: [dropped()]
  defp dropped(before, updated, {:replace_runner, stage, node, _runner_id}) do
    old = Document.nodes(before, stage)[node]
    new = Document.nodes(updated, stage)[node]
    fields = Map.keys(old["inputs"]) -- Map.keys(new["inputs"])
    validators = old["validators"] -- new["validators"]

    Enum.map(fields, &{:field, &1}) ++ Enum.map(validators, &{:validator, &1})
  end

  defp dropped(_before, _updated, _op), do: []

  @spec warnings(before :: Document.t(), updated :: Document.t()) :: [Issue.t()]
  defp warnings(before, updated) do
    was = references(before)

    updated
    |> references()
    |> Enum.sort_by(fn {key, _status} -> key end)
    |> Enum.flat_map(fn {key, status} -> warning(Map.get(was, key), status, key) end)
  end

  @spec warning(was :: :ok | Issue.t() | nil, status :: :ok | Issue.t(), key :: tuple()) :: [
          Issue.t()
        ]
  defp warning(:ok, %Issue{} = broken, _key), do: [broken]

  defp warning(%Issue{code: :unknown_source}, :ok, key), do: [re_resolved(key)]

  defp warning(%Issue{code: :unknown_source}, %Issue{code: code} = issue, _key)
       when code != :unknown_source, do: [issue]

  defp warning(was, %Issue{code: :source_not_visible} = issue, _key) when was != issue,
    do: [issue]

  defp warning(%Issue{code: :source_not_visible} = was, %Issue{} = issue, _key)
       when was != issue, do: [issue]

  defp warning(_was, _status, _key), do: []

  @spec re_resolved(key :: tuple()) :: Issue.t()
  defp re_resolved({stage, node, {:after, source}}) do
    %Issue{
      code: :reference_resolved,
      target: {:after, stage, node, source},
      message: "#{node} will now wait on #{source}, which this name re-resolves."
    }
  end

  defp re_resolved({stage, node, field}) do
    %Issue{
      code: :reference_resolved,
      target: {:field, stage, node, field},
      message:
        "#{node}.#{field} will now read this name, which re-resolves its dangling reference."
    }
  end

  # The status of every binding and After edge in the document.
  @spec references(document :: Document.t()) :: %{tuple() => :ok | Issue.t()}
  defp references(document) do
    for {stage, name, node} <- Document.all_nodes(document),
        reference <- node_references(document, stage, name, node),
        into: %{} do
      reference
    end
  end

  @spec node_references(
          document :: Document.t(),
          stage :: String.t(),
          name :: String.t(),
          node :: map()
        ) ::
          [{tuple(), :ok | Issue.t()}]
  defp node_references(document, stage, name, node) do
    bindings =
      for {field, %{"bind" => source}} <- node["inputs"],
          {:ok, entry} <- [Catalog.field(node["runner"], field)] do
        {{stage, name, field}, binding_status(document, stage, name, entry, source)}
      end

    waits =
      for source <- node["after"] do
        {{stage, name, {:after, source}}, after_status(document, stage, name, source)}
      end

    bindings ++ waits
  end

  @spec binding_status(
          document :: Document.t(),
          stage :: String.t(),
          node :: String.t(),
          field :: map(),
          source :: String.t()
        ) :: :ok | Issue.t()
  defp binding_status(document, stage, node, field, source) do
    target = {:field, stage, node, field.id}

    case Compatibility.check(document, stage, field.type_id, source) do
      {:ok, _fit} -> visibility_status(document, stage, source, target)
      {:error, issue} -> %{issue | target: target}
    end
  end

  @spec visibility_status(
          document :: Document.t(),
          stage :: String.t(),
          source :: String.t(),
          target :: Issue.target()
        ) :: :ok | Issue.t()
  defp visibility_status(document, stage, source, target) do
    case Compatibility.visibility(document, stage, source) do
      :visible ->
        :ok

      :not_visible ->
        %Issue{
          code: :source_not_visible,
          core_id: :stage_input_unbound,
          target: target,
          message:
            "#{source} doesn't run before stage #{stage}, so this field has nothing to read."
        }

      :stage_unreachable ->
        %Issue{
          code: :source_not_visible,
          target: target,
          message:
            "Stage #{stage} isn't reachable from start, so #{source} doesn't run before it."
        }
    end
  end

  @spec after_status(
          document :: Document.t(),
          stage :: String.t(),
          node :: String.t(),
          source :: String.t()
        ) ::
          :ok | Issue.t()
  defp after_status(document, stage, node, source) do
    if is_map_key(Document.nodes(document, stage), source) do
      :ok
    else
      %Issue{
        code: :unknown_source,
        core_id: :after_source_not_found,
        target: {:after, stage, node, source},
        message: "#{node} waits on #{source}, which does not exist."
      }
    end
  end

  # Issues

  @spec unknown(code :: atom(), what :: String.t()) :: Issue.t()
  defp unknown(code, what),
    do: %Issue{code: code, target: :workflow, message: "That #{what} does not exist."}

  @spec invalid_params() :: Issue.t()
  defp invalid_params do
    %Issue{code: :invalid_params, target: :workflow, message: "That edit has the wrong shape."}
  end

  @spec collision(name :: String.t()) :: Issue.t()
  defp collision(name) do
    %Issue{
      code: :name_collision,
      core_id: :name_collision,
      target: :workflow,
      message: "#{name} is already in use."
    }
  end
end

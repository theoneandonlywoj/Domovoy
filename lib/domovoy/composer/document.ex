defmodule Domovoy.Composer.Document do
  @moduledoc """
  The string-keyed map that holds a draft, plus read helpers over it.

      %{"version" => 1, "name" => "w", "start" => "prepare",
        "inputs" => %{"prompt" => %{"type" => "DomovoyCore.Type.String", "required" => true}},
        "vertices" => %{
          "prepare" => %{"kind" => "stage", "next" => "review", "nodes" => %{
            "ask_claude" => %{"runner" => "DomovoyClaudeCodePlugin.Runner.AskClaude",
              "inputs" => %{"context" => %{"bind" => "prompt"}, "options" => %{"literal" => "{}"}},
              "after" => ["trust_mise"], "validators" => [], "retry" => %{}, "store" => true}}},
          "review" => %{"kind" => "decision", "prompt" => "...", "decider" => "DomovoyCore.Decider.Person",
            "choices" => [%{"name" => "revise", "description" => "...", "target" => ["rerun", "prepare"],
                            "inputs" => %{"prompt" => "DomovoyCore.Type.String"}}]}},
        "layout" => %{"workflow" => %{"prepare" => %{"x" => 0, "y" => 0}},
                      "stages" => %{"prepare" => %{"ask_claude" => %{"x" => 40, "y" => 80}}}}}

  Targets are `["run", v]`, `["rerun", stage]` or `["halt"]`. `retry` is `%{}` or
  `%{"max_attempts" => n}`. An absent `"default"` and `"default" => nil` stay
  distinct. A binding holds only the source name; its type comes from the field's
  declaration at build.

  A node, stage, decision or input may also hold
  `"metadata" => %{"description" => "Looks up the worktree."}`, which `description/1` reads.
  """

  alias Domovoy.Composer.Issue

  @type t :: map()

  @starter "main"

  # Issues in nested lists, flattened once at the top.
  @typep found :: [Issue.t() | found()]

  @doc """
  A new document with one empty stage as its start.
  """
  @spec new(name :: String.t()) :: t()
  def new(name) do
    %{
      "version" => 1,
      "name" => name,
      "start" => @starter,
      "inputs" => %{},
      "vertices" => %{@starter => stage()},
      "layout" => %{
        "workflow" => %{@starter => %{"x" => 60, "y" => 80}},
        "stages" => %{@starter => %{}}
      }
    }
  end

  @doc """
  An empty stage.
  """
  @spec stage() :: map()
  def stage, do: %{"kind" => "stage", "next" => nil, "nodes" => %{}}

  @doc """
  An empty decision.
  """
  @spec decision() :: map()
  def decision do
    %{
      "kind" => "decision",
      "prompt" => "",
      "decider" => "DomovoyCore.Decider.Person",
      "choices" => []
    }
  end

  @doc """
  A node with no inputs.
  """
  @spec new_node(runner_id :: String.t()) :: map()
  def new_node(runner_id) do
    %{
      "runner" => runner_id,
      "inputs" => %{},
      "after" => [],
      "validators" => [],
      "retry" => %{},
      "store" => true
    }
  end

  @doc """
  The nodes of one stage; empty for a decision or an unknown vertex.
  """
  @spec nodes(document :: t(), stage :: String.t()) :: %{String.t() => map()}
  def nodes(document, stage), do: get_in(document, ["vertices", stage, "nodes"]) || %{}

  @doc """
  Every node of the document as `{stage, name, node}`.
  """
  @spec all_nodes(document :: t()) :: [{String.t(), String.t(), map()}]
  def all_nodes(document) do
    for {stage, _vertex} <- document["vertices"], {name, node} <- nodes(document, stage) do
      {stage, name, node}
    end
  end

  @doc """
  The names of every decision.
  """
  @spec decisions(document :: t()) :: [String.t()]
  def decisions(document) do
    for {name, %{"kind" => "decision"}} <- document["vertices"], do: name
  end

  @doc """
  Every choice input as `{decision, choice, key, type}`.
  """
  @spec choice_inputs(document :: t()) :: [{String.t(), String.t(), String.t(), String.t()}]
  def choice_inputs(document) do
    for {decision, %{"kind" => "decision", "choices" => choices}} <- document["vertices"],
        choice <- choices,
        {key, type} <- choice["inputs"] do
      {decision, choice["name"], key, type}
    end
  end

  @doc """
  What an item's metadata holds as a description. Malformed metadata isn't a shape
  issue, because an optional tooltip mustn't stop a draft opening. A blank text counts
  as malformed.
  """
  @spec description(item :: map()) :: {:ok, String.t()} | :absent | :malformed
  def description(%{"metadata" => %{"description" => text}}) when is_binary(text) do
    if String.trim(text) == "", do: :malformed, else: {:ok, text}
  end

  def description(%{"metadata" => %{"description" => _other}}), do: :malformed
  def description(%{"metadata" => metadata}) when is_map(metadata), do: :absent
  def description(%{"metadata" => _other}), do: :malformed
  def description(_item), do: :absent

  @doc """
  Whether every string in a term is valid UTF-8 without NUL. Postgres rejects NUL
  in jsonb, and Jason can't encode broken UTF-8.
  """
  @spec text_safe?(term :: term()) :: boolean()
  def text_safe?(term) when is_binary(term),
    do: String.valid?(term) and not String.contains?(term, <<0>>)

  def text_safe?(term) when is_tuple(term), do: term |> Tuple.to_list() |> text_safe?()
  def text_safe?([head | tail]), do: text_safe?(head) and text_safe?(tail)

  def text_safe?(term) when is_map(term) and not is_struct(term) do
    Enum.all?(term, fn {key, value} -> text_safe?(key) and text_safe?(value) end)
  end

  def text_safe?(_term), do: true

  @doc """
  What stops a term being read as a document, one issue per problem. Every read
  helper, `Domovoy.Composer.Compatibility` and `Domovoy.Composer.Cycles` assume the
  shape, so a caller holding a term that didn't come through `edit/2`, such as a
  saved row, checks this first. Values are never echoed.
  """
  @spec shape_issues(document :: term()) :: [Issue.t()]
  def shape_issues(document) do
    cond do
      not plain_map?(document) ->
        [malformed(:workflow, "document")]

      not text_safe?(document) ->
        [malformed(:workflow, "text, which can't hold NUL or broken UTF-8,")]

      true ->
        List.flatten([
          expect(is_binary(document["name"]), :workflow, "name"),
          expect(is_binary(document["start"]), :workflow, "start"),
          each_entry(document["inputs"], :workflow, "inputs", &input_shape/1),
          each_entry(document["vertices"], :workflow, "vertices", &vertex_shape/1)
        ])
    end
  end

  @spec input_shape(entry :: {String.t(), term()}) :: found()
  defp input_shape({name, input}) do
    expect(
      plain_map?(input) and is_binary(input["type"]) and
        is_boolean(Map.get(input, "required", false)),
      {:input, name},
      "input"
    )
  end

  @spec vertex_shape(entry :: {String.t(), term()}) :: found()
  defp vertex_shape({name, %{"kind" => "stage", "next" => next, "nodes" => nodes}}) do
    target = {:vertex, name}

    [
      expect(is_binary(next) or is_nil(next), target, "next"),
      each_entry(nodes, target, "nodes", &node_shape(name, &1))
    ]
  end

  defp vertex_shape({name, %{"kind" => "decision", "choices" => choices} = vertex}) do
    target = {:vertex, name}

    [
      expect(is_binary(vertex["prompt"]), target, "prompt"),
      expect(is_binary(vertex["decider"]), target, "decider"),
      if(list?(choices),
        do: Enum.map(choices, &choice_shape(name, &1)),
        else: malformed(target, "choices")
      )
    ]
  end

  defp vertex_shape({name, _vertex}), do: [malformed({:vertex, name}, "vertex")]

  @spec node_shape(stage :: String.t(), entry :: {String.t(), term()}) :: found()
  defp node_shape(stage, {name, node}) do
    target = {:node, stage, name}

    if plain_map?(node) do
      [
        expect(is_binary(node["runner"]), target, "runner"),
        each_entry(node["inputs"], target, "inputs", &field_shape(stage, name, &1)),
        expect(strings?(node["after"]), target, "after"),
        expect(strings?(node["validators"]), target, "validators"),
        expect(plain_map?(node["retry"]), target, "retry"),
        expect(is_boolean(node["store"]), target, "store")
      ]
    else
      [malformed(target, "node")]
    end
  end

  @spec field_shape(stage :: String.t(), node :: String.t(), entry :: {String.t(), term()}) ::
          found()
  defp field_shape(_stage, _node, {_field, %{"bind" => source} = input})
       when is_binary(source) and map_size(input) == 1,
       do: []

  defp field_shape(_stage, _node, {_field, %{"literal" => _raw} = input})
       when map_size(input) == 1,
       do: []

  defp field_shape(stage, node, {field, _input}) do
    [malformed({:field, stage, node, field}, "input")]
  end

  @spec choice_shape(decision :: String.t(), choice :: term()) :: found()
  defp choice_shape(decision, %{"name" => name, "description" => description} = choice)
       when is_binary(name) and is_binary(description) do
    target = {:choice, decision, name}

    [
      expect(choice_target?(choice["target"]), target, "target"),
      each_entry(choice["inputs"], target, "inputs", &choice_input_shape(target, &1))
    ]
  end

  defp choice_shape(decision, _choice), do: [malformed({:vertex, decision}, "choice")]

  @spec choice_input_shape(target :: Issue.target(), entry :: {String.t(), term()}) :: found()
  defp choice_input_shape(target, {_key, type}), do: expect(is_binary(type), target, "inputs")

  @spec choice_target?(target :: term()) :: boolean()
  defp choice_target?(["halt"]), do: true
  defp choice_target?([kind, vertex]) when kind in ["run", "rerun"], do: is_binary(vertex)
  defp choice_target?(_target), do: false

  @spec each_entry(
          value :: term(),
          target :: Issue.target(),
          what :: String.t(),
          shape :: ({String.t(), term()} -> [Issue.t()])
        ) :: found()
  defp each_entry(value, target, what, shape) do
    if plain_map?(value) and Enum.all?(Map.keys(value), &is_binary/1) do
      value |> Enum.sort() |> Enum.map(shape)
    else
      [malformed(target, what)]
    end
  end

  @spec expect(ok? :: boolean(), target :: Issue.target(), what :: String.t()) :: found()
  defp expect(true, _target, _what), do: []
  defp expect(false, target, what), do: [malformed(target, what)]

  @spec malformed(target :: Issue.target(), what :: String.t()) :: Issue.t()
  defp malformed(target, what) do
    %Issue{
      code: :malformed_document,
      target: target,
      message: "This draft's #{what} has the wrong shape."
    }
  end

  @spec plain_map?(term :: term()) :: boolean()
  defp plain_map?(term), do: is_map(term) and not is_struct(term)

  @spec list?(term :: term()) :: boolean()
  defp list?(term), do: is_list(term) and not List.improper?(term)

  @spec strings?(term :: term()) :: boolean()
  defp strings?(term), do: list?(term) and Enum.all?(term, &is_binary/1)
end

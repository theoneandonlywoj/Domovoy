defmodule Domovoy.Composer.CoreBridge do
  @moduledoc """
  Builds real Core structs from a document, without raising.

  Everything resolves through `Domovoy.Catalog`. A binding and a literal both take
  the type their field declares, whatever the source gives, so an Any field binds
  as Any. The layout travels in the workflow's metadata, which is outside the
  fingerprint. So does a valid description, in its node's, stage's or decision's
  metadata; an input's stays in the document.

  An issue's message is built from document names, never from an exception, because
  some Core raises echo values.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.Issue
  alias Domovoy.Composer.LiteralPolicy
  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Workflow

  # The Core errors that reach a caller only as the prefix of a raised message.
  @raised_ids [:invalid_node, :invalid_decider]

  @doc """
  Builds the workflow, stopping at the first error. A graph error stops the build
  rather than reach `Stage.new/1`, which would hold it and let Core report a later
  stage's missing input instead.
  """
  @spec build(document :: term()) :: {:ok, Workflow.t()} | {:error, [Issue.t()]}
  def build(document), do: guarded(:workflow, fn -> workflow(document) end)

  @doc """
  Runs a call into Core, turning any failure into an issue on `target`: a raise, a
  throw, an exit, a returned `%Error{}`, or an error tuple. An error's `type`, or the
  identifier leading a raised message, becomes `core_id`; nothing else of the failure
  is kept. A list of issues from a nested call passes through.
  """
  @spec guarded(target :: Issue.target(), fun :: (-> term())) ::
          {:ok, term()} | {:error, [Issue.t()]}
  def guarded(target, fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, [%Issue{} | _rest] = issues} -> {:error, issues}
      {:error, %Error{type: type}} -> rejected(target, type)
      %Error{type: type} -> rejected(target, type)
      {:error, _reason} -> rejected(target, nil)
      value -> {:ok, value}
    end
  rescue
    exception -> rejected(target, raised_id(exception))
  catch
    _kind, _reason -> rejected(target, nil)
  end

  @spec rejected(target :: Issue.target(), core_id :: atom() | nil) :: {:error, [Issue.t()]}
  defp rejected(target, core_id) do
    {:error,
     [
       %Issue{
         code: :core_rejected,
         core_id: core_id,
         target: target,
         message: "Core rejected #{where(target)}#{if core_id, do: " (#{core_id})"}."
       }
     ]}
  end

  @spec where(target :: Issue.target()) :: String.t()
  defp where({:vertex, vertex}), do: "vertex #{vertex}"
  defp where({:node, stage, node}), do: "node #{node} of stage #{stage}"
  defp where(_workflow), do: "the workflow"

  @spec raised_id(exception :: Exception.t()) :: atom() | nil
  defp raised_id(%ArgumentError{message: message}) do
    Enum.find(@raised_ids, &String.starts_with?(message, "#{&1}:"))
  end

  defp raised_id(_exception), do: nil

  @spec workflow(document :: Document.t()) :: {:ok, Workflow.t()} | {:error, [Issue.t()]}
  defp workflow(document) do
    with {:ok, vertices} <- map_ok(Enum.sort(document["vertices"]), &vertex/1) do
      guarded(:workflow, fn ->
        Workflow.new(%{
          name: document["name"],
          start: document["start"],
          inputs: Map.new(document["inputs"], &input/1),
          vertices: Map.new(vertices, &{&1.name, &1}),
          metadata: %{"domovoy_editor" => document["layout"]}
        })
      end)
    end
  end

  @spec input(entry :: {String.t(), map()}) :: {String.t(), Workflow.new_input()}
  defp input({name, input}) do
    {:ok, type} = Catalog.type(input["type"])

    built =
      Enum.reduce(input, %{type: type.module}, fn
        {"required", required}, built -> Map.put(built, :required, required)
        {"default", default}, built -> Map.put(built, :default, default(input["type"], default))
        _other, built -> built
      end)

    {name, built}
  end

  @spec default(type :: String.t(), raw :: term()) :: term()
  defp default(_type, nil), do: nil
  defp default(type, raw), do: parsed!(type, raw)

  # A failed match here is caught by `guarded/2`, which drops the term it holds.
  @spec parsed!(type :: String.t(), raw :: term()) :: term()
  defp parsed!(type, raw) do
    {:ok, value} = LiteralPolicy.parse(type, raw)
    value
  end

  @spec vertex(entry :: {String.t(), map()}) ::
          {:ok, Stage.t() | Decision.t()} | {:error, [Issue.t()]}
  defp vertex({name, %{"kind" => "stage"} = stage}) do
    target = {:vertex, name}

    with {:ok, nodes} <- map_ok(Enum.sort(stage["nodes"]), &node(name, &1)),
         {:ok, graph} <- guarded(target, fn -> Graph.new(nodes) end) do
      guarded(target, fn ->
        Stage.new(%{name: name, graph: graph, next: stage["next"], metadata: metadata(stage)})
      end)
    end
  end

  defp vertex({name, %{"kind" => "decision"} = decision}) do
    guarded({:vertex, name}, fn ->
      %{module: decider} = Enum.find(Catalog.deciders(), &(&1.id == decision["decider"]))

      Decision.new(%{
        name: name,
        prompt: decision["prompt"],
        decider: decider_spec(decider, decision),
        choices: Enum.map(decision["choices"], &choice/1),
        metadata: metadata(decision)
      })
    end)
  end

  # The bare module when no option is set, so a decision without options keeps
  # its fingerprint.
  @spec decider_spec(decider :: module(), decision :: map()) :: module() | {module(), keyword()}
  defp decider_spec(decider, decision) do
    case Document.decider_node(decision) do
      nil -> decider
      node -> {decider, node: node}
    end
  end

  @spec choice(choice :: map()) :: Choice.t()
  defp choice(choice) do
    Choice.new(%{
      name: choice["name"],
      description: choice["description"],
      target: target(choice["target"]),
      inputs:
        Map.new(choice["inputs"], fn {key, id} ->
          {:ok, type} = Catalog.type(id)
          {key, type.module}
        end)
    })
  end

  @spec target(target :: [String.t()]) :: Choice.target()
  defp target(["halt"]), do: :halt
  defp target(["run", vertex]), do: {:run, vertex}
  defp target(["rerun", vertex]), do: {:rerun, vertex}

  @spec node(stage :: String.t(), entry :: {String.t(), map()}) ::
          {:ok, Node.t()} | {:error, [Issue.t()]}
  defp node(stage, {name, node}) do
    guarded({:node, stage, name}, fn ->
      {:ok, runner} = Catalog.runner(node["runner"])

      bind =
        for {id, %{"bind" => source}} <- node["inputs"], into: %{} do
          field = declared(runner, id)
          {field.name, {source, field.type}}
        end

      args =
        for {id, %{"literal" => raw}} <- node["inputs"], into: %{} do
          field = declared(runner, id)
          {field.name, {parsed!(field.type_id, raw), field.type}}
        end

      Node.new(%{
        name: name,
        runner: runner.module,
        type: runner.output_module,
        bind: bind,
        args: args,
        after: node["after"],
        validators: Enum.map(node["validators"], &validator_module/1),
        retry: retry(node["retry"]),
        store?: node["store"],
        metadata: metadata(node)
      })
    end)
  end

  # Core doesn't validate metadata, so only a valid description reaches it.
  @spec metadata(item :: map()) :: %{optional(String.t()) => String.t()}
  defp metadata(item) do
    case Document.description(item) do
      {:ok, text} -> %{"description" => text}
      _absent_or_malformed -> %{}
    end
  end

  @spec declared(runner :: map(), id :: String.t()) :: map()
  defp declared(runner, id) do
    {:ok, field} = Catalog.field(runner.id, id)
    field
  end

  @spec validator_module(id :: String.t()) :: module()
  defp validator_module(id) do
    {:ok, validator} = Catalog.validator(id)
    validator.module
  end

  @spec retry(retry :: map()) :: keyword()
  defp retry(%{"max_attempts" => attempts}), do: [max_attempts: attempts]
  defp retry(_retry), do: []

  # The first failure stops the walk, so a later vertex can't hide it.
  @spec map_ok(list :: list(), fun :: (term() -> {:ok, term()} | {:error, [Issue.t()]})) ::
          {:ok, list()} | {:error, [Issue.t()]}
  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while([], fn item, built ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | built]}
        {:error, issues} -> {:halt, {:error, issues}}
      end
    end)
    |> case do
      {:error, issues} -> {:error, issues}
      built -> {:ok, Enum.reverse(built)}
    end
  end
end

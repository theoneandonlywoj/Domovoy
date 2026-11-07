defmodule Domovoy.Composer.RunInputs do
  @moduledoc """
  Turns the text of a start form or a decision form into the typed values Core casts.

  `Domovoy.Composer.LiteralPolicy` refuses a type outside its list, while Core refuses
  text for a type such as `Cracow.Float`, so a bind-only type is read by its primitive
  here. Nothing touches the file system, and an error names the input and never holds
  its value: Core's cast checks a path once, at submit.
  """

  alias Domovoy.Catalog
  alias Domovoy.Composer.Document
  alias Domovoy.Composer.LiteralPolicy
  alias DomovoyCore.Runner

  @primitives %{string: :text, integer: :integer, float: :float, boolean: :boolean}

  @type editor :: LiteralPolicy.editor() | :none
  @type field :: %{
          name: String.t(),
          type: String.t(),
          editor: editor(),
          default: String.t() | nil,
          required: boolean(),
          bound: boolean()
        }
  @type code :: :invalid | :missing | :relative
  @type error :: %{name: String.t(), code: code()}

  @doc """
  The fields a start form shows, by input name.
  """
  @spec fields(document :: Document.t()) :: [field()]
  def fields(document) do
    bound = bound_inputs(document)

    for {name, input} <- Enum.sort(document["inputs"]) do
      %{
        name: name,
        type: Catalog.type_label(input["type"]),
        editor: editor(input["type"]),
        default: input["default"],
        required: input["required"] == true,
        bound: name in bound
      }
    end
  end

  @doc """
  Reads a start form. A blank field with a default is left to Core's default. A blank
  required or bound input with none is `:missing`, because Core's own check passes a
  bound one and the run would then fail midway.
  """
  @spec parse(document :: Document.t(), params :: map()) :: {:ok, map()} | {:error, [error()]}
  def parse(document, params) do
    document
    |> fields()
    |> Enum.map(fn field -> {field, read(field, Map.get(params, field.name, ""))} end)
    |> collect()
  end

  @doc """
  The fields a decision form shows for one choice.
  """
  @spec choice_fields(choice :: map()) :: [field()]
  def choice_fields(choice) do
    for {name, type} <- Enum.sort(choice["inputs"]) do
      %{
        name: name,
        type: Catalog.type_label(type),
        editor: editor(type),
        default: nil,
        required: false,
        bound: false
      }
    end
  end

  @doc """
  Reads a decision form. A blank field is always left out, since Core keeps the earlier
  value on a rerun.
  """
  @spec parse_choice(choice :: map(), params :: map()) :: {:ok, map()} | {:error, [error()]}
  def parse_choice(choice, params) do
    choice
    |> choice_fields()
    |> Enum.map(fn field -> {field, read(field, Map.get(params, field.name, ""))} end)
    |> collect()
  end

  @doc """
  The runners of a document that aren't pure, for a person to confirm. A runner that
  declares nothing counts. An unknown runner is left out, because a start refuses it.
  """
  @spec effects(document :: Document.t()) :: [%{id: String.t(), label: String.t()}]
  def effects(document) do
    for {_vertex, %{"nodes" => nodes}} <- document["vertices"],
        {_name, %{"runner" => id}} <- nodes,
        {:ok, runner} <- [Catalog.runner(id)],
        Runner.effect(runner.module).class != :pure,
        uniq: true do
      %{id: runner.id, label: runner.label}
    end
    |> Enum.sort_by(& &1.label)
  end

  @spec editor(type :: term()) :: editor()
  defp editor(type) do
    case LiteralPolicy.editor(type) do
      :bind_only -> primitive(type)
      editor -> editor
    end
  end

  @spec primitive(type :: term()) :: editor()
  defp primitive(type) do
    case Catalog.type(type) do
      {:ok, %{module: module}} -> Map.get(@primitives, module.type(), :none)
      :error -> :none
    end
  end

  @spec bound_inputs(document :: Document.t()) :: MapSet.t(String.t())
  defp bound_inputs(document) do
    for {_vertex, %{"nodes" => nodes}} <- document["vertices"],
        {_name, %{"inputs" => inputs}} <- nodes,
        {_field, %{"bind" => source}} <- inputs,
        is_map_key(document["inputs"], source),
        into: MapSet.new() do
      source
    end
  end

  @spec read(field :: field(), raw :: term()) :: :omit | {:ok, term()} | {:error, code()}
  defp read(field, raw) do
    cond do
      not is_binary(raw) or not Document.text_safe?(raw) -> {:error, :invalid}
      String.trim(raw) == "" -> blank(field)
      field.editor == :none -> {:error, :invalid}
      true -> present(field.editor, raw)
    end
  end

  # `.` would otherwise mean the host's own checkout.
  @spec blank(field :: field()) :: :omit | {:error, code()}
  defp blank(%{default: default, editor: :path}) when is_binary(default) do
    if Path.type(default) == :absolute, do: :omit, else: {:error, :relative}
  end

  defp blank(%{default: default}) when is_binary(default), do: :omit
  defp blank(%{required: false, bound: false}), do: :omit
  defp blank(_field), do: {:error, :missing}

  @spec present(editor :: LiteralPolicy.editor(), raw :: String.t()) ::
          {:ok, term()} | {:error, code()}
  defp present(:path, raw) do
    if Path.type(raw) == :absolute, do: {:ok, raw}, else: {:error, :relative}
  end

  defp present(editor, raw) do
    case LiteralPolicy.parse_editor(editor, raw) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid}
    end
  end

  @spec collect(read :: [{field(), :omit | {:ok, term()} | {:error, code()}}]) ::
          {:ok, map()} | {:error, [error()]}
  defp collect(read) do
    case for {field, {:error, code}} <- read, do: %{name: field.name, code: code} do
      [] -> {:ok, for({field, {:ok, value}} <- read, into: %{}, do: {field.name, value})}
      errors -> {:error, errors}
    end
  end
end

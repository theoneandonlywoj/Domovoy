defmodule Domovoy.Composer.LiteralPolicy do
  @moduledoc """
  Which types take a typed-in literal, and how raw text becomes a value.

  Literals are stored as raw text and parsed only at analysis and build. Only
  UUID, URI and Email call a Core `cast/2`: the others could touch the file
  system, and Path, File and Directory stay path text so that no host path is
  checked or exported. A type outside this list is bind-only, as is every plugin
  type.
  """

  alias DomovoyCore.Type

  @type editor ::
          :text
          | :integer
          | :float
          | :number
          | :boolean
          | :uuid
          | :uri
          | :email
          | :path
          | :json_object
          | :json
          | :bind_only

  @editors %{
    "DomovoyCore.Type.String" => :text,
    "DomovoyCore.Type.Integer" => :integer,
    "DomovoyCore.Type.Float" => :float,
    "DomovoyCore.Type.Number" => :number,
    "DomovoyCore.Type.Boolean" => :boolean,
    "DomovoyCore.Type.UUID" => :uuid,
    "DomovoyCore.Type.URI" => :uri,
    "DomovoyCore.Type.Email" => :email,
    "DomovoyCore.Type.Path" => :path,
    "DomovoyCore.Type.File" => :path,
    "DomovoyCore.Type.Directory" => :path,
    "DomovoyCore.Type.Map" => :json_object,
    "DomovoyCore.Type.Any" => :json
  }

  @bind_only [
    "DomovoyCore.Type.Date",
    "DomovoyCore.Type.Time",
    "DomovoyCore.Type.NaiveDateTime",
    "DomovoyCore.Type.DateTime",
    "DomovoyCore.Type.Decimal",
    "DomovoyCore.Type.Binary"
  ]

  @doc """
  The Core type ids that have a literal editor.
  """
  @spec editor_types() :: [String.t()]
  def editor_types, do: Map.keys(@editors)

  @doc """
  The Core type ids that are usable only through a binding.
  """
  @spec bind_only_types() :: [String.t()]
  def bind_only_types, do: @bind_only

  @doc """
  The editor for a type id. An unlisted type is bind-only.
  """
  @spec editor(type :: term()) :: editor()
  def editor(type), do: Map.get(@editors, type, :bind_only)

  @doc """
  Parses raw literal text for a type id. An error never holds the value.
  """
  @spec parse(type :: term(), raw :: term()) :: {:ok, term()} | :error
  def parse(type, raw) when is_binary(raw), do: parse_as(editor(type), raw)
  def parse(_type, _raw), do: :error

  @doc """
  Parses raw text as an editor reads it, for a type whose editor came from elsewhere.
  An error never holds the value.
  """
  @spec parse_editor(editor :: editor(), raw :: term()) :: {:ok, term()} | :error
  def parse_editor(editor, raw) when is_binary(raw), do: parse_as(editor, raw)
  def parse_editor(_editor, _raw), do: :error

  @spec parse_as(editor :: editor(), raw :: String.t()) :: {:ok, term()} | :error
  defp parse_as(:text, raw), do: {:ok, raw}
  defp parse_as(:integer, raw), do: integer(raw)
  defp parse_as(:float, raw), do: float(raw)

  defp parse_as(:number, raw) do
    with :error <- integer(raw), do: float(raw)
  end

  defp parse_as(:boolean, "true"), do: {:ok, true}
  defp parse_as(:boolean, "false"), do: {:ok, false}
  defp parse_as(:boolean, _raw), do: :error
  defp parse_as(:uuid, raw), do: raw |> Type.UUID.cast(%{}) |> cast_result()
  defp parse_as(:uri, raw), do: raw |> Type.URI.cast(%{}) |> cast_result()
  defp parse_as(:email, raw), do: raw |> Type.Email.cast(%{}) |> cast_result()

  defp parse_as(:path, raw) do
    if String.trim(raw) == "", do: :error, else: {:ok, raw}
  end

  defp parse_as(:json_object, raw) do
    case Jason.decode(raw) do
      {:ok, %{} = object} -> {:ok, object}
      _other -> :error
    end
  end

  defp parse_as(:json, raw) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, _error} -> :error
    end
  end

  defp parse_as(:bind_only, _raw), do: :error

  @spec integer(raw :: String.t()) :: {:ok, integer()} | :error
  defp integer(raw) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  @spec float(raw :: String.t()) :: {:ok, float()} | :error
  defp float(raw) do
    case Float.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  @spec cast_result(result :: term()) :: {:ok, term()} | :error
  defp cast_result({:ok, value}), do: {:ok, value}
  defp cast_result(_error), do: :error
end

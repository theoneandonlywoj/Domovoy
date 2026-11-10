defmodule DomovoyWeb.Keymap do
  @moduledoc """
  The dashboard's key bindings, loaded from `priv/keymap.json` at compile time and validated by
  `DomovoyWeb.Keymap.Spec`. Editing the file recompiles this module; a broken file fails the build.

  Templates ask for keys by action id, never by literal key: `{Keymap.attrs("go.jobs")}` renders
  `data-shortcut` and, for keys a browser can announce, `aria-keyshortcuts`.
  """

  alias DomovoyWeb.Keymap.Spec

  @path Path.expand("../../priv/keymap.json", __DIR__)
  @external_resource @path
  @keymap @path |> File.read!() |> Spec.parse!()

  @actions for {_scope, actions} <- @keymap.scopes, pair <- actions, into: %{}, do: pair

  @typedoc "An action id such as `\"go.jobs\"`."
  @type action :: String.t()

  @doc "The single key of `action`; raises for an unknown action or one bound to a list of keys."
  @spec key(action()) :: String.t()
  def key(action) do
    case keys(action) do
      [key] -> key
      _keys -> raise ArgumentError, "keymap action #{inspect(action)} has several keys"
    end
  end

  @doc "The key at 0-based `index` of a list action; nil past the end; raises for an unknown action."
  @spec key(action :: action(), index :: non_neg_integer()) :: String.t() | nil
  def key(action, index) when is_integer(index) and index >= 0, do: Enum.at(keys(action), index)

  @doc "Every key of `action`, in order; raises for an unknown action."
  @spec keys(action()) :: [String.t()]
  def keys(action) do
    case Map.fetch(@actions, action) do
      {:ok, keys} -> keys
      :error -> raise ArgumentError, "unknown keymap action #{inspect(action)}"
    end
  end

  @doc """
  The shortcut attributes of a single-key action: `data-shortcut` and, unless the key is a sequence,
  `aria-keyshortcuts`. A nil action gives `[]`.
  """
  @spec attrs(action() | nil) :: [{String.t(), String.t()}]
  def attrs(nil), do: []

  def attrs(action), do: action |> key() |> build_attrs()

  @doc "The shortcut attributes of `index` of a list action; `[]` for a nil action or past the end."
  @spec attrs(action :: action() | nil, index :: non_neg_integer()) :: [{String.t(), String.t()}]
  def attrs(nil, _index), do: []
  def attrs(action, index), do: action |> key(index) |> build_attrs()

  @spec build_attrs(key :: String.t() | nil) :: [{String.t(), String.t()}]
  defp build_attrs(nil), do: []

  defp build_attrs(key) do
    case aria(key) do
      nil -> [{"data-shortcut", key}]
      aria -> [{"data-shortcut", key}, {"aria-keyshortcuts", aria}]
    end
  end

  @doc "The `aria-keyshortcuts` value of a key: none (nil) for a two-key sequence, else the key."
  @spec aria(String.t()) :: String.t() | nil
  def aria(key), do: if(String.contains?(key, " "), do: nil, else: key)

  @doc "Prefix keys that start a two-key sequence on the page."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @keymap.prefixes

  @doc "Every action id, sorted."
  @spec actions() :: [action()]
  def actions, do: @actions |> Map.keys() |> Enum.sort()
end

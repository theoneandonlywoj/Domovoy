defmodule DomovoyWeb.Keymap.Spec do
  @moduledoc """
  Parses and validates the keymap JSON (`priv/keymap.json`). `DomovoyWeb.Keymap` calls `parse!/1` at
  compile time, so a broken keymap fails `mix compile` with an `ArgumentError` naming the scope, the
  action and the key.

  The file holds `prefixes` (keys that start a two-key sequence) and `scopes`, each mapping action ids to
  one key or a non-empty list of keys. The rules:

    * each prefix is one printable non-space character, and prefixes are unique;
    * the only scope is `page`;
    * an action id looks like `group.name` (lowercase letters and `_`);
    * a key is one printable non-space character or `"<prefix> <char>"` with a declared prefix;
    * no single key equals a prefix;
    * each key belongs to one action.
  """

  @type t :: %{prefixes: [String.t()], scopes: %{String.t() => %{String.t() => [String.t()]}}}

  @scope ~r/\Apage\z/
  @action ~r/\A[a-z_]+(\.[a-z_]+)+\z/

  @doc "Decodes and validates keymap JSON; single keys are normalised to one-element lists."
  @spec parse!(String.t()) :: t()
  def parse!(json) when is_binary(json) do
    case JSON.decode!(json) do
      %{"prefixes" => prefixes, "scopes" => %{} = scopes} when is_list(prefixes) ->
        prefixes = validate_prefixes!(prefixes)
        scopes = Map.new(scopes, fn {scope, actions} -> normalise!(scope, actions) end)

        Enum.each(scopes, fn {scope, actions} -> validate_scope!(scope, actions, prefixes) end)

        %{prefixes: prefixes, scopes: scopes}

      _other ->
        raise ArgumentError,
              "keymap: expected an object with a \"prefixes\" list and a \"scopes\" object"
    end
  end

  defp validate_prefixes!(prefixes) do
    Enum.each(prefixes, fn prefix ->
      if !single?(prefix),
        do:
          raise(ArgumentError, "keymap: prefix #{inspect(prefix)} is not one printable character")
    end)

    if prefixes != Enum.uniq(prefixes),
      do: raise(ArgumentError, "keymap: prefixes repeat a key: #{inspect(prefixes)}")

    prefixes
  end

  defp normalise!(scope, actions) do
    if !Regex.match?(@scope, scope),
      do: raise(ArgumentError, "keymap: scope #{inspect(scope)} is not page")

    if !is_map(actions),
      do: raise(ArgumentError, "keymap: scope #{inspect(scope)} is not an object of actions")

    {scope,
     Map.new(actions, fn {action, keys} -> {action, normalise_keys!(scope, action, keys)} end)}
  end

  defp normalise_keys!(_scope, _action, key) when is_binary(key), do: [key]

  defp normalise_keys!(scope, action, [_ | _] = keys) do
    if Enum.all?(keys, &is_binary/1), do: keys, else: invalid_keys!(scope, action, keys)
  end

  defp normalise_keys!(scope, action, keys), do: invalid_keys!(scope, action, keys)

  @spec invalid_keys!(String.t(), String.t(), term()) :: no_return()
  defp invalid_keys!(scope, action, keys) do
    raise ArgumentError,
          "keymap: scope #{inspect(scope)}, action #{inspect(action)}: " <>
            "expected a key or a non-empty list of keys, got #{inspect(keys)}"
  end

  defp validate_scope!(scope, actions, prefixes) do
    bindings = for {action, keys} <- Enum.sort(actions), key <- keys, do: {action, key}

    actions |> Map.keys() |> Enum.each(&validate_action!(scope, &1))

    Enum.each(bindings, fn {action, key} -> validate_key!(scope, action, key, prefixes) end)

    Enum.reduce(bindings, %{}, fn {action, key}, seen ->
      case Map.fetch(seen, key) do
        {:ok, other} -> key_error!(scope, action, key, "is already bound to #{inspect(other)}")
        :error -> Map.put(seen, key, action)
      end
    end)
  end

  defp validate_action!(scope, action) do
    if !Regex.match?(@action, action) do
      raise ArgumentError,
            "keymap: scope #{inspect(scope)}, action #{inspect(action)}: " <>
              "action ids look like group.name (lowercase letters and _)"
    end
  end

  defp validate_key!(scope, action, key, prefixes) do
    cond do
      single?(key) ->
        if key in prefixes,
          do: key_error!(scope, action, key, "is a prefix, so it cannot be a page key")

      sequence?(key) ->
        [prefix, _char] = String.split(key, " ")

        if prefix not in prefixes,
          do: key_error!(scope, action, key, "uses undeclared prefix #{inspect(prefix)}")

      true ->
        key_error!(scope, action, key, "is not one printable character or \"<prefix> <char>\"")
    end
  end

  @spec key_error!(String.t(), String.t(), String.t(), String.t()) :: no_return()
  defp key_error!(scope, action, key, reason) do
    raise ArgumentError,
          "keymap: scope #{inspect(scope)}, action #{inspect(action)}, key #{inspect(key)} #{reason}"
  end

  defp single?(key) when is_binary(key) do
    String.length(key) == 1 and String.printable?(key) and not Regex.match?(~r/\A\s\z/u, key)
  end

  defp single?(_key), do: false

  defp sequence?(key) do
    case String.split(key, " ") do
      [prefix, char] -> single?(prefix) and single?(char)
      _other -> false
    end
  end
end

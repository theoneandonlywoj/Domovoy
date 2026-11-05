defmodule Domovoy.Catalog do
  @moduledoc """
  The only owner of string-to-module resolution.

  Everything outside this module speaks in string ids. An id is `inspect(module)`
  and resolves by map lookup alone, so an unknown string never creates an atom
  or loads a module. The map is reflected from the installed plugins at boot,
  held in `:persistent_term`, and never holds anything `Curated` hides.
  """

  alias Domovoy.Catalog.Curated
  alias DomovoyCore.Runner
  alias DomovoyCore.Type

  @key {__MODULE__, :catalog}
  @any inspect(Type.Any)

  @type id :: String.t()
  @type entry :: map()

  @doc """
  Reflects the installed plugins and stores the catalog. Called once, at boot.
  """
  @spec load() :: :ok
  def load do
    plugins = Enum.map(Curated.plugins(), &plugin_entry/1)

    owned =
      for plugin <- plugins, plugin.installed?, module <- app_modules(plugin.app), into: %{} do
        {module, plugin}
      end

    visible = Map.drop(owned, Curated.hidden())

    catalog = %{
      plugins: plugins,
      types: index(visible, &Type.type?/1, &entry/2),
      runners: index(visible, &Runner.runner?/1, &runner_entry/2),
      validators: Map.new(Curated.validators(), &curated_validator(&1, owned)),
      deciders: Enum.map(Curated.deciders(), &entry(&1, Map.fetch!(owned, &1))),
      owned: owned
    }

    :persistent_term.put(@key, catalog)
  end

  @doc """
  Finds a runner by id.
  """
  @spec runner(id :: term()) :: {:ok, entry()} | :error
  def runner(id), do: Map.fetch(catalog().runners, id)

  @doc """
  Finds a type by id.
  """
  @spec type(id :: term()) :: {:ok, entry()} | :error
  def type(id), do: Map.fetch(catalog().types, id)

  @doc """
  Every installed type, sorted by label.
  """
  @spec types() :: [entry()]
  def types, do: catalog().types |> Map.values() |> Enum.sort_by(& &1.label)

  @doc """
  Finds a curated validator by id.
  """
  @spec validator(id :: term()) :: {:ok, entry()} | :error
  def validator(id), do: Map.fetch(catalog().validators, id)

  @doc """
  Finds one field of a runner by the field's string id.
  """
  @spec field(runner_id :: term(), field_id :: term()) :: {:ok, entry()} | :error
  def field(runner_id, field_id) do
    with {:ok, runner} <- runner(runner_id) do
      Enum.find_value(runner.fields, :error, &(&1.id == field_id and {:ok, &1}))
    end
  end

  @doc """
  The label of a type, or the id itself when the type isn't in the catalog.
  """
  @spec type_label(id :: id()) :: String.t()
  def type_label(id) do
    case type(id) do
      {:ok, type} -> type.label
      :error -> id
    end
  end

  @doc """
  The validators of a runner: those it declares, which a node can't remove, and
  the curated ones a node may add because the runner has every field they read.
  """
  @spec validators_for(runner_id :: term()) :: %{inherited: [entry()], curated: [entry()]}
  def validators_for(runner_id) do
    case runner(runner_id) do
      {:ok, runner} ->
        catalog = catalog()
        fields = MapSet.new(runner.fields, & &1.id)

        %{
          inherited: Enum.map(runner.validators, &inherited_validator(&1, catalog)),
          curated:
            catalog.validators
            |> Map.values()
            |> Enum.filter(fn validator -> Enum.all?(validator.requires, &(&1 in fields)) end)
            |> Enum.reject(&(&1.module in runner.validators))
            |> Enum.sort_by(& &1.label)
        }

      :error ->
        %{inherited: [], curated: []}
    end
  end

  @doc """
  The deciders a Decision may name.
  """
  @spec deciders() :: [entry()]
  def deciders, do: catalog().deciders

  @doc """
  Every known plugin, with `installed?` and `verified?`.
  """
  @spec plugins() :: [entry()]
  def plugins, do: catalog().plugins

  @doc """
  Lists runners matching every given filter, sorted by label.

  `:label`, `:module` and `:plugin` match part of the text, ignoring case;
  `:text` does the same across those and the type labels. `:input` and `:output`
  are exact type ids. A filter of any other key or shape matches nothing.
  """
  @spec search(filters :: map()) :: [entry()]
  def search(filters) when is_map(filters) do
    catalog().runners
    |> Map.values()
    |> Enum.filter(fn runner -> Enum.all?(filters, &matches?(runner, &1)) end)
    |> Enum.sort_by(& &1.label)
  end

  @doc """
  Lists runners that turn a `from` value into a `to` value: the output is exactly
  `to` and a field is exactly `from`. An Any field doesn't count, because it
  would make every runner an adapter.
  """
  @spec adapters(from :: id(), to :: id()) :: [entry()]
  def adapters(from, to) do
    catalog().runners
    |> Map.values()
    |> Enum.filter(&(&1.output == to and adapter_field(&1, from) != nil))
    |> Enum.sort_by(& &1.label)
  end

  @doc """
  The first field of a runner taking exactly `from`, never an Any field.
  """
  @spec adapter_field(runner :: entry(), from :: id()) :: entry() | nil
  def adapter_field(runner, from) do
    Enum.find(runner.fields, &(&1.type_id == from and &1.type_id != @any))
  end

  @spec catalog() :: map()
  defp catalog, do: :persistent_term.get(@key)

  @spec plugin_entry(plugin :: map()) :: entry()
  defp plugin_entry(plugin) do
    Map.merge(plugin, %{installed?: Application.spec(plugin.app) != nil, verified?: false})
  end

  @spec app_modules(app :: atom()) :: [module()]
  defp app_modules(app) do
    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  @spec index(
          owned :: map(),
          keep? :: (module() -> boolean()),
          build :: (module(), map() -> entry())
        ) ::
          %{id() => entry()}
  defp index(owned, keep?, build) do
    for {module, plugin} <- owned, keep?.(module), into: %{} do
      {inspect(module), build.(module, plugin)}
    end
  end

  @spec entry(module :: module(), plugin :: map()) :: entry()
  defp entry(module, plugin) do
    %{id: inspect(module), module: module, label: label(module, plugin), plugin: plugin.name}
  end

  @spec label(module :: module(), plugin :: map()) :: String.t()
  defp label(module, plugin) do
    name = module |> Module.split() |> List.last()
    if plugin.prefix, do: "#{plugin.prefix} #{name}", else: name
  end

  @spec runner_entry(module :: module(), plugin :: map()) :: entry()
  defp runner_entry(module, plugin) do
    required = module.__domovoy_core__(:required)
    input = module.__domovoy_core__(:input)

    module
    |> entry(plugin)
    |> Map.merge(%{
      input: input,
      output: inspect(module.__domovoy_core__(:output)),
      output_module: module.__domovoy_core__(:output),
      required: required,
      validators: module.__domovoy_core__(:validators),
      retry: module.__domovoy_core__(:retry),
      extra?: module.__domovoy_core__(:extra?),
      version: module.__domovoy_core__(:version),
      effect: module.__domovoy_core__(:effect),
      fields: fields(input, required)
    })
  end

  @spec fields(input :: module(), required :: [atom()]) :: [entry()]
  defp fields(input, required) do
    defaults = struct(input)

    for name <- input.__schema__(:fields), name not in Curated.hidden_fields() do
      type = input.__schema__(:type, name)

      %{
        name: name,
        id: Atom.to_string(name),
        type: type,
        type_id: inspect(type),
        required: name in required,
        default: Map.get(defaults, name)
      }
    end
  end

  @spec curated_validator(validator :: map(), owned :: map()) :: {id(), entry()}
  defp curated_validator(validator, owned) do
    entry = validator.module |> entry(Map.fetch!(owned, validator.module)) |> Map.merge(validator)
    {entry.id, entry}
  end

  @spec inherited_validator(module :: module(), catalog :: map()) :: entry()
  defp inherited_validator(module, catalog) do
    id = inspect(module)

    Map.get_lazy(catalog.validators, id, fn ->
      module
      |> entry(Map.fetch!(catalog.owned, module))
      |> Map.merge(%{description: nil, requires: []})
    end)
  end

  @spec matches?(runner :: entry(), filter :: {term(), term()}) :: boolean()
  defp matches?(runner, {:text, text}) when is_binary(text) do
    types = [runner.output | Enum.map(runner.fields, & &1.type_id)]
    labels = Enum.map(types, &type_label/1)
    Enum.any?([runner.label, runner.id, runner.plugin | labels], &contains?(&1, text))
  end

  defp matches?(runner, {:label, text}) when is_binary(text), do: contains?(runner.label, text)
  defp matches?(runner, {:module, text}) when is_binary(text), do: contains?(runner.id, text)
  defp matches?(runner, {:plugin, text}) when is_binary(text), do: contains?(runner.plugin, text)
  defp matches?(runner, {:output, type}), do: runner.output == type
  defp matches?(runner, {:input, type}), do: Enum.any?(runner.fields, &(&1.type_id == type))
  defp matches?(_runner, _filter), do: false

  @spec contains?(text :: String.t(), part :: String.t()) :: boolean()
  defp contains?(text, part), do: String.contains?(String.downcase(text), String.downcase(part))
end

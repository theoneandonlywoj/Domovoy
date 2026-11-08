defmodule Domovoy.Composer.InputSets do
  @moduledoc """
  A draft's saved input sets: named launch values a New run launcher can fill in again.

  The storage policy lives here. A field's text is kept by default when its editor is
  plain (`:eligible` in `Domovoy.Composer.RunInputs`), and a path, id, URI, email or
  JSON field's text (`:opt_in`) only when the person asked for that field. A field
  that can't be typed here is never kept. A kept opt-in value goes back to a start,
  never to the page. Sets are deleted with their draft.

  Like runs, sets exist only with `composer_runs_enabled` on: otherwise every function
  gives `{:error, :runs_disabled}`. Queries pass `log: false`, since a set holds input
  text.
  """

  import Ecto.Query

  alias Domovoy.Composer.Document
  alias Domovoy.Composer.InputSet
  alias Domovoy.Composer.RunInputs
  alias Domovoy.Composer.Runs
  alias Domovoy.Repo

  @name_limit 255

  @type disabled :: {:error, :runs_disabled}

  @type loaded :: %{
          params: %{String.t() => String.t()},
          reused: %{String.t() => String.t()},
          drift: [%{name: String.t(), kind: :removed | :type_changed}],
          blank: [String.t()]
        }

  @doc """
  A draft's sets, by name. A malformed draft id has none.
  """
  @spec list(draft_id :: term()) :: [InputSet.t()] | disabled()
  def list(draft_id) do
    gated(fn ->
      case Ecto.UUID.cast(draft_id) do
        {:ok, uuid} ->
          Repo.all(from(set in InputSet, where: set.draft_id == ^uuid, order_by: set.name),
            log: false
          )

        :error ->
          []
      end
    end)
  end

  @doc """
  Saves the text typed into `params` as a set called `name`, keeping only what the
  storage policy allows: an `:opt_in` field only when `opt_ins` names it. A name the
  draft already uses gives `:name_taken` and changes nothing.
  """
  @spec save(
          draft_id :: term(),
          name :: term(),
          fields :: [RunInputs.field()],
          params :: term(),
          opt_ins :: [String.t()]
        ) ::
          {:ok, InputSet.t()}
          | {:error, :name_taken | :invalid_name | :not_found}
          | disabled()
  def save(draft_id, name, fields, params, opt_ins) do
    gated(fn ->
      with {:ok, uuid} <- cast(draft_id),
           {:ok, name} <- valid_name(name),
           false <- taken?(uuid, name) do
        %InputSet{draft_id: uuid, name: name, values: kept(fields, params, opt_ins)}
        |> InputSet.changeset()
        |> Repo.insert(log: false)
        |> inserted()
      else
        true -> {:error, :name_taken}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Finds a set of a draft. A malformed id, and another draft's set, are not found.
  """
  @spec fetch(draft_id :: term(), id :: term()) ::
          {:ok, InputSet.t()} | {:error, :not_found} | disabled()
  def fetch(draft_id, id) do
    gated(fn ->
      with {:ok, draft_uuid} <- cast(draft_id),
           {:ok, uuid} <- cast(id),
           %InputSet{} = set <-
             Repo.get_by(InputSet, [id: uuid, draft_id: draft_uuid], log: false) do
        {:ok, set}
      else
        _missing -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Deletes a set of a draft. Runs started with it keep a nil `input_set_id`.
  """
  @spec delete(draft_id :: term(), id :: term()) :: :ok | {:error, :not_found} | disabled()
  def delete(draft_id, id) do
    gated(fn ->
      with {:ok, draft_uuid} <- cast(draft_id),
           {:ok, uuid} <- cast(id),
           {1, _rows} <-
             Repo.delete_all(
               from(set in InputSet, where: set.id == ^uuid and set.draft_id == ^draft_uuid),
               log: false
             ) do
        :ok
      else
        _missing -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Reads a set against the draft's fields as they are now: `params` for the form,
  `reused` for opt-in text that goes only to the start, `drift` for a kept field the
  draft removed or retyped, and `blank` for each field the set fills in neither way.
  """
  @spec load(set :: InputSet.t(), fields :: [RunInputs.field()]) :: loaded() | disabled()
  def load(set, fields), do: gated(fn -> loaded(set, fields) end)

  @spec loaded(set :: InputSet.t(), fields :: [RunInputs.field()]) :: loaded()
  defp loaded(%InputSet{values: values}, fields) do
    by_name = Map.new(fields, &{&1.name, &1})

    read =
      for {name, %{"type" => type, "text" => text}} <- values,
          is_binary(text),
          do: read_value(by_name[name], name, type, text)

    params = for {:params, pair} <- read, into: %{}, do: pair
    reused = for {:reused, pair} <- read, into: %{}, do: pair

    %{
      params: params,
      reused: reused,
      drift: Enum.sort_by(for({:drift, drift} <- read, do: drift), & &1.name),
      blank:
        for(
          %{name: name} <- fields,
          not is_map_key(params, name) and not is_map_key(reused, name),
          do: name
        )
    }
  end

  @spec read_value(
          field :: RunInputs.field() | nil,
          name :: String.t(),
          type :: term(),
          text :: String.t()
        ) :: {:params | :reused, {String.t(), String.t()}} | {:drift, map()} | {:skip, String.t()}
  defp read_value(nil, name, _type, _text), do: {:drift, %{name: name, kind: :removed}}

  defp read_value(%{type_id: type, reuse: :eligible}, name, type, text),
    do: {:params, {name, text}}

  defp read_value(%{type_id: type, reuse: :opt_in}, name, type, text), do: {:reused, {name, text}}
  defp read_value(%{type_id: type}, name, type, _text), do: {:skip, name}
  defp read_value(_retyped, name, _type, _text), do: {:drift, %{name: name, kind: :type_changed}}

  @spec kept(fields :: [RunInputs.field()], params :: term(), opt_ins :: [String.t()]) :: map()
  defp kept(fields, params, opt_ins) do
    params = if is_map(params), do: params, else: %{}

    for %{name: name, reuse: reuse, type_id: type} <- fields,
        reuse == :eligible or (reuse == :opt_in and name in opt_ins),
        text = params[name],
        is_binary(text) and Document.text_safe?(text) and String.trim(text) != "",
        into: %{} do
      {name, %{"type" => type, "text" => text}}
    end
  end

  @spec valid_name(name :: term()) :: {:ok, String.t()} | {:error, :invalid_name}
  defp valid_name(name) when is_binary(name) do
    if Document.text_safe?(name) and String.trim(name) != "" and
         String.length(name) <= @name_limit,
       do: {:ok, String.trim(name)},
       else: {:error, :invalid_name}
  end

  defp valid_name(_name), do: {:error, :invalid_name}

  @spec taken?(draft_id :: String.t(), name :: String.t()) :: boolean()
  defp taken?(draft_id, name) do
    Repo.exists?(from(set in InputSet, where: set.draft_id == ^draft_id and set.name == ^name),
      log: false
    )
  end

  # A second save racing the first one meets the unique index.
  @spec inserted(result :: {:ok, InputSet.t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, InputSet.t()} | {:error, :name_taken | :not_found}
  defp inserted({:ok, set}), do: {:ok, set}

  defp inserted({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :name),
      do: {:error, :name_taken},
      else: {:error, :not_found}
  end

  @spec cast(id :: term()) :: {:ok, String.t()} | {:error, :not_found}
  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  @spec gated(fun :: (-> result)) :: result | disabled() when result: term()
  defp gated(fun), do: if(Runs.enabled?(), do: fun.(), else: {:error, :runs_disabled})
end

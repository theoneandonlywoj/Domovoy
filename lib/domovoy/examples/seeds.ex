defmodule Domovoy.Examples.Seeds do
  @moduledoc """
  Reconciles the example drafts: reads the saved drafts, then creates each example
  whose engine name no draft holds. A draft holding that name is left alone, whatever
  it now says, because it may hold a person's edits.

  Every example is validated before anything is written, and each insert holds the
  finished document, so an interrupted run leaves whole drafts only and the next run
  adds the missing ones. Two runs at once can both create a draft, since nothing
  enforces a unique engine name.
  """

  alias Domovoy.Composer
  alias Domovoy.Examples.Definitions

  @type outcome :: {engine_name :: String.t(), :created | :kept}

  @doc """
  Runs the reconciliation. Raises with the issue codes of a definition that fails
  validation, and on a failed insert, never with a literal value.
  """
  @spec run() :: [outcome()]
  def run do
    examples = Definitions.all()
    Enum.each(examples, &validate!/1)
    existing = MapSet.new(Composer.list_drafts(), & &1.document["name"])

    Enum.map(examples, fn %{document: %{"name" => name}} = example ->
      if name in existing, do: {name, :kept}, else: {name, create!(example)}
    end)
  end

  @spec validate!(example :: map()) :: :ok
  defp validate!(%{document: document}) do
    case Composer.validate(document) do
      {:valid, _result} ->
        :ok

      {:invalid, issues} ->
        codes = Enum.map(issues, &{&1.code, &1.core_id})
        raise "Seed #{document["name"]} is not a valid definition: #{inspect(codes)}"
    end
  end

  @spec create!(example :: map()) :: :created
  defp create!(%{title: title, document: document}) do
    case Composer.create_draft(title, document) do
      {:ok, _draft} ->
        :created

      {:error, changeset} ->
        fields = Keyword.keys(changeset.errors)
        raise "Seed #{document["name"]} could not be saved: #{inspect(fields)}"
    end
  end
end

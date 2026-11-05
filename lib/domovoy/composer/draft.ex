defmodule Domovoy.Composer.Draft do
  @moduledoc """
  One saved composer draft: a title and its document.

  `config/config.exs` sets binary ids and UTC timestamps for generators only,
  so this schema states both. Saves go through an optimistic lock, so a tab
  holding an older row can't overwrite a newer one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "composer_drafts" do
    field :title, :string
    field :document, :map
    field :lock_version, :integer, default: 1

    timestamps()
  end

  @doc """
  Casts a title and a document, refusing a title Postgres can't store.
  """
  @spec changeset(draft :: t(), attrs :: map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = draft, attrs) do
    draft
    |> cast(attrs, [:title, :document])
    |> validate_required([:title, :document])
    |> validate_length(:title, max: 255, count: :codepoints)
    |> validate_change(:title, &validate_text/2)
    |> optimistic_lock(:lock_version)
  end

  @spec validate_text(field :: atom(), title :: String.t()) :: keyword()
  defp validate_text(field, title) do
    if String.valid?(title) and not String.contains?(title, <<0>>),
      do: [],
      else: [{field, "must be text without NUL"}]
  end
end

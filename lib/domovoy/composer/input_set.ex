defmodule Domovoy.Composer.InputSet do
  @moduledoc """
  A named, reusable set of launch values for one draft. `values` maps an input's name
  to its type id and the text typed for it, such as
  `%{"area" => %{"type" => "Domovoy.Examples.Cracow.Float", "text" => "58.5"}}`, so a
  type changed since can be told apart. A draft's deletion deletes its sets.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "composer_input_sets" do
    field :draft_id, :binary_id
    field :name, :string
    field :values, :map

    timestamps()
  end

  @doc """
  A changeset for a set whose every field `Domovoy.Composer.InputSets` has set.
  """
  @spec changeset(set :: t()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = set) do
    set
    |> change()
    |> validate_required([:draft_id, :name, :values])
    |> foreign_key_constraint(:draft_id)
    |> unique_constraint(:name, name: :composer_input_sets_draft_id_name_index)
  end
end

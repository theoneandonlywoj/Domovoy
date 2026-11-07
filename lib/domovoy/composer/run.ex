defmodule Domovoy.Composer.Run do
  @moduledoc """
  One started run of a draft: the snapshot of its document, and the ids Core knows it
  by. It holds no status and no input value, because Core's committed view stays the
  only authority. A draft's deletion leaves the row, with a nil `draft_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "composer_runs" do
    field :draft_id, :binary_id
    field :workflow_name, :string
    field :document, :map
    field :fingerprint, :string
    field :start_command_id, :string

    timestamps()
  end

  @doc """
  A changeset for a row whose every field the gateway has set.
  """
  @spec changeset(run :: t()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = run) do
    run
    |> change()
    |> foreign_key_constraint(:draft_id)
  end
end

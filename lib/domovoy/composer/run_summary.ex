defmodule Domovoy.Composer.RunSummary do
  @moduledoc """
  A derived, possibly stale status row for one run, so history lists runs without
  opening each one. It holds no input or output value and never authorises a command:
  a command re-reads Core first. `Domovoy.Composer.Runs` alone writes it, and it goes
  with its run.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:run_id, :binary_id, autogenerate: false}

  schema "composer_run_summaries" do
    field :committed_phase, :string
    field :outcome, :string
    field :generation, :integer
    field :committed_seq, :integer, default: 0
    field :pending_decisions, {:array, :string}, default: []
    field :error_type, :string
    field :terminal, :boolean, default: false
    field :projection_version, :integer
    field :refreshed_at, :utc_datetime_usec
  end
end

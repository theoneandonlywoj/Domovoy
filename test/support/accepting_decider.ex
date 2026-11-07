defmodule Domovoy.AcceptingDecider do
  @moduledoc """
  Picks `accept` at once. It declares a non-idempotent effect, so its decision is an
  attempt of its own in the run's events. It isn't curated, so only a hand-built Core
  workflow can name it.
  """

  use DomovoyCore.Decider, effect: :non_idempotent

  alias DomovoyCore.Context
  alias DomovoyCore.Decision

  @impl DomovoyCore.Decider
  def decide(%Decision{}, %Context{}, _opts), do: {:ok, "accept"}
end

defmodule Domovoy.RaisingValidator do
  @moduledoc """
  Tells the test's gate it ran, then raises with the node's `secret` field. It isn't
  curated, so only a hand-built Core workflow can name it.
  """

  @behaviour DomovoyCore.Validator

  @impl DomovoyCore.Validator
  def validate(changeset, %DomovoyCore.Context{node: node}) do
    send(Domovoy.RunTestGate, {:validated, node})
    raise ArgumentError, Ecto.Changeset.get_field(changeset, :secret)
  end
end

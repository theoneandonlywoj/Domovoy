defmodule Domovoy.Examples.Cracow.AreaPolicy do
  @moduledoc """
  Rejects unusually large listings at the node boundary. Ported from Core's
  `cracow_house_price` notebook.
  """

  @behaviour DomovoyCore.Validator

  import Ecto.Changeset

  @impl DomovoyCore.Validator
  def validate(changeset, %DomovoyCore.Context{}),
    do: validate_number(changeset, :area, less_than_or_equal_to: 300)
end

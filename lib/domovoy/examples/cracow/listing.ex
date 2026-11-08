defmodule Domovoy.Examples.Cracow.Listing do
  @moduledoc """
  Refuses a listing no flat in Kraków could match. Errors name fields and rules,
  never values. Ported from Core's `cracow_house_price` notebook.
  """

  @behaviour DomovoyCore.Validator

  import Ecto.Changeset

  alias Domovoy.Examples.Cracow.Market

  @impl DomovoyCore.Validator
  def validate(changeset, %DomovoyCore.Context{}) do
    changeset
    |> validate_number(:rooms, greater_than_or_equal_to: 1)
    |> validate_number(:bathrooms, greater_than_or_equal_to: 1)
    |> validate_number(:area, greater_than_or_equal_to: 15)
    |> validate_number(:floor, greater_than_or_equal_to: 0)
    |> validate_inclusion(:district, Market.districts())
  end
end

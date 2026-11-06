defmodule Domovoy.Examples.Cracow.RoomLayout do
  @moduledoc """
  Keeps bathrooms within the listing's room count. Ported from Core's
  `cracow_house_price` notebook.
  """

  @behaviour DomovoyCore.Validator

  import Ecto.Changeset

  @impl DomovoyCore.Validator
  def validate(changeset, %DomovoyCore.Context{}) do
    rooms = get_field(changeset, :rooms)
    bathrooms = get_field(changeset, :bathrooms)

    if is_integer(rooms) and is_integer(bathrooms) and bathrooms > rooms do
      add_error(changeset, :bathrooms, "must not exceed rooms",
        validation: :bathrooms_within_rooms
      )
    else
      changeset
    end
  end
end

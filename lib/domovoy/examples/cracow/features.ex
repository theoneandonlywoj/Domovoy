defmodule Domovoy.Examples.Cracow.Features do
  @moduledoc """
  The normalized listing every branch reads.

  A value is a plain map with string keys: `rooms`, `bathrooms`, `area`, `district`,
  `floor`, `balcony`, `year_built` and `m2_per_room`. Anything else is refused, so a
  producer that forgets a field fails at the arrow, not inside a branch. Ported from
  Core's `cracow_house_price` notebook.
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :map

  @impl DomovoyCore.Type
  def cast(raw, _metadata) when is_map(raw) and not is_struct(raw) do
    with %{
           "rooms" => rooms,
           "bathrooms" => bathrooms,
           "area" => area,
           "district" => district,
           "floor" => floor,
           "balcony" => balcony,
           "year_built" => year_built,
           "m2_per_room" => m2_per_room
         } <- raw,
         true <- is_integer(rooms),
         true <- is_integer(bathrooms),
         true <- is_number(area),
         true <- is_binary(district),
         true <- is_integer(floor),
         true <- is_boolean(balcony),
         true <- is_integer(year_built),
         true <- is_number(m2_per_room) do
      {:ok, raw}
    else
      _ -> :error
    end
  end

  def cast(_raw, _metadata), do: :error
end

defmodule Domovoy.Examples.Cracow.Normalize do
  @moduledoc """
  Checks the listing and gives one features value to every branch. Ported from Core's
  `cracow_house_price` notebook.
  """

  use DomovoyCore.Runner

  alias Domovoy.Examples.Cracow.Features
  alias Domovoy.Examples.Cracow.Float, as: CracowFloat
  alias Domovoy.Examples.Cracow.Listing

  output(Features)

  input do
    field :rooms, DomovoyCore.Type.Integer
    field :bathrooms, DomovoyCore.Type.Integer
    field :area, CracowFloat
    field :district, DomovoyCore.Type.String
    field :floor, DomovoyCore.Type.Integer, default: 1
    field :balcony, DomovoyCore.Type.Boolean, default: false
    field :year_built, DomovoyCore.Type.Integer, default: 2005
  end

  required([:rooms, :bathrooms, :area, :district])
  validators([Listing])

  @impl DomovoyCore.Runner
  def run(%Input{} = listing, %DomovoyCore.Context{}) do
    features =
      listing
      |> Map.from_struct()
      |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
      |> Map.put("m2_per_room", listing.area / listing.rooms)

    {:ok, features}
  end
end

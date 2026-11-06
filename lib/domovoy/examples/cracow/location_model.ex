defmodule Domovoy.Examples.Cracow.LocationModel do
  @moduledoc """
  The district, floor, balcony and age factor. Ported from Core's
  `cracow_house_price` notebook.
  """

  use DomovoyCore.Runner

  alias Domovoy.Examples.Cracow.Features
  alias Domovoy.Examples.Cracow.Float, as: CracowFloat
  alias Domovoy.Examples.Cracow.Market

  output(CracowFloat)

  input do
    field :features, Features
  end

  required([:features])

  @impl DomovoyCore.Runner
  def run(%Input{features: features}, %DomovoyCore.Context{}) do
    %{"district" => district, "floor" => floor, "balcony" => balcony, "year_built" => year} =
      features

    {:ok, Market.location_factor(district, floor, balcony, year)}
  end
end

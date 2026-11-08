defmodule Domovoy.Examples.Cracow.LayoutModel do
  @moduledoc """
  The rooms and bathrooms factor. Ported from Core's `cracow_house_price` notebook.
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
    %{"rooms" => rooms, "bathrooms" => bathrooms, "area" => area} = features
    {:ok, Market.layout_factor(rooms, bathrooms, area)}
  end
end

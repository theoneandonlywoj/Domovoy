defmodule Domovoy.Examples.Cracow.AreaModel do
  @moduledoc """
  The base value of the flat, from its area alone. Ported from Core's
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
    {:ok, Market.base_value(features["area"])}
  end
end

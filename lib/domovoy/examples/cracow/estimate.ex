defmodule Domovoy.Examples.Cracow.Estimate do
  @moduledoc """
  Joins the three terms into one price. Ported from Core's `cracow_house_price`
  notebook.
  """

  use DomovoyCore.Runner

  alias Domovoy.Examples.Cracow.Features
  alias Domovoy.Examples.Cracow.Float, as: CracowFloat

  output(DomovoyCore.Type.Map)

  input do
    field :features, Features
    field :base, CracowFloat
    field :layout, CracowFloat
    field :location, CracowFloat
  end

  required([:features, :base, :layout, :location])

  @impl DomovoyCore.Runner
  def run(%Input{} = input, %DomovoyCore.Context{}) do
    price = input.base * input.layout * input.location

    {:ok,
     %{
       "price" => round(price),
       "per_m2" => round(price / input.features["area"]),
       "components" => %{
         "base" => round(input.base),
         "layout" => input.layout,
         "location" => input.location
       }
     }}
  end
end

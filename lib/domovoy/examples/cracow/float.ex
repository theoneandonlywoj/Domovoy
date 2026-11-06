defmodule Domovoy.Examples.Cracow.Float do
  @moduledoc """
  A float, such as an area in square metres. An integer is promoted to a float;
  anything else is refused. Ported from Core's `cracow_house_price` notebook.
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :float

  @impl DomovoyCore.Type
  def cast(raw, _metadata) when is_float(raw), do: {:ok, raw}
  def cast(raw, _metadata) when is_integer(raw), do: {:ok, raw * 1.0}
  def cast(_raw, _metadata), do: :error
end

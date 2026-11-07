defmodule Domovoy.Examples.Cracow.Market do
  @moduledoc """
  An illustrative price model for flats in Kraków, ported from Core's
  `cracow_house_price` notebook. Every coefficient is made up to look plausible;
  nothing is fitted to real listings.

      price = base(area) × layout(rooms, bathrooms, area) × location(district, floor, balcony, year)
  """

  @districts %{
    "Stare Miasto" => 1.35,
    "Kazimierz" => 1.30,
    "Krowodrza" => 1.12,
    "Dębniki" => 1.08,
    "Podgórze" => 1.05,
    "Bronowice" => 1.02,
    "Prądnik Biały" => 0.95,
    "Bieżanów-Prokocim" => 0.88,
    "Nowa Huta" => 0.80
  }

  @doc """
  The districts the model knows, sorted.
  """
  @spec districts() :: [String.t()]
  def districts, do: @districts |> Map.keys() |> Enum.sort()

  @doc """
  The price multiplier of a district.
  """
  @spec district_factor(district :: String.t()) :: float()
  def district_factor(district), do: Map.fetch!(@districts, district)

  @doc """
  PLN per m² as a quadratic in area: small flats cost more per metre.
  """
  @spec base_per_m2(area :: number()) :: float()
  def base_per_m2(area), do: 17_800 - 42 * area + 0.16 * area * area

  @doc """
  Value of the flat before layout and location adjustments.
  """
  @spec base_value(area :: number()) :: float()
  def base_value(area), do: area * base_per_m2(area)

  @doc """
  Rooms and bathrooms add value; too many rooms for the area take it away.
  """
  @spec layout_factor(rooms :: integer(), bathrooms :: integer(), area :: number()) :: float()
  def layout_factor(rooms, bathrooms, area) do
    crowding = max(0.0, rooms - area / 18)
    1 + 0.025 * (rooms - 1) + 0.04 * (bathrooms - 1) - 0.02 * crowding * crowding
  end

  @doc """
  The district multiplier times the floor, balcony and age steps.
  """
  @spec location_factor(
          district :: String.t(),
          floor :: integer(),
          balcony? :: boolean(),
          year_built :: integer()
        ) :: float()
  def location_factor(district, floor, balcony?, year_built) do
    district_factor(district) * floor_factor(floor) * balcony_factor(balcony?) *
      age_factor(year_built)
  end

  @doc """
  The step for a floor.
  """
  @spec floor_factor(floor :: integer()) :: float()
  def floor_factor(0), do: 0.96
  def floor_factor(floor) when floor >= 5, do: 1.03
  def floor_factor(_floor), do: 1.0

  @doc """
  The step for a balcony.
  """
  @spec balcony_factor(balcony? :: boolean()) :: float()
  def balcony_factor(true), do: 1.03
  def balcony_factor(false), do: 1.0

  @doc """
  The step for the year of construction.
  """
  @spec age_factor(year :: integer()) :: float()
  def age_factor(year) when year >= 2015, do: 1.08
  def age_factor(year) when year < 1960, do: 1.02
  def age_factor(year) when year <= 1989, do: 0.94
  def age_factor(_year), do: 1.0
end

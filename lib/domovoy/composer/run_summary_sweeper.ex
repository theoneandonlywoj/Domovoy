defmodule Domovoy.Composer.RunSummarySweeper do
  @moduledoc """
  Refreshes a bounded batch of run summaries every interval, through
  `Domovoy.Composer.Runs.sweep_summaries/1`, so missing, unfinished and outdated ones
  converge without a page opening each run. The first sweeps after a migration are the
  backfill. A failed sweep is logged by its type only.
  """

  use GenServer

  require Logger

  alias Domovoy.Composer.Runs

  @batch 20

  @doc """
  Starts the sweeper, which sweeps every `interval` milliseconds.
  """
  @spec start_link(interval :: pos_integer()) :: GenServer.on_start()
  def start_link(interval), do: GenServer.start_link(__MODULE__, interval, name: __MODULE__)

  @impl true
  def init(interval) do
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:sweep, interval) do
    case Runs.sweep_summaries(@batch) do
      {:ok, _visited} -> :ok
      {:error, type} -> Logger.warning("Run summary sweep failed: #{inspect(type)}")
    end

    schedule(interval)
    {:noreply, interval}
  end

  @spec schedule(interval :: pos_integer()) :: reference()
  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end

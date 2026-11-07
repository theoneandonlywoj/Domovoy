defmodule Domovoy.RunTestRepo do
  @moduledoc """
  A repo for tests that need Core's Postgres adapters to commit, since `Domovoy.Repo`
  is sandboxed in test. It logs at debug, so a test can see whether Core's own
  `log: false` held. It isn't in `ecto_repos`.
  """

  use Ecto.Repo, otp_app: :domovoy, adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, config) do
    shared = :domovoy |> Application.fetch_env!(Domovoy.Repo) |> Keyword.drop([:pool, :pool_size])
    {:ok, shared |> Keyword.merge(config) |> Keyword.merge(pool_size: 5)}
  end
end

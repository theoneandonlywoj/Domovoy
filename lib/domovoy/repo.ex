defmodule Domovoy.Repo do
  use Ecto.Repo,
    otp_app: :domovoy,
    adapter: Ecto.Adapters.Postgres
end

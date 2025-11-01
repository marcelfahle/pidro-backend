defmodule PidroServer.Repo do
  use Ecto.Repo,
    otp_app: :pidro_server,
    adapter: Ecto.Adapters.Postgres
end

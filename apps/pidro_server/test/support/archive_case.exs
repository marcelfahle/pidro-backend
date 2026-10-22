defmodule PidroServer.ArchiveCase do
  @moduledoc """
  Exclusive archive integration tests in a disposable PostgreSQL database.

  Unlike DataCase, no shared transaction owner can be destroyed by cancellation.
  The normal pool and all migrations are real; the original database is untouched.
  Callers must use async: false; ExUnit finishes async cases before these run.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Games.{GameSupervisor, RoomManager}
  alias PidroServer.Repo

  using do
    quote do
      import Ecto.Query
      alias PidroServer.Repo
    end
  end

  setup %{async: false} do
    RoomManager.reset_for_test()
    stop_games()
    original = Application.fetch_env!(:pidro_server, Repo)
    previous = Application.get_env(:pidro_server, :game_archive_enabled)
    database = "pidro_archive_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Sandbox.mode(Repo, :auto)
    Repo.query!(~s(CREATE DATABASE "#{database}"))

    on_exit(fn ->
      RoomManager.reset_for_test()
      stop_games()
      Application.put_env(:pidro_server, :game_archive_enabled, previous)
      restart_repo(original)
      Sandbox.mode(Repo, :auto)
      Repo.query!(~s|DROP DATABASE "#{database}" WITH (FORCE)|)
      Sandbox.mode(Repo, :manual)
    end)

    restart_repo(
      Keyword.merge(original, database: database, pool: DBConnection.ConnectionPool, pool_size: 5)
    )

    Ecto.Migrator.run(Repo, :up, all: true, log: false)
    Application.put_env(:pidro_server, :game_archive_enabled, true)
    :ok
  end

  defp restart_repo(config) do
    :ok = Supervisor.terminate_child(PidroServer.Supervisor, Repo)
    Application.put_env(:pidro_server, Repo, config)
    {:ok, _} = Supervisor.restart_child(PidroServer.Supervisor, Repo)
  end

  defp stop_games do
    for pid <- GameSupervisor.list_games(),
        do: DynamicSupervisor.terminate_child(GameSupervisor, pid)
  end
end

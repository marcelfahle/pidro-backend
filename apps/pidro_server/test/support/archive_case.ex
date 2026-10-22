defmodule PidroServer.ArchiveCase do
  @moduledoc """
  Exclusive archive integration tests on independent PostgreSQL connections.

  Unlike DataCase, no shared transaction owner can be destroyed by cancellation.
  Restore only rows created by the test, preserving pre-existing database data.
  Callers must use async: false; ExUnit finishes async cases before these run.
  """
  use ExUnit.CaseTemplate

  import Ecto.Query
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
    Sandbox.mode(Repo, :auto)
    previous = Application.get_env(:pidro_server, :game_archive_enabled)

    baseline =
      for {schema, key} <- [
            {PidroServer.GameArchive.Archive, :game_instance_id},
            {PidroServer.Stats.GameStats, :id},
            {PidroServer.Accounts.User, :id}
          ] do
        {schema, key, Repo.all(from row in schema, select: field(row, ^key))}
      end

    Application.put_env(:pidro_server, :game_archive_enabled, true)

    on_exit(fn ->
      RoomManager.reset_for_test()

      for pid <- GameSupervisor.list_games(),
          do: DynamicSupervisor.terminate_child(GameSupervisor, pid)

      Repo.query!("DROP TRIGGER IF EXISTS archive_slow_write ON game_archive_events")
      Repo.query!("DROP FUNCTION IF EXISTS archive_test_slow_write()")
      Repo.query!("ALTER TABLE game_archive_events DROP CONSTRAINT IF EXISTS archive_test_outage")
      Repo.query!("ALTER TABLE game_archives DROP CONSTRAINT IF EXISTS participation_outage")

      for {schema, key, ids} <- baseline do
        Repo.delete_all(from row in schema, where: field(row, ^key) not in ^ids)
      end

      Application.put_env(:pidro_server, :game_archive_enabled, previous)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end
end

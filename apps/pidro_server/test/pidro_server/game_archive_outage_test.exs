defmodule PidroServer.GameArchiveOutageTest do
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.GameArchive
  alias PidroServer.Games.{GameAdapter, GameSupervisor}

  test "blocked SQL and an unavailable shared task supervisor cannot stall gameplay" do
    {:ok, pid} = GameSupervisor.start_game("SLOW")
    id = Pidro.Server.get_snapshot(pid).game_instance_id
    assert GameArchive.get(id).last_revision == 0

    Repo.query!("""
    CREATE FUNCTION archive_test_slow_write() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM game_archives WHERE game_instance_id = NEW.game_instance_id AND room_code = 'SLOW') THEN
        PERFORM pg_sleep(5);
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER archive_slow_write BEFORE INSERT ON game_archive_events FOR EACH ROW EXECUTE FUNCTION archive_test_slow_write()"
    )

    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:SLOW")
    :sys.suspend(PidroServer.TaskSupervisor)

    try do
      {elapsed_us, result} =
        :timer.tc(fn -> GameAdapter.apply_action("SLOW", :north, :select_dealer) end)

      assert {:ok, _} = result
      assert elapsed_us < 1_000_000
      assert_receive {:state_update, "SLOW", %{state_revision: 1}}, 1_000
      assert_receive {:state_update, "SLOW", %{state_revision: 2}}, 1_000
      assert Process.alive?(pid)
      assert {:ok, %{status: :degraded}} = GameArchive.health("SLOW")
    after
      :sys.resume(PidroServer.TaskSupervisor)
    end

    Repo.query!("DROP TRIGGER archive_slow_write ON game_archive_events")
    :ok = Pidro.Server.set_pace(pid, :own)
    assert GameArchive.get(id).evidence_status == "partial"
    assert {:ok, %{status: :healthy}} = GameArchive.health("SLOW")
    assert :ok = GameSupervisor.stop_game("SLOW")
    assert GameArchive.get(id).status == "closed"
  end
end

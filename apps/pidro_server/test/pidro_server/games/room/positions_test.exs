defmodule PidroServer.Games.Room.PositionsTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.RoomManager.Room

  defp room_with_positions(positions) do
    %Room{
      code: "TEST",
      host_id: "host1",
      positions: positions,
      status: :waiting,
      max_players: 4,
      created_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      metadata: %{}
    }
  end

  describe "available/1" do
    test "returns all positions when empty" do
      room = room_with_positions(Positions.empty())
      assert Positions.available(room) == [:north, :east, :south, :west]
    end

    test "excludes occupied positions" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert Positions.available(room) == [:east, :west]
    end

    test "returns empty list when all positions occupied" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})
      assert Positions.available(room) == []
    end
  end

  describe "team_available/2" do
    test "returns available positions for north_south team" do
      room = room_with_positions(%{north: nil, east: "p1", south: nil, west: "p2"})
      assert Positions.team_available(room, :north_south) == [:north, :south]
    end

    test "returns available positions for east_west team" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert Positions.team_available(room, :east_west) == [:east, :west]
    end

    test "returns empty list when team is full" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert Positions.team_available(room, :north_south) == []
    end
  end

  describe "assign/3" do
    test "assigns explicit position" do
      room = room_with_positions(Positions.empty())
      assert {:ok, updated_room, :north} = Positions.assign(room, "player1", :north)
      assert updated_room.positions[:north] == "player1"
      assert updated_room.positions[:east] == nil
    end

    test "returns :seat_taken for occupied position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:error, :seat_taken} = Positions.assign(room, "player2", :north)
    end

    test "assigns team position to first available in team" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:ok, updated_room, :south} = Positions.assign(room, "player2", :north_south)
      assert updated_room.positions[:south] == "player2"
    end

    test "returns :team_full when team occupied" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})
      assert {:error, :team_full} = Positions.assign(room, "player3", :north_south)
    end

    test "auto-assigns first available" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:ok, updated_room, :east} = Positions.assign(room, "player2", :auto)
      assert updated_room.positions[:east] == "player2"
    end

    test "auto-assigns with nil position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:ok, updated_room, :east} = Positions.assign(room, "player2", nil)
      assert updated_room.positions[:east] == "player2"
    end

    test "returns :room_full when no positions available" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})
      assert {:error, :room_full} = Positions.assign(room, "player5", :auto)
    end

    test "returns :already_seated when player already in room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert {:error, :already_seated} = Positions.assign(room, "p1", :east)
    end

    test "returns :invalid_position for invalid position parameter" do
      room = room_with_positions(Positions.empty())
      assert {:error, :invalid_position} = Positions.assign(room, "player1", :invalid)
    end
  end

  describe "assign_with_fallback/3" do
    test "honours a free hinted seat" do
      room = room_with_positions(Positions.empty())

      assert {:ok, updated, :south, true} = Positions.assign_with_fallback(room, "p1", :south)
      assert updated.positions[:south] == "p1"
    end

    test "honours a free hinted team" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:ok, updated, :south, true} =
               Positions.assign_with_fallback(room, "p2", :north_south)

      assert updated.positions[:south] == "p2"
    end

    test "falls back to the first open seat when the hinted seat is taken" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:ok, updated, :east, false} = Positions.assign_with_fallback(room, "p2", :north)
      assert updated.positions[:east] == "p2"
      assert updated.positions[:north] == "p1"
    end

    test "falls back when the hinted team is full" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p2", west: nil})

      assert {:ok, updated, :east, false} =
               Positions.assign_with_fallback(room, "p3", :north_south)

      assert updated.positions[:east] == "p3"
    end

    test "reports the hint as honoured when it is absent" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:ok, _updated, :east, true} = Positions.assign_with_fallback(room, "p2", nil)
      assert {:ok, _updated, :east, true} = Positions.assign_with_fallback(room, "p2", :auto)
    end

    test "returns :room_full when no seat is open" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})

      assert {:error, :room_full} = Positions.assign_with_fallback(room, "p5", :north)
    end

    test "returns :already_seated for a player already in the room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:error, :already_seated} = Positions.assign_with_fallback(room, "p1", :east)
    end

    test "rejects an unresolved :partner hint as :invalid_position" do
      room = room_with_positions(Positions.empty())

      assert {:error, :invalid_position} = Positions.assign_with_fallback(room, "p1", :partner)
    end
  end

  describe "move/3" do
    test "moves a seated player to a vacant position and returns the origin" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})

      assert {:ok, updated, :north} = Positions.move(room, "p1", :west)
      assert updated.positions == %{north: nil, east: "p2", south: nil, west: "p1"}
    end

    test "returns :seat_taken when the target position is occupied" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})

      assert {:error, :seat_taken} = Positions.move(room, "p1", :east)
    end

    test "returns :seat_taken when the target is the player's own position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:error, :seat_taken} = Positions.move(room, "p1", :north)
    end

    test "returns :player_not_in_room for an unseated player" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:error, :player_not_in_room} = Positions.move(room, "p9", :east)
    end

    test "returns :invalid_position for an unknown position" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})

      assert {:error, :invalid_position} = Positions.move(room, "p1", :middle)
    end
  end

  describe "player_ids/1" do
    test "derives player list in canonical order (N, E, S, W)" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})
      assert Positions.player_ids(room) == ["p1", "p2", "p3", "p4"]
    end

    test "excludes nil positions" do
      room = room_with_positions(%{north: "p1", east: nil, south: "p3", west: nil})
      assert Positions.player_ids(room) == ["p1", "p3"]
    end

    test "returns empty list for empty room" do
      room = room_with_positions(Positions.empty())
      assert Positions.player_ids(room) == []
    end
  end

  describe "count/1" do
    test "counts occupied positions" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})
      assert Positions.count(room) == 2
    end

    test "returns 0 for empty room" do
      room = room_with_positions(Positions.empty())
      assert Positions.count(room) == 0
    end

    test "returns max count for full room" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: "p4"})
      assert Positions.count(room) == 4
    end
  end

  describe "has_player?/2" do
    test "returns true when player is in room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert Positions.has_player?(room, "p1") == true
    end

    test "returns false when player is not in room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert Positions.has_player?(room, "p2") == false
    end

    test "returns false for empty room" do
      room = room_with_positions(Positions.empty())
      assert Positions.has_player?(room, "p1") == false
    end
  end

  describe "get_position/2" do
    test "returns position of player" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})
      assert Positions.get_position(room, "p1") == :north
      assert Positions.get_position(room, "p2") == :east
    end

    test "returns nil when player not in room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      assert Positions.get_position(room, "p2") == nil
    end
  end

  describe "remove/2" do
    test "clears player position" do
      room = room_with_positions(%{north: "p1", east: "p2", south: nil, west: nil})
      updated_room = Positions.remove(room, "p1")
      assert updated_room.positions[:north] == nil
      assert updated_room.positions[:east] == "p2"
    end

    test "handles removing player not in room" do
      room = room_with_positions(%{north: "p1", east: nil, south: nil, west: nil})
      updated_room = Positions.remove(room, "p2")
      assert updated_room.positions == room.positions
    end

    test "removes all instances of player" do
      room = room_with_positions(%{north: "p1", east: "p2", south: "p3", west: nil})
      updated_room = Positions.remove(room, "p2")
      assert updated_room.positions[:east] == nil
      assert Positions.has_player?(updated_room, "p2") == false
    end
  end

  describe "empty/0" do
    test "returns map with all positions set to nil" do
      assert Positions.empty() == %{north: nil, east: nil, south: nil, west: nil}
    end
  end

  describe "integration scenarios" do
    test "multiple players join in sequence" do
      room = room_with_positions(Positions.empty())

      {:ok, room, :north} = Positions.assign(room, "p1", :auto)
      {:ok, room, :east} = Positions.assign(room, "p2", :auto)
      {:ok, room, :south} = Positions.assign(room, "p3", :auto)
      {:ok, room, :west} = Positions.assign(room, "p4", :auto)

      assert Positions.count(room) == 4
      assert Positions.player_ids(room) == ["p1", "p2", "p3", "p4"]
    end

    test "team selection works correctly" do
      room = room_with_positions(Positions.empty())

      {:ok, room, :north} = Positions.assign(room, "p1", :north_south)
      {:ok, room, :east} = Positions.assign(room, "p2", :east_west)
      {:ok, room, :south} = Positions.assign(room, "p3", :north_south)
      {:ok, room, :west} = Positions.assign(room, "p4", :east_west)

      assert room.positions[:north] == "p1"
      assert room.positions[:south] == "p3"
      assert room.positions[:east] == "p2"
      assert room.positions[:west] == "p4"
    end

    test "mixed assignment strategies" do
      room = room_with_positions(Positions.empty())

      {:ok, room, :west} = Positions.assign(room, "p1", :west)
      {:ok, room, :north} = Positions.assign(room, "p2", :north_south)
      {:ok, room, :east} = Positions.assign(room, "p3", :auto)
      {:ok, room, :south} = Positions.assign(room, "p4", :south)

      assert Positions.count(room) == 4
      assert Positions.available(room) == []
    end
  end
end

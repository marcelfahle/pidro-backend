defmodule PidroServer.Games.RematchTest do
  @moduledoc """
  A rematch is a new game in the same room: same code, same seats, agreed
  through the ready check once the previous game is over.
  """

  use PidroServerWeb.ChannelCase, async: false

  import Ecto.Query

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Profiles
  alias PidroServer.Repo
  alias PidroServer.RoomFixtures
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.GameChannel

  @scores %{north_south: 62, east_west: 40}

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  defp four_player_game do
    users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Rematch #{&1}"}))
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Thursday four"})
    for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    playing = RoomFixtures.ready_room(room.code)
    assert playing.status == :playing
    {playing, Enum.map(users, & &1.id)}
  end

  defp finish_game(room_code) do
    send(RoomManager, {:game_over, room_code, :north_south, @scores})
    {:ok, finished} = RoomManager.get_room(room_code)
    assert finished.status == :finished
    finished
  end

  defp ask_for_rematch(room, user_ids) do
    {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)

    Enum.map(user_ids, fn user_id ->
      {:ok, snapshot} = RoomManager.confirm_rematch(room.code, room.id, user_id, self(), epoch)
      snapshot
    end)
  end

  defp game_pid(room_code) do
    {:ok, pid} = GameSupervisor.get_game(room_code)
    pid
  end

  describe "the same four, again" do
    test "game over turns the ready check into a rematch vote" do
      {room, user_ids} = four_player_game()
      {:ok, before} = RoomManager.readiness(room.code)

      finish_game(room.code)

      {:ok, vote} = RoomManager.readiness(room.code)
      assert vote.status == :finished
      assert vote.ready_players == []
      assert vote.ready_epoch == before.ready_epoch + 1

      assert {:error, :stale_readiness, _} =
               RoomManager.confirm_rematch(
                 room.code,
                 room.id,
                 hd(user_ids),
                 self(),
                 before.ready_epoch
               )
    end

    test "the last agreement starts a new game in the same room with the same seats" do
      {room, user_ids} = four_player_game()
      first_game = game_pid(room.code)
      finish_game(room.code)

      {early, [last]} = Enum.split(user_ids, 3)
      ask_for_rematch(room, early)

      {:ok, waiting} = RoomManager.get_room(room.code)
      assert waiting.status == :finished
      assert Process.alive?(first_game)

      [started] = ask_for_rematch(room, [last])
      assert started.status == :playing

      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.code == room.code
      assert rematch.id == room.id
      assert rematch.positions == room.positions
      assert rematch.host_id == room.host_id
      assert rematch.game_number == 2

      for {position, seat} <- room.seats do
        assert rematch.seats[position].user_id == seat.user_id
        assert rematch.seats[position].status == :connected
      end

      second_game = game_pid(room.code)
      refute second_game == first_game
      refute Process.alive?(first_game)

      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.phase == :dealer_selection
      assert state.cumulative_scores == %{north_south: 0, east_west: 0}
      assert state.winner == nil
    end

    test "nobody is moved out of the room, so a second rematch works the same way" do
      {room, user_ids} = four_player_game()

      finish_game(room.code)
      ask_for_rematch(room, user_ids)
      finish_game(room.code)
      ask_for_rematch(room, user_ids)

      {:ok, third} = RoomManager.get_room(room.code)
      assert third.status == :playing
      assert third.game_number == 3
    end

    test "each game in the room saves its own stats and progression" do
      {room, user_ids} = four_player_game()

      finish_game(room.code)
      ask_for_rematch(room, user_ids)
      finish_game(room.code)

      rows = Repo.all(from gs in GameStats, where: gs.room_code == ^room.code)
      assert length(rows) == 2

      instance_ids = Enum.map(rows, & &1.game_instance_id)
      assert Enum.all?(instance_ids, &is_binary/1)
      assert length(Enum.uniq(instance_ids)) == 2

      for user_id <- user_ids do
        assert {:ok, %{games_played: 2}} = Profiles.get_or_create_profile(user_id)
      end
    end

    test "a repeated game over for the same game saves nothing new" do
      {room, _user_ids} = four_player_game()

      finish_game(room.code)
      finish_game(room.code)

      assert Repo.aggregate(from(gs in GameStats, where: gs.room_code == ^room.code), :count) == 1
    end
  end

  describe "who can ask, and when" do
    test "a rematch needs a finished game, and ready still needs a waiting room" do
      {room, [user_id | _]} = four_player_game()
      {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)

      assert {:ok, _already_ready} =
               RoomManager.confirm_rematch(room.code, room.id, user_id, self(), epoch)

      {:ok, still_playing} = RoomManager.get_room(room.code)
      assert still_playing.status == :playing
      assert still_playing.game_number == 1

      finish_game(room.code)
      {:ok, %{ready_epoch: vote_epoch}} = RoomManager.readiness(room.code)

      assert {:error, :room_not_waiting, _} =
               RoomManager.confirm_ready(room.code, room.id, user_id, self(), vote_epoch)
    end

    test "three of four is not a rematch" do
      {room, user_ids} = four_player_game()
      finish_game(room.code)

      snapshots = ask_for_rematch(room, Enum.take(user_ids, 3))

      assert List.last(snapshots).status == :finished
      assert length(List.last(snapshots).ready_players) == 3
      assert {:ok, %{status: :finished, game_number: 1}} = RoomManager.get_room(room.code)
    end
  end

  describe "solo with bots" do
    test "the bots stay seated after game over and the rematch starts on the human's word" do
      user = AccountsFixtures.user_fixture(%{display_name: "Solo"})
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Solo", bot_difficulty: :smart})

      for position <- [:east, :south, :west] do
        {:ok, _pid} = BotManager.start_bot(room.code, position, :smart, 5_000)
      end

      playing = RoomFixtures.ready_room(room.code)
      assert playing.status == :playing

      bots = for {pos, %{occupant_type: :bot, bot_pid: pid}} <- playing.seats, do: {pos, pid}
      assert length(bots) == 3

      finished = finish_game(room.code)

      for {position, pid} <- bots do
        assert Process.alive?(pid)
        assert finished.seats[position].bot_pid == pid
      end

      {:ok, vote} = RoomManager.readiness(room.code)
      assert vote.ready_players == [:east, :south, :west]

      [started] = ask_for_rematch(room, [user.id])
      assert started.status == :playing

      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.config.bot_difficulty == :smart
      for {position, pid} <- bots, do: assert(rematch.seats[position].bot_pid == pid)

      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.phase == :dealer_selection
    end

    test "a bot restarted by its supervisor gets its seat back" do
      user = AccountsFixtures.user_fixture(%{display_name: "Solo"})
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Solo"})
      {:ok, pid} = BotManager.start_bot(room.code, :east, :basic, 5_000)
      {:ok, seated} = RoomManager.get_room(room.code)
      assert seated.seats.east.bot_pid == pid
      {:ok, before} = RoomManager.readiness(room.code)

      bot_id = seated.positions.east
      replacement = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, _room, :east} = RoomManager.join_bot(room.code, bot_id, replacement, :east)

      {:ok, reattached} = RoomManager.get_room(room.code)
      assert reattached.seats.east.bot_pid == replacement
      assert {:ok, ^before} = RoomManager.readiness(room.code)
    end
  end

  describe "nobody agrees" do
    test "the finished room closes on its timer" do
      {room, _user_ids} = four_player_game()
      finish_game(room.code)

      Process.sleep(Lifecycle.config(:finished_room_ttl_ms) + 200)
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "a rematch outlives the close timer of the game before it" do
      {room, user_ids} = four_player_game()
      finish_game(room.code)
      ask_for_rematch(room, user_ids)

      Process.sleep(Lifecycle.config(:finished_room_ttl_ms) + 200)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
    end
  end

  describe "the channel event" do
    setup do
      users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Channel #{&1}"}))
      [host | others] = users
      {:ok, room} = RoomManager.create_room(host.id, %{})
      for user <- others, do: RoomManager.join_room(room.code, user.id)

      sockets =
        Enum.map(users, fn user ->
          {:ok, socket} = create_socket(user)
          {:ok, reply, joined} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
          {joined, reply}
        end)

      [{_socket, %{readiness: initial}} | _] = sockets
      params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}

      for {socket, _reply} <- sockets do
        ref = push(socket, "ready", params)
        assert_reply ref, :ok, _
      end

      %{room: room, sockets: Enum.map(sockets, &elem(&1, 0))}
    end

    test "rematch takes the ready payload and the last one starts the game", %{
      room: room,
      sockets: [first | rest] = sockets
    } do
      {:ok, %{game_instance_id: first_instance}} = GameAdapter.get_snapshot(room.code)
      finish_game(room.code)
      assert_push "readiness_updated", %{status: :finished, ready_players: [], ready_epoch: epoch}

      ref = push(first, "rematch", %{})
      assert_reply ref, :error, %{reason: "invalid_readiness"}

      ref = push(first, "rematch", %{"room_id" => room.id, "ready_epoch" => epoch - 1})
      assert_reply ref, :error, %{reason: "stale_readiness"}

      params = %{"room_id" => room.id, "ready_epoch" => epoch}
      ref = push(first, "rematch", params)
      assert_reply ref, :ok, %{readiness: %{status: :finished, ready_players: [:north]}}

      for socket <- rest do
        ref = push(socket, "rematch", params)
        assert_reply ref, :ok, _
      end

      assert_push "readiness_updated", %{status: :playing}
      assert {:ok, %{status: :playing, game_number: 2}} = RoomManager.get_room(room.code)

      # Every socket accepted snapshots from the first game's instance. The
      # rematch is a new instance and its state must still reach them.
      {:ok, %{game_instance_id: second_instance}} = GameAdapter.get_snapshot(room.code)
      refute second_instance == first_instance

      for _socket <- sockets do
        assert_push "game_state", %{game_instance_id: ^second_instance, state: state}
        assert state.phase in [:dealer_selection, "dealer_selection"]
      end

      assert length(sockets) == 4
    end
  end
end

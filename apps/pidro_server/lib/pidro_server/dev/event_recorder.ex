if Mix.env() == :dev do
  defmodule PidroServer.Dev.EventRecorder do
    @moduledoc """
    Records game events for the development UI event log.

    EventRecorder subscribes to game state updates and derives discrete events
    by comparing consecutive game states. Events are stored in ETS with automatic
    cleanup when games end.

    ## Architecture

    - One EventRecorder process per game (started on-demand)
    - Subscribes to `game:<room_code>` PubSub topic
    - Stores up to 500 events per game in ETS
    - Auto-cleanup on game end or process termination

    ## Usage

        # Start recording events for a game
        {:ok, pid} = EventRecorder.start_link(room_code: "abc123")

        # Get recent events
        events = EventRecorder.get_events("abc123", limit: 50)

        # Get filtered events
        events = EventRecorder.get_events("abc123", type: :bid_made)

        # Stop recording
        EventRecorder.stop("abc123")
    """

    use GenServer
    require Logger

    alias PidroServer.Dev.Event

    @max_events_per_game 500
    @table_name :dev_game_events

    # Client API

    @doc """
    Starts the EventRecorder for a specific game.

    ## Options

    - `:room_code` - Required. The game room code to monitor.
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      room_code = Keyword.fetch!(opts, :room_code)
      GenServer.start_link(__MODULE__, room_code, name: via_tuple(room_code))
    end

    @doc """
    Stops the EventRecorder for a game and cleans up its events.
    """
    @spec stop(String.t()) :: :ok
    def stop(room_code) do
      case Registry.lookup(PidroServer.Dev.EventRecorderRegistry, room_code) do
        [{pid, _}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end

    @doc """
    Gets events for a game with optional filtering.

    ## Options

    - `:limit` - Maximum number of events to return (default: 100, max: 500)
    - `:type` - Filter by event type (e.g., `:bid_made`, `:card_played`)
    - `:player` - Filter by player position (e.g., `:north`, `:south`)
    - `:offset` - Skip N events from the start (default: 0)

    Events are returned in reverse chronological order (newest first).
    """
    @spec get_events(String.t(), keyword()) :: [Event.t()]
    def get_events(room_code, opts \\ []) do
      limit = min(Keyword.get(opts, :limit, 100), @max_events_per_game)
      offset = Keyword.get(opts, :offset, 0)
      type_filter = Keyword.get(opts, :type)
      player_filter = Keyword.get(opts, :player)

      # Check if table exists first
      case :ets.whereis(@table_name) do
        :undefined ->
          []

        _table ->
          case :ets.lookup(@table_name, room_code) do
            [{^room_code, events}] ->
              events
              |> filter_by_type(type_filter)
              |> filter_by_player(player_filter)
              |> Enum.drop(offset)
              |> Enum.take(limit)

            [] ->
              []
          end
      end
    end

    @doc """
    Returns the total count of events for a game.
    """
    @spec count_events(String.t()) :: non_neg_integer()
    def count_events(room_code) do
      case :ets.whereis(@table_name) do
        :undefined ->
          0

        _table ->
          case :ets.lookup(@table_name, room_code) do
            [{^room_code, events}] -> length(events)
            [] -> 0
          end
      end
    end

    @doc """
    Clears all events for a game.
    """
    @spec clear_events(String.t()) :: :ok
    def clear_events(room_code) do
      case :ets.whereis(@table_name) do
        :undefined ->
          :ok

        _table ->
          :ets.delete(@table_name, room_code)
          :ok
      end
    end

    # Server Callbacks

    @impl true
    def init(room_code) do
      # Ensure ETS table exists
      case :ets.whereis(@table_name) do
        :undefined ->
          :ets.new(@table_name, [:named_table, :public, :set, write_concurrency: true])

        _ ->
          :ok
      end

      # Initialize empty event list for this game
      :ets.insert(@table_name, {room_code, []})

      # Subscribe to game updates
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      Logger.debug("EventRecorder started for game #{room_code}")

      {:ok, %{room_code: room_code, previous_state: nil}}
    end

    @impl true
    def handle_info({:state_update, new_state}, %{previous_state: prev_state} = state) do
      # Derive events from state diff
      events = derive_events(prev_state, new_state)

      # Store events
      Enum.each(events, fn event ->
        add_event(state.room_code, event)
      end)

      {:noreply, %{state | previous_state: new_state}}
    end

    @impl true
    def handle_info({:game_over, winner, scores}, state) do
      # Create game over event
      event =
        Event.new(:game_over, nil, %{
          winner: winner,
          final_scores: scores
        })

      add_event(state.room_code, event)

      {:noreply, state}
    end

    @impl true
    def handle_info({:bot_reasoning, event}, state) do
      # Bot reasoning event received directly from BotPlayer
      add_event(state.room_code, event)

      {:noreply, state}
    end

    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, %{room_code: room_code}) do
      Logger.debug("EventRecorder stopping for game #{room_code}")
      :ok
    end

    # Private Functions

    defp via_tuple(room_code) do
      {:via, Registry, {PidroServer.Dev.EventRecorderRegistry, room_code}}
    end

    defp add_event(room_code, event) do
      case :ets.lookup(@table_name, room_code) do
        [{^room_code, events}] ->
          # Add new event to front (newest first)
          updated_events = [event | events] |> Enum.take(@max_events_per_game)
          :ets.insert(@table_name, {room_code, updated_events})

        [] ->
          :ets.insert(@table_name, {room_code, [event]})
      end
    end

    defp derive_events(nil, new_state) do
      # First state update - only log initial phase if not dealer_selection
      case new_state.phase do
        :dealer_selection -> []
        phase -> [Event.new(phase, nil, %{hand_number: new_state.hand_number})]
      end
    end

    defp derive_events(prev_state, new_state) do
      []
      |> check_dealer_change(prev_state, new_state)
      |> check_phase_change(prev_state, new_state)
      |> check_bids(prev_state, new_state)
      |> check_trump(prev_state, new_state)
      |> check_trick(prev_state, new_state)
      |> check_scores(prev_state, new_state)
    end

    defp check_dealer_change(events, prev_state, new_state) do
      if prev_state.current_dealer != new_state.current_dealer &&
           new_state.current_dealer != nil do
        event = Event.new(:dealer_selected, new_state.current_dealer, %{})
        [event | events]
      else
        events
      end
    end

    defp check_phase_change(events, prev_state, new_state) do
      if prev_state.phase != new_state.phase do
        case new_state.phase do
          :dealing ->
            event = Event.new(:cards_dealt, nil, %{hand_number: new_state.hand_number})
            [event | events]

          _ ->
            events
        end
      else
        events
      end
    end

    defp check_bids(events, prev_state, new_state) do
      prev_bids = prev_state.bids || []
      new_bids = new_state.bids || []

      if length(new_bids) > length(prev_bids) do
        # New bid was made
        new_bid = List.first(new_bids)

        event =
          if new_bid.amount == :pass do
            Event.new(:bid_passed, new_bid.player, %{})
          else
            Event.new(:bid_made, new_bid.player, %{bid_amount: new_bid.amount})
          end

        [event | events]
      else
        events
      end
    end

    defp check_trump(events, prev_state, new_state) do
      if prev_state.trump_suit != new_state.trump_suit && new_state.trump_suit != nil do
        # Trump was declared - find who declared it (the highest bidder)
        declarer = if new_state.highest_bid, do: new_state.highest_bid.player, else: nil

        event = Event.new(:trump_declared, declarer, %{suit: new_state.trump_suit})
        [event | events]
      else
        events
      end
    end

    defp check_trick(events, prev_state, new_state) do
      prev_trick = prev_state.current_trick || []
      new_trick = new_state.current_trick || []

      events =
        if length(new_trick) > length(prev_trick) do
          # Card was played
          new_card = List.first(new_trick)

          # Determine which player played it based on turn order
          player = determine_player_from_trick(new_state, new_trick)

          event = Event.new(:card_played, player, %{card: new_card})
          [event | events]
        else
          events
        end

      # Check if trick was won (trick count increased)
      prev_tricks = prev_state.tricks || []
      new_tricks = new_state.tricks || []

      if length(new_tricks) > length(prev_tricks) do
        # A trick was just won
        latest_trick = List.first(new_tricks)

        event =
          Event.new(:trick_won, latest_trick.winner, %{
            points: latest_trick.points,
            trick_number: new_state.trick_number
          })

        [event | events]
      else
        events
      end
    end

    defp check_scores(events, prev_state, new_state) do
      new_hand_points = new_state.hand_points || %{north_south: 0, east_west: 0}

      # Check if hand was scored (phase changed to scoring or new hand started)
      if prev_state.phase == :playing && new_state.phase != :playing &&
           (new_hand_points.north_south > 0 || new_hand_points.east_west > 0) do
        winning_team =
          if new_hand_points.north_south > new_hand_points.east_west do
            :north_south
          else
            :east_west
          end

        event =
          Event.new(:hand_scored, nil, %{
            ns_points: new_hand_points.north_south,
            ew_points: new_hand_points.east_west,
            winning_team: winning_team,
            hand_number: new_state.hand_number
          })

        [event | events]
      else
        events
      end
    end

    defp determine_player_from_trick(state, _trick) do
      # The number of cards in the trick tells us which player played
      # For now, use current_turn as an approximation
      # TODO: Improve by tracking trick leader and turn rotation
      state.current_turn
    end

    defp filter_by_type(events, nil), do: events
    defp filter_by_type(events, type), do: Enum.filter(events, &(&1.type == type))

    defp filter_by_player(events, nil), do: events
    defp filter_by_player(events, player), do: Enum.filter(events, &(&1.player == player))
  end
end

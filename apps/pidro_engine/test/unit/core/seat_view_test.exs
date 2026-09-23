defmodule Pidro.Core.SeatViewTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.{GameState, SeatView}
  alias Pidro.Core.Types.Bid
  alias Pidro.Game.{Engine, Play}
  alias Pidro.Test.GameTrace

  # North holds seven trumps, so entering play kills the King (the first
  # non-point trump in hand order). East, South and West go cold one by one.
  defp kill_state do
    hands = %{
      north: [
        {14, :hearts},
        {13, :hearts},
        {12, :hearts},
        {11, :hearts},
        {10, :hearts},
        {9, :hearts},
        {8, :hearts}
      ],
      east: [{7, :hearts}, {6, :hearts}, {4, :hearts}, {14, :clubs}, {13, :clubs}, {12, :clubs}],
      south: [{5, :hearts}, {3, :hearts}, {11, :clubs}, {10, :clubs}, {9, :clubs}, {8, :clubs}],
      west: [{5, :diamonds}, {2, :hearts}, {7, :clubs}, {6, :clubs}, {4, :clubs}, {3, :clubs}]
    }

    base = GameState.new()

    %{
      base
      | phase: :playing,
        current_dealer: :west,
        current_turn: :north,
        trump_suit: :hearts,
        highest_bid: {:north, 6},
        bidding_team: :north_south,
        bids: [%Bid{position: :north, amount: 6}],
        players:
          Map.new(base.players, fn {pos, player} -> {pos, %{player | hand: hands[pos]}} end),
        events: [{:cards_dealt, %{}}]
    }
    |> Play.compute_kills()
  end

  defp play_all(state, plays) do
    Enum.reduce(plays, state, fn {pos, card}, acc ->
      {:ok, next} = Engine.apply_action(acc, pos, {:play_card, card})
      next
    end)
  end

  defp mid_hand_state do
    GameTrace.states(7)
    |> Enum.find(&(&1.phase == :playing and &1.tricks != [] and &1.current_trick != nil))
  end

  describe "for_seat/2" do
    test "keeps the viewer's hand and shows other hands empty with their counts" do
      state = mid_hand_state()
      view = SeatView.for_seat(state, :north)

      assert view.position == :north
      assert view.state.players.north.hand == state.players.north.hand

      for pos <- [:east, :south, :west] do
        assert view.state.players[pos].hand == []
        assert view.hand_counts[pos] == length(state.players[pos].hand)
      end

      assert view.hand_counts.north == length(state.players.north.hand)
    end

    test "hides the deck, discards, events and dealer pool size during play" do
      for state <- GameTrace.states(11),
          state.phase == :playing,
          pos <- [:north, :east, :south, :west] do
        view = SeatView.for_seat(state, pos)

        assert view.state.deck == []
        assert view.state.discarded_cards == []
        assert view.state.events == []
        assert view.state.dealer_pool_size == nil
        assert view.state.cache == %{}
      end
    end

    test "keeps public fields unchanged" do
      state = %{
        mid_hand_state()
        | cards_requested: %{east: 3, south: 5, west: 2},
          cumulative_scores: %{north_south: 21, east_west: -7}
      }

      state = put_in(state.players.west.revealed_cards, [{9, :spades}])
      view = SeatView.for_seat(state, :south)

      for field <- [
            :phase,
            :bids,
            :highest_bid,
            :bidding_team,
            :trump_suit,
            :tricks,
            :current_trick,
            :trick_number,
            :cards_requested,
            :hand_points,
            :cumulative_scores,
            :current_dealer,
            :current_turn,
            :hand_number,
            :config
          ] do
        assert Map.fetch!(view.state, field) == Map.fetch!(state, field), "#{field} changed"
      end

      assert view.state.players.west.revealed_cards == [{9, :spades}]

      for {pos, player} <- state.players do
        assert view.state.players[pos].eliminated? == player.eliminated?
        assert view.state.players[pos].tricks_won == player.tricks_won
        assert view.state.players[pos].team == player.team
      end
    end

    test "a card killed on entering play is still shown after three tricks" do
      state = kill_state()
      assert state.killed_cards == %{north: [{13, :hearts}]}

      state =
        play_all(state,
          north: {14, :hearts},
          east: {4, :hearts},
          south: {3, :hearts},
          west: {2, :hearts},
          north: {12, :hearts},
          east: {6, :hearts},
          south: {5, :hearts},
          west: {5, :diamonds},
          north: {11, :hearts},
          east: {7, :hearts}
        )

      assert length(state.tricks) == 3
      assert state.killed_cards == %{}, "engine resets its own field after the first play"

      for pos <- [:north, :east, :south, :west] do
        view = SeatView.for_seat(state, pos)
        assert view.killed_cards == %{north: [{13, :hearts}]}
        assert view.state.killed_cards == view.killed_cards
      end
    end

    test "a second hand's view shows no kills from the first hand" do
      state =
        kill_state()
        |> play_all(
          north: {14, :hearts},
          east: {4, :hearts},
          south: {3, :hearts},
          west: {2, :hearts},
          north: {12, :hearts},
          east: {6, :hearts},
          south: {5, :hearts},
          west: {5, :diamonds},
          north: {11, :hearts},
          east: {7, :hearts},
          north: {10, :hearts},
          north: {9, :hearts},
          north: {8, :hearts}
        )

      assert state.hand_number == 2
      assert state.phase == :bidding
      assert SeatView.for_seat(state, :east).killed_cards == %{}
    end

    test "only the dealer sees the rob pool, and only under manual rob" do
      deck = [{14, :hearts}, {3, :spades}, {9, :hearts}]
      base = GameState.new()

      state = %{
        base
        | phase: :second_deal,
          current_dealer: :north,
          current_turn: :north,
          trump_suit: :hearts,
          highest_bid: {:east, 7},
          deck: deck,
          config: Map.put(base.config, :auto_dealer_rob, false)
      }

      assert SeatView.for_seat(state, :north).state.deck == deck

      for pos <- [:east, :south, :west] do
        assert SeatView.for_seat(state, pos).state.deck == []
      end

      auto = %{state | config: Map.put(state.config, :auto_dealer_rob, true)}
      assert SeatView.for_seat(auto, :north).state.deck == []
    end

    test "carries the position during dealer selection when nobody has the turn" do
      state = GameState.new()
      assert state.current_turn == nil
      assert SeatView.for_seat(state, :west).position == :west
    end
  end

  describe "killed_cards/1" do
    test "takes the first non-empty entry per seat since the last deal" do
      events = [
        {:cards_dealt, %{}},
        {:cards_killed, %{east: [{6, :spades}]}},
        {:cards_dealt, %{}},
        {:cards_killed, %{north: [], south: [{7, :hearts}]}},
        {:card_played, :south, {14, :hearts}},
        {:cards_killed, %{}},
        {:cards_killed, %{south: [{3, :hearts}], north: [{4, :hearts}]}}
      ]

      assert SeatView.killed_cards(%{GameState.new() | events: events}) ==
               %{south: [{7, :hearts}], north: [{4, :hearts}]}
    end
  end
end

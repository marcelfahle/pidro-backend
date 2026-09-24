defmodule PidroServer.Games.Bots.TimeoutStrategyTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.{GameState, SeatView}
  alias Pidro.Core.Types.Bid
  alias Pidro.Game.Engine
  alias PidroServer.Games.Bots.TimeoutStrategy

  # A seat view for the seat on turn, built from just the fields a test sets.
  defp view(fields) do
    base = GameState.new(seed: 1)
    position = Map.get(fields, :current_turn) || :north
    hands = Map.get(fields, :players, %{})

    players =
      Map.new(base.players, fn {pos, player} ->
        {pos, %{player | hand: get_in(hands, [pos, :hand]) || []}}
      end)

    state = base |> Map.merge(Map.delete(fields, :players)) |> Map.put(:players, players)
    SeatView.for_seat(state, position)
  end

  describe "pick_action/2" do
    test "passes during bidding" do
      assert {:ok, :pass, "timeout auto-play"} =
               TimeoutStrategy.pick_action([:pass, {:bid, 8}], view(%{phase: :bidding}))
    end

    test "takes the minimum bid when the dealer is forced to bid" do
      assert {:ok, {:bid, 6}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(
                 [{:bid, 7}, {:bid, 6}, {:bid, 8}],
                 view(%{phase: :bidding})
               )
    end

    test "chooses the suit with the highest trump count when declaring" do
      game_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{north: %{hand: [{14, :hearts}, {2, :hearts}, {6, :clubs}, {9, :spades}]}}
      }

      legal_actions = [{:declare_trump, :hearts}, {:declare_trump, :clubs}]

      assert {:ok, {:declare_trump, :hearts}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(legal_actions, view(game_state))
    end

    test "breaks declaring ties by total point value and then suit order" do
      game_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{north: %{hand: [{14, :hearts}, {2, :hearts}, {14, :clubs}, {5, :clubs}]}}
      }

      legal_actions = [{:declare_trump, :hearts}, {:declare_trump, :clubs}]

      assert {:ok, {:declare_trump, :clubs}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(legal_actions, view(game_state))

      tied_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{
          north: %{hand: [{14, :hearts}, {2, :hearts}, {14, :diamonds}, {2, :diamonds}]}
        }
      }

      tied_actions = [{:declare_trump, :hearts}, {:declare_trump, :diamonds}]

      assert {:ok, {:declare_trump, :hearts}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(tied_actions, view(tied_state))
    end

    test "plays the lowest legal trump" do
      legal_actions = [
        {:play_card, {14, :hearts}},
        {:play_card, {5, :diamonds}},
        {:play_card, {2, :hearts}}
      ]

      assert {:ok, {:play_card, {2, :hearts}}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(
                 legal_actions,
                 view(%{phase: :playing, trump_suit: :hearts})
               )
    end

    test "delegates dealer rob selection and room-owned dealer selection" do
      assert {:ok, {:select_hand, :choose_6_cards}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(
                 [{:select_hand, :choose_6_cards}],
                 view(%{phase: :second_deal})
               )

      assert {:ok, :select_dealer, "timeout auto-play"} =
               TimeoutStrategy.pick_action([:select_dealer], view(%{phase: :dealer_selection}))
    end

    test "only accepts a seat view, never the full game state" do
      raw_state = %{GameState.new(seed: 1) | phase: :bidding}

      assert_raise FunctionClauseError, fn ->
        apply(TimeoutStrategy, :pick_action, [[:pass], raw_state])
      end
    end
  end

  # Pins the move the turn timer makes in each phase, on real engine states.
  describe "timer moves on real game states" do
    defp at(overrides), do: Map.merge(GameState.new(seed: 1), overrides)

    defp with_hand(state, position, hand),
      do: %{state | players: Map.update!(state.players, position, &%{&1 | hand: hand})}

    defp timer_move(state) do
      position = state.current_turn
      legal = Engine.legal_actions(state, position)
      {:ok, action, "timeout auto-play"} = TimeoutStrategy.pick_action(legal, timer_input(state))
      assert action in legal
      action
    end

    defp timer_input(state), do: SeatView.for_seat(state, state.current_turn)

    test "bidding passes" do
      state = at(%{phase: :bidding, current_dealer: :west, current_turn: :north})
      assert timer_move(state) == :pass
    end

    test "a forced dealer bids the minimum" do
      passes =
        for {pos, i} <- Enum.with_index([:north, :east, :south]),
            do: %Bid{position: pos, amount: :pass, timestamp: i}

      state = at(%{phase: :bidding, current_dealer: :west, current_turn: :west, bids: passes})
      assert timer_move(state) == {:bid, 6}
    end

    test "declaring names the suit with the most trumps" do
      hand = [
        {14, :clubs},
        {5, :spades},
        {3, :clubs},
        {13, :hearts},
        {2, :hearts},
        {9, :diamonds},
        {8, :spades},
        {7, :diamonds},
        {6, :diamonds}
      ]

      state =
        at(%{
          phase: :declaring,
          current_dealer: :west,
          current_turn: :north,
          highest_bid: {:north, 7}
        })
        |> with_hand(:north, hand)

      assert timer_move(state) == {:declare_trump, :clubs}
    end

    test "playing throws the lowest legal trump" do
      hand = [{14, :hearts}, {5, :diamonds}, {2, :hearts}, {3, :clubs}]

      state =
        at(%{
          phase: :playing,
          trump_suit: :hearts,
          current_dealer: :west,
          current_turn: :north,
          highest_bid: {:north, 7}
        })
        |> with_hand(:north, hand)

      assert timer_move(state) == {:play_card, {2, :hearts}}
    end

    test "a manual rob returns the hand-selection marker" do
      base = GameState.new(seed: 1)

      state =
        at(%{
          phase: :second_deal,
          trump_suit: :hearts,
          current_dealer: :north,
          current_turn: :north,
          highest_bid: {:east, 7},
          deck: [{14, :hearts}],
          config: Map.put(base.config, :auto_dealer_rob, false)
        })

      assert timer_move(state) == {:select_hand, :choose_6_cards}
    end
  end
end

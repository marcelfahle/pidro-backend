defmodule PidroServer.Games.Bots.TimeoutStrategyTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Bots.TimeoutStrategy

  describe "pick_action/2" do
    test "passes during bidding" do
      assert {:ok, :pass, "timeout auto-play"} =
               TimeoutStrategy.pick_action([:pass, {:bid, 8}], %{phase: :bidding})
    end

    test "chooses the suit with the highest trump count when declaring" do
      game_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{
          north: %{
            hand: [{14, :hearts}, {2, :hearts}, {6, :clubs}, {9, :spades}]
          }
        }
      }

      legal_actions = [
        {:declare_trump, :hearts},
        {:declare_trump, :clubs}
      ]

      assert {:ok, {:declare_trump, :hearts}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(legal_actions, game_state)
    end

    test "breaks declaring ties by total point value and then suit order" do
      game_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{
          north: %{
            hand: [{14, :hearts}, {2, :hearts}, {14, :clubs}, {5, :clubs}]
          }
        }
      }

      legal_actions = [
        {:declare_trump, :hearts},
        {:declare_trump, :clubs}
      ]

      assert {:ok, {:declare_trump, :clubs}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(legal_actions, game_state)

      tied_state = %{
        phase: :declaring,
        current_turn: :north,
        players: %{
          north: %{
            hand: [{14, :hearts}, {2, :hearts}, {14, :diamonds}, {2, :diamonds}]
          }
        }
      }

      tied_actions = [
        {:declare_trump, :hearts},
        {:declare_trump, :diamonds}
      ]

      assert {:ok, {:declare_trump, :hearts}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(tied_actions, tied_state)
    end

    test "plays the lowest legal trump" do
      legal_actions = [
        {:play_card, {14, :hearts}},
        {:play_card, {5, :diamonds}},
        {:play_card, {2, :hearts}}
      ]

      game_state = %{phase: :playing, trump_suit: :hearts}

      assert {:ok, {:play_card, {2, :hearts}}, "timeout auto-play"} =
               TimeoutStrategy.pick_action(legal_actions, game_state)
    end

    test "delegates dealer rob selection and room-owned dealer selection" do
      assert {:ok, {:select_hand, :choose_6_cards}, "timeout auto-play"} =
               TimeoutStrategy.pick_action([{:select_hand, :choose_6_cards}], %{phase: :second_deal})

      assert {:ok, :select_dealer, "timeout auto-play"} =
               TimeoutStrategy.pick_action([:select_dealer], %{phase: :dealer_selection})
    end
  end
end

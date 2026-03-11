defmodule PidroServer.Games.GameAdapterTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.{GameAdapter, Lifecycle}

  describe "transition_delay_ms/2" do
    test "returns hand transition delay when hand number increases" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [%{}], current_trick: nil}
      new_state = %{phase: :dealer_selection, hand_number: 2, tricks: [%{}], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) ==
               Lifecycle.config(:hand_transition_delay_ms)
    end

    test "returns trick transition delay when a trick completes" do
      old_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [],
        current_trick: %{plays: [1, 2, 3]}
      }

      new_state = %{
        phase: :playing,
        hand_number: 1,
        tricks: [%{winner: :north}],
        current_trick: nil
      }

      assert GameAdapter.transition_delay_ms(old_state, new_state) ==
               Lifecycle.config(:trick_transition_delay_ms)
    end

    test "returns zero when the game is complete" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [%{}], current_trick: nil}
      new_state = %{phase: :complete, hand_number: 2, tricks: [%{}, %{}], current_trick: nil}

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0
    end

    test "returns zero for normal in-hand updates" do
      old_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: %{plays: [1]}}
      new_state = %{phase: :playing, hand_number: 1, tricks: [], current_trick: %{plays: [1, 2]}}

      assert GameAdapter.transition_delay_ms(old_state, new_state) == 0
    end
  end
end

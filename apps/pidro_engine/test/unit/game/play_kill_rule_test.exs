defmodule Pidro.Game.PlayKillRuleTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.Types
  alias Pidro.Core.Types.Player
  alias Pidro.Game.Play

  describe "killed card validation bug" do
    test "player with killed cards should be able to play from their hand" do
      # Setup: West has 7 trumps (clubs) and must kill one.
      # Trump is Clubs.
      
      # Hand before kill: 7 Clubs, 6 Clubs, 4 Clubs, 3 Clubs, 2 Clubs, 14 Clubs, 11 Clubs
      # Non-point trumps: 7 Clubs, 6 Clubs, 11 Clubs (Wait, 11 is Jack? No 11 is Jack in some games but here ranks are 2..14. Jack is 11. Jack is point card (1 point))
      # Points: A(14)=1, J(11)=1, 10=1, R5=5, W5=5, 2=1.
      # Non-points: K(13), Q(12), 9, 8, 7, 6, 4, 3.
      
      # Let's construct a hand with >6 cards, excess trumps.
      # Trump: Clubs.
      # Hand: 
      # 14 Clubs (Ace) - Point
      # 10 Clubs - Point
      # 2 Clubs - Point
      # 9 Clubs - Non-point
      # 8 Clubs - Non-point
      # 7 Clubs - Non-point
      # 6 Clubs - Non-point
      
      # Total 7 cards. All trumps.
      # Must kill 1 card. Should be a non-point trump. e.g. 7 Clubs.
      
      west_hand = [
        {14, :clubs},
        {10, :clubs},
        {2, :clubs},
        {9, :clubs},
        {8, :clubs},
        {7, :clubs},
        {6, :clubs}
      ]
      
      player = %Player{
        position: :west,
        hand: west_hand,
        team: :east_west
      }
      
      state = %Types.GameState{
        trump_suit: :clubs,
        players: %{west: player},
        phase: :playing,
        current_turn: :west,
        trick_number: 0
      }
      
      # Compute kills
      killed_state = Play.compute_kills(state)
      
      # Verify killed cards
      killed = killed_state.killed_cards[:west]
      assert length(killed) == 1
      # It kills oldest non-point. The logic is: 
      # non_point = Card.non_point_trumps(player.hand, trump)
      # to_kill = Enum.take(non_point, excess)
      # We don't strictly care WHICH one is killed for this test, just that one IS killed.
      assert length(killed_state.players[:west].hand) == 6
      
      # The killed card should NOT be in the hand
      killed_card = hd(killed)
      refute killed_card in killed_state.players[:west].hand
      
      # Now try to play a valid card from the hand
      card_to_play = hd(killed_state.players[:west].hand)
      
      # This should succeed, but currently fails with {:must_play_top_killed_card_first, ...}
      result = Play.play_card(killed_state, :west, card_to_play)
      
      assert {:ok, _} = result
    end
  end
end

defmodule Pidro.LouisianaRulesTest do
  use ExUnit.Case, async: true

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.{GameState, SeatView, Types}
  alias Pidro.Game.{Bidding, Engine, Play}
  alias Pidro.Rules.Louisiana

  test "trump led requires trump, and the left five leads trump rather than its printed suit" do
    hand = [{13, :diamonds}, {5, :diamonds}, {4, :hearts}, {3, :clubs}]
    state = playing(hand, {5, :diamonds})

    assert Engine.legal_actions(state, :east) == [
             {:play_card, {5, :diamonds}},
             {:play_card, {4, :hearts}}
           ]

    assert {:error, _} = Engine.apply_action(state, :east, {:play_card, {13, :diamonds}})
    assert Louisiana.legal_plays([{3, :clubs}], :hearts, :hearts) == [{3, :clubs}]
  end

  test "non-trump lead allows following suit or trump, not an unrelated discard" do
    hand = [{13, :diamonds}, {5, :diamonds}, {4, :hearts}, {3, :clubs}]
    state = playing(hand, {7, :diamonds})
    assert Engine.legal_actions(state, :east) == Enum.map(Enum.take(hand, 3), &{:play_card, &1})
    assert {:error, _} = Engine.apply_action(state, :east, {:play_card, {3, :clubs}})
    assert {:ok, _} = Engine.apply_action(state, :east, {:play_card, {13, :diamonds}})

    assert Louisiana.legal_plays([{5, :diamonds}, {3, :clubs}], :hearts, :diamonds) == [
             {5, :diamonds}
           ]

    assert Louisiana.legal_plays([{3, :clubs}, {2, :spades}], :hearts, :diamonds) == [
             {3, :clubs},
             {2, :spades}
           ]

    assert Louisiana.legal_plays(hand, :hearts, nil) == hand
  end

  test "highest trump wins, otherwise highest led-suit card, not an off-suit ace" do
    plays = [{:north, {7, :clubs}}, {:east, {14, :spades}}, {:south, {10, :clubs}}]
    assert Louisiana.winner(plays, :hearts) == :south
    assert Louisiana.winner(plays ++ [{:west, {2, :hearts}}], :hearts) == :west

    assert Louisiana.winner(
             [{:north, {4, :hearts}}, {:east, {5, :diamonds}}, {:south, {5, :hearts}}],
             :hearts
           ) == :south

    trick = %Types.Trick{number: 1, leader: :north, plays: plays}
    assert {:ok, :south, 0} = Play.determine_trick_winner(trick, :hearts, :louisiana)
    assert Pidro.Finnish.Scorer.score_trick(trick, :hearts, :louisiana).winner == :south
  end

  test "a player without trumps keeps their hand and turn and can play" do
    state = playing([{3, :clubs}, {2, :spades}], {7, :clubs}) |> Play.compute_kills()
    refute state.players.east.eliminated?
    assert state.current_turn == :east
    assert {:ok, next} = Engine.apply_action(state, :east, {:play_card, {3, :clubs}})
    refute next.players.east.eliminated?
    assert next.players.east.hand == [{2, :spades}]
    assert next.players.east.revealed_cards == []
  end

  test "minimum and forced dealer bid are seven, and seat views carry the rules" do
    state = %{
      GameState.new(seed: 1, variant: :louisiana)
      | phase: :bidding,
        current_dealer: :north
    }

    assert state.config.min_bid == 7
    assert state.config.max_bid == 14
    assert state.config.winning_score == 62
    assert {:error, {:invalid_bid_amount, 6}} = Bidding.validate_bid(state, :east, 6)

    state =
      Enum.reduce([:east, :south, :west], state, fn position, state ->
        {:ok, next} = Bidding.apply_pass(state, position)
        next
      end)

    assert hd(Bidding.legal_actions(state, :north)) == {:bid, 7}
    refute :pass in Bidding.legal_actions(state, :north)
    assert {:ok, %{highest_bid: {:north, 7}}} = Bidding.apply_bid(state, :north, 7)
    view = SeatView.for_seat(state, :north)
    assert view.variant == :louisiana
    assert view.config.min_bid == 7
  end

  test "Louisiana bot uses a legal trump policy pick, otherwise the lowest legal non-point card" do
    state = playing([{13, :hearts}, {3, :clubs}, {2, :spades}], {7, :clubs})
    legal = Engine.legal_actions(state, :east)

    assert {{:play_card, {13, :hearts}}, _} =
             Rulebook.decide(SeatView.for_seat(state, :east), legal)

    state = playing([{13, :clubs}, {4, :clubs}, {2, :spades}], {7, :clubs})
    legal = Engine.legal_actions(state, :east)

    assert {{:play_card, {4, :clubs}}, _} =
             Rulebook.decide(SeatView.for_seat(state, :east), legal)
  end

  test "a short redeal uses non-trump discards deterministically and still gives every seat six" do
    held = [{2, :hearts}, {3, :hearts}, {4, :hearts}, {6, :hearts}]

    {trumps, plain} =
      Enum.split_with(Pidro.Core.Deck.ordered() -- held, &Pidro.Core.Card.is_trump?(&1, :hearts))

    {fillers, discarded} = Enum.split(plain, 6)
    base = GameState.new(seed: 7, variant: :louisiana)

    players =
      Map.new(Enum.zip(Types.all_positions(), held), fn {position, card} ->
        {position, %{base.players[position] | hand: [card]}}
      end)

    state = %{
      base
      | phase: :second_deal,
        current_dealer: :north,
        trump_suit: :hearts,
        highest_bid: {:north, 7},
        players: players,
        deck: trumps ++ fillers,
        discarded_cards: discarded
    }

    {:ok, dealt} = Pidro.Game.Discard.second_deal(state)
    assert dealt.chance != state.chance

    assert Task.async(fn -> Pidro.Game.Discard.second_deal(state) end) |> Task.await() ==
             {:ok, dealt}

    pool = dealt.players.north.hand ++ dealt.deck
    chosen = Pidro.Game.DealerRob.select_best_cards(pool, :hearts)
    assert {:ok, playing} = Pidro.Game.Discard.dealer_rob_pack(dealt, chosen)
    assert Enum.all?(playing.players, fn {_, player} -> length(player.hand) == 6 end)

    cards =
      Enum.flat_map(playing.players, fn {_, player} -> player.hand end) ++
        playing.discarded_cards ++ playing.deck

    assert Enum.sort(cards) == Enum.sort(Pidro.Core.Deck.ordered())
  end

  defp playing(hand, lead) do
    state = GameState.new(seed: 1, variant: :louisiana)

    players =
      Map.new(state.players, fn {position, player} ->
        {position,
         %{player | hand: if(position == :east, do: hand, else: [{8, :hearts}, {9, :clubs}])}}
      end)

    %{
      state
      | phase: :playing,
        trump_suit: :hearts,
        current_turn: :east,
        players: players,
        current_trick: %Types.Trick{number: 1, leader: :north, plays: [{:north, lead}]}
    }
  end
end

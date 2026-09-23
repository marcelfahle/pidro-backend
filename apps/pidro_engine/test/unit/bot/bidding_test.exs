defmodule Pidro.Bot.BiddingTest do
  use ExUnit.Case, async: true

  import Pidro.Test.Scenario, only: [suit: 2]

  alias Pidro.Bot.{Bidding, Thresholds}
  alias Pidro.Core.SeatView
  alias Pidro.Test.{GameTrace, Scenario}

  doctest Pidro.Bot.Bidding

  # Nine cards: the given cards plus low, pointless filler in the black suits.
  defp hand(cards) do
    filler = suit(:clubs, [3, 4, 7, 8]) ++ suit(:spades, [6, 7, 8, 9])
    cards ++ Enum.take(filler -- cards, 9 - length(cards))
  end

  defp decide(state), do: Bidding.decide_bid(Scenario.view(state), Scenario.legal(state))

  describe "decide_bid/2" do
    test "AE1: J, 10, 7, 6, 5 first to bid bids below 9" do
      {action, _reason} =
        decide(Scenario.bidding(me: :north, hand: hand(suit(:hearts, [11, 10, 7, 6, 5]))))

      assert action == :pass or match?({:bid, n} when n < 9, action)
    end

    test "AE2: no trump above the 9 and no Five passes" do
      cards =
        suit(:hearts, [9, 8, 4]) ++
          suit(:diamonds, [7, 6]) ++ suit(:clubs, [9, 3]) ++ suit(:spades, [8, 2])

      assert {:pass, _} = decide(Scenario.bidding(me: :north, hand: cards))
    end

    test "AE3: partner bid 8, the next seat passed, A-K-5 passes" do
      state =
        Scenario.bidding(
          me: :south,
          bids: [north: 8, east: :pass],
          hand: hand(suit(:hearts, [14, 13, 5]))
        )

      assert {:pass, reason} = decide(state)
      assert reason =~ "Partner's 8 stands"
    end

    test "AE4: a dealer with a worthless hand after three passes bids 6 and says it was forced" do
      cards =
        suit(:hearts, [9, 8]) ++
          suit(:diamonds, [7, 6, 4]) ++ suit(:clubs, [9, 3]) ++ suit(:spades, [8, 7])

      state =
        Scenario.bidding(
          me: :west,
          dealer: :west,
          bids: [north: :pass, east: :pass, south: :pass],
          hand: cards
        )

      assert {{:bid, 6}, reason} = decide(state)
      assert reason =~ "must bid"
    end

    test "both Fives of one colour bid higher than one Five with the same small trumps" do
      both = hand(suit(:hearts, [5, 7, 4]) ++ [{5, :diamonds}])
      one = hand(suit(:hearts, [5, 7, 4]))

      assert Bidding.estimate(both, :hearts, false) > Bidding.estimate(one, :hearts, false)

      assert bid_amount(decide(Scenario.bidding(me: :north, hand: both))) >
               bid_amount(decide(Scenario.bidding(me: :north, hand: one)))
    end

    test "a fractional estimate rounds down" do
      cards = hand(suit(:hearts, [14, 13, 11, 5, 4]))
      estimate = Bidding.estimate(cards, :hearts, false)
      assert estimate != trunc(estimate)

      assert {{:bid, amount}, _} = decide(Scenario.bidding(me: :north, hand: cards))
      assert amount == trunc(estimate)
    end

    test "the same hand bids one higher as dealer than in first seat" do
      cards = hand(suit(:hearts, [14, 13, 5]))

      {{:bid, first}, _} = decide(Scenario.bidding(me: :north, hand: cards))

      {{:bid, dealer}, _} =
        decide(
          Scenario.bidding(
            me: :west,
            dealer: :west,
            bids: [north: :pass, east: :pass, south: 6],
            hand: cards
          )
        )

      assert dealer == first + Thresholds.get(:dealer_bonus)
    end

    test "passes when an opponent has already bid above its estimate" do
      cards = hand(suit(:hearts, [14, 13, 5]))
      {{:bid, own}, _} = decide(Scenario.bidding(me: :north, hand: cards))

      state = Scenario.bidding(me: :south, bids: [east: own], dealer: :north, hand: cards)
      assert {:pass, reason} = decide(state)
      assert reason =~ "below the #{own + 1} needed"
    end

    test "overbids partner only with a clear margin" do
      strong = hand(suit(:hearts, [14, 13, 12, 11, 10, 5, 2]) ++ [{5, :diamonds}])
      state = Scenario.bidding(me: :south, bids: [north: 7, east: :pass], hand: strong)
      assert {{:bid, amount}, _} = decide(state)
      assert amount >= 7 + Thresholds.get(:overbid_partner_margin)
    end

    test "equal estimates resolve to the same suit on every run" do
      cards =
        suit(:spades, [14, 13, 5]) ++ suit(:diamonds, [14, 13, 5]) ++ suit(:clubs, [9, 8, 3])

      results = for _ <- 1..20, do: Bidding.best_suit(cards, false)
      assert Enum.uniq(results) == [{:diamonds, Bidding.estimate(cards, :diamonds, false)}]
    end

    test "chooses a legal action when only one bid remains" do
      strong = hand(suit(:hearts, [14, 13, 12, 11, 10, 5, 2]) ++ [{5, :diamonds}])
      state = Scenario.bidding(me: :west, bids: [north: :pass, east: 12, south: 13], hand: strong)

      legal = Scenario.legal(state)
      assert legal == [{:bid, 14}, :pass]
      assert Bidding.estimate(strong, :hearts, true) < 14
      assert {:pass, _} = decide(state)
    end

    test "a dealer that is not forced bids its estimate rounded down" do
      strong = hand(suit(:hearts, [14, 13, 12, 11, 10, 5, 2]) ++ [{5, :diamonds}])

      state =
        Scenario.bidding(me: :west, bids: [north: :pass, east: :pass, south: 6], hand: strong)

      {{:bid, amount}, _} = decide(state)
      assert amount == min(trunc(Bidding.estimate(strong, :hearts, true)), 14)
    end

    test "always returns a legal action in the bidding states of real games" do
      for seed <- 1..40,
          state <- GameTrace.states(seed),
          state.phase == :bidding do
        view = SeatView.for_seat(state, state.current_turn)
        legal = Scenario.legal(state)
        {action, reason} = Bidding.decide_bid(view, legal)

        assert action in legal
        assert reason != ""
      end
    end
  end

  describe "decide_trump/2" do
    test "AE19: names hearts holding A, K, 5 of hearts" do
      cards = hand(suit(:hearts, [14, 13, 5]))
      state = Scenario.declaring(me: :east, hand: cards)

      assert {{:declare_trump, :hearts}, reason} =
               Bidding.decide_trump(Scenario.view(state), Scenario.legal(state))

      assert reason =~ "Hearts"
    end

    test "names the suit the bid was based on" do
      cards =
        suit(:clubs, [14, 11, 10, 5]) ++
          [{5, :spades}] ++ suit(:hearts, [9, 8]) ++ suit(:diamonds, [7, 6])

      {suit, _} = Bidding.best_suit(cards, false)
      state = Scenario.declaring(me: :north, hand: cards)

      assert {{:declare_trump, ^suit}, _} =
               Bidding.decide_trump(Scenario.view(state), Scenario.legal(state))

      assert suit == :clubs
    end
  end

  defp bid_amount({{:bid, amount}, _}), do: amount
  defp bid_amount({:pass, _}), do: 0
end

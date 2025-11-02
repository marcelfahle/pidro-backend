look at spec/ masterplan.md masterplan-redeal.md and guides to how the game works.

we found a bug (not sure) in the trump decleration. As you see below, player :east made the highest bid and it's correctly identified that it's :east turn to declare the trump suit.

But when I perform this action with {:ok, state} = step(state, :east, {:declare_trump, :clubs}), I get the following error

► East performs: Declare Clubs ♣

✗ Error: {:not_dealer_turn, :north, :east}

\*\* (MatchError) no match of right hand side value:

    {:error, {:not_dealer_turn, :north, :east}}

    (stdlib 7.1) erl_eval.erl:672: :erl_eval.expr/6
    iex:10: (file)

Phase: Trump Declaration
Hand: #1
Dealer: North
Turn: East

Scores:
North/South: 0 this hand, 0 total
East/West: 0 this hand, 0 total

Bidding:
Highest Bid: 10 by East
History:
East: 10
South: PASS
West: PASS
North: PASS

Players:

North (North/South)
Hand: K♥★ 7♦ 5♥★ 2♠ Q♥★ J♠ 4♥★ 7♠ 3♠

East (East/West)
Hand: K♠ 2♥★ 6♣ K♣ 4♣ 5♣ 5♠ 9♠ 10♣

South (North/South)
Hand: 5♦★ 7♥★ J♣ 6♦ 9♦ 2♦ Q♠ A♥★ 6♠

West (East/West)
Hand: 7♣ 8♣ K♦ 2♣ 8♦ 10♥★ A♠ Q♦ 10♠

:ok
iex(10)> {:ok, state} = step(state, :east, {:declare_trump, :clubs})

► East performs: Declare Clubs ♣

✗ Error: {:not_dealer_turn, :north, :east}

\*\* (MatchError) no match of right hand side value:

    {:error, {:not_dealer_turn, :north, :east}}

    (stdlib 7.1) erl_eval.erl:672: :erl_eval.expr/6
    iex:10: (file)

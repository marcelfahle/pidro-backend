look at spec/ masterplan.md masterplan-redeal.md and guides to how the game works.

We found a bug in the game when we switch from declare_trump to redeal to play phase. In the following example we have auto_rob activated (see AUTO_DEALER_ROB.md).

The whole iea is that when a player picks a trump suit that in all the hands (minus the dealer) all non trump cards are discarded and the hands filled up again by the dealer until everybody has 6 cards.

In the current state of the game, only the dealer seems to end up with 6 cards. All other players still have the original 9 cards.
Compare game views from the trump declaration phase:

===
Phase: Trump Declaration
Hand: #1
Dealer: East
Turn: East

Scores:
North/South: 0 this hand, 0 total
East/West: 0 this hand, 0 total

Bidding:
Highest Bid: 6 by East
History:
South: PASS
West: PASS
North: PASS
East: 6

Players:

North (North/South)
Hand: A♦ 7♠ A♣ 5♣ 2♠ 10♠ 6♥★ K♣ 10♣

East (East/West)
Hand: 6♣ 5♦★ 7♦ J♠ 9♣ A♥★ 8♣ 7♥★ 2♣

South (North/South)
Hand: 3♠ 3♥★ 2♥★ 4♣ 10♦ 6♠ Q♦ Q♥★ 4♠

West (East/West)
Hand: K♠ A♠ J♣ 7♣ 8♥★ 6♦ 8♦ 9♦ 10♥★

:ok
iex(20)> {:ok, state} = step(state, :east, {:declare_trump, :diamonds})

► East performs: Declare Diamonds ♦

✓ Action successful!

===

and when we've declared the trump and the redeal phase ran automatically (?)

===
Phase: Playing
Hand: #1
Dealer: East
Turn: South

Scores:
North/South: 0 this hand, 0 total
East/West: 0 this hand, 0 total

Bidding:
Highest Bid: 6 by East
History:
South: PASS
West: PASS
North: PASS
East: 6

Trump: Diamonds ♦

Players:

North (North/South)
Hand: A♦[1]★ 7♠ A♣ 5♣ 2♠ 10♠ 6♥ K♣ 10♣

East (East/West)
Hand: J♦[1]★ 5♦[5]★ 5♥[5]★ A♥ 2♦[1]★ J♠

South (North/South)
Hand: 3♠ 3♥ 2♥ 4♣ 10♦[1]★ 6♠ Q♦★ Q♥ 4♠

West (East/West)
Hand: K♠ A♠ J♣ 7♣ 8♥ 6♦★ 8♦★ 9♦★ 10♥

# :ok

Event Log
╔═══════════════════════════════════════════════════════════╗
║ EVENT LOG ║
╚═══════════════════════════════════════════════════════════╝

1. [DEALER] East selected as dealer (cut Q♠)
2. [DEAL] Initial deal complete (36 cards dealt)
3. [PASS] South passed
4. [PASS] West passed
5. [PASS] North passed
6. [BID] East bid 6
7. [BID COMPLETE] East won with bid of 6
8. [TRUMP] Diamonds ♦ declared as trump
9. [ROB] East robbed pack (took 16, kept 6)

took 16 in this case is def wrong, if cards were distributed to others.

This seems to be a bug in the system. I'm sure we have the functionality, maybe it's just the IEx tools.

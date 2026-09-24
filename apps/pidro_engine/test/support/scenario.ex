defmodule Pidro.Test.Scenario do
  @moduledoc """
  Builds valid game states for bot tests from a compact description.

  Cards in a playing scenario are written relative to trump: an integer is
  that rank of the trump suit, `:off5` is the Five of the same colour, and a
  `{rank, suit}` tuple is taken as-is (use it for non-trump filler).

      Scenario.playing(
        me: :south,
        hands: %{south: [5, 9, 3]},
        trick: [north: 14, east: 4],
        tricks: [[north: 13, east: 2, south: 8, west: 6]]
      )

  Seats without an explicit hand get their lowest unused trump plus
  non-trump filler, so they stay active. Their contents never matter to the
  bot, which only sees their size.
  """

  alias Pidro.Bot.Knowledge
  alias Pidro.Core.{Card, GameState, SeatView}
  alias Pidro.Core.Types
  alias Pidro.Core.Types.{Bid, Trick}
  alias Pidro.Game.{Engine, Play}

  @positions [:north, :east, :south, :west]

  @doc """
  Builds a playing-phase state where it is `me`'s turn.

  Options:
  - `:me` (required) - the seat to move; checked against the trick order
  - `:trump` - trump suit, default `:hearts`
  - `:hands` - `%{position => cards}`
  - `:trick` - plays in the current trick, leader first
  - `:tricks` - completed tricks, each a keyword list of plays, leader first
  - `:bid` - `{position, amount}`, default `{:north, 8}`
  - `:dealer` - default the seat before the bidder
  - `:cold` - seats that have gone cold
  - `:killed` - `%{position => cards}` killed on entering play
  - `:counts` - `%{position => size}` for seats without an explicit hand
  """
  @spec playing(keyword()) :: Types.GameState.t()
  def playing(opts) do
    trump = Keyword.get(opts, :trump, :hearts)
    me = Keyword.fetch!(opts, :me)
    card = &to_card(&1, trump)

    hands =
      Map.new(Keyword.get(opts, :hands, %{}), fn {pos, cards} -> {pos, Enum.map(cards, card)} end)

    trick = Enum.map(Keyword.get(opts, :trick, []), fn {pos, c} -> {pos, card.(c)} end)

    tricks =
      opts
      |> Keyword.get(:tricks, [])
      |> Enum.map(fn plays -> Enum.map(plays, fn {pos, c} -> {pos, card.(c)} end) end)

    killed =
      Map.new(Keyword.get(opts, :killed, %{}), fn {pos, cards} -> {pos, Enum.map(cards, card)} end)

    cold = Keyword.get(opts, :cold, [])
    {bidder, _amount} = bid = Keyword.get(opts, :bid, {:north, 8})
    dealer = Keyword.get(opts, :dealer, previous(bidder))

    used =
      Enum.concat([
        Enum.concat(Map.values(hands)),
        Enum.map(trick, &elem(&1, 1)),
        Enum.flat_map(tricks, &Enum.map(&1, fn {_p, c} -> c end)),
        Enum.concat(Map.values(killed))
      ])

    played_by = fn pos -> Enum.count(Enum.concat(tricks) ++ trick, &(elem(&1, 0) == pos)) end
    counts = Keyword.get(opts, :counts, %{})

    {hands, _used} =
      Enum.reduce(@positions, {hands, used}, fn pos, {acc, used} ->
        if Map.has_key?(acc, pos) or pos in cold do
          {Map.put_new(acc, pos, []), used}
        else
          size = Map.get(counts, pos, max(6 - played_by.(pos), 1))
          filled = fill_hand(size, trump, used)
          {Map.put(acc, pos, filled), used ++ filled}
        end
      end)

    completed =
      tricks
      |> Enum.with_index(1)
      |> Enum.map(fn {[{leader, _} | _] = plays, number} ->
        {:ok, winner, points} =
          Play.determine_trick_winner(%Trick{number: number, leader: leader, plays: plays}, trump)

        %Trick{number: number, leader: leader, plays: plays, winner: winner, points: points}
      end)

    current =
      case trick do
        [] -> nil
        [{leader, _} | _] -> %Trick{number: length(completed) + 1, leader: leader, plays: trick}
      end

    base = GameState.new(seed: 1)

    players =
      Map.new(base.players, fn {pos, player} ->
        {pos,
         %{
           player
           | hand: hands[pos],
             eliminated?: pos in cold,
             tricks_won: Enum.count(completed, &(&1.winner == pos))
         }}
      end)

    state = %{
      base
      | phase: :playing,
        trump_suit: trump,
        current_dealer: dealer,
        current_turn: me,
        highest_bid: bid,
        bidding_team: Types.position_to_team(bidder),
        bids: [%Bid{position: bidder, amount: elem(bid, 1)}],
        players: players,
        tricks: completed,
        current_trick: current,
        trick_number: length(completed) + if(current, do: 1, else: 0),
        hand_points: engine_hand_points(completed),
        events: [{:cards_dealt, %{}}, {:cards_killed, killed}]
    }

    check_turn!(state, me)
    state
  end

  @doc """
  Builds a bidding-phase state where it is `me`'s turn to bid.

  Options:
  - `:me` (required), `:hand` (required, nine `{rank, suit}` cards)
  - `:dealer` - default the seat before the first bidder
  - `:bids` - earlier bids in order, as `[position: amount | :pass]`
  """
  @spec bidding(keyword()) :: Types.GameState.t()
  def bidding(opts) do
    me = Keyword.fetch!(opts, :me)
    bids = Keyword.get(opts, :bids, [])
    first = if bids == [], do: me, else: bids |> hd() |> elem(0)
    dealer = Keyword.get(opts, :dealer, previous(first))

    bid_structs =
      bids
      |> Enum.with_index()
      |> Enum.map(fn {{pos, amount}, i} -> %Bid{position: pos, amount: amount, timestamp: i} end)

    highest =
      bids
      |> Enum.reject(&(elem(&1, 1) == :pass))
      |> List.last()

    state = %{
      with_hand(GameState.new(seed: 1), me, Keyword.fetch!(opts, :hand))
      | phase: :bidding,
        current_dealer: dealer,
        current_turn: me,
        bids: bid_structs,
        highest_bid: highest,
        bidding_team: highest && Types.position_to_team(elem(highest, 0))
    }

    if Engine.legal_actions(state, me) == [], do: raise("not #{me}'s turn to bid")
    state
  end

  @doc """
  Builds a declaring-phase state where `me` won the bid and names trump.
  """
  @spec declaring(keyword()) :: Types.GameState.t()
  def declaring(opts) do
    me = Keyword.fetch!(opts, :me)
    amount = Keyword.get(opts, :amount, 8)

    %{
      with_hand(GameState.new(seed: 1), me, Keyword.fetch!(opts, :hand))
      | phase: :declaring,
        current_dealer: Keyword.get(opts, :dealer, previous(me)),
        current_turn: me,
        bids: [%Bid{position: me, amount: amount}],
        highest_bid: {me, amount},
        bidding_team: Types.position_to_team(me)
    }
  end

  @doc """
  Returns the view of the seat whose turn it is.
  """
  @spec view(Types.GameState.t()) :: SeatView.t()
  def view(%Types.GameState{current_turn: me} = state), do: SeatView.for_seat(state, me)

  @doc """
  Returns the legal actions of the seat whose turn it is.
  """
  @spec legal(Types.GameState.t()) :: [Types.action()]
  def legal(%Types.GameState{current_turn: me} = state), do: Engine.legal_actions(state, me)

  @doc """
  Returns cards of one suit, for bidding hands.
  """
  @spec suit(Types.suit(), [Types.rank()]) :: [Types.card()]
  def suit(suit, ranks), do: Enum.map(ranks, &{&1, suit})

  @doc """
  Converts a compact card to a `{rank, suit}` card under `trump`.
  """
  @spec to_card(integer() | :off5 | Types.card(), Types.suit()) :: Types.card()
  def to_card(:off5, trump), do: {5, Card.same_color_suit(trump)}
  def to_card(rank, trump) when is_integer(rank), do: {rank, trump}
  def to_card({_rank, _suit} = card, _trump), do: card

  defp with_hand(state, me, hand) do
    others = @positions -- [me]
    rest = (full_deck() -- hand) |> Enum.chunk_every(9)

    players =
      Map.new(state.players, fn {pos, player} ->
        cards = if pos == me, do: hand, else: Enum.at(rest, Enum.find_index(others, &(&1 == pos)))
        {pos, %{player | hand: cards}}
      end)

    %{state | players: players}
  end

  # One unused trump keeps the seat active; the rest is non-trump filler.
  defp fill_hand(size, trump, used) do
    trump_card =
      trump |> Knowledge.all_trumps() |> Enum.reverse() |> Enum.find(&(&1 not in used))

    filler =
      full_deck()
      |> Enum.reject(&(Card.is_trump?(&1, trump) or &1 in used))
      |> Enum.take(size - 1)

    [trump_card | filler]
  end

  # What the engine accumulates during play: the whole trick to its winner.
  defp engine_hand_points(tricks) do
    Enum.reduce(tricks, %{north_south: 0, east_west: 0}, fn trick, acc ->
      Map.update!(acc, Types.position_to_team(trick.winner), &(&1 + trick.points))
    end)
  end

  defp check_turn!(state, me) do
    if Engine.legal_actions(state, me) == [] do
      raise ArgumentError, "#{me} has no legal play in this scenario"
    end

    expected = expected_turn(state)

    if expected != me do
      raise ArgumentError, "scenario says #{me} is to play, but the trick order gives #{expected}"
    end
  end

  defp expected_turn(%{current_trick: %Trick{plays: plays}} = state) do
    {last, _card} = List.last(plays)
    next_active(state, last)
  end

  defp expected_turn(%{tricks: [], highest_bid: {bidder, _}} = state),
    do: active_or_next(state, bidder)

  defp expected_turn(%{tricks: tricks} = state),
    do: active_or_next(state, List.last(tricks).winner)

  defp active_or_next(state, pos) do
    if state.players[pos].eliminated?, do: next_active(state, pos), else: pos
  end

  defp next_active(state, pos) do
    pos
    |> Stream.iterate(&Types.next_position/1)
    |> Stream.drop(1)
    |> Enum.find(&(not state.players[&1].eliminated?))
  end

  defp full_deck, do: for(suit <- Types.all_suits(), rank <- 2..14, do: {rank, suit})

  defp previous(pos),
    do: pos |> Types.next_position() |> Types.next_position() |> Types.next_position()
end

defmodule Pidro.Bot.Knowledge do
  @moduledoc """
  What a seat can work out about the table from its seat view.

  Every card-play rule asks the same few questions: which trumps are still
  out, who is winning the trick, who has yet to play, and whether the trick is
  safe. This module answers them from a `Pidro.Core.SeatView` alone, reusing
  the engine's own ranking and scoring.

  ## Supported variant

  The Pidro.Bot modules play Finnish Pidro only, the one variant the engine
  implements. Ranking, trump membership and scoring come from the engine
  (`Pidro.Core.Card`, `Pidro.Game.Play`, `Pidro.Finnish.Scorer`); only
  tactical preferences and bidding estimates belong to the bot. When another
  rule set is added, these facts should come from the selected engine rules
  rather than a bot-side copy.

  ## Live threats

  A trump is a live threat when it is not in the bot's hand, has not been
  played, and was not killed. The dealer's discarded trumps stay hidden, so
  every conclusion here is conservative: a trick the bot calls safe cannot be
  taken by an opponent, but some safe tricks are not recognised.
  """

  alias Pidro.Core.{Card, SeatView, Types}
  alias Pidro.Core.Types.Trick
  alias Pidro.Finnish.Scorer
  alias Pidro.Game.Play

  @type view :: SeatView.t()
  @type card :: Types.card()
  @type position :: Types.position()

  @doc """
  Returns every trump of `suit`, highest first, as the engine ranks them.

  Derived from `Pidro.Core.Card.is_trump?/2` and `Pidro.Core.Card.compare/3`
  rather than a bot-side list, so it follows the engine's rules.

  ## Examples

      iex> Pidro.Bot.Knowledge.all_trumps(:hearts) |> Enum.take(2)
      [{14, :hearts}, {13, :hearts}]

      iex> Pidro.Bot.Knowledge.all_trumps(:hearts) |> Enum.slice(9, 2)
      [{5, :hearts}, {5, :diamonds}]
  """
  @spec all_trumps(Types.suit()) :: [card()]
  def all_trumps(suit) do
    for(
      deck_suit <- Types.all_suits(),
      rank <- 2..14,
      Card.is_trump?({rank, deck_suit}, suit),
      do: {rank, deck_suit}
    )
    |> Enum.sort(&(Card.compare(&1, &2, suit) == :gt))
  end

  @doc """
  Returns the trumps in the viewer's hand, lowest first.
  """
  @spec my_trumps(view()) :: [card()]
  def my_trumps(%SeatView{hand: hand, trump_suit: trump}) do
    hand
    |> Enum.filter(&Card.is_trump?(&1, trump))
    |> sort_ascending(trump)
  end

  @doc """
  Returns every card played this hand, including the trick in progress.
  """
  @spec played_cards(view()) :: [card()]
  def played_cards(%SeatView{} = view) do
    tricks = view.tricks ++ List.wrap(view.current_trick)
    for %Trick{plays: plays} <- tricks, {_pos, card} <- plays, do: card
  end

  @doc """
  Returns the trumps the viewer cannot place: not in its hand, not played,
  and not killed. Highest first.
  """
  @spec unseen_trumps(view()) :: [card()]
  def unseen_trumps(%SeatView{} = view) do
    known =
      MapSet.new(view.hand ++ played_cards(view) ++ Enum.concat(Map.values(view.killed_cards)))

    view.trump_suit
    |> all_trumps()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  @doc """
  Returns the unseen trumps another seat could still hold, highest first.

  When no other seat holds cards, nothing is a threat: any unseen trump is
  then in the dealer's discards or the undealt deck.
  """
  @spec live_threats(view()) :: [card()]
  def live_threats(%SeatView{} = view) do
    if other_active_seats(view) == [], do: [], else: unseen_trumps(view)
  end

  @doc """
  Returns the seat and card currently winning the trick, or `nil` before the
  first card of a trick.
  """
  @spec current_winner(view()) :: {position(), card()} | nil
  def current_winner(%SeatView{current_trick: %Trick{plays: [_ | _]} = trick} = view) do
    {:ok, winner, _points} = Play.determine_trick_winner(trick, view.trump_suit)
    {winner, trick.plays |> List.keyfind!(winner, 0) |> elem(1)}
  end

  def current_winner(%SeatView{}), do: nil

  @doc """
  Returns the seats other than the viewer that still have to play to the
  current trick: active seats that have not played to it yet.
  """
  @spec seats_to_act(view()) :: [position()]
  def seats_to_act(%SeatView{} = view) do
    played = for {pos, _card} <- trick_plays(view), do: pos
    other_active_seats(view) -- played
  end

  @doc """
  Returns the opponents that still have to play to the current trick.
  """
  @spec opponents_to_act(view()) :: [position()]
  def opponents_to_act(%SeatView{} = view) do
    my_team = my_team(view)
    Enum.reject(seats_to_act(view), &(Types.position_to_team(&1) == my_team))
  end

  @doc """
  Returns true when one of `seats` could hold a live trump above `card`.

  A seat with no cards holds nothing, so an empty or card-less list of seats
  can never beat the card.
  """
  @spec beatable_by?(view(), card(), [position()]) :: boolean()
  def beatable_by?(%SeatView{} = view, card, seats) do
    trump = view.trump_suit

    Enum.any?(seats, &(view.players[&1].hand_count > 0)) and
      Enum.any?(unseen_trumps(view), &beats?(&1, card, trump))
  end

  @doc """
  Returns true when no other seat could hold a trump above `card`.
  """
  @spec unbeatable?(view(), card()) :: boolean()
  def unbeatable?(%SeatView{} = view, card) do
    not beatable_by?(view, card, other_active_seats(view))
  end

  @doc """
  Returns true when the viewer's side holds the winning card and no opponent
  still to act could hold a higher trump.
  """
  @spec safe_trick?(view()) :: boolean()
  def safe_trick?(%SeatView{} = view) do
    case current_winner(view) do
      {winner, card} ->
        Types.position_to_team(winner) == my_team(view) and
          not beatable_by?(view, card, opponents_to_act(view))

      nil ->
        false
    end
  end

  @doc """
  Returns true when playing `card` would win the trick for the viewer's side
  and no opponent still to act could beat it.
  """
  @spec safe_after?(view(), card()) :: boolean()
  def safe_after?(%SeatView{} = view, card) do
    wins_trick?(view, card) and not beatable_by?(view, card, opponents_to_act(view))
  end

  @doc """
  Returns true when `card` would beat the card currently winning the trick.
  On an empty trick any card wins.
  """
  @spec wins_trick?(view(), card()) :: boolean()
  def wins_trick?(%SeatView{} = view, card) do
    case current_winner(view) do
      {_winner, winning} -> beats?(card, winning, view.trump_suit)
      nil -> true
    end
  end

  @doc """
  Returns the points the winner of the current trick would take. The 2 of
  trump is left out because its point stays with the side that played it.
  """
  @spec points_on_trick(view()) :: non_neg_integer()
  def points_on_trick(%SeatView{current_trick: %Trick{plays: [_ | _]} = trick} = view) do
    Scorer.score_trick(trick, view.trump_suit).winner_points
  end

  def points_on_trick(%SeatView{}), do: 0

  @doc """
  Returns true when an opponent has played a Five to the current trick.
  """
  @spec opponent_five_on_trick?(view()) :: boolean()
  def opponent_five_on_trick?(%SeatView{} = view) do
    my_team = my_team(view)

    Enum.any?(trick_plays(view), fn {pos, card} ->
      Types.position_to_team(pos) != my_team and five?(card, view.trump_suit)
    end)
  end

  @doc """
  Returns each side's points from the completed tricks of this hand.

  Computed with `Pidro.Finnish.Scorer`, so the 2 of trump counts for the side
  that played it. The engine's running `hand_points` credits it to the trick
  winner and is not used.
  """
  @spec side_points(view()) :: %{Types.team() => non_neg_integer()}
  def side_points(%SeatView{} = view) do
    view.tricks
    |> Enum.map(&Scorer.score_trick(&1, view.trump_suit))
    |> Scorer.aggregate_team_scores()
  end

  @doc """
  Returns the viewer's team.
  """
  @spec my_team(view()) :: Types.team()
  def my_team(%SeatView{position: position}), do: Types.position_to_team(position)

  @doc """
  Returns the viewer's partner.
  """
  @spec partner(view()) :: position()
  def partner(%SeatView{position: position}), do: Types.partner_position(position)

  @doc """
  Returns true when the viewer's team won the bid this hand.
  """
  @spec bidding_side?(view()) :: boolean()
  def bidding_side?(%SeatView{} = view), do: view.bidding_team == my_team(view)

  @doc """
  Returns true when the viewer is to lead the next trick.
  """
  @spec leading?(view()) :: boolean()
  def leading?(%SeatView{} = view), do: trick_plays(view) == []

  @doc """
  Returns true when this is the first trick of the hand.
  """
  @spec opening_trick?(view()) :: boolean()
  def opening_trick?(%SeatView{tricks: tricks}), do: tricks == []

  @doc """
  Returns true when `card` is either Five of the trump colour.

  ## Examples

      iex> Pidro.Bot.Knowledge.five?({5, :diamonds}, :hearts)
      true

      iex> Pidro.Bot.Knowledge.five?({5, :clubs}, :hearts)
      false
  """
  @spec five?(card(), Types.suit()) :: boolean()
  def five?({5, _suit} = card, trump), do: Card.is_trump?(card, trump)
  def five?(_card, _trump), do: false

  @doc """
  Returns true when `card` ranks above `other` in the trump order.
  """
  @spec beats?(card(), card(), Types.suit()) :: boolean()
  def beats?(card, other, trump), do: Card.compare(card, other, trump) == :gt

  @doc """
  Sorts cards from the lowest trump to the highest.

  ## Examples

      iex> Pidro.Bot.Knowledge.sort_ascending([{14, :hearts}, {5, :diamonds}, {2, :hearts}], :hearts)
      [{2, :hearts}, {5, :diamonds}, {14, :hearts}]
  """
  @spec sort_ascending([card()], Types.suit()) :: [card()]
  def sort_ascending(cards, trump), do: Enum.sort(cards, &(Card.compare(&1, &2, trump) != :gt))

  defp trick_plays(%SeatView{current_trick: %Trick{plays: plays}}), do: plays
  defp trick_plays(%SeatView{}), do: []

  defp other_active_seats(%SeatView{position: position, players: players}) do
    for pos <- Types.all_positions(),
        pos != position,
        not players[pos].eliminated?,
        do: pos
  end
end

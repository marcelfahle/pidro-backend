defmodule Pidro.Bot.Bidding do
  @moduledoc """
  How the rulebook bot bids and names trump.

  Each suit gets a point estimate from the nine-card hand, counting the
  same-colour Five as trump (see `Pidro.Bot.Thresholds`). The bot bids its
  best suit's estimate rounded down, passes when that is below the lowest
  legal bid, and lets its partner's standing bid stand unless its own
  estimate clears it by the overbid margin. A dealer forced to bid takes the
  minimum. Declaring trump recomputes the best suit from the current hand, so
  a substitute that inherits an undeclared bid names its own best suit.

  Bidding is conservative on purpose: overbidding is the most-reported
  complaint about computer partners, and a set costs the partner the hand.
  """

  alias Pidro.Bot.Thresholds
  alias Pidro.Core.{Card, SeatView, Types}

  @type decision :: {Types.action(), String.t()}

  @doc """
  Returns the bid estimate of `hand` with `suit` as trump.

  ## Parameters

  - `hand` - the cards held, trump or not
  - `suit` - the candidate trump suit
  - `dealer?` - whether the bidder is the dealer, who robs the pack

  ## Examples

      iex> hand = [{11, :hearts}, {10, :hearts}, {7, :hearts}, {6, :hearts}, {5, :hearts}]
      iex> Pidro.Bot.Bidding.estimate(hand, :hearts, false)
      4.0
  """
  @spec estimate([Types.card()], Types.suit(), boolean()) :: float()
  def estimate(hand, suit, dealer?) do
    trumps = Enum.filter(hand, &Card.is_trump?(&1, suit))
    honours = {{14, suit} in trumps, {13, suit} in trumps}

    (sure_points(trumps, suit) + half_credit(trumps, suit) + fives(trumps, honours) +
       control(trumps, honours) + if(dealer?, do: t(:dealer_bonus), else: 0)) * 1.0
  end

  @doc """
  Returns the best suit for `hand` and its estimate.

  Equal estimates resolve in the fixed suit order hearts, diamonds, clubs,
  spades, the same order the timer auto-play uses.

  ## Examples

      iex> Pidro.Bot.Bidding.best_suit([{14, :spades}, {13, :spades}, {5, :spades}], false)
      {:spades, 7.0}
  """
  @spec best_suit([Types.card()], boolean()) :: {Types.suit(), float()}
  def best_suit(hand, dealer?) do
    Types.all_suits()
    |> Enum.map(&{&1, estimate(hand, &1, dealer?)})
    |> Enum.reduce(fn {_suit, est} = candidate, {_best, best_est} = best ->
      if est > best_est, do: candidate, else: best
    end)
  end

  @doc """
  Chooses a bid or a pass from `legal` for the seat in `view`.

  ## Returns

  `{action, reason}` where `action` is a member of `legal`.
  """
  @spec decide_bid(SeatView.t(), [Types.action()]) :: decision()
  def decide_bid(%SeatView{} = view, legal) do
    dealer? = view.state.current_dealer == view.position
    {suit, est} = best_suit(own_hand(view), dealer?)
    bids = for {:bid, amount} <- legal, do: amount
    worth = "#{suit_name(suit)} are worth about #{trunc(est)} points"

    cond do
      bids == [] ->
        {:pass, "No higher bid is left, so I pass."}

      :pass not in legal ->
        min = Enum.min(bids)
        {{:bid, min}, "Everyone passed, so as dealer I must bid and take the minimum #{min}."}

      partner_bid = partner_standing_bid(view) ->
        margin = t(:overbid_partner_margin)

        if est >= partner_bid + margin do
          bid(est, bids, "#{worth}, well above partner's #{partner_bid}")
        else
          {:pass, "Partner's #{partner_bid} stands, and my #{worth}, not enough to go over it."}
        end

      trunc(est) < Enum.min(bids) ->
        {:pass,
         "My best suit is not enough: #{worth}, below the #{Enum.min(bids)} needed, so I pass."}

      true ->
        bid(est, bids, worth)
    end
  end

  @doc """
  Names trump from `legal` for the seat in `view`: the best suit of the hand
  it holds now.

  ## Returns

  `{action, reason}` where `action` is a member of `legal`.
  """
  @spec decide_trump(SeatView.t(), [Types.action()]) :: decision()
  def decide_trump(%SeatView{} = view, legal) do
    dealer? = view.state.current_dealer == view.position
    {suit, est} = best_suit(own_hand(view), dealer?)

    if {:declare_trump, suit} in legal do
      {{:declare_trump, suit},
       "I name #{suit_name(suit)}, my strongest suit at about #{trunc(est)} points."}
    else
      {hd(legal), "My strongest suit cannot be named, so I take the first one offered."}
    end
  end

  defp bid(est, bids, worth) do
    amount = est |> trunc() |> min(Enum.max(bids))
    {{:bid, amount}, "#{worth}, so I bid #{amount}."}
  end

  defp partner_standing_bid(%SeatView{} = view) do
    case view.state.highest_bid do
      {pos, amount} -> if pos == Types.partner_position(view.position), do: amount
      nil -> nil
    end
  end

  defp sure_points(trumps, suit) do
    if({14, suit} in trumps, do: t(:ace), else: 0) + if({2, suit} in trumps, do: t(:two), else: 0)
  end

  defp half_credit(trumps, suit) do
    t(:jack_or_ten) * Enum.count([{11, suit}, {10, suit}], &(&1 in trumps))
  end

  defp fives(trumps, {ace?, king?}) do
    value = five_value(length(trumps), ace? or king?)
    value * Enum.count(trumps, &match?({5, _}, &1))
  end

  defp control(trumps, honours) do
    case honours do
      {true, true} ->
        t(:control_ace_king)

      {false, false} ->
        0

      _one ->
        if length(trumps) >= t(:control_one_honour_min_trumps),
          do: t(:control_one_honour),
          else: 0
    end
  end

  defp five_value(trump_count, honour?) do
    protected? =
      trump_count >= t(:five_protection_trumps) or
        (honour? and trump_count >= t(:five_protection_trumps_with_honour))

    if protected?, do: t(:five_protected), else: t(:five_unprotected)
  end

  defp own_hand(%SeatView{position: position, state: state}), do: state.players[position].hand

  defp suit_name(suit), do: Types.suit_to_name(suit)

  defp t(name), do: Thresholds.get(name)
end

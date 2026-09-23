defmodule Pidro.Bot.Rulebook do
  @moduledoc """
  The rulebook bot: one entry point from a seat view to a legal move.

  `decide/2` dispatches on the phase to `Pidro.Bot.Bidding` or
  `Pidro.Bot.Play` and returns the action with a one-sentence reason. It is
  deterministic: the same view and legal actions always give the same move
  and reason, and no rule draws a random number.

  Every decision is guarded. If the legal actions have a shape the rules do
  not expect, a rule raises, or a rule returns a move that is not legal, the
  bot falls back to the safest legal move (`fallback/2`): it passes, or plays
  its lowest non-point card, never a random one.

  The dealer's rob and the kill stay with the engine's own selection, so in
  `:second_deal` the `{:select_hand, :choose_6_cards}` marker is returned
  unchanged for the caller to resolve.
  """

  alias Pidro.Bot.{Bidding, Play}
  alias Pidro.Core.{SeatView, Types}

  @type decision :: {Types.action(), String.t()}

  @doc """
  Chooses a move for the seat in `view` from the non-empty list `legal`.

  ## Returns

  `{action, reason}`, where `action` is a member of `legal` and `reason` is
  one plain-language sentence.
  """
  @spec decide(SeatView.t(), [Types.action(), ...]) :: decision()
  def decide(%SeatView{} = view, [_ | _] = legal) do
    phase = view.state.phase

    if Enum.all?(legal, &expected_shape?(phase, &1)) do
      view |> dispatch(phase, legal) |> ensure_legal(view, legal)
    else
      fallback(view, legal, "I did not recognise the moves on offer")
    end
  rescue
    error ->
      kind = error.__struct__ |> Module.split() |> List.last()
      fallback(view, legal, "A rule failed on this position (#{kind})")
  end

  @doc """
  Returns the safest legal move: pass if allowed, otherwise the lowest
  non-point card, the minimum bid, or the first move offered.

  Used when no rule applies, and by callers whose own strategy failed.
  """
  @spec fallback(SeatView.t(), [Types.action(), ...]) :: decision()
  def fallback(%SeatView{} = view, [_ | _] = legal) do
    fallback(view, legal, "No rule applied")
  end

  defp fallback(view, legal, why) do
    cards = for {:play_card, card} <- legal, do: card
    bids = for {:bid, amount} <- legal, is_integer(amount), do: amount

    cond do
      :pass in legal ->
        {:pass, "#{why}, so I pass."}

      cards != [] and view.state.trump_suit != nil ->
        card = cards |> Play.discard_order(view.state.trump_suit) |> hd()

        {{:play_card, card},
         "#{why}, so I play my lowest card, the #{Types.card_to_string(card)}."}

      bids != [] ->
        {{:bid, Enum.min(bids)}, "#{why}, so I make the minimum bid."}

      true ->
        {hd(legal), "#{why}, so I take the first move offered."}
    end
  end

  defp dispatch(_view, _phase, [:select_dealer]), do: {:select_dealer, "I cut for dealer."}

  defp dispatch(_view, :second_deal, [{:select_hand, :choose_6_cards} = marker]) do
    {marker, "The engine keeps my best six cards from the pack."}
  end

  defp dispatch(view, :bidding, legal), do: Bidding.decide_bid(view, legal)
  defp dispatch(view, :declaring, legal), do: Bidding.decide_trump(view, legal)
  defp dispatch(view, :playing, legal), do: Play.decide(view, legal)
  defp dispatch(view, _phase, legal), do: fallback(view, legal)

  defp ensure_legal({action, reason} = decision, view, legal) do
    if action in legal and is_binary(reason) and reason != "" do
      decision
    else
      fallback(view, legal, "My rules suggested a move that is not allowed")
    end
  end

  defp expected_shape?(:dealer_selection, :select_dealer), do: true
  defp expected_shape?(:bidding, :pass), do: true
  defp expected_shape?(:bidding, {:bid, amount}) when is_integer(amount), do: true
  defp expected_shape?(:declaring, {:declare_trump, suit}), do: suit in Types.all_suits()
  defp expected_shape?(:second_deal, {:select_hand, :choose_6_cards}), do: true

  defp expected_shape?(:playing, {:play_card, {rank, suit}}),
    do: rank in 2..14 and suit in Types.all_suits()

  defp expected_shape?(_phase, _action), do: false
end

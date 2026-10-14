defmodule Pidro.Rules.Finnish do
  @moduledoc "Finnish play: only trumps, highest trump wins, no trumps means going cold."
  @behaviour Pidro.Rules

  alias Pidro.Core.{Card, Types}

  @doc "All trumps in hand, including the same-colour left five, in hand order."
  @impl true
  @spec legal_plays([Types.card()], Types.suit(), Types.suit() | nil) :: [Types.card()]
  def legal_plays(hand, trump, _led_suit), do: Enum.filter(hand, &Card.is_trump?(&1, trump))

  @doc "The highest trump wins; ties retain the first play."
  @impl true
  @spec winner([{Types.position(), Types.card()}, ...], Types.suit()) :: Types.position()
  def winner(plays, trump) do
    {position, _card} =
      Enum.reduce(plays, fn {_position, card} = play, {_winner, best} = winning ->
        if Card.compare(card, best, trump) == :gt, do: play, else: winning
      end)

    position
  end

  @doc "A hand without trumps is eliminated, including an empty hand."
  @impl true
  @spec eliminate?([Types.card()], Types.suit()) :: boolean()
  def eliminate?(hand, trump), do: not Enum.any?(hand, &Card.is_trump?(&1, trump))
end

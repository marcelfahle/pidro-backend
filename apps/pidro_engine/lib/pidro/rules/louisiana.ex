defmodule Pidro.Rules.Louisiana do
  @moduledoc "Louisiana play: follow suit or trump, with all four players in every trick."
  @behaviour Pidro.Rules

  alias Pidro.Core.{Card, Types}
  alias Pidro.Rules.Finnish

  @doc "Follow the effective led suit or trump; with neither, any card is legal."
  @impl true
  @spec legal_plays([Types.card()], Types.suit(), Types.suit() | nil) :: [Types.card()]
  def legal_plays(hand, _trump, nil), do: hand

  def legal_plays(hand, trump, led_suit) do
    following =
      Enum.filter(hand, fn {_rank, suit} = card ->
        Card.is_trump?(card, trump) or suit == led_suit
      end)

    if following == [], do: hand, else: following
  end

  @doc "Highest trump wins; without trumps, highest card of the led suit wins."
  @impl true
  @spec winner([{Types.position(), Types.card()}, ...], Types.suit()) :: Types.position()
  def winner([{_leader, {_rank, led_suit}} | _] = plays, trump) do
    case Enum.filter(plays, fn {_position, card} -> Card.is_trump?(card, trump) end) do
      [] ->
        {position, _card} =
          plays
          |> Enum.filter(fn {_position, {_rank, suit}} -> suit == led_suit end)
          |> Enum.max_by(fn {_position, {rank, _suit}} -> rank end)

        position

      trumps ->
        Finnish.winner(trumps, trump)
    end
  end

  @doc "Louisiana players never go cold, even when their hand has no trumps."
  @impl true
  @spec eliminate?([Types.card()], Types.suit()) :: boolean()
  def eliminate?(_hand, _trump), do: false
end

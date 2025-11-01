defmodule Pidro.Generators do
  @moduledoc """
  StreamData generators for property-based testing of Pidro game components.
  """

  use ExUnitProperties

  @doc """
  Generates valid card ranks for Pidro.
  """
  def rank do
    StreamData.member_of([:ace, :two, :three, :four, :five, :six, :seven, :eight, :nine, :ten, :jack, :queen, :king])
  end

  @doc """
  Generates valid card suits.
  """
  def suit do
    StreamData.member_of([:hearts, :diamonds, :clubs, :spades])
  end

  @doc """
  Generates a valid card.
  """
  def card do
    StreamData.tuple({rank(), suit()})
  end

  @doc """
  Generates a list of unique cards.
  """
  def cards(opts \\ []) do
    min_length = Keyword.get(opts, :min_length, 0)
    max_length = Keyword.get(opts, :max_length, 52)

    StreamData.uniq_list_of(card(), min_length: min_length, max_length: max_length)
  end

  @doc """
  Generates a valid hand of cards (9 cards for Pidro).
  """
  def hand do
    cards(min_length: 9, max_length: 9)
  end

  @doc """
  Generates a valid bid value.
  """
  def bid do
    StreamData.integer(5..14)
  end

  @doc """
  Generates a player ID.
  """
  def player_id do
    StreamData.member_of([:north, :south, :east, :west])
  end

  @doc """
  Generates a team ID.
  """
  def team_id do
    StreamData.member_of([:team1, :team2])
  end

  @doc """
  Generates a trump suit.
  """
  def trump_suit do
    suit()
  end
end

defmodule Pidro.Core.Trick do
  @moduledoc """
  Trick operations for the Pidro game engine.

  A trick represents a single round of play where each active player plays one card.
  The highest trump card wins the trick and collects the points, with special handling
  for the 2 of trump.

  ## Finnish Pidro Trick Rules

  ### Play Order
  - The leader plays first
  - Play continues clockwise from the leader
  - Each active (non-eliminated) player must play a trump card
  - The highest trump card wins the trick

  ### Trump Ranking (Highest to Lowest)
  A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2

  ### Special 2 of Trump Rule
  The 2 of trump has a unique scoring property:
  - The player who plays the 2 of trump always keeps 1 point
  - This point is NOT awarded to the trick winner
  - The trick winner gets all other points in the trick

  ### Point Distribution Example
  If a trick contains: A (1), 10 (1), 7 (0), 2 (1)
  - Total trick value: 3 points
  - Player who played 2: gets 1 point
  - Trick winner: gets 2 points (A + 10)

  ## Examples

      iex> alias Pidro.Core.Trick
      iex> trick = Trick.new(:north)
      iex> trick = Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Trick.add_play(trick, :east, {10, :hearts})
      iex> Trick.winner(trick, :hearts)
      {:ok, :north}

      iex> alias Pidro.Core.Trick
      iex> trick = Trick.new(:south)
      iex> trick = Trick.add_play(trick, :south, {5, :hearts})  # Right 5
      iex> trick = Trick.add_play(trick, :west, {5, :diamonds})  # Wrong 5
      iex> Trick.winner(trick, :hearts)
      {:ok, :south}  # Right 5 beats Wrong 5

      iex> alias Pidro.Core.Trick
      iex> trick = Trick.new(:north)
      iex> trick = Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Trick.add_play(trick, :east, {11, :hearts})
      iex> trick = Trick.add_play(trick, :south, {10, :hearts})
      iex> trick = Trick.add_play(trick, :west, {2, :hearts})
      iex> Trick.points(trick, :hearts)
      3  # A(1) + J(1) + 10(1) + 2(1) = 4, but 2 is kept by player, so 3 to winner
  """

  use TypedStruct

  alias Pidro.Core.{Card, Types}

  @type position :: Types.position()
  @type card :: Types.card()
  @type suit :: Types.suit()

  # =============================================================================
  # Struct Definition
  # =============================================================================

  typedstruct do
    field(:leader, Types.position(), enforce: true)
    field(:plays, [{Types.position(), Types.card()}], default: [])
  end

  # =============================================================================
  # Trick Creation
  # =============================================================================

  @doc """
  Creates a new empty trick with the given leader.

  The leader is the first player to play a card in this trick.

  ## Parameters
  - `leader` - Position of the player who will lead this trick

  ## Returns
  A new `Trick.t()` struct

  ## Examples

      iex> Pidro.Core.Trick.new(:north)
      %Pidro.Core.Trick{leader: :north, plays: []}
  """
  @spec new(position()) :: t()
  def new(leader) when leader in [:north, :east, :south, :west] do
    %__MODULE__{
      leader: leader,
      plays: []
    }
  end

  # =============================================================================
  # Play Management
  # =============================================================================

  @doc """
  Adds a card play to the trick.

  Appends a {position, card} tuple to the list of plays.
  Does not validate if the play is legal - validation should be done
  by the game engine before calling this function.

  ## Parameters
  - `trick` - The current trick
  - `position` - Position of the player making the play
  - `card` - The card being played

  ## Returns
  Updated `Trick.t()` with the new play added

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick.plays
      [{:north, {14, :hearts}}]

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {10, :hearts})
      iex> length(trick.plays)
      2
  """
  @spec add_play(t(), position(), card()) :: t()
  def add_play(%__MODULE__{plays: plays} = trick, position, card)
      when position in [:north, :east, :south, :west] do
    %{trick | plays: plays ++ [{position, card}]}
  end

  # =============================================================================
  # Trick Resolution
  # =============================================================================

  @doc """
  Determines the winner of the trick.

  The winner is the player who played the highest trump card,
  following the Finnish Pidro trump ranking:
  A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2

  Where:
  - Right 5: The 5 of the trump suit
  - Wrong 5: The 5 of the same-color suit

  ## Parameters
  - `trick` - The trick to evaluate
  - `trump_suit` - The declared trump suit

  ## Returns
  - `{:ok, position}` - Position of the winning player
  - `{:error, :incomplete_trick}` - If the trick has no plays yet

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {13, :hearts})
      iex> Pidro.Core.Trick.winner(trick, :hearts)
      {:ok, :north}

      iex> trick = Pidro.Core.Trick.new(:south)
      iex> trick = Pidro.Core.Trick.add_play(trick, :south, {5, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :west, {5, :diamonds})
      iex> Pidro.Core.Trick.winner(trick, :hearts)
      {:ok, :south}  # Right 5 beats Wrong 5

      iex> trick = Pidro.Core.Trick.new(:east)
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {2, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :south, {4, :hearts})
      iex> Pidro.Core.Trick.winner(trick, :hearts)
      {:ok, :south}  # 4 beats 2
  """
  @spec winner(t(), suit()) :: {:ok, position()} | {:error, :incomplete_trick}
  def winner(%__MODULE__{plays: []}, _trump_suit) do
    {:error, :incomplete_trick}
  end

  def winner(%__MODULE__{plays: plays}, trump_suit) do
    {winning_position, _winning_card} =
      plays
      |> Enum.max_by(fn {_position, card} ->
        # Use Card.compare to determine the highest card
        # We need a numeric ranking for max_by
        card_ranking(card, trump_suit)
      end)

    {:ok, winning_position}
  end

  @doc """
  Calculates the total points awarded to the trick winner.

  This function handles the special 2 of trump rule:
  - The player who played the 2 of trump keeps 1 point
  - The trick winner receives all other points in the trick

  ## Point Values (in trump suit only)
  - Ace: 1 point
  - Jack: 1 point
  - 10: 1 point
  - Right 5 (5 of trump): 5 points
  - Wrong 5 (5 of same-color suit): 5 points
  - 2: 1 point (but kept by player who played it)
  - All other cards: 0 points

  ## Parameters
  - `trick` - The completed trick
  - `trump_suit` - The declared trump suit

  ## Returns
  Integer representing total points for the trick winner (0-14)

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {11, :hearts})
      iex> Pidro.Core.Trick.points(trick, :hearts)
      2  # Ace (1) + Jack (1)

      iex> trick = Pidro.Core.Trick.new(:south)
      iex> trick = Pidro.Core.Trick.add_play(trick, :south, {5, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :west, {10, :hearts})
      iex> Pidro.Core.Trick.points(trick, :hearts)
      6  # Right 5 (5) + Ten (1)

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {2, :hearts})
      iex> Pidro.Core.Trick.points(trick, :hearts)
      1  # Ace (1), but 2 kept by player who played it

      iex> trick = Pidro.Core.Trick.new(:east)
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {7, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :south, {9, :hearts})
      iex> Pidro.Core.Trick.points(trick, :hearts)
      0  # No point cards
  """
  @spec points(t(), suit()) :: 0..14
  def points(%__MODULE__{plays: plays}, trump_suit) do
    plays
    |> Enum.map(fn {_position, card} -> Card.point_value(card, trump_suit) end)
    |> Enum.sum()
    |> subtract_two_of_trump(plays, trump_suit)
  end

  # =============================================================================
  # Utility Functions
  # =============================================================================

  @doc """
  Returns the number of plays in the trick.

  ## Parameters
  - `trick` - The trick to count

  ## Returns
  Integer representing the number of card plays

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> Pidro.Core.Trick.play_count(trick)
      0

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {10, :hearts})
      iex> Pidro.Core.Trick.play_count(trick)
      2
  """
  @spec play_count(t()) :: non_neg_integer()
  def play_count(%__MODULE__{plays: plays}) do
    length(plays)
  end

  @doc """
  Checks if the trick is complete (has 4 plays).

  ## Parameters
  - `trick` - The trick to check

  ## Returns
  `true` if trick has 4 plays, `false` otherwise

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> Pidro.Core.Trick.complete?(trick)
      false

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {10, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :south, {7, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :west, {3, :hearts})
      iex> Pidro.Core.Trick.complete?(trick)
      true
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{plays: plays}) do
    length(plays) == 4
  end

  @doc """
  Returns the card played by a specific position in the trick.

  ## Parameters
  - `trick` - The trick to search
  - `position` - The position to find

  ## Returns
  - `{:ok, card}` if the position has played
  - `{:error, :not_found}` if the position hasn't played yet

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> Pidro.Core.Trick.card_played_by(trick, :north)
      {:ok, {14, :hearts}}

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> Pidro.Core.Trick.card_played_by(trick, :east)
      {:error, :not_found}
  """
  @spec card_played_by(t(), position()) :: {:ok, card()} | {:error, :not_found}
  def card_played_by(%__MODULE__{plays: plays}, position) do
    case Enum.find(plays, fn {pos, _card} -> pos == position end) do
      {_position, card} -> {:ok, card}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Returns the positions that have played in this trick.

  ## Parameters
  - `trick` - The trick to analyze

  ## Returns
  List of positions that have played

  ## Examples

      iex> trick = Pidro.Core.Trick.new(:north)
      iex> trick = Pidro.Core.Trick.add_play(trick, :north, {14, :hearts})
      iex> trick = Pidro.Core.Trick.add_play(trick, :east, {10, :hearts})
      iex> Pidro.Core.Trick.positions_played(trick)
      [:north, :east]
  """
  @spec positions_played(t()) :: [position()]
  def positions_played(%__MODULE__{plays: plays}) do
    Enum.map(plays, fn {position, _card} -> position end)
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Returns a numeric ranking for a card to use with Enum.max_by
  # Higher numbers mean better cards
  @spec card_ranking(card(), suit()) :: float()
  defp card_ranking(card, trump_suit) do
    {rank, card_suit} = card

    cond do
      # Not a trump card: very low ranking
      not Card.is_trump?(card, trump_suit) ->
        -1000.0

      # Ace of trump: highest rank
      rank == 14 and card_suit == trump_suit ->
        14.0

      # King, Queen, Jack, 10, 9, 8, 7, 6 of trump: standard ranks
      rank in [13, 12, 11, 10, 9, 8, 7, 6] and card_suit == trump_suit ->
        rank * 1.0

      # Right 5 (5 of trump suit): ranks between 6 and wrong 5
      rank == 5 and card_suit == trump_suit ->
        5.0

      # Wrong 5 (5 of same-color suit): ranks just below Right 5
      rank == 5 and card_suit == Card.same_color_suit(trump_suit) ->
        4.5

      # 4 of trump: ranks below Wrong 5
      rank == 4 and card_suit == trump_suit ->
        4.0

      # 3 of trump
      rank == 3 and card_suit == trump_suit ->
        3.0

      # 2 of trump: lowest rank
      rank == 2 and card_suit == trump_suit ->
        2.0

      # Default case
      true ->
        0.0
    end
  end

  # Subtracts 1 point if the 2 of trump was played in this trick
  # The player who played the 2 keeps that point, not the trick winner
  @spec subtract_two_of_trump(non_neg_integer(), [{position(), card()}], suit()) ::
          non_neg_integer()
  defp subtract_two_of_trump(total_points, plays, trump_suit) do
    has_two_of_trump? =
      Enum.any?(plays, fn {_position, {rank, suit}} ->
        rank == 2 and suit == trump_suit
      end)

    if has_two_of_trump? do
      max(total_points - 1, 0)
    else
      total_points
    end
  end
end

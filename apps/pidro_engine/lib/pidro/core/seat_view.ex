defmodule Pidro.Core.SeatView do
  @moduledoc """
  What one seat is allowed to know about a game.

  A seat view is the only input a bot strategy may decide from. It holds the
  viewer's position, a redacted `GameState`, how many cards each seat holds,
  and the cards killed this hand.

  The redacted state keeps the `GameState` shape so engine helpers such as
  `Pidro.Game.Play.determine_trick_winner/2` and `Pidro.Finnish.Scorer` run on
  it unchanged. It is built from an allow-list of public fields, so a field
  added to `GameState` later stays hidden until it is added here on purpose.

  ## What a seat can see

  - Its own hand.
  - Bids, trump, tricks played, the current trick, and the scores.
  - How many cards each non-dealer drew in the second deal (`cards_requested`).
  - Cards revealed by a player who went cold, and cards killed this hand.
  - How many cards every seat holds.
  - The dealer's rob pool, but only for the dealer during a manual rob.

  ## What stays hidden

  Other seats' hands, the deck, the discards, the dealer's pool size, and the
  raw event log. The event log carries every dealt, second-dealt and discarded
  card and is never reset between hands, so no part of it is exposed.
  """

  use TypedStruct

  alias Pidro.Core.Types
  alias Pidro.Core.Types.{GameState, Player}

  typedstruct do
    field(:position, Types.position(), enforce: true)
    field(:state, GameState.t(), enforce: true)
    field(:hand_counts, %{Types.position() => non_neg_integer()}, enforce: true)
    field(:killed_cards, %{Types.position() => [Types.card()]}, enforce: true)
  end

  @doc """
  Builds the view of `state` from the seat at `position`.

  ## Parameters

  - `state` - The full, authoritative game state
  - `position` - The seat whose view to build

  ## Returns

  A `SeatView` whose `state` holds only public fields and the viewer's own
  hand. The redacted state's `killed_cards` holds the kills of the current
  hand (see `killed_cards/1`).

  ## Examples

      iex> state = Pidro.Core.GameState.new()
      iex> view = Pidro.Core.SeatView.for_seat(state, :north)
      iex> view.position
      :north
      iex> view.state.events
      []
  """
  @spec for_seat(GameState.t(), Types.position()) :: t()
  def for_seat(%GameState{} = state, position)
      when position in [:north, :east, :south, :west] do
    killed = killed_cards(state)

    redacted = %GameState{
      phase: state.phase,
      hand_number: state.hand_number,
      variant: state.variant,
      players:
        Map.new(state.players, fn {pos, player} ->
          {pos, redact_player(player, pos == position)}
        end),
      current_dealer: state.current_dealer,
      current_turn: state.current_turn,
      dealer_selection_cuts: state.dealer_selection_cuts,
      deck: visible_deck(state, position),
      discarded_cards: [],
      bids: state.bids,
      highest_bid: state.highest_bid,
      bidding_team: state.bidding_team,
      trump_suit: state.trump_suit,
      cards_requested: state.cards_requested,
      dealer_pool_size: nil,
      killed_cards: killed,
      tricks: state.tricks,
      current_trick: state.current_trick,
      trick_number: state.trick_number,
      hand_points: state.hand_points,
      cumulative_scores: state.cumulative_scores,
      winner: state.winner,
      events: [],
      config: state.config,
      cache: %{}
    }

    %__MODULE__{
      position: position,
      state: redacted,
      hand_counts: Map.new(state.players, fn {pos, player} -> {pos, length(player.hand)} end),
      killed_cards: killed
    }
  end

  @doc """
  Returns the cards each seat killed in the current hand.

  The engine's `killed_cards` field is recomputed after every play and is
  empty from the second card of a hand onward, so this reads the
  `:cards_killed` events instead. It takes, per seat, the first non-empty
  entry recorded since the hand's `:cards_dealt` event.

  ## Parameters

  - `state` - The full game state

  ## Returns

  A map of position to killed cards; seats that killed nothing are absent.

  ## Examples

      iex> Pidro.Core.SeatView.killed_cards(Pidro.Core.GameState.new())
      %{}
  """
  @spec killed_cards(GameState.t()) :: %{Types.position() => [Types.card()]}
  def killed_cards(%GameState{events: events}) do
    events
    |> current_hand_events()
    |> Enum.reduce(%{}, fn
      {:cards_killed, kills}, acc ->
        Enum.reduce(kills, acc, fn
          {_pos, []}, inner -> inner
          {pos, cards}, inner -> Map.put_new(inner, pos, cards)
        end)

      _event, acc ->
        acc
    end)
  end

  # Events after the last deal, oldest first. Every hand starts with one
  # `:cards_dealt` event, including hands after the first.
  defp current_hand_events(events) do
    events
    |> Enum.reverse()
    |> Enum.take_while(&(not match?({:cards_dealt, _}, &1)))
    |> Enum.reverse()
  end

  defp redact_player(%Player{} = player, own_seat?) do
    %Player{
      position: player.position,
      team: player.team,
      hand: if(own_seat?, do: player.hand, else: []),
      eliminated?: player.eliminated?,
      revealed_cards: player.revealed_cards,
      tricks_won: player.tricks_won
    }
  end

  # Under manual rob the dealer picks six cards from their hand plus the deck,
  # so the dealer sees the deck while choosing. Nobody else ever does.
  defp visible_deck(%GameState{phase: :second_deal, current_dealer: dealer} = state, dealer) do
    if Map.get(state.config, :auto_dealer_rob, true), do: [], else: state.deck
  end

  defp visible_deck(_state, _position), do: []
end

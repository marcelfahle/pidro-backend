defmodule Pidro.Core.Binary do
  @moduledoc """
  Compact, lossy binary encoding and decoding for game positions.

  This module provides efficient binary representations of game state components
  for performance-critical operations. Inspired by chess bitboards and binary
  protocols, it uses compact binary encoding to minimize memory usage and
  enable fast serialization/deserialization.

  ## Design

  - Cards: 6 bits (4 bits for rank 2-14, 2 bits for suit)
  - Hands: Variable length based on card count
  - Game position: variable length based on cards held

  ## Performance

  Binary encoding is particularly useful for:
  - Fast state hashing for caching
  - Network transmission
  - Comparing the encoded subset of states for equality

  ## Not a resume format

  This format is lossy by design: it carries phase, hand number, current dealer
  and turn, each player's hand and eliminated flag, deck, trump, highest bid,
  and cumulative scores, and nothing else. It does not carry revealed cards,
  tricks won, the bid or trick history, the event log, redeal state,
  dealer-selection cuts, the winner, the game's config, or the chance stream.
  A state from `from_binary/1` therefore has
  `chance: nil` and cannot cross a transition that draws — it is a compact
  fingerprint of a position, not a saved game. To save and resume a game, use
  `:erlang.term_to_binary/1` on the `%GameState{}` itself, which preserves
  chance.

  ## Usage

      # Encode a card
      binary = Binary.encode_card({14, :hearts})

      # Encode a hand
      hand_binary = Binary.encode_hand([{14, :hearts}, {13, :hearts}])

      # Encode the compact, lossy position
      state_binary = Binary.to_binary(state)
  """

  alias Pidro.Core.Types
  alias Pidro.Core.Types.{GameState, Player}

  # =============================================================================
  # Card Encoding/Decoding
  # =============================================================================

  @doc """
  Encodes a card as a 6-bit binary.

  ## Binary Format
  - Bits 0-3: Rank (2-14) stored as (rank - 2), giving 0-12
  - Bits 4-5: Suit (hearts=0, diamonds=1, clubs=2, spades=3)

  ## Examples

      iex> Binary.encode_card({14, :hearts})
      <<0b001100::6>>

      iex> Binary.encode_card({2, :spades})
      <<0b110000::6>>
  """
  @spec encode_card(Types.card()) :: <<_::6>>
  def encode_card({rank, suit}) when rank >= 2 and rank <= 14 do
    rank_bits = rank - 2
    suit_bits = encode_suit(suit)
    <<rank_bits::4, suit_bits::2>>
  end

  @doc """
  Decodes a 6-bit binary back to a card.

  ## Examples

      iex> Binary.decode_card(<<0b001100::6>>)
      {:ok, {14, :hearts}}

      iex> Binary.decode_card(<<0b110011::6>>)
      {:ok, {2, :spades}}
  """
  @spec decode_card(<<_::6>>) :: {:ok, Types.card()} | {:error, :invalid_binary}
  def decode_card(<<rank_bits::4, suit_bits::2>>) when rank_bits <= 12 do
    with {:ok, suit} <- decode_suit(suit_bits) do
      rank = rank_bits + 2
      {:ok, {rank, suit}}
    end
  rescue
    _ -> {:error, :invalid_binary}
  end

  def decode_card(_), do: {:error, :invalid_binary}

  # =============================================================================
  # Hand Encoding/Decoding
  # =============================================================================

  @doc """
  Encodes a hand (list of cards) as binary.

  ## Binary Format
  - First byte: Number of cards (0-255)
  - Remaining bytes: Concatenated card encodings

  ## Examples

      iex> Binary.encode_hand([{14, :hearts}, {13, :hearts}])
      <<2, 0b001100::6, 0b001011::6>>
  """
  @spec encode_hand([Types.card()]) :: bitstring()
  def encode_hand(cards) when is_list(cards) and length(cards) <= 255 do
    card_count = length(cards)

    # Encode each card into 6 bits and concatenate them into a single binary
    cards_binary =
      cards
      |> Enum.map(&encode_card/1)
      |> Enum.reduce(<<>>, fn <<bits::6>>, acc ->
        <<acc::bitstring, bits::6>>
      end)

    <<card_count::8, cards_binary::bitstring>>
  end

  @doc """
  Decodes a binary back to a hand (list of cards).

  ## Examples

      iex> binary = Binary.encode_hand([{14, :hearts}, {13, :hearts}])
      iex> Binary.decode_hand(binary)
      {:ok, [{14, :hearts}, {13, :hearts}]}
  """
  @spec decode_hand(bitstring()) :: {:ok, [Types.card()]} | {:error, :invalid_binary}
  def decode_hand(bitstring) do
    case decode_hand_prefix(bitstring) do
      {:ok, cards, <<>>} -> {:ok, cards}
      _ -> {:error, :invalid_binary}
    end
  end

  defp decode_hand_prefix(<<card_count::8, rest::bitstring>>) do
    decode_cards(rest, card_count, [])
  end

  defp decode_hand_prefix(_), do: {:error, :invalid_binary}

  # Helper for decoding multiple cards
  defp decode_cards(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_cards(<<card_bits::6, rest::bitstring>>, count, acc) when count > 0 do
    case decode_card(<<card_bits::6>>) do
      {:ok, card} -> decode_cards(rest, count - 1, [card | acc])
      error -> error
    end
  end

  defp decode_cards(_, _, _), do: {:error, :invalid_binary}

  # =============================================================================
  # Game State Encoding/Decoding
  # =============================================================================

  @doc """
  Encodes the supported subset of a game state as a compact bitstring.

  The format supports hand numbers from 0 to 255, card lists containing at
  most 255 cards, and cumulative scores from -32,768 to 32,767. Values outside
  those ranges cannot be represented. See "Not a resume format" for the state
  fields deliberately omitted from the format.

  ## Binary Format

  The binary format includes:
  1. Phase (4 bits)
  2. Hand number (8 bits)
  3. Current dealer and turn (6 bits)
  4. Bidding state (variable)
  5. Trump suit (3 bits, includes nil option)
  6. Player hands and eliminated flags (variable)
  7. Deck (variable)
  8. Scores (32 bits)

  ## Returns

  Bitstring representation of the supported fields.

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> binary = Binary.to_binary(state)
      iex> is_bitstring(binary)
      true

  The output is a bitstring and is not necessarily byte-aligned.
  """
  @spec to_binary(GameState.t()) :: bitstring()
  def to_binary(%GameState{} = state) do
    phase_bits = encode_phase(state.phase)
    hand_number = state.hand_number
    {dealer_bits, turn_bits} = encode_positions(state.current_dealer, state.current_turn)
    bid_binary = encode_bid_state(state.highest_bid)
    trump_bits = encode_trump_suit(state.trump_suit)

    # Encode players
    players_binary =
      [:north, :east, :south, :west]
      |> Enum.reduce(<<>>, fn pos, acc ->
        player_binary = encode_player(state.players[pos])
        <<acc::bitstring, player_binary::bitstring>>
      end)

    # Encode deck
    deck_binary = encode_hand(state.deck)

    # Encode scores
    ns_score = state.cumulative_scores[:north_south]
    ew_score = state.cumulative_scores[:east_west]

    <<
      phase_bits::4,
      hand_number::8,
      dealer_bits::3,
      turn_bits::3,
      trump_bits::3,
      bid_binary::bitstring,
      players_binary::bitstring,
      deck_binary::bitstring,
      ns_score::signed-16,
      ew_score::signed-16
    >>
  end

  @doc """
  Decodes a binary back into a partial game state.

  The result carries only what `to_binary/1` encodes. Everything else is
  reset to the `%GameState{}` defaults, including no bids, no tricks, no hand
  points, no event log, no dealer-selection cuts, the default config in place
  of the original's, and `chance: nil`. See "Not a resume format" in the
  module documentation — a decoded state cannot be played across a transition
  that draws.

  ## Parameters

  - `binary` - Bitstring representation of a game state

  ## Returns

  - `{:ok, game_state}` if decoding succeeds
  - `{:error, reason}` if the binary is invalid

  Decoding never generates entropy or invents a default chance value. Use
  `:erlang.term_to_binary/1` on the full state when continued play must survive
  a future random transition.
  """
  @spec from_binary(bitstring()) :: {:ok, GameState.t()} | {:error, atom()}
  def from_binary(
        <<phase_bits::4, hand_number::8, dealer_bits::3, turn_bits::3, trump_bits::3,
          rest::bitstring>>
      ) do
    with {:ok, phase} <- decode_phase(phase_bits),
         {:ok, dealer} <- decode_position(dealer_bits),
         {:ok, turn} <- decode_position(turn_bits),
         {:ok, trump_suit} <- decode_trump_suit(trump_bits),
         {:ok, bid, rest2} <- decode_bid_state(rest),
         {:ok, players, rest3} <- decode_players(rest2),
         {:ok, deck, rest4} <- decode_deck(rest3),
         {:ok, ns_score, ew_score} <- decode_scores(rest4) do
      state = %GameState{
        phase: phase,
        hand_number: hand_number,
        current_dealer: dealer,
        current_turn: turn,
        trump_suit: trump_suit,
        highest_bid: bid,
        bidding_team: if(bid, do: Types.position_to_team(elem(bid, 0)), else: nil),
        players: players,
        deck: deck,
        cumulative_scores: %{north_south: ns_score, east_west: ew_score},
        chance: nil
      }

      {:ok, state}
    end
  end

  def from_binary(_), do: {:error, :invalid_binary}

  # =============================================================================
  # Helper Encoding Functions
  # =============================================================================

  @spec encode_suit(Types.suit()) :: 0..3
  defp encode_suit(:hearts), do: 0
  defp encode_suit(:diamonds), do: 1
  defp encode_suit(:clubs), do: 2
  defp encode_suit(:spades), do: 3

  @spec decode_suit(0..3) :: {:ok, Types.suit()}
  defp decode_suit(0), do: {:ok, :hearts}
  defp decode_suit(1), do: {:ok, :diamonds}
  defp decode_suit(2), do: {:ok, :clubs}
  defp decode_suit(3), do: {:ok, :spades}

  @spec encode_phase(Types.phase()) :: 0..9
  defp encode_phase(:dealer_selection), do: 0
  defp encode_phase(:dealing), do: 1
  defp encode_phase(:bidding), do: 2
  defp encode_phase(:declaring), do: 3
  defp encode_phase(:discarding), do: 4
  defp encode_phase(:second_deal), do: 5
  defp encode_phase(:playing), do: 6
  defp encode_phase(:scoring), do: 7
  defp encode_phase(:complete), do: 8
  defp encode_phase(:hand_complete), do: 9

  @spec decode_phase(0..15) :: {:ok, Types.phase()} | {:error, :invalid_phase}
  defp decode_phase(0), do: {:ok, :dealer_selection}
  defp decode_phase(1), do: {:ok, :dealing}
  defp decode_phase(2), do: {:ok, :bidding}
  defp decode_phase(3), do: {:ok, :declaring}
  defp decode_phase(4), do: {:ok, :discarding}
  defp decode_phase(5), do: {:ok, :second_deal}
  defp decode_phase(6), do: {:ok, :playing}
  defp decode_phase(7), do: {:ok, :scoring}
  defp decode_phase(8), do: {:ok, :complete}
  defp decode_phase(9), do: {:ok, :hand_complete}
  defp decode_phase(_), do: {:error, :invalid_phase}

  @spec encode_positions(Types.position() | nil, Types.position() | nil) :: {0..4, 0..4}
  defp encode_positions(dealer, turn) do
    dealer_bits = encode_optional_position(dealer)
    turn_bits = encode_optional_position(turn)
    {dealer_bits, turn_bits}
  end

  @spec encode_optional_position(Types.position() | nil) :: 0..4
  defp encode_optional_position(nil), do: 0
  defp encode_optional_position(:north), do: 1
  defp encode_optional_position(:east), do: 2
  defp encode_optional_position(:south), do: 3
  defp encode_optional_position(:west), do: 4

  @spec decode_position(0..7) ::
          {:ok, Types.position() | nil} | {:error, :invalid_position}
  defp decode_position(0), do: {:ok, nil}
  defp decode_position(1), do: {:ok, :north}
  defp decode_position(2), do: {:ok, :east}
  defp decode_position(3), do: {:ok, :south}
  defp decode_position(4), do: {:ok, :west}
  defp decode_position(_), do: {:error, :invalid_position}

  @spec encode_trump_suit(Types.suit() | nil) :: 0..4
  defp encode_trump_suit(nil), do: 0
  defp encode_trump_suit(:hearts), do: 1
  defp encode_trump_suit(:diamonds), do: 2
  defp encode_trump_suit(:clubs), do: 3
  defp encode_trump_suit(:spades), do: 4

  @spec decode_trump_suit(0..7) :: {:ok, Types.suit() | nil} | {:error, :invalid_suit}
  defp decode_trump_suit(0), do: {:ok, nil}
  defp decode_trump_suit(1), do: {:ok, :hearts}
  defp decode_trump_suit(2), do: {:ok, :diamonds}
  defp decode_trump_suit(3), do: {:ok, :clubs}
  defp decode_trump_suit(4), do: {:ok, :spades}
  defp decode_trump_suit(_), do: {:error, :invalid_suit}

  @spec encode_bid_state({Types.position(), Types.bid_amount()} | nil) :: bitstring()
  defp encode_bid_state(nil), do: <<0::1>>

  defp encode_bid_state({position, amount}) do
    pos_bits = encode_optional_position(position)
    <<1::1, pos_bits::3, amount::4>>
  end

  @spec decode_bid_state(bitstring()) ::
          {:ok, {Types.position(), Types.bid_amount()} | nil, bitstring()}
          | {:error, :invalid_binary}
  defp decode_bid_state(<<0::1, rest::bitstring>>), do: {:ok, nil, rest}

  defp decode_bid_state(<<1::1, pos_bits::3, amount::4, rest::bitstring>>)
       when amount in 6..14 do
    case decode_position(pos_bits) do
      {:ok, position} when not is_nil(position) ->
        {:ok, {position, amount}, rest}

      _ ->
        {:error, :invalid_binary}
    end
  end

  defp decode_bid_state(_), do: {:error, :invalid_binary}

  @spec encode_player(Player.t()) :: bitstring()
  defp encode_player(%Player{hand: hand, eliminated?: eliminated}) do
    hand_binary = encode_hand(hand)
    eliminated_bit = if eliminated, do: 1, else: 0
    <<eliminated_bit::1, hand_binary::bitstring>>
  end

  @spec decode_players(bitstring()) ::
          {:ok, %{Types.position() => Player.t()}, bitstring()} | {:error, :invalid_binary}
  defp decode_players(bitstring) do
    positions = [:north, :east, :south, :west]

    Enum.reduce_while(positions, {:ok, %{}, bitstring}, fn position, {:ok, players_acc, rest} ->
      case decode_player(position, rest) do
        {:ok, player, new_rest} ->
          {:cont, {:ok, Map.put(players_acc, position, player), new_rest}}

        error ->
          {:halt, error}
      end
    end)
  end

  @spec decode_player(Types.position(), bitstring()) ::
          {:ok, Player.t(), bitstring()} | {:error, :invalid_binary}
  defp decode_player(position, <<eliminated_bit::1, rest::bitstring>>) do
    case decode_hand_prefix(rest) do
      {:ok, hand, remaining} ->
        player = %Player{
          position: position,
          team: Types.position_to_team(position),
          hand: hand,
          eliminated?: eliminated_bit == 1,
          revealed_cards: [],
          tricks_won: 0
        }

        {:ok, player, remaining}

      error ->
        error
    end
  end

  defp decode_player(_, _), do: {:error, :invalid_binary}

  @spec decode_deck(bitstring()) :: {:ok, [Types.card()], bitstring()} | {:error, :invalid_binary}
  defp decode_deck(bitstring) do
    case decode_hand_prefix(bitstring) do
      {:ok, deck, remaining} ->
        {:ok, deck, remaining}

      error ->
        error
    end
  end

  @spec decode_scores(bitstring()) :: {:ok, integer(), integer()} | {:error, :invalid_binary}
  defp decode_scores(<<ns_score::signed-16, ew_score::signed-16>>) do
    {:ok, ns_score, ew_score}
  end

  defp decode_scores(_), do: {:error, :invalid_binary}
end

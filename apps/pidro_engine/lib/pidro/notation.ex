defmodule Pidro.Notation do
  @moduledoc """
  Pidro Game Notation (PGN) - A compact, URL-safe notation for serializing game state.

  PGN provides a chess FEN-like notation for representing the complete state of a
  Pidro game in a compact string format. This enables:
  - Saving and loading game states
  - Sharing games via URLs
  - Game state debugging and logging
  - Event replay and analysis

  ## Notation Format

  The PGN format uses slash-separated fields:

  ```
  phase/dealer/turn/trump/bid/scores/hand/tricks/redeal
  ```

  ### Field Descriptions

  - **phase**: Current game phase (2-letter code)
    - `ds` = dealer_selection
    - `dl` = dealing
    - `bd` = bidding
    - `dc` = declaring
    - `di` = discarding
    - `sd` = second_deal
    - `pl` = playing
    - `sc` = scoring
    - `cp` = complete

  - **dealer**: Current dealer position (N/E/S/W) or "-" if none
  - **turn**: Current turn position (N/E/S/W) or "-" if none
  - **trump**: Trump suit (h/d/c/s) or "-" if none
  - **bid**: Highest bid in format "position:amount" (e.g., "N:10") or "-"
  - **scores**: Cumulative scores "NS:xx:EW:yy" (e.g., "NS:15:EW:8")
  - **hand**: Current hand number (e.g., "h3" for hand 3)
  - **tricks**: Number of completed tricks (e.g., "t2" for 2 tricks)
  - **redeal**: Redeal information "cr:N:2,E:3;dp:10;kc:N:5h,6d" or "-"
    - `cr` = cards_requested (comma-separated "position:count" pairs)
    - `dp` = dealer_pool_size
    - `kc` = killed_cards (comma-separated "position:cards" groups)

  ## Card Notation

  Cards are represented using rank and suit abbreviations:
  - **Ranks**: 2-9 (as is), T=10, J=11, Q=12, K=13, A=14
  - **Suits**: h=hearts, d=diamonds, c=clubs, s=spades

  ### Examples
  - `Ah` = Ace of hearts
  - `5d` = 5 of diamonds
  - `Tc` = 10 of clubs
  - `Js` = Jack of spades

  ## Example PGN Strings

  ### Initial State
  ```
  ds/-/-/-/-/NS:0:EW:0/h1/t0/-
  ```
  Dealer selection phase, no dealer yet, no trump, no bids, zero scores, hand 1.

  ### During Play
  ```
  pl/N/E/h/N:10/NS:0:EW:0/h1/t2/-
  ```
  Playing phase, North is dealer, East's turn, hearts trump, North bid 10,
  zero scores, hand 1, 2 tricks completed.

  ### With Redeal Information
  ```
  pl/N/E/h/N:10/NS:0:EW:0/h1/t2/cr:E:2,S:3,W:1;dp:8;kc:S:4h,3h
  ```
  Playing phase with redeal data: East got 2 cards, South got 3, West got 1,
  dealer pool was 8 cards, South killed 4h and 3h.

  ### Game Complete
  ```
  cp/N/E/h/N:10/NS:62:EW:45/h5/t6/-
  ```
  Game complete, North/South won with 62 points.

  ## Round-Trip Guarantee

  The notation system guarantees that `decode(encode(state))` produces an
  equivalent game state (within the serialized fields).

  Note: Some fields like player hands, deck state, and event history are not
  included in the basic PGN format for compactness. For full state serialization,
  use extended formats or the GameState struct directly.
  """

  alias Pidro.Core.Types
  alias Pidro.Core.Types.GameState
  alias Pidro.Core.GameState, as: GS

  @type card :: Types.card()
  @type position :: Types.position()
  @type suit :: Types.suit()
  @type phase :: Types.phase()
  @type pgn_string :: String.t()

  # Phase encoding map
  @phase_to_code %{
    dealer_selection: "ds",
    dealing: "dl",
    bidding: "bd",
    declaring: "dc",
    discarding: "di",
    second_deal: "sd",
    playing: "pl",
    scoring: "sc",
    complete: "cp"
  }

  @code_to_phase Map.new(@phase_to_code, fn {k, v} -> {v, k} end)

  # Position encoding
  @position_to_code %{north: "N", east: "E", south: "S", west: "W"}
  @code_to_position Map.new(@position_to_code, fn {k, v} -> {v, k} end)

  # Suit encoding
  @suit_to_code %{hearts: "h", diamonds: "d", clubs: "c", spades: "s"}
  @code_to_suit Map.new(@suit_to_code, fn {k, v} -> {v, k} end)

  # Rank encoding
  @rank_to_code %{10 => "T", 11 => "J", 12 => "Q", 13 => "K", 14 => "A"}
  @code_to_rank Map.new(@rank_to_code, fn {k, v} -> {v, k} end)

  # =============================================================================
  # Game State Encoding/Decoding
  # =============================================================================

  @doc """
  Encodes a GameState into a PGN string.

  Converts the game state into a compact, URL-safe string representation
  following the PGN format specification.

  ## Parameters
  - `state` - The GameState struct to encode

  ## Returns
  A PGN string representing the game state

  ## Examples

      iex> state = GameState.new()
      iex> Pidro.Notation.encode(state)
      "ds/-/-/-/-/NS:0:EW:0/h1/t0/-"

      iex> state = %GameState{
      ...>   phase: :playing,
      ...>   current_dealer: :north,
      ...>   current_turn: :east,
      ...>   trump_suit: :hearts,
      ...>   highest_bid: {:north, 10},
      ...>   cumulative_scores: %{north_south: 15, east_west: 8},
      ...>   hand_number: 2,
      ...>   trick_number: 3,
      ...>   cards_requested: %{},
      ...>   dealer_pool_size: nil,
      ...>   killed_cards: %{}
      ...> }
      iex> Pidro.Notation.encode(state)
      "pl/N/E/h/N:10/NS:15:EW:8/h2/t3/-"
  """
  @spec encode(GameState.t()) :: pgn_string()
  def encode(%GameState{} = state) do
    [
      encode_phase(state.phase),
      encode_position(state.current_dealer),
      encode_position(state.current_turn),
      encode_suit(state.trump_suit),
      encode_bid(state.highest_bid),
      encode_scores(state.cumulative_scores),
      encode_hand_number(state.hand_number),
      encode_trick_number(state.trick_number),
      encode_redeal(state.cards_requested, state.dealer_pool_size, state.killed_cards)
    ]
    |> Enum.join("/")
  end

  @doc """
  Decodes a PGN string into a GameState.

  Parses a PGN string and reconstructs a GameState struct with the
  serialized fields populated. Fields not included in PGN (like player
  hands, deck, events) are initialized to default values.

  ## Parameters
  - `pgn` - The PGN string to decode

  ## Returns
  - `{:ok, GameState.t()}` - Successfully decoded game state
  - `{:error, String.t()}` - Error message if parsing fails

  ## Examples

      iex> Pidro.Notation.decode("ds/-/-/-/-/NS:0:EW:0/h1/t0/-")
      {:ok, %GameState{
        phase: :dealer_selection,
        current_dealer: nil,
        current_turn: nil,
        trump_suit: nil,
        highest_bid: nil,
        cumulative_scores: %{north_south: 0, east_west: 0},
        hand_number: 1,
        trick_number: 0,
        cards_requested: %{},
        dealer_pool_size: nil,
        killed_cards: %{}
      }}

      iex> Pidro.Notation.decode("pl/N/E/h/N:10/NS:15:EW:8/h2/t3/-")
      {:ok, %GameState{
        phase: :playing,
        current_dealer: :north,
        current_turn: :east,
        trump_suit: :hearts,
        highest_bid: {:north, 10},
        cumulative_scores: %{north_south: 15, east_west: 8},
        hand_number: 2,
        trick_number: 3,
        cards_requested: %{},
        dealer_pool_size: nil,
        killed_cards: %{}
      }}

      iex> Pidro.Notation.decode("invalid")
      {:error, "Invalid PGN format: expected 9 fields, got 1"}
  """
  @spec decode(pgn_string()) :: {:ok, GameState.t()} | {:error, String.t()}
  def decode(pgn) when is_binary(pgn) do
    case String.split(pgn, "/") do
      # Support both old 8-field format (backward compatibility) and new 9-field format
      [phase, dealer, turn, trump, bid, scores, hand, tricks] ->
        decode_with_fields(phase, dealer, turn, trump, bid, scores, hand, tricks, "-")

      [phase, dealer, turn, trump, bid, scores, hand, tricks, redeal] ->
        decode_with_fields(phase, dealer, turn, trump, bid, scores, hand, tricks, redeal)

      fields ->
        {:error, "Invalid PGN format: expected 8 or 9 fields, got #{length(fields)}"}
    end
  end

  def decode(_), do: {:error, "Invalid input: expected string"}

  defp decode_with_fields(phase, dealer, turn, trump, bid, scores, hand, tricks, redeal) do
    with {:ok, phase_val} <- decode_phase(phase),
         {:ok, dealer_val} <- decode_position(dealer),
         {:ok, turn_val} <- decode_position(turn),
         {:ok, trump_val} <- decode_suit(trump),
         {:ok, bid_val} <- decode_bid(bid),
         {:ok, scores_val} <- decode_scores(scores),
         {:ok, hand_val} <- decode_hand_number(hand),
         {:ok, tricks_val} <- decode_trick_number(tricks),
         {:ok, {cards_req, pool_size, killed}} <- decode_redeal(redeal) do
      state = GS.new()

      updated_state = %{
        state
        | phase: phase_val,
          current_dealer: dealer_val,
          current_turn: turn_val,
          trump_suit: trump_val,
          highest_bid: bid_val,
          cumulative_scores: scores_val,
          hand_number: hand_val,
          trick_number: tricks_val,
          cards_requested: cards_req,
          dealer_pool_size: pool_size,
          killed_cards: killed
      }

      {:ok, updated_state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # =============================================================================
  # Card Encoding/Decoding
  # =============================================================================

  @doc """
  Encodes a card into notation.

  Converts a card tuple `{rank, suit}` into a compact two-character string.

  ## Parameters
  - `card` - A card tuple `{rank, suit}`

  ## Returns
  A 2-character string representing the card

  ## Examples

      iex> Pidro.Notation.encode_card({14, :hearts})
      "Ah"

      iex> Pidro.Notation.encode_card({5, :diamonds})
      "5d"

      iex> Pidro.Notation.encode_card({10, :clubs})
      "Tc"

      iex> Pidro.Notation.encode_card({11, :spades})
      "Js"
  """
  @spec encode_card(card()) :: String.t()
  def encode_card({rank, suit}) when rank in 2..14 do
    rank_str =
      case rank do
        r when r in 2..9 -> Integer.to_string(r)
        r -> @rank_to_code[r]
      end

    suit_str = @suit_to_code[suit]
    "#{rank_str}#{suit_str}"
  end

  @doc """
  Decodes a card from notation.

  Parses a card notation string back into a card tuple `{rank, suit}`.

  ## Parameters
  - `str` - A card notation string (e.g., "Ah", "5d")

  ## Returns
  - `{:ok, card()}` - Successfully decoded card
  - `{:error, String.t()}` - Error message if parsing fails

  ## Examples

      iex> Pidro.Notation.decode_card("Ah")
      {:ok, {14, :hearts}}

      iex> Pidro.Notation.decode_card("5d")
      {:ok, {5, :diamonds}}

      iex> Pidro.Notation.decode_card("Tc")
      {:ok, {10, :clubs}}

      iex> Pidro.Notation.decode_card("Js")
      {:ok, {11, :spades}}

      iex> Pidro.Notation.decode_card("Xx")
      {:error, "Invalid card notation: Xx"}
  """
  @spec decode_card(String.t()) :: {:ok, card()} | {:error, String.t()}
  def decode_card(str) when is_binary(str) and byte_size(str) == 2 do
    <<rank_char::binary-size(1), suit_char::binary-size(1)>> = str

    with {:ok, rank} <- parse_rank(rank_char),
         {:ok, suit} <- parse_suit(suit_char) do
      {:ok, {rank, suit}}
    else
      {:error, _} -> {:error, "Invalid card notation: #{str}"}
    end
  end

  def decode_card(str) when is_binary(str) do
    {:error, "Invalid card notation length: expected 2 characters, got #{byte_size(str)}"}
  end

  def decode_card(_), do: {:error, "Invalid input: expected string"}

  # =============================================================================
  # Private Helper Functions - Encoding
  # =============================================================================

  @spec encode_phase(phase()) :: String.t()
  defp encode_phase(phase), do: @phase_to_code[phase]

  @spec encode_position(position() | nil) :: String.t()
  defp encode_position(nil), do: "-"
  defp encode_position(pos), do: @position_to_code[pos]

  @spec encode_suit(suit() | nil) :: String.t()
  defp encode_suit(nil), do: "-"
  defp encode_suit(suit), do: @suit_to_code[suit]

  @spec encode_bid({position(), 6..14} | nil) :: String.t()
  defp encode_bid(nil), do: "-"

  defp encode_bid({position, amount}) when amount in 6..14 do
    "#{@position_to_code[position]}:#{amount}"
  end

  @spec encode_scores(%{north_south: integer(), east_west: integer()}) :: String.t()
  defp encode_scores(%{north_south: ns, east_west: ew}) do
    "NS:#{ns}:EW:#{ew}"
  end

  @spec encode_hand_number(non_neg_integer()) :: String.t()
  defp encode_hand_number(num), do: "h#{num}"

  @spec encode_trick_number(non_neg_integer()) :: String.t()
  defp encode_trick_number(num), do: "t#{num}"

  @spec encode_redeal(map(), integer() | nil, map()) :: String.t()
  defp encode_redeal(cards_requested, dealer_pool_size, killed_cards)
       when map_size(cards_requested) == 0 and is_nil(dealer_pool_size) and
              map_size(killed_cards) == 0 do
    "-"
  end

  defp encode_redeal(cards_requested, dealer_pool_size, killed_cards) do
    parts = []

    # Encode cards_requested
    parts =
      if map_size(cards_requested) > 0 do
        cr_str =
          cards_requested
          |> Enum.sort()
          |> Enum.map(fn {pos, count} -> "#{@position_to_code[pos]}:#{count}" end)
          |> Enum.join(",")

        ["cr:#{cr_str}" | parts]
      else
        parts
      end

    # Encode dealer_pool_size
    parts =
      if dealer_pool_size do
        ["dp:#{dealer_pool_size}" | parts]
      else
        parts
      end

    # Encode killed_cards
    parts =
      if map_size(killed_cards) > 0 do
        kc_str =
          killed_cards
          |> Enum.sort()
          |> Enum.map(fn {pos, cards} ->
            cards_str = cards |> Enum.map(&encode_card/1) |> Enum.join(",")
            "#{@position_to_code[pos]}:#{cards_str}"
          end)
          |> Enum.join("|")

        ["kc:#{kc_str}" | parts]
      else
        parts
      end

    case parts do
      [] -> "-"
      _ -> parts |> Enum.reverse() |> Enum.join(";")
    end
  end

  # =============================================================================
  # Private Helper Functions - Decoding
  # =============================================================================

  @spec decode_phase(String.t()) :: {:ok, phase()} | {:error, String.t()}
  defp decode_phase(code) do
    case @code_to_phase[code] do
      nil -> {:error, "Invalid phase code: #{code}"}
      phase -> {:ok, phase}
    end
  end

  @spec decode_position(String.t()) :: {:ok, position() | nil} | {:error, String.t()}
  defp decode_position("-"), do: {:ok, nil}

  defp decode_position(code) do
    case @code_to_position[code] do
      nil -> {:error, "Invalid position code: #{code}"}
      pos -> {:ok, pos}
    end
  end

  @spec decode_suit(String.t()) :: {:ok, suit() | nil} | {:error, String.t()}
  defp decode_suit("-"), do: {:ok, nil}

  defp decode_suit(code) do
    case @code_to_suit[code] do
      nil -> {:error, "Invalid suit code: #{code}"}
      suit -> {:ok, suit}
    end
  end

  @spec decode_bid(String.t()) :: {:ok, {position(), 6..14} | nil} | {:error, String.t()}
  defp decode_bid("-"), do: {:ok, nil}

  defp decode_bid(bid_str) do
    case String.split(bid_str, ":") do
      [pos_code, amount_str] ->
        with {:ok, position} when not is_nil(position) <- decode_position(pos_code),
             {amount, ""} <- Integer.parse(amount_str),
             true <- amount in 6..14 do
          {:ok, {position, amount}}
        else
          {:ok, nil} -> {:error, "Invalid bid: position cannot be nil"}
          :error -> {:error, "Invalid bid amount: #{amount_str}"}
          false -> {:error, "Bid amount out of range: #{amount_str}"}
        end

      _ ->
        {:error, "Invalid bid format: #{bid_str}"}
    end
  end

  @spec decode_scores(String.t()) ::
          {:ok, %{north_south: integer(), east_west: integer()}} | {:error, String.t()}
  defp decode_scores(scores_str) do
    case String.split(scores_str, ":") do
      ["NS", ns_str, "EW", ew_str] ->
        with {ns, ""} <- Integer.parse(ns_str),
             {ew, ""} <- Integer.parse(ew_str) do
          {:ok, %{north_south: ns, east_west: ew}}
        else
          :error -> {:error, "Invalid score format: #{scores_str}"}
        end

      _ ->
        {:error, "Invalid score format: #{scores_str}"}
    end
  end

  @spec decode_hand_number(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp decode_hand_number("h" <> num_str) do
    case Integer.parse(num_str) do
      {num, ""} when num >= 0 -> {:ok, num}
      _ -> {:error, "Invalid hand number: #{num_str}"}
    end
  end

  defp decode_hand_number(str), do: {:error, "Invalid hand number format: #{str}"}

  @spec decode_trick_number(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp decode_trick_number("t" <> num_str) do
    case Integer.parse(num_str) do
      {num, ""} when num >= 0 -> {:ok, num}
      _ -> {:error, "Invalid trick number: #{num_str}"}
    end
  end

  defp decode_trick_number(str), do: {:error, "Invalid trick number format: #{str}"}

  @spec parse_rank(String.t()) :: {:ok, 2..14} | {:error, String.t()}
  defp parse_rank(str) do
    case @code_to_rank[str] do
      nil ->
        case Integer.parse(str) do
          {rank, ""} when rank in 2..9 -> {:ok, rank}
          _ -> {:error, "Invalid rank: #{str}"}
        end

      rank ->
        {:ok, rank}
    end
  end

  @spec parse_suit(String.t()) :: {:ok, suit()} | {:error, String.t()}
  defp parse_suit(str) do
    case @code_to_suit[str] do
      nil -> {:error, "Invalid suit: #{str}"}
      suit -> {:ok, suit}
    end
  end

  @spec decode_redeal(String.t()) ::
          {:ok, {map(), integer() | nil, map()}} | {:error, String.t()}
  defp decode_redeal("-"), do: {:ok, {%{}, nil, %{}}}

  defp decode_redeal(redeal_str) do
    # Parse redeal string: "cr:N:2,E:3;dp:10;kc:N:5h,6d|E:4h"
    parts = String.split(redeal_str, ";")

    result =
      Enum.reduce_while(parts, {:ok, {%{}, nil, %{}}}, fn part, {:ok, {cr, dp, kc}} ->
        cond do
          String.starts_with?(part, "cr:") ->
            case decode_cards_requested(String.trim_leading(part, "cr:")) do
              {:ok, cards_req} -> {:cont, {:ok, {cards_req, dp, kc}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          String.starts_with?(part, "dp:") ->
            case decode_dealer_pool_size(String.trim_leading(part, "dp:")) do
              {:ok, pool_size} -> {:cont, {:ok, {cr, pool_size, kc}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          String.starts_with?(part, "kc:") ->
            case decode_killed_cards(String.trim_leading(part, "kc:")) do
              {:ok, killed} -> {:cont, {:ok, {cr, dp, killed}}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          true ->
            {:halt, {:error, "Invalid redeal part: #{part}"}}
        end
      end)

    result
  end

  @spec decode_cards_requested(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp decode_cards_requested(str) do
    # Parse "N:2,E:3,W:1"
    pairs = String.split(str, ",")

    result =
      Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(pair, ":") do
          [pos_code, count_str] ->
            with {:ok, pos} when not is_nil(pos) <- decode_position(pos_code),
                 {count, ""} <- Integer.parse(count_str),
                 true <- count >= 0 do
              {:cont, {:ok, Map.put(acc, pos, count)}}
            else
              {:ok, nil} -> {:halt, {:error, "Invalid position in cards_requested: #{pos_code}"}}
              :error -> {:halt, {:error, "Invalid count in cards_requested: #{count_str}"}}
              false -> {:halt, {:error, "Invalid count value: #{count_str}"}}
            end

          _ ->
            {:halt, {:error, "Invalid cards_requested pair: #{pair}"}}
        end
      end)

    result
  end

  @spec decode_dealer_pool_size(String.t()) :: {:ok, integer()} | {:error, String.t()}
  defp decode_dealer_pool_size(str) do
    case Integer.parse(str) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, "Invalid dealer_pool_size: #{str}"}
    end
  end

  @spec decode_killed_cards(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp decode_killed_cards(str) do
    # Parse "N:5h,6d|E:4h"
    groups = String.split(str, "|")

    result =
      Enum.reduce_while(groups, {:ok, %{}}, fn group, {:ok, acc} ->
        case String.split(group, ":", parts: 2) do
          [pos_code, cards_str] ->
            with {:ok, pos} when not is_nil(pos) <- decode_position(pos_code),
                 {:ok, cards} <- decode_card_list(cards_str) do
              {:cont, {:ok, Map.put(acc, pos, cards)}}
            else
              {:ok, nil} -> {:halt, {:error, "Invalid position in killed_cards: #{pos_code}"}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _ ->
            {:halt, {:error, "Invalid killed_cards group: #{group}"}}
        end
      end)

    result
  end

  @spec decode_card_list(String.t()) :: {:ok, list(card())} | {:error, String.t()}
  defp decode_card_list(str) do
    # Parse "5h,6d,4h"
    card_strs = String.split(str, ",")

    result =
      Enum.reduce_while(card_strs, {:ok, []}, fn card_str, {:ok, acc} ->
        case decode_card(card_str) do
          {:ok, card} -> {:cont, {:ok, [card | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      error -> error
    end
  end
end

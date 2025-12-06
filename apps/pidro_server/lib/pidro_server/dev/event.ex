if Mix.env() == :dev do
  defmodule PidroServer.Dev.Event do
    @moduledoc """
    Event types for the development UI event log system.

    Events are derived from game state changes and represent discrete actions
    that occur during gameplay. Each event has a type, timestamp, player (if applicable),
    and type-specific metadata.

    ## Event Types

    - `:dealer_selected` - A dealer was selected for the hand
    - `:cards_dealt` - Cards were dealt to players
    - `:bid_made` - A player made a bid
    - `:bid_passed` - A player passed on bidding
    - `:trump_declared` - Trump suit was declared
    - `:card_played` - A player played a card
    - `:trick_won` - A trick was won by a player
    - `:hand_scored` - Hand completed and scored
    - `:game_over` - Game completed with winner
    - `:bot_reasoning` - Bot decision-making reasoning (dev/debug)

    ## Example

        iex> Event.new(:bid_made, :north, %{bid_amount: 8})
        %Event{
          type: :bid_made,
          player: :north,
          timestamp: ~U[2025-11-02 15:30:45.123456Z],
          metadata: %{bid_amount: 8}
        }
    """

    @type event_type ::
            :dealer_selected
            | :cards_dealt
            | :bid_made
            | :bid_passed
            | :trump_declared
            | :card_played
            | :trick_won
            | :hand_scored
            | :game_over
            | :bot_reasoning

    @type position :: :north | :south | :east | :west

    @type t :: %__MODULE__{
            type: event_type(),
            player: position() | nil,
            timestamp: DateTime.t(),
            metadata: map()
          }

    @enforce_keys [:type, :timestamp]
    defstruct [:type, :player, :timestamp, :metadata]

    @doc """
    Converts a raw game engine event tuple into an Event struct.
    """
    @spec from_raw(tuple()) :: t()
    def from_raw({:dealer_selected, position, _card}),
      do: new(:dealer_selected, position)

    def from_raw({:cards_dealt, _hands}),
      do: new(:cards_dealt, nil)

    def from_raw({:bid_made, position, amount}),
      do: new(:bid_made, position, %{bid_amount: amount})

    def from_raw({:player_passed, position}),
      do: new(:bid_passed, position)

    def from_raw({:bidding_complete, _position, _amount}),
      # Skip this one for UI noise reduction or handle if needed
      do: nil

    def from_raw({:trump_declared, suit}),
      # Declarer implicit in UI usually
      do: new(:trump_declared, nil, %{suit: suit})

    # Adjust for trump declared with declarer if available in context, but raw event is {:trump_declared, suit}
    # Wait, Core Types says: {:trump_declared, suit()}
    # So we don't know who declared it from the event alone? The context might be needed.
    # But EventRecorder was inferring it from state.
    # For now, we just show "Trump declared: Suit".

    def from_raw({:card_played, position, card}),
      do: new(:card_played, position, %{card: card})

    def from_raw({:trick_won, position, points}),
      do: new(:trick_won, position, %{points: points})

    def from_raw({:hand_scored, winning_team, points}),
      # We might need to infer the split points from context or just show winner
      # Simplified
      do:
        new(:hand_scored, nil, %{
          winning_team: winning_team,
          points: points,
          ns_points: 0,
          ew_points: 0
        })

    def from_raw({:game_won, team, score}),
      do: new(:game_over, nil, %{winner: team, final_scores: %{team => score}})

    # Ignore other events
    def from_raw(_), do: nil

    @doc """
    Creates a new event with the given type, optional player, and metadata.

    ## Parameters

    - `type` - The event type (see module docs for valid types)
    - `player` - The player associated with this event (optional)
    - `metadata` - Additional data specific to this event type (default: %{})

    ## Examples

        iex> Event.new(:dealer_selected, :north, %{hand_number: 1})
        %Event{type: :dealer_selected, player: :north, ...}

        iex> Event.new(:cards_dealt)
        %Event{type: :cards_dealt, player: nil, ...}
    """
    @spec new(event_type(), position() | nil, map()) :: t()
    def new(type, player \\ nil, metadata \\ %{}) do
      %__MODULE__{
        type: type,
        player: player,
        timestamp: DateTime.utc_now(),
        metadata: metadata
      }
    end

    @doc """
    Formats an event as a human-readable string for display in the UI.

    ## Examples

        iex> event = Event.new(:bid_made, :north, %{bid_amount: 8})
        iex> Event.format(event)
        "North bid 8"

        iex> event = Event.new(:trump_declared, :south, %{suit: :spades})
        iex> Event.format(event)
        "South declared ♠ as trump"
    """
    @spec format(t()) :: String.t()
    def format(%__MODULE__{type: :dealer_selected, player: player}) do
      "#{format_player(player)} selected as dealer"
    end

    def format(%__MODULE__{type: :cards_dealt}) do
      "Cards dealt to all players"
    end

    def format(%__MODULE__{type: :bid_made, player: player, metadata: %{bid_amount: amount}}) do
      "#{format_player(player)} bid #{amount}"
    end

    def format(%__MODULE__{type: :bid_passed, player: player}) do
      "#{format_player(player)} passed"
    end

    def format(%__MODULE__{type: :trump_declared, player: player, metadata: %{suit: suit}}) do
      "#{format_player(player)} declared #{format_suit(suit)} as trump"
    end

    def format(%__MODULE__{type: :card_played, player: player, metadata: %{card: card}}) do
      "#{format_player(player)} played #{format_card(card)}"
    end

    def format(%__MODULE__{type: :trick_won, player: player, metadata: %{points: points}}) do
      "#{format_player(player)} won trick (#{points} points)"
    end

    def format(%__MODULE__{
          type: :hand_scored,
          metadata: %{ns_points: ns, ew_points: ew, winning_team: winner}
        }) do
      "Hand scored - N/S: #{ns}, E/W: #{ew} (#{format_team(winner)} won)"
    end

    def format(%__MODULE__{type: :game_over, metadata: %{winner: winner, final_scores: scores}}) do
      "Game over! #{format_team(winner)} wins #{scores[winner]}-#{scores[other_team(winner)]}"
    end

    def format(%__MODULE__{
          type: :bot_reasoning,
          player: player,
          metadata: %{action: action, reasoning: reasoning}
        }) do
      "#{format_player(player)} (Bot) chose '#{format_action(action)}' - #{reasoning}"
    end

    # Fallback for unknown event types
    def format(%__MODULE__{type: type, player: nil}) do
      "#{type}"
    end

    def format(%__MODULE__{type: type, player: player}) do
      "#{format_player(player)} - #{type}"
    end

    @doc """
    Converts an event to JSON-serializable format for export.
    """
    @spec to_json(t()) :: map()
    def to_json(%__MODULE__{} = event) do
      %{
        type: event.type,
        player: event.player,
        timestamp: DateTime.to_iso8601(event.timestamp),
        metadata: event.metadata,
        formatted: format(event)
      }
    end

    # Private helper functions

    defp format_player(nil), do: "System"
    defp format_player(player), do: player |> to_string() |> String.capitalize()

    defp format_suit(:hearts), do: "♥"
    defp format_suit(:diamonds), do: "♦"
    defp format_suit(:clubs), do: "♣"
    defp format_suit(:spades), do: "♠"
    defp format_suit(suit), do: to_string(suit)

    defp format_card(%{rank: rank, suit: suit}) do
      "#{format_rank(rank)}#{format_suit(suit)}"
    end

    defp format_card(card) when is_binary(card), do: card
    defp format_card(card), do: inspect(card)

    defp format_rank(:ace), do: "A"
    defp format_rank(:king), do: "K"
    defp format_rank(:queen), do: "Q"
    defp format_rank(:jack), do: "J"
    defp format_rank(rank) when is_integer(rank), do: to_string(rank)
    defp format_rank(rank), do: to_string(rank)

    defp format_team(:north_south), do: "North/South"
    defp format_team(:east_west), do: "East/West"
    defp format_team(team), do: to_string(team)

    defp other_team(:north_south), do: :east_west
    defp other_team(:east_west), do: :north_south

    defp format_action(:pass), do: "Pass"
    defp format_action({:bid, amount}), do: "Bid #{amount}"
    defp format_action({:play_card, card}), do: "Play #{format_card(card)}"
    defp format_action({:declare_trump, suit}), do: "Declare #{format_suit(suit)} as trump"
    defp format_action(action), do: inspect(action)
  end
end

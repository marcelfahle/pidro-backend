defmodule PidroServerWeb.Dev.ArchivePresentation do
  @moduledoc "Finite, data-only archive v1 projection for the read-only Watch table."

  @positions [:north, :east, :south, :west]
  @suits [:hearts, :diamonds, :clubs, :spades]
  @phases [
    :dealer_selection,
    :dealing,
    :bidding,
    :declaring,
    :discarding,
    :second_deal,
    :playing,
    :scoring,
    :hand_complete,
    :complete
  ]

  def state(%{"state" => state}) when is_map(state) do
    %{
      players:
        Map.new(@positions, fn position ->
          player = get_in(state, ["players", Atom.to_string(position)]) || %{}
          {position, %{hand: cards(player["hand"] || []), cold: player["eliminated?"] == true}}
        end),
      phase: enum(state["phase"], @phases),
      current_turn: enum(state["current_turn"], @positions),
      current_dealer: enum(state["current_dealer"], @positions),
      trump_suit: enum(state["trump_suit"], @suits),
      highest_bid: bid(state["highest_bid"]),
      current_trick: trick(state["current_trick"]),
      hand_number: state["hand_number"],
      cumulative_scores: %{
        north_south: get_in(state, ["cumulative_scores", "north_south"]) || 0,
        east_west: get_in(state, ["cumulative_scores", "east_west"]) || 0
      },
      winner: enum(state["winner"], [:north_south, :east_west])
    }
  end

  def state(_), do: nil

  def seats(participants, names) do
    Map.new(@positions, fn position ->
      seat = participants[Atom.to_string(position)] || %{}
      user = names[seat["user_id"]] || %{}
      bot? = seat["occupant_type"] == "bot"
      profile = if bot?, do: PidroServer.BotCatalogue.profile(seat["bot_persona"])
      name = user[:display_name] || user[:username] || if(bot?, do: "Bot", else: "Unknown player")

      {position,
       %{
         status: seat_status(seat),
         player_id: seat["user_id"],
         username: name,
         display_name: name,
         bot_profile: if(profile, do: PidroServer.BotCatalogue.public(profile)),
         avatar_url: nil
       }}
    end)
  end

  defp seat_status(%{"occupant_type" => "vacant"}), do: :vacant
  defp seat_status(%{"status" => "bot_substitute"}), do: :bot_substitute

  defp seat_status(%{"status" => status}) when status in ["reconnecting", "grace"],
    do: :reconnecting

  defp seat_status(%{"occupant_type" => "bot"}), do: :permanent_bot
  defp seat_status(seat) when map_size(seat) == 0, do: :vacant
  defp seat_status(_), do: :normal

  defp cards(values),
    do: Enum.flat_map(values, fn value -> if card(value), do: [card(value)], else: [] end)

  defp card(%{"$tuple" => [rank, suit]}) when rank in 2..14 do
    if suit = enum(suit, @suits), do: {rank, suit}
  end

  defp card(_), do: nil

  defp bid(%{"$tuple" => [position, amount]}) when is_integer(amount) do
    if position = enum(position, @positions), do: {position, amount}
  end

  defp bid(_), do: nil

  defp trick(%{"plays" => plays} = trick) when is_list(plays) do
    %{
      number: trick["number"],
      plays:
        Enum.flat_map(plays, fn
          %{"$tuple" => [position, value]} ->
            case {enum(position, @positions), card(value)} do
              {nil, _} -> []
              {_, nil} -> []
              play -> [play]
            end

          _ ->
            []
        end)
    }
  end

  defp trick(_), do: nil

  defp enum(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  def describe(%{"$tuple" => values}), do: Enum.map_join(values, " · ", &describe/1)
  def describe(%{"$set" => values}), do: Enum.map_join(values, ", ", &describe/1)
  def describe(values) when is_list(values), do: Enum.map_join(values, "; ", &describe/1)

  def describe(value) when is_map(value) do
    value
    |> Map.drop(["$struct"])
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{describe(value)}" end)
  end

  def describe(nil), do: "—"
  def describe(value), do: to_string(value)
end

defmodule PidroServer.Games.Room.Positions do
  @moduledoc """
  Pure functions for managing player seating positions in a room.

  This module provides all logic for seat assignment without any side effects.
  All functions are pure - they take a room and return a new room or error tuple.

  Design principle: Single source of truth - the positions map is canonical.
  All other player-related data (player_ids list, available_positions, etc.) is derived.
  """

  alias PidroServer.Games.RoomManager.Room

  @type position :: :north | :east | :south | :west
  @type team :: :north_south | :east_west
  @type choice :: position() | team() | :auto | nil

  @positions [:north, :east, :south, :west]
  @teams %{
    north_south: [:north, :south],
    east_west: [:east, :west]
  }

  @doc "Returns an empty positions map"
  def empty do
    %{north: nil, east: nil, south: nil, west: nil}
  end

  @doc "Returns list of unoccupied positions"
  def available(%Room{positions: positions, config: config}) do
    @positions
    |> Enum.filter(&(Map.get(positions, &1) == nil and not Map.has_key?(config.seat_holds, &1)))
  end

  @doc "Returns available positions for a specific team"
  def team_available(%Room{} = room, team) when team in [:north_south, :east_west] do
    Enum.filter(available(room), &(&1 in @teams[team]))
  end

  @doc "The seat across the table, where the partner of whoever sits at `position` sits"
  @spec partner(position() | nil) :: position() | nil
  def partner(:north), do: :south
  def partner(:south), do: :north
  def partner(:east), do: :west
  def partner(:west), do: :east
  def partner(nil), do: nil

  @doc "Returns list of player IDs in canonical order (N, E, S, W)"
  def player_ids(%Room{positions: positions}) do
    @positions
    |> Enum.map(&Map.get(positions, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Returns count of occupied positions"
  def count(room) do
    room |> player_ids() |> length()
  end

  @doc "Checks if a player is seated in the room"
  def has_player?(%Room{positions: positions}, player_id) do
    positions
    |> Map.values()
    |> Enum.any?(&(&1 == player_id))
  end

  @doc "Returns the position of a player, or nil if not seated"
  def get_position(%Room{positions: positions}, player_id) do
    positions
    |> Enum.find_value(fn {pos, id} -> if id == player_id, do: pos end)
  end

  @doc """
  Assigns a player to a position in the room.

  Choice can be:
  - `nil` or `:auto` - auto-assign first available
  - `:north`, `:east`, `:south`, `:west` - specific seat
  - `:north_south`, `:east_west` - team preference

  Returns `{:ok, room, assigned_position}` or `{:error, reason}`
  """
  def assign(%Room{max_players: max} = room, player_id, choice) do
    cond do
      count(room) >= max -> {:error, :room_full}
      has_player?(room, player_id) -> {:error, :already_seated}
      true -> do_assign(room, player_id, normalize_choice(choice))
    end
  end

  @doc """
  Assigns a player using `hint` as a preference, falling back to the first open
  seat when the hinted seat is taken or the hinted team is full.

  `hint` accepts the same choices as `assign/3`; a `:partner` hint must be
  resolved to a concrete position by the caller first.

  Returns `{:ok, room, position, hint_honored}` where `hint_honored` is `false`
  only when the fallback was used, or `{:error, reason}` from `assign/3` when no
  seat can be given at all.
  """
  @spec assign_with_fallback(Room.t(), String.t(), choice()) ::
          {:ok, Room.t(), position(), boolean()}
          | {:error, :room_full | :already_seated | :invalid_position}
  def assign_with_fallback(%Room{} = room, player_id, hint) do
    case assign(room, player_id, hint) do
      {:ok, updated_room, position} ->
        {:ok, updated_room, position, true}

      {:error, reason} when reason in [:seat_taken, :team_full] ->
        assign_fallback(room, player_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assign_fallback(%Room{} = room, player_id) do
    case assign(room, player_id, :auto) do
      {:ok, updated_room, position} -> {:ok, updated_room, position, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves a seated player to a vacant position.

  Returns `{:ok, room, previous_position}`, or `{:error, reason}` with
  `:invalid_position`, `:player_not_in_room` or `:seat_taken` (the target holds
  a player, which includes a held seat).
  """
  @spec move(Room.t(), String.t(), position()) ::
          {:ok, Room.t(), position()}
          | {:error, :invalid_position | :player_not_in_room | :seat_taken}
  def move(%Room{positions: positions} = room, player_id, to) do
    cond do
      to not in @positions ->
        {:error, :invalid_position}

      not has_player?(room, player_id) ->
        {:error, :player_not_in_room}

      Map.get(positions, to) != nil or not hold_allows?(room, player_id, to) ->
        {:error, :seat_taken}

      true ->
        from = get_position(room, player_id)
        {:ok, room |> remove(player_id) |> place(player_id, to), from}
    end
  end

  @doc "Removes a player from their position"
  def remove(%Room{positions: positions} = room, player_id) do
    new_positions =
      Map.new(positions, fn {pos, id} ->
        {pos, if(id == player_id, do: nil, else: id)}
      end)

    %{room | positions: new_positions}
  end

  # Normalize user input to internal representation
  defp normalize_choice(nil), do: :auto
  defp normalize_choice(:auto), do: :auto
  defp normalize_choice(team) when team in [:north_south, :east_west], do: {:team, team}
  defp normalize_choice(pos) when pos in @positions, do: {:seat, pos}
  defp normalize_choice(_), do: :invalid

  defp do_assign(_room, _player_id, :invalid), do: {:error, :invalid_position}

  defp do_assign(%Room{} = room, player_id, :auto) do
    case available_for(room, player_id, @positions) do
      [pos | _] -> {:ok, place(room, player_id, pos), pos}
      [] -> {:error, :room_full}
    end
  end

  defp do_assign(%Room{} = room, player_id, {:team, team}) do
    case available_for(room, player_id, @teams[team]) do
      [pos | _] -> {:ok, place(room, player_id, pos), pos}
      [] -> {:error, :team_full}
    end
  end

  defp do_assign(%Room{positions: positions} = room, player_id, {:seat, pos}) do
    if Map.get(positions, pos) == nil and hold_allows?(room, player_id, pos),
      do: {:ok, place(room, player_id, pos), pos},
      else: {:error, :seat_taken}
  end

  # A seat held for the player comes first and a password seat last, so a
  # player who names no seat is not sent to one that needs the password.
  defp available_for(room, player_id, positions) do
    positions
    |> Enum.filter(&(room.positions[&1] == nil and hold_allows?(room, player_id, &1)))
    |> Enum.sort_by(&{room.config.seat_holds[&1] != player_id, &1 in room.config.password_seats})
  end

  defp hold_allows?(room, player_id, position) do
    Map.get(room.config.seat_holds, position) in [nil, player_id]
  end

  defp place(%Room{positions: positions} = room, player_id, pos) do
    config = %{room.config | seat_holds: Map.delete(room.config.seat_holds, pos)}

    %{
      room
      | positions: Map.put(positions, pos, player_id),
        config: config,
        seat_hold_started_at: Map.delete(room.seat_hold_started_at, pos)
    }
  end
end

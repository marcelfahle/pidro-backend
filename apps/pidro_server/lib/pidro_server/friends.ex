defmodule PidroServer.Friends do
  @moduledoc "Directed friendship edges, discovery and live player entries."
  import Ecto.Query

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Blocks
  alias PidroServer.ClassicSocial
  alias PidroServer.Friends.Friendship
  alias PidroServer.Games.RoomManager
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.Presence

  @doc "Adds one edge, idempotently, and returns the caller's full list."
  @spec add(String.t(), String.t()) :: {:ok, map()} | {:error, atom() | Ecto.Changeset.t()}
  def add(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id),
         {:ok, _} <-
           Repo.transaction(fn ->
             Blocks.lock_pair(user_id, friend_id)

             if Blocks.blocked?(user_id, friend_id), do: Repo.rollback(:user_not_found)

             case Repo.insert(Friendship.changeset(user_id, friend_id),
                    on_conflict: :nothing,
                    conflict_target: [:user_id, :friend_id]
                  ) do
               {:ok, edge} -> edge
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      changed(user_id, friend_id)
      {:ok, list(user_id)}
    end
  end

  @doc "Deletes both edges and returns the caller's full list."
  @spec remove(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def remove(user_id, friend_id) do
    with {:ok, friend_id} <- target(user_id, friend_id) do
      Repo.delete_all(
        from f in Friendship,
          where:
            (f.user_id == ^user_id and f.friend_id == ^friend_id) or
              (f.user_id == ^friend_id and f.friend_id == ^user_id)
      )

      changed(user_id, friend_id)
      {:ok, list(user_id)}
    end
  end

  @doc "Returns mutual friends and incoming-only edges, with live presence."
  @spec list(String.t()) :: map()
  def list(user_id) do
    outgoing = outgoing_ids(user_id)

    incoming =
      Repo.all(
        from f in Friendship,
          where: f.friend_id == ^user_id,
          order_by: [desc: f.inserted_at, asc: f.user_id],
          select: f.user_id
      )

    entries = entries(incoming)
    {friends, added_you} = Enum.split_with(entries, &MapSet.member?(outgoing, &1.user_id))

    %{
      friends:
        Enum.sort_by(
          friends,
          &{&1.presence == "offline", User.name_key(&1.display_name), &1.user_id}
        ),
      added_you: added_you
    }
    |> with_classic(user_id)
  end

  @doc "Finds up to ten registered players by the existing folded-name prefix."
  @spec search(String.t(), term()) :: {:ok, [map()]} | {:error, :query_too_short}
  def search(user_id, query) when is_binary(query) do
    query = query |> String.normalize(:nfkc) |> String.trim()

    if String.length(query) < 3 do
      {:error, :query_too_short}
    else
      prefix = User.name_key(query)

      ids =
        from(u in User,
          where: u.guest == false and u.id != ^user_id,
          order_by: [asc: coalesce(u.display_name, u.username), asc: u.id],
          select: {u.id, coalesce(u.display_name, u.username)}
        )
        |> Blocks.excluding(user_id)
        |> Repo.all()
        |> Stream.filter(fn {_id, name} ->
          String.starts_with?(User.name_key(name) || "", prefix)
        end)
        |> Stream.map(&elem(&1, 0))
        |> Enum.take(10)

      {:ok, related_entries(user_id, ids)}
    end
  end

  def search(_user_id, _query), do: {:error, :query_too_short}

  @doc "Returns non-friend humans from the caller's last twenty completed games."
  @spec recent(String.t()) :: [map()]
  def recent(user_id) do
    outgoing = outgoing_ids(user_id)

    mutual =
      Repo.all(from f in Friendship, where: f.friend_id == ^user_id, select: f.user_id)
      |> Enum.filter(&MapSet.member?(outgoing, &1))
      |> MapSet.new()

    ids =
      Repo.all(
        from g in GameStats,
          where: ^user_id in g.player_ids and not is_nil(g.completed_at),
          order_by: [desc: g.completed_at, desc: g.id],
          limit: 20,
          select: g.player_ids
      )
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&(&1 == user_id or MapSet.member?(mutual, &1)))

    visible =
      from(u in User, where: u.id in ^ids, select: u.id)
      |> Blocks.excluding(user_id)
      |> Repo.all()
      |> MapSet.new()

    related_entries(user_id, Enum.filter(ids, &MapSet.member?(visible, &1))) |> Enum.take(10)
  end

  defp with_classic(list, user_id) do
    case Repo.get(User, user_id) do
      %User{classic_user_id: id} when not is_nil(id) ->
        Map.put(list, :classic, %{not_here: ClassicSocial.not_here(id)})

      _ ->
        list
    end
  end

  defp target(user_id, friend_id) do
    with {:ok, id} <- Ecto.UUID.cast(friend_id),
         false <- id == user_id,
         %User{guest: false} <- Repo.get(User, id) do
      {:ok, id}
    else
      true -> {:error, :cannot_friend_self}
      _ -> {:error, :user_not_found}
    end
  end

  defp outgoing_ids(user_id) do
    Repo.all(from f in Friendship, where: f.user_id == ^user_id, select: f.friend_id)
    |> MapSet.new()
  end

  defp related_entries(user_id, ids) do
    outgoing = outgoing_ids(user_id)

    incoming =
      Repo.all(from f in Friendship, where: f.friend_id == ^user_id, select: f.user_id)
      |> MapSet.new()

    Enum.map(entries(ids), fn entry ->
      relation =
        case {MapSet.member?(outgoing, entry.user_id), MapSet.member?(incoming, entry.user_id)} do
          {true, true} -> "friend"
          {false, true} -> "added_you"
          {true, false} -> "added"
          {false, false} -> "none"
        end

      Map.put(entry, :relation, relation)
    end)
  end

  defp entries(ids) do
    users = Auth.get_users_map(ids)
    lobby = Presence.list("lobby")

    games = for room <- RoomManager.list_rooms(), do: {room, Presence.list("game:" <> room.code)}
    tables = games |> Enum.flat_map(&seated_company/1) |> Map.new()
    watching = games |> Enum.flat_map(fn {_room, connected} -> Map.keys(connected) end)
    connected = lobby |> Map.keys() |> Enum.concat(watching) |> MapSet.new()

    for id <- ids, user = users[id], user && user.guest == false do
      entry = %{
        user_id: id,
        display_name: User.public_name(user),
        avatar_url: user.avatar_url,
        presence: "offline"
      }

      cond do
        company = tables[id] ->
          %{entry | presence: "at_table"} |> Map.put(:table_company, company)

        MapSet.member?(connected, id) ->
          %{entry | presence: "online"}

        true ->
          entry
      end
    end
  end

  # Connected players holding a human seat, with whether anyone else human sits
  # there. A connected spectator holds no seat and stays online.
  defp seated_company({room, connected}) do
    humans = for {_, %{occupant_type: :human, user_id: id}} <- room.seats, do: id

    for id <- humans, Map.has_key?(connected, id) do
      {id, if(Enum.any?(humans, &(&1 != id)), do: "people", else: "bots")}
    end
  end

  defp changed(user_id, friend_id) do
    for id <- [user_id, friend_id] do
      Phoenix.PubSub.broadcast(PidroServer.PubSub, "lobby:updates", {:friends_changed, id})
    end
  end
end

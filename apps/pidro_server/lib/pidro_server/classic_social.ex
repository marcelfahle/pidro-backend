defmodule PidroServer.ClassicSocial do
  @moduledoc "Classic social facts, resolved when both players have claimed."
  import Ecto.Query
  require Logger

  alias PidroServer.Accounts.User
  alias PidroServer.Blocks
  alias PidroServer.Blocks.Block
  alias PidroServer.Friends.Friendship
  alias PidroServer.Repo

  @doc "Keeps optional social arrays separate from the progression input."
  @spec legacy_data(map()) :: map()
  def legacy_data(data) do
    for key <- [:friend_ids, :friended_by_ids, :blocked_ids],
        value = Map.get(data, key, Map.get(data, Atom.to_string(key))),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  @doc "Stores directed Classic facts inside the claim transaction, idempotently."
  @spec store(integer(), map()) :: :ok
  def store(classic_id, data) do
    data = legacy_data(data)

    friendships =
      for id <- Map.get(data, :friend_ids, []),
          do: %{classic_user_id: classic_id, classic_friend_id: id}

    incoming =
      for id <- Map.get(data, :friended_by_ids, []),
          do: %{classic_user_id: id, classic_friend_id: classic_id}

    blocks =
      for id <- Map.get(data, :blocked_ids, []),
          do: %{classic_user_id: classic_id, classic_blocked_id: id}

    # Two mutual friends may claim together and insert the same facts. Keep
    # unique-index locks in the same order in both claim transactions.
    friendships =
      Enum.sort_by(friendships ++ incoming, &{&1.classic_user_id, &1.classic_friend_id})

    Repo.insert_all("classic_friendships", friendships, on_conflict: :nothing)
    Repo.insert_all("classic_blocks", blocks, on_conflict: :nothing)
    :ok
  end

  @doc "Counts outgoing Classic friends who do not yet have a claimed user."
  @spec not_here(integer()) :: non_neg_integer()
  def not_here(classic_id) do
    Repo.one(
      from f in "classic_friendships",
        left_join: u in User,
        on: u.classic_user_id == f.classic_friend_id,
        where: f.classic_user_id == ^classic_id and is_nil(u.id),
        select: count(f.classic_friend_id)
    )
  end

  @doc "Resolves touching edges after commit; failures are logged and emitted as telemetry."
  @spec resolve_classic(User.t()) :: :ok | {:error, term()}
  def resolve_classic(%User{classic_user_id: nil}), do: :ok

  def resolve_classic(%User{classic_user_id: classic_id}) do
    friends = edge_query("classic_friendships", :classic_friend_id, classic_id, "friend")

    # Both kinds must see the same claimed users, even if a claim commits
    # during discovery. Otherwise a friendship could appear without its block.
    edge_query("classic_blocks", :classic_blocked_id, classic_id, "block")
    |> union_all(^friends)
    |> Repo.all()
    |> Enum.group_by(fn {_kind, a, b} -> Enum.sort([a, b]) end)
    |> Enum.reduce_while(:ok, fn {pair, edges}, :ok ->
      case resolve_pair(pair, edges) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, failed(classic_id, reason)}
      end
    end)
  rescue
    error -> failed(classic_id, error)
  end

  defp edge_query(table, other_field, classic_id, kind) do
    from e in table,
      join: a in User,
      on: a.classic_user_id == e.classic_user_id,
      join: b in User,
      on: b.classic_user_id == field(e, ^other_field),
      where: e.classic_user_id == ^classic_id or field(e, ^other_field) == ^classic_id,
      where: a.id != b.id and not a.guest and not b.guest,
      select: {type(^kind, :string), a.id, b.id}
  end

  defp resolve_pair([a, b], edges) do
    # Use the same ordered locks as live friend adds and blocks. Each pair has
    # its own transaction, so overlapping claims never hold multiple pairs.
    result =
      Repo.transaction(fn ->
        Blocks.lock_pair(a, b)

        for {"block", user_id, blocked_id} <- edges do
          Repo.insert!(Block.changeset(user_id, blocked_id),
            on_conflict: :nothing,
            conflict_target: [:user_id, :blocked_id]
          )
        end

        if Blocks.blocked?(a, b) do
          Repo.delete_all(
            from f in Friendship,
              where:
                (f.user_id == ^a and f.friend_id == ^b) or
                  (f.user_id == ^b and f.friend_id == ^a)
          )
        else
          for {"friend", user_id, friend_id} <- edges do
            Repo.insert!(Friendship.changeset(user_id, friend_id),
              on_conflict: :nothing,
              conflict_target: [:user_id, :friend_id]
            )
          end
        end
      end)

    case result do
      {:ok, _} ->
        for id <- [a, b] do
          Phoenix.PubSub.broadcast(PidroServer.PubSub, "lobby:updates", {:friends_changed, id})
        end

      {:error, _} ->
        :ok
    end

    result
  end

  defp failed(classic_id, reason) do
    Logger.error(
      "Classic social resolution failed for classic_user_id=#{classic_id}: #{inspect(reason)}"
    )

    :telemetry.execute(
      [:pidro_server, :classic_social, :resolve, :error],
      %{count: 1},
      %{classic_user_id: classic_id, reason: reason}
    )

    {:error, reason}
  end
end

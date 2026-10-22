defmodule PidroServer.GameReports do
  @moduledoc "Private reports. Admin reads and bounded retention are trusted internal APIs only."
  import Ecto.Query
  alias PidroServer.GameReports.{Report, Validation}
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  def create(user_id, params) do
    with {:ok, attrs} <- Validation.validate(params),
         true <- participant?(user_id, attrs) do
      persist(user_id, attrs)
    else
      false -> {:error, :not_participant}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp persist(user_id, attrs) do
    result =
      Repo.transaction(fn ->
        # A database lock serializes the per-user quota across all server nodes.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [user_id])
        cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

        count =
          Repo.aggregate(
            from(r in Report, where: r.user_id == ^user_id and r.inserted_at > ^cutoff),
            :count
          )

        if count >= 5, do: Repo.rollback(:rate_limited)
        Repo.insert!(struct!(Report, Map.put(attrs, :user_id, user_id)), log: false)
      end)

    case result do
      {:ok, report} ->
        PidroServer.Diagnostics.emit(:report_created, %{
          report_id: report.id,
          user_id: report.user_id,
          room_code: report.room_code,
          game_instance_id: report.game_instance_id
        })

        {:ok, report}

      error ->
        error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp participant?(user_id, attrs) do
    current_participant?(user_id, attrs) or
      Repo.exists?(
        from(g in GameStats,
          where:
            g.game_instance_id == ^attrs.game_instance_id and
              g.room_code == ^attrs.room_code and ^user_id in g.player_ids and
              not is_nil(g.completed_at)
        )
      ) or archived_participant?(user_id, attrs)
  end

  defp archived_participant?(user_id, attrs) do
    case Application.get_env(:pidro_server, :game_report_archive_lookup) do
      nil -> false
      module -> module.participant?(attrs.game_instance_id, attrs.room_code, user_id) === true
    end
  end

  defp current_participant?(user_id, attrs) do
    with {:ok, room1} <- RoomManager.get_room(attrs.room_code),
         true <- room1.status in [:playing, :finished] and room1.game_number > 0,
         true <- user_id in Map.values(room1.positions),
         {:ok, snap1} <- GameAdapter.get_snapshot(attrs.room_code),
         true <- snap1.game_instance_id == attrs.game_instance_id,
         {:ok, room2} <- RoomManager.get_room(attrs.room_code),
         true <- room_identity(room1) == room_identity(room2),
         {:ok, snap2} <- GameAdapter.get_snapshot(attrs.room_code) do
      snap2.game_instance_id == attrs.game_instance_id
    else
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp room_identity(room),
    do:
      Map.take(room, [
        :id,
        :status,
        :positions,
        :game_number,
        :game_started_at,
        :snapshot_revision
      ])

  @doc "Trusted internal admin API; caller must enforce admin authorization. No public route."
  def admin_list(limit \\ 50) when is_integer(limit) and limit in 1..100 do
    admin_search(limit: limit)
  end

  @doc """
  Trusted internal admin search, newest first. Keyword filters are ANDed:
  report_id, user_id, game_instance_id, room_code, build, from (inclusive UTC
  DateTime), to (exclusive UTC DateTime), before ({UTC DateTime, report UUID}),
  limit (1..100, default 50). Invalid options raise ArgumentError.
  """
  def admin_search(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    unless is_integer(limit) and limit in 1..100, do: raise(ArgumentError, "invalid report limit")

    query = Enum.reduce(Keyword.delete(opts, :limit), Report, &search_filter/2)

    Repo.all(from(r in query, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit),
      log: false
    )
  end

  defp search_filter({key, value}, query)
       when key in [:report_id, :user_id] and is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} ->
        field_name = if key == :report_id, do: :id, else: :user_id
        where(query, [r], field(r, ^field_name) == ^id)

      _ ->
        raise ArgumentError, "invalid report identity filter"
    end
  end

  defp search_filter({key, value}, query)
       when key in [:game_instance_id, :room_code, :build] and is_binary(value) and
              byte_size(value) in 1..64,
       do: where(query, [r], field(r, ^key) == ^value)

  defp search_filter({:from, %DateTime{utc_offset: 0, std_offset: 0} = time}, query),
    do: where(query, [r], r.inserted_at >= ^time)

  defp search_filter({:to, %DateTime{utc_offset: 0, std_offset: 0} = time}, query),
    do: where(query, [r], r.inserted_at < ^time)

  defp search_filter({:before, {%DateTime{utc_offset: 0, std_offset: 0} = time, id}}, query) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        where(query, [r], r.inserted_at < ^time or (r.inserted_at == ^time and r.id < ^id))

      _ ->
        raise ArgumentError, "invalid report cursor"
    end
  end

  defp search_filter(_, _), do: raise(ArgumentError, "invalid report filter")

  @doc "Trusted internal admin API; caller must enforce admin authorization."
  def admin_get(id), do: Repo.get(Report, id, log: false)

  @doc "Delete at most 1000 reports older than 30 days. Ops repeats until zero."
  def cleanup(limit \\ 1000) when is_integer(limit) and limit in 1..1000 do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    ids =
      from r in Report,
        where: r.inserted_at < ^cutoff,
        order_by: r.inserted_at,
        limit: ^limit,
        select: r.id

    Repo.delete_all(from r in Report, where: r.id in subquery(ids))
  end
end

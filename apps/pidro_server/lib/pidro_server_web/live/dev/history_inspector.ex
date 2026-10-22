defmodule PidroServerWeb.Dev.HistoryInspector do
  @moduledoc "Read-only admin history queries and validated URL filters. No engine decoding."

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.GameArchive
  alias PidroServer.GameReports
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  @page_size 25
  @fields ~w(user_id room_code game_instance_id status report_id build from to before_at before_id revision after_revision player)
  @compile {:no_warn_undefined, [GameArchive, GameReports]}

  def fields, do: @fields

  def load(action, params) do
    with {:ok, opts} <- filters(params),
         {:ok, opts} <- resolve_player(opts) do
      {:ok, read(action, params, opts)}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, "Evidence storage is unavailable. This does not mean no history exists."}
  end

  defp filters(params) do
    result =
      Enum.reduce_while(@fields, {:ok, []}, fn field, {:ok, opts} ->
        case parse(field, Map.get(params, field, "")) do
          {:ok, nil} ->
            {:cont, {:ok, opts}}

          {:ok, value} ->
            {:cont, {:ok, [{key(field), value} | opts]}}

          :error ->
            {:halt,
             {:error, "Invalid #{field}. Use the indicated format; times require a UTC offset."}}
        end
      end)

    with {:ok, opts} <- result do
      cond do
        opts[:from] && opts[:to] && DateTime.compare(opts[:from], opts[:to]) != :lt ->
          {:error, "From must be earlier than To (exclusive)."}

        !!opts[:before_at] != !!opts[:before_id] ->
          {:error, "Incomplete page cursor. Start a new search."}

        true ->
          {:ok, opts}
      end
    end
  end

  # Keys come only from the static field list, never from input.
  defp key(field), do: String.to_existing_atom(field)
  defp parse(_, ""), do: {:ok, nil}

  defp parse(field, value) when field in ~w(from to before_at) and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse(field, value) when field in ~w(revision after_revision) and is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and number <= 9_007_199_254_740_991 -> {:ok, number}
      _ -> :error
    end
  end

  defp parse(field, value) when field in ~w(user_id report_id) and is_binary(value),
    do: Ecto.UUID.cast(value)

  defp parse("status", value) when value in ~w(active complete closed interrupted),
    do: {:ok, value}

  defp parse("status", _), do: :error
  defp parse("room_code", value), do: token(value, ~r/^[A-Z0-9]{4,12}$/)
  defp parse("build", value), do: token(value, ~r/^[0-9]{1,20}$/)

  defp parse(field, value) when field in ~w(game_instance_id before_id),
    do: token(value, ~r/^[A-Za-z0-9_-]{1,64}$/)

  defp parse("player", value) when is_binary(value) and byte_size(value) <= 80,
    do: {:ok, String.trim(value)}

  defp parse(_, _), do: :error

  defp token(value, regex) when is_binary(value),
    do: if(Regex.match?(regex, value), do: {:ok, value}, else: :error)

  defp token(_, _), do: :error

  defp resolve_player(opts) do
    if opts[:player] do
      users =
        Repo.all(
          from u in User,
            where: u.username == ^opts[:player] or u.display_name == ^opts[:player],
            select: u.id,
            limit: 2
        )

      case users do
        [id] ->
          if opts[:user_id] && opts[:user_id] != id,
            do: {:error, "Player name and user ID do not match."},
            else: {:ok, Keyword.put(opts, :user_id, id)}

        [] ->
          {:error, "No player with that exact username or display name. Try a user ID."}

        _ ->
          {:error,
           "That display name matches multiple accounts. Use the player admin page to choose a user ID."}
      end
    else
      {:ok, opts}
    end
  end

  defp page_opts(opts, keys) do
    selected = Keyword.take(opts, keys) |> Keyword.put(:limit, @page_size)

    if opts[:before_at],
      do: Keyword.put(selected, :before, {opts[:before_at], opts[:before_id]}),
      else: selected
  end

  defp read(:archives, _params, opts) do
    rows =
      GameArchive.search(
        page_opts(opts, [:from, :to, :user_id, :room_code, :game_instance_id, :status])
      )

    %{rows: rows, next: cursor(rows, :started_at, :game_instance_id)}
  end

  defp read(:reports, _params, opts) do
    rows =
      GameReports.admin_search(
        page_opts(opts, [:from, :to, :user_id, :room_code, :game_instance_id, :report_id, :build])
      )

    %{rows: rows, next: cursor(rows, :inserted_at, :id)}
  end

  defp read(:archive, %{"id" => id}, opts) do
    with {:ok, _} <- token(id, ~r/^[A-Za-z0-9_-]{1,64}$/),
         archive when not is_nil(archive) <- GameArchive.get(id) do
      snapshot = GameArchive.snapshot(id, opts[:revision] || :latest)

      events =
        GameArchive.events(id, after_revision: opts[:after_revision] || -1, limit: @page_size)

      %{
        archive: archive,
        snapshot: snapshot,
        events: events,
        next_event: if(length(events) == @page_size, do: List.last(events).revision),
        next_step: if(snapshot, do: GameArchive.step(id, snapshot["state_revision"])),
        names: participant_names(archive.participants),
        reports: GameReports.admin_search(game_instance_id: id, limit: @page_size)
      }
    else
      _ -> %{archive: nil}
    end
  end

  defp read(:report, %{"id" => id}, _opts) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        report = GameReports.admin_get(id)
        archive = if report, do: GameArchive.get(report.game_instance_id)
        %{report: report, archive: archive}

      :error ->
        %{report: nil, archive: nil}
    end
  end

  defp read(:summaries, _params, opts) do
    query = from g in GameStats, order_by: [desc: g.completed_at, desc: g.id], limit: @page_size

    query =
      Enum.reduce(
        Keyword.take(opts, [:user_id, :room_code, :game_instance_id, :from, :to]),
        query,
        &summary_filter/2
      )

    query =
      if opts[:before_at],
        do:
          from(g in query,
            where:
              g.completed_at < ^opts[:before_at] or
                (g.completed_at == ^opts[:before_at] and g.id < ^opts[:before_id])
          ),
        else: query

    rows = Repo.all(query)
    %{rows: rows, next: cursor(rows, :completed_at, :id)}
  end

  defp read(:summary, %{"id" => id}, _opts) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> %{summary: Repo.get(GameStats, id)}
      :error -> %{summary: nil}
    end
  end

  defp summary_filter({:user_id, id}, query), do: from(g in query, where: ^id in g.player_ids)

  defp summary_filter({:room_code, code}, query),
    do: from(g in query, where: g.room_code == ^code)

  defp summary_filter({:game_instance_id, id}, query),
    do: from(g in query, where: g.game_instance_id == ^id)

  defp summary_filter({:from, dt}, query), do: from(g in query, where: g.completed_at >= ^dt)
  defp summary_filter({:to, dt}, query), do: from(g in query, where: g.completed_at < ^dt)

  defp cursor(rows, time, id) when length(rows) == @page_size do
    last = List.last(rows)

    %{
      "before_at" => DateTime.to_iso8601(Map.fetch!(last, time)),
      "before_id" => Map.fetch!(last, id)
    }
  end

  defp cursor(_, _, _), do: nil

  defp participant_names(participants) do
    ids =
      participants
      |> Map.values()
      |> Enum.map(& &1["user_id"])
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    Repo.all(
      from u in User,
        where: u.id in ^ids,
        select: {u.id, %{username: u.username, display_name: u.display_name}}
    )
    |> Map.new()
  end
end

defmodule PidroServer.Games.Room.Config do
  @moduledoc """
  The record of how a room was set up: its name, the bot difficulty requested
  at creation, and whether it is a solo table.

  A config is set once, when the room is created, and does not change for the
  life of the room. The seat plan sent at creation is not part of it: seats
  change during play, so `parse_create_params/1` returns the plan beside the
  config as a create-time input.

  There are two ways in, and both end at the same validation:

    * `new/1` - the internal constructor. Takes attributes (a keyword list or a
      map with atom or string keys) and accepts `solo` directly.
    * `parse_create_params/1` - the boundary parser. Takes a string-keyed
      create-room request body, derives `solo` from the seat plan, and rejects
      every key the grammar below does not name.

  ## Create request grammar

      body            := { name?, seats?, bot_difficulty? }
      name            := string, trimmed, at most 60 chars; missing or blank -> none
      seats           := { seat_2?, seat_3?, seat_4? }      any other key -> error "seats.<key>"
      seat            := "ai" | "open"                      missing -> "open"
      bot_difficulty  := "random" | "basic" | "smart"       missing -> "basic"

      solo            := seat_2 = seat_3 = seat_4 = "ai"
      seat_plan       := { east <- seat_2, south <- seat_3, west <- seat_4 }

  ## Errors

  Both entry points collect every problem rather than stopping at the first and
  return `{:error, {:invalid_room_params, errors}}`, where each error is
  `%{field: path, message: text}` and `path` names the offending field, such as
  `"settings"`, `"bot_difficulty"` or `"seats.seat_5"`. Caller input is never
  converted to an atom.

  This module is pure: it reads no application config, no repo and no process.
  """

  @type bot_difficulty :: :random | :basic | :smart
  @type seat_plan :: %{east: :bot | :open, south: :bot | :open, west: :bot | :open}
  @type error :: %{field: String.t(), message: String.t()}
  @type errors :: {:invalid_room_params, [error()]}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          bot_difficulty: bot_difficulty(),
          solo: boolean()
        }

  defstruct name: nil, bot_difficulty: :basic, solo: false

  @max_name_length 60

  @difficulties [:random, :basic, :smart]
  @difficulty_by_wire %{"random" => :random, "basic" => :basic, "smart" => :smart}

  # Validation and error order for the config's own fields.
  @fields [:name, :bot_difficulty, :solo]
  @field_by_wire %{"name" => :name, "bot_difficulty" => :bot_difficulty, "solo" => :solo}

  @accepted_fields ["name", "seats", "bot_difficulty"]

  # Seat order for the plan and for seat errors.
  @seats [{"seat_2", :east}, {"seat_3", :south}, {"seat_4", :west}]
  @seat_keys Enum.map(@seats, &elem(&1, 0))

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc "Returns the default config: no name, `:basic` difficulty, not solo."
  @spec new() :: {:ok, t()}
  def new, do: {:ok, %__MODULE__{}}

  @doc """
  Builds a config from attributes.

  Accepts a keyword list or a map with atom or string keys, or an existing
  config, which is validated and returned. The recognised keys are `name`,
  `bot_difficulty` (an atom or its wire string) and `solo`. A missing key takes
  its default. Any other key is rejected, as is a key given more than once.

  ## Examples

      iex> PidroServer.Games.Room.Config.new(name: " Friday ", bot_difficulty: "smart")
      {:ok, %PidroServer.Games.Room.Config{name: "Friday", bot_difficulty: :smart, solo: false}}

      iex> PidroServer.Games.Room.Config.new(is_dev_room: true)
      {:error, {:invalid_room_params, [%{field: "is_dev_room", message: "is not an accepted field"}]}}
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, errors()}
  def new(%__MODULE__{} = config), do: config |> Map.from_struct() |> build()
  def new(attrs) when is_map(attrs) and not is_struct(attrs), do: build(attrs)

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: build(attrs), else: invalid_attrs()
  end

  def new(_attrs), do: invalid_attrs()

  # ---------------------------------------------------------------------------
  # Boundary Parser
  # ---------------------------------------------------------------------------

  @doc """
  Parses a string-keyed create-room request body into a config and a seat plan.

  `solo` is derived here, once: it is true when seats 2, 3 and 4 are all `"ai"`.
  The name and difficulty then go through the same validation as `new/1`.

  Errors are ordered: `name`, then `seats` (known seats in seat order, then
  unknown seat keys sorted), then `bot_difficulty`, then unknown top-level keys
  sorted.

  ## Examples

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"seats" => %{"seat_3" => "ai"}})
      {:ok, %PidroServer.Games.Room.Config{}, %{east: :open, south: :bot, west: :open}}

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"settings" => %{}})
      {:error, {:invalid_room_params, [%{field: "settings", message: "is not an accepted field"}]}}
  """
  @spec parse_create_params(term()) :: {:ok, t(), seat_plan()} | {:error, errors()}
  def parse_create_params(body) when is_map(body) and not is_struct(body) do
    {seat_plan, seat_errors} = parse_seats(body)
    unknown_errors = unknown_key_errors(Map.keys(body), @accepted_fields, "", &body_label/1)

    {config, config_errors} =
      body
      |> Map.take(["name", "bot_difficulty"])
      |> Map.put("solo", solo_plan?(seat_plan))
      |> build()
      |> split_result()

    {name_errors, difficulty_errors} = Enum.split_with(config_errors, &(&1.field == "name"))

    case name_errors ++ seat_errors ++ difficulty_errors ++ unknown_errors do
      [] -> {:ok, config, seat_plan}
      errors -> {:error, {:invalid_room_params, errors}}
    end
  end

  def parse_create_params(_body) do
    {:error, {:invalid_room_params, [error("body", "must be a JSON object")]}}
  end

  @doc """
  Returns the top-level field names a create-room request may contain.

  The OpenAPI create-request schema is checked against this list so the two
  descriptions cannot drift apart.
  """
  @spec accepted_fields() :: [String.t()]
  def accepted_fields, do: @accepted_fields

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Converts a config to a JSON-safe map. The difficulty is emitted as its wire
  string.
  """
  @spec serialize(t()) :: %{name: String.t() | nil, bot_difficulty: String.t(), solo: boolean()}
  def serialize(%__MODULE__{} = config) do
    %{
      name: config.name,
      bot_difficulty: Atom.to_string(config.bot_difficulty),
      solo: config.solo
    }
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  # The one validation both entry points end at. `attrs` is any enumerable of
  # `{key, value}` pairs.
  defp build(attrs) do
    {known, duplicates, unknown} = classify(attrs)
    defaults = %__MODULE__{}

    results =
      Enum.map(@fields, fn field ->
        cond do
          field in duplicates -> {field, {:error, "was given more than once"}}
          Map.has_key?(known, field) -> {field, validate(field, Map.fetch!(known, field))}
          true -> {field, {:ok, Map.fetch!(defaults, field)}}
        end
      end)

    field_errors =
      for {field, {:error, message}} <- results, do: error(Atom.to_string(field), message)

    case field_errors ++ unknown_key_errors(unknown, [], "", &attr_label/1) do
      [] ->
        {:ok, struct!(__MODULE__, for({field, {:ok, value}} <- results, do: {field, value}))}

      errors ->
        {:error, {:invalid_room_params, errors}}
    end
  end

  # Sorts attribute keys into recognised fields, fields given twice (as an atom
  # and a string, or repeated in a keyword list), and everything else.
  defp classify(attrs) do
    Enum.reduce(attrs, {%{}, [], []}, fn {key, value}, {known, duplicates, unknown} ->
      case field_for(key) do
        nil ->
          {known, duplicates, [key | unknown]}

        field when is_map_key(known, field) ->
          {known, Enum.uniq([field | duplicates]), unknown}

        field ->
          {Map.put(known, field, value), duplicates, unknown}
      end
    end)
  end

  defp field_for(key) when key in @fields, do: key
  defp field_for(key) when is_binary(key), do: Map.get(@field_by_wire, key)
  defp field_for(_key), do: nil

  defp validate(:name, nil), do: {:ok, nil}

  defp validate(:name, name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > @max_name_length -> {:error, name_length_message()}
      true -> {:ok, trimmed}
    end
  end

  defp validate(:name, _other), do: {:error, "must be a string"}

  defp validate(:bot_difficulty, difficulty) when difficulty in @difficulties,
    do: {:ok, difficulty}

  defp validate(:bot_difficulty, difficulty) do
    # An explicit lookup: caller input is never turned into an atom.
    case Map.fetch(@difficulty_by_wire, difficulty) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, "must be one of: #{Enum.join(@difficulties, ", ")}"}
    end
  end

  defp validate(:solo, solo) when is_boolean(solo), do: {:ok, solo}
  defp validate(:solo, _other), do: {:error, "must be a boolean"}

  defp name_length_message, do: "must be at most #{@max_name_length} characters"

  # ---------------------------------------------------------------------------
  # Seat Plan
  # ---------------------------------------------------------------------------

  defp parse_seats(body) do
    case Map.fetch(body, "seats") do
      :error ->
        {open_plan(), []}

      {:ok, seats} when is_map(seats) and not is_struct(seats) ->
        results =
          Enum.map(@seats, fn {key, position} -> {key, position, parse_seat(seats, key)} end)

        plan =
          Map.new(results, fn
            {_key, position, {:ok, occupant}} -> {position, occupant}
            {_key, position, {:error, _message}} -> {position, :open}
          end)

        value_errors =
          for {key, _position, {:error, message}} <- results, do: error("seats." <> key, message)

        {plan,
         value_errors ++ unknown_key_errors(Map.keys(seats), @seat_keys, "seats.", &body_label/1)}

      {:ok, _other} ->
        {open_plan(), [error("seats", "must be an object")]}
    end
  end

  defp parse_seat(seats, key) do
    case Map.fetch(seats, key) do
      :error -> {:ok, :open}
      {:ok, "ai"} -> {:ok, :bot}
      {:ok, "open"} -> {:ok, :open}
      {:ok, _other} -> {:error, "must be one of: ai, open"}
    end
  end

  defp open_plan, do: Map.new(@seats, fn {_key, position} -> {position, :open} end)

  defp solo_plan?(seat_plan), do: Enum.all?(seat_plan, fn {_position, seat} -> seat == :bot end)

  # ---------------------------------------------------------------------------
  # Errors
  # ---------------------------------------------------------------------------

  defp unknown_key_errors(keys, accepted, prefix, label) do
    keys
    |> Enum.reject(&(&1 in accepted))
    |> Enum.map(label)
    |> Enum.sort()
    |> Enum.map(&error(prefix <> &1, "is not an accepted field"))
  end

  # Path segments for unknown keys. Neither ever mints an atom from a key.
  # Internal attributes may be atom-keyed, so `:is_dev_room` reads "is_dev_room".
  defp attr_label(key) when is_atom(key), do: Atom.to_string(key)
  defp attr_label(key), do: body_label(key)

  # A request body is string-keyed, so any other key shows as written: ":name".
  defp body_label(key) when is_binary(key), do: key
  defp body_label(key), do: inspect(key)

  defp split_result({:ok, config}), do: {config, []}
  defp split_result({:error, {:invalid_room_params, errors}}), do: {nil, errors}

  defp invalid_attrs do
    {:error,
     {:invalid_room_params, [error("config", "must be a map, a keyword list or a config")]}}
  end

  defp error(field, message), do: %{field: field, message: message}
end

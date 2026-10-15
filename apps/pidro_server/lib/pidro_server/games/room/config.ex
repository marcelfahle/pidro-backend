defmodule PidroServer.Games.Room.Config do
  @moduledoc """
  The record of how a room was set up: its name, legacy bot preference,
  and whether it is a solo table.

  `bot_difficulty` is deprecated compatibility data for older clients. It is
  still validated and echoed, but every accepted value uses the same production
  rulebook. New clients should omit it.

  Seat requirements and friend holds stay in the config; holds are consumed
  when their user sits down or released by the host. The initial bot/open
  plan is returned beside it because occupants change during play.

  There are two ways in, and both end at the same validation:

    * `new/1` - the internal constructor. Takes attributes (a keyword list or a
      map with atom or string keys) and accepts `solo` directly.
    * `parse_create_params/1` - the boundary parser. Takes a string-keyed
      create-room request body, derives `solo` from the seat plan, and rejects
      every key the grammar below does not name.

  ## Create request grammar

      body            := { name?, seats?, bot_difficulty?, rule_set? }
      name            := string, trimmed, at most 60 chars; missing or blank -> none
                         at most 4096 bytes as sent, whatever the char count
      seats           := { seat_2?, seat_3?, seat_4? }      any other key -> error "seats.<key>"
      seat            := "ai" | "open" | { type: "open", min_games: 0 | 100 | 1000 }
      bot_difficulty  := "random" | "basic" | "smart"       missing -> "basic"
      rule_set        := "finnish" | "louisiana"             missing -> "finnish"

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
  @type seat_plan :: %{
          east: :bot | :open | :held,
          south: :bot | :open | :held,
          west: :bot | :open | :held
        }
  @type error :: %{field: String.t(), message: String.t()}
  @type errors :: {:invalid_room_params, [error()]}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          bot_difficulty: bot_difficulty(),
          rule_set: :finnish | :louisiana,
          solo: boolean(),
          seat_requirements: %{optional(atom()) => 0 | 100 | 1000},
          seat_holds: %{optional(atom()) => Ecto.UUID.t()}
        }

  defstruct name: nil,
            bot_difficulty: :basic,
            rule_set: :finnish,
            solo: false,
            seat_requirements: %{},
            seat_holds: %{}

  @max_name_length 60

  # A character is a grapheme, and one grapheme can carry any number of
  # combining marks, so the character cap alone does not bound a name's size.
  # The longest emoji sequence Unicode recommends is 35 bytes, which puts 60 of
  # them at 2100 bytes; 4096 leaves every real name alone and is checked on the
  # raw input, before anything walks the string.
  @max_name_bytes 4096

  @difficulties [:random, :basic, :smart]
  @difficulty_by_wire %{"random" => :random, "basic" => :basic, "smart" => :smart}
  @difficulty_wire_values Enum.map(@difficulties, &Atom.to_string/1)

  # Validation and error order for the config's own fields.
  @fields [:name, :bot_difficulty, :rule_set, :solo, :seat_requirements, :seat_holds]
  @field_by_wire %{
    "name" => :name,
    "bot_difficulty" => :bot_difficulty,
    "rule_set" => :rule_set,
    "solo" => :solo,
    "seat_requirements" => :seat_requirements,
    "seat_holds" => :seat_holds
  }
  @rule_set_by_wire %{"finnish" => :finnish, "louisiana" => :louisiana}

  @accepted_fields ["name", "seats", "bot_difficulty", "rule_set"]

  # Seat order for the plan and for seat errors.
  @seats [{"seat_2", :east}, {"seat_3", :south}, {"seat_4", :west}]
  @seat_keys Enum.map(@seats, &elem(&1, 0))

  # What a seat may be asked to hold, in the order the error message lists them.
  @seat_occupants [{"ai", :bot}, {"open", :open}]
  @seat_values Enum.map(@seat_occupants, &elem(&1, 0))

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc "Returns the default config: no name, `:basic` difficulty, Finnish rules, not solo."
  @spec new() :: {:ok, t()}
  def new, do: {:ok, %__MODULE__{}}

  @doc """
  Builds a config from attributes.

  Accepts a keyword list or a map with atom or string keys, or an existing
  config, which is validated and returned. The recognised keys are `name`,
  `bot_difficulty` and `rule_set` (atoms or wire strings), `solo`, and
  `seat_requirements` (position atoms mapped to 0, 100 or 1000). A missing key
  takes its default. Any other key is rejected, as is a key given more than once.

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
  unknown seat keys sorted), then `bot_difficulty`, then `rule_set`, then unknown top-level keys
  sorted.

  ## Examples

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"seats" => %{"seat_3" => "ai"}})
      {:ok, %PidroServer.Games.Room.Config{}, %{east: :open, south: :bot, west: :open}}

      iex> PidroServer.Games.Room.Config.parse_create_params(%{"settings" => %{}})
      {:error, {:invalid_room_params, [%{field: "settings", message: "is not an accepted field"}]}}
  """
  @spec parse_create_params(term()) :: {:ok, t(), seat_plan()} | {:error, errors()}
  def parse_create_params(body) when is_map(body) and not is_struct(body) do
    {seat_plan, requirements, holds, seat_errors} = parse_seats(body)
    unknown_errors = unknown_key_errors(Map.keys(body), @accepted_fields, "", &body_label/1)

    {config, config_errors} =
      body
      |> Map.take(["name", "bot_difficulty", "rule_set"])
      |> Map.put("solo", solo_plan?(seat_plan))
      |> Map.put("seat_requirements", requirements)
      |> Map.put("seat_holds", holds)
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

  @doc """
  Returns the accepted `bot_difficulty` wire strings, in declared order.

  Like the three functions below, this is a value constraint of the create
  request. The OpenAPI room schemas take their enums and name cap from these
  functions, and a spec test checks the published spec against them.
  """
  @spec difficulties() :: [String.t()]
  def difficulties, do: @difficulty_wire_values

  @doc "Returns the accepted rule-set wire strings."
  @spec rule_sets() :: [String.t()]
  def rule_sets, do: ["finnish", "louisiana"]

  @doc "Returns the keys a create request's `seats` object may contain, in seat order."
  @spec seat_keys() :: [String.t()]
  def seat_keys, do: @seat_keys

  @doc "Returns the values a create request may give a seat."
  @spec seat_values() :: [String.t()]
  def seat_values, do: @seat_values

  @doc "Returns the most characters a room name may have after trimming."
  @spec max_name_length() :: pos_integer()
  def max_name_length, do: @max_name_length

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Converts a config to a JSON-safe map. Difficulty and rule set are emitted as wire strings.
  """
  @spec serialize(t()) :: %{
          name: String.t() | nil,
          bot_difficulty: String.t(),
          rule_set: String.t(),
          solo: boolean()
        }
  def serialize(%__MODULE__{} = config) do
    %{
      name: config.name,
      bot_difficulty: Atom.to_string(config.bot_difficulty),
      rule_set: Atom.to_string(config.rule_set),
      solo: config.solo
    }
  end

  @doc "Serializes a seat with its configured requirement; occupied seats show zero."
  @spec serialize_seat(t(), PidroServer.Games.Room.Seat.t()) :: map()
  def serialize_seat(%__MODULE__{} = config, seat) do
    held_user_id = if seat.occupant_type == :vacant, do: config.seat_holds[seat.position]

    min_games =
      if seat.occupant_type == :vacant and is_nil(held_user_id),
        do: Map.get(config.seat_requirements, seat.position, 0),
        else: 0

    data = seat |> PidroServer.Games.Room.Seat.serialize() |> Map.put(:min_games, min_games)

    if held_user_id,
      do: Map.merge(data, %{status: "free", held_for: %{user_id: held_user_id}}),
      else: data
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

  defp validate(:name, name) when is_binary(name) and byte_size(name) > @max_name_bytes,
    do: {:error, name_length_message()}

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
      :error -> {:error, "must be one of: #{Enum.join(@difficulty_wire_values, ", ")}"}
    end
  end

  defp validate(:solo, solo) when is_boolean(solo), do: {:ok, solo}
  defp validate(:solo, _other), do: {:error, "must be a boolean"}

  defp validate(:seat_requirements, requirements) when is_map(requirements) do
    if Enum.all?(requirements, fn {position, games} ->
         position in [:east, :south, :west] and games in [0, 100, 1000]
       end),
       do: {:ok, requirements},
       else: {:error, "must map east, south or west to 0, 100 or 1000"}
  end

  defp validate(:seat_requirements, _), do: {:error, "must be a map"}

  defp validate(:seat_holds, holds) when is_map(holds) do
    if Enum.all?(holds, fn {position, user_id} ->
         position in [:north, :east, :south, :west] and
           match?({:ok, ^user_id}, Ecto.UUID.cast(user_id))
       end),
       do: {:ok, holds},
       else: {:error, "must map positions to user UUIDs"}
  end

  defp validate(:seat_holds, _), do: {:error, "must be a map"}

  defp validate(:rule_set, value) when value in [:finnish, :louisiana], do: {:ok, value}

  defp validate(:rule_set, value) do
    case Map.fetch(@rule_set_by_wire, value) do
      {:ok, known} -> {:ok, known}
      :error -> {:error, "must be one of: #{Enum.join(rule_sets(), ", ")}"}
    end
  end

  defp name_length_message, do: "must be at most #{@max_name_length} characters"

  # ---------------------------------------------------------------------------
  # Seat Plan
  # ---------------------------------------------------------------------------

  defp parse_seats(body) do
    case Map.fetch(body, "seats") do
      :error ->
        {open_plan(), %{}, %{}, []}

      {:ok, seats} when is_map(seats) and not is_struct(seats) ->
        results =
          Enum.map(@seats, fn {key, position} -> {key, position, parse_seat(seats, key)} end)

        plan =
          Map.new(results, fn
            {_key, position, {:ok, occupant, _min_games}} -> {position, occupant}
            {_key, position, {:error, _message}} -> {position, :open}
          end)

        requirements =
          for {_key, position, {:ok, :open, min_games}} <- results,
              min_games > 0,
              into: %{},
              do: {position, min_games}

        holds =
          for {_key, position, {:ok, :held, user_id}} <- results,
              into: %{},
              do: {position, user_id}

        value_errors =
          for {key, _position, {:error, message}} <- results, do: error("seats." <> key, message)

        {plan, requirements, holds,
         value_errors ++ unknown_key_errors(Map.keys(seats), @seat_keys, "seats.", &body_label/1)}

      {:ok, _other} ->
        {open_plan(), %{}, %{}, [error("seats", "must be an object")]}
    end
  end

  defp parse_seat(seats, key) do
    case Map.get(seats, key, "open") do
      "ai" ->
        {:ok, :bot, 0}

      "open" ->
        {:ok, :open, 0}

      %{"type" => "open", "min_games" => games} = value
      when games in [0, 100, 1000] and map_size(value) == 2 ->
        {:ok, :open, games}

      %{"type" => "held", "user_id" => user_id} = value when map_size(value) == 2 ->
        case Ecto.UUID.cast(user_id) do
          {:ok, id} -> {:ok, :held, id}
          :error -> {:error, "held seats require a user_id UUID"}
        end

      value when is_map(value) ->
        {:error, "must be an open seat with min_games of 0, 100 or 1000"}

      _ ->
        {:error, "must be one of: #{Enum.join(@seat_values, ", ")}"}
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

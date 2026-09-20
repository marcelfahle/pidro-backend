defmodule PidroServer.Games.Room.ConfigTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.Config

  doctest Config

  @all_open %{east: :open, south: :open, west: :open}

  defp fields({:error, {:invalid_room_params, errors}}), do: Enum.map(errors, & &1.field)

  describe "default config" do
    test "new/0 returns no name, basic difficulty, not solo" do
      assert {:ok, %Config{name: nil, bot_difficulty: :basic, solo: false}} = Config.new()
    end

    test "new/1 with an empty map or keyword list equals the default" do
      {:ok, default} = Config.new()

      assert Config.new(%{}) == {:ok, default}
      assert Config.new([]) == {:ok, default}
    end

    test "the bare struct equals the default" do
      assert {:ok, %Config{}} == Config.new()
    end
  end

  describe "new/1 accepted attributes" do
    test "accepts a keyword list with atom keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :smart, solo: false}} =
               Config.new(name: "Friday", bot_difficulty: :smart)
    end

    test "accepts a map with atom keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :random, solo: true}} =
               Config.new(%{name: "Friday", bot_difficulty: :random, solo: true})
    end

    test "accepts a map with string keys" do
      assert {:ok, %Config{name: "Friday", bot_difficulty: :smart, solo: true}} =
               Config.new(%{"name" => "Friday", "bot_difficulty" => "smart", "solo" => true})
    end

    test "accepts solo: true with no seat plan" do
      assert {:ok, %Config{solo: true}} = Config.new(solo: true)
    end

    test "accepts the difficulty as a wire string or an atom alike" do
      assert Config.new(bot_difficulty: "random") == Config.new(bot_difficulty: :random)
      assert {:ok, %Config{bot_difficulty: :random}} = Config.new(bot_difficulty: "random")
      assert {:ok, %Config{bot_difficulty: :basic}} = Config.new(bot_difficulty: "basic")
      assert {:ok, %Config{bot_difficulty: :smart}} = Config.new(bot_difficulty: :smart)
    end

    test "returns an existing config unchanged" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.new(config) == {:ok, config}
    end

    test "treats a nil name as no name" do
      assert {:ok, %Config{name: nil}} = Config.new(name: nil)
    end

    test "round-trips a serialized config" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.new(Config.serialize(config)) == {:ok, config}
    end
  end

  describe "new/1 rejected attributes" do
    test "rejects is_dev_room as an unknown key" do
      assert {:error, {:invalid_room_params, [%{field: "is_dev_room", message: message}]}} =
               Config.new(%{is_dev_room: true})

      assert is_binary(message)
    end

    test "rejects an unknown string key without minting an atom" do
      key = "zz_room_config_never_an_atom_#{System.unique_integer([:positive])}"

      assert fields(Config.new(%{key => 1})) == [key]
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "rejects an unknown difficulty, as atom or string" do
      assert fields(Config.new(bot_difficulty: :expert)) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: "expert")) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: nil)) == ["bot_difficulty"]
      assert fields(Config.new(bot_difficulty: 3)) == ["bot_difficulty"]
    end

    test "rejects a non-boolean solo" do
      assert fields(Config.new(solo: "true")) == ["solo"]
      assert fields(Config.new(solo: nil)) == ["solo"]
    end

    test "rejects a non-string and an over-long name" do
      assert fields(Config.new(name: 42)) == ["name"]
      assert fields(Config.new(name: String.duplicate("a", 61))) == ["name"]
    end

    test "rejects a key given as both an atom and a string" do
      assert fields(Config.new(%{:name => "A", "name" => "B"})) == ["name"]
    end

    test "rejects attributes that are neither a map, a keyword list nor a config" do
      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} =
               Config.new("Friday")

      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} =
               Config.new([1, 2])

      assert {:error, {:invalid_room_params, [%{field: "config", message: _}]}} = Config.new(nil)
    end

    test "collects every error" do
      result = Config.new(name: 42, bot_difficulty: :expert, solo: 1, is_dev_room: true)

      assert fields(result) == ["name", "bot_difficulty", "solo", "is_dev_room"]
    end
  end

  describe "parse_create_params/1 happy paths" do
    test "an empty body parses to the default config with all seats open" do
      {:ok, default} = Config.new()

      assert Config.parse_create_params(%{}) == {:ok, default, @all_open}
    end

    test "a name, one ai seat and smart" do
      body = %{"name" => "Friday", "seats" => %{"seat_3" => "ai"}, "bot_difficulty" => "smart"}

      assert {:ok, config, seat_plan} = Config.parse_create_params(body)
      assert config == %Config{name: "Friday", bot_difficulty: :smart, solo: false}
      assert seat_plan == %{east: :open, south: :bot, west: :open}
    end

    test "maps seat_2 to east, seat_3 to south and seat_4 to west" do
      assert {:ok, _, %{east: :bot, south: :open, west: :open}} =
               Config.parse_create_params(%{"seats" => %{"seat_2" => "ai"}})

      assert {:ok, _, %{east: :open, south: :bot, west: :open}} =
               Config.parse_create_params(%{"seats" => %{"seat_3" => "ai"}})

      assert {:ok, _, %{east: :open, south: :open, west: :bot}} =
               Config.parse_create_params(%{"seats" => %{"seat_4" => "ai"}})
    end

    test "seats 2, 3 and 4 all ai parse to a solo config" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_3" => "ai", "seat_4" => "ai"}}

      assert {:ok, %Config{solo: true, bot_difficulty: :basic}, seat_plan} =
               Config.parse_create_params(body)

      assert seat_plan == %{east: :bot, south: :bot, west: :bot}
    end

    test "two ai seats and one missing seat key parse to not solo with the missing seat open" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_4" => "ai"}}

      assert {:ok, %Config{solo: false}, seat_plan} = Config.parse_create_params(body)
      assert seat_plan == %{east: :bot, south: :open, west: :bot}
    end

    test "explicit open seats and an empty seats object are all open" do
      explicit = %{"seats" => %{"seat_2" => "open", "seat_3" => "open", "seat_4" => "open"}}

      assert {:ok, %Config{solo: false}, @all_open} = Config.parse_create_params(explicit)

      assert {:ok, %Config{solo: false}, @all_open} =
               Config.parse_create_params(%{"seats" => %{}})
    end

    test "an omitted difficulty yields basic" do
      body = %{"seats" => %{"seat_2" => "ai"}}

      assert {:ok, %Config{bot_difficulty: :basic}, _} = Config.parse_create_params(body)
    end

    test "a difficulty supplied with no bot seat is accepted and stored" do
      assert {:ok, %Config{bot_difficulty: :random, solo: false}, @all_open} =
               Config.parse_create_params(%{"bot_difficulty" => "random"})
    end
  end

  describe "parse_create_params/1 name" do
    test "a name of only whitespace is stored as none" do
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => "  \t\n "})
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => ""})
    end

    test "a null name is stored as none" do
      assert {:ok, %Config{name: nil}, _} = Config.parse_create_params(%{"name" => nil})
    end

    test "a name with surrounding spaces is stored trimmed" do
      assert {:ok, %Config{name: "Friday night"}, _} =
               Config.parse_create_params(%{"name" => "  Friday night  "})
    end

    test "a 60-character name is accepted" do
      name = String.duplicate("a", 60)

      assert {:ok, %Config{name: ^name}, _} = Config.parse_create_params(%{"name" => name})
    end

    test "the cap counts characters, not bytes, and applies after trimming" do
      name = String.duplicate("å", 60)

      assert {:ok, %Config{name: ^name}, _} =
               Config.parse_create_params(%{"name" => "  " <> name <> "  "})
    end

    test "a 61-character name is rejected naming name" do
      result = Config.parse_create_params(%{"name" => String.duplicate("a", 61)})

      assert fields(result) == ["name"]
    end

    test "a non-string name is rejected naming name" do
      assert fields(Config.parse_create_params(%{"name" => 42})) == ["name"]
      assert fields(Config.parse_create_params(%{"name" => %{"first" => "x"}})) == ["name"]
      assert fields(Config.parse_create_params(%{"name" => ["x"]})) == ["name"]
    end
  end

  describe "parse_create_params/1 bot difficulty" do
    test "an unknown difficulty returns an error whose field path is bot_difficulty" do
      body = %{"seats" => %{"seat_2" => "ai"}, "bot_difficulty" => "expert"}

      assert {:error, {:invalid_room_params, [%{field: "bot_difficulty", message: message}]}} =
               Config.parse_create_params(body)

      assert message =~ "random"
      assert message =~ "basic"
      assert message =~ "smart"
    end

    test "null, non-string and wrongly-cased difficulties are rejected" do
      assert fields(Config.parse_create_params(%{"bot_difficulty" => nil})) == ["bot_difficulty"]
      assert fields(Config.parse_create_params(%{"bot_difficulty" => 1})) == ["bot_difficulty"]

      assert fields(Config.parse_create_params(%{"bot_difficulty" => "Smart"})) ==
               ["bot_difficulty"]
    end
  end

  describe "parse_create_params/1 unknown fields" do
    test "a body containing settings returns an error whose field path is settings" do
      body = %{
        "name" => "Friday",
        "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false}
      }

      assert {:error, {:invalid_room_params, [%{field: "settings", message: message}]}} =
               Config.parse_create_params(body)

      assert is_binary(message)
    end

    test "a body containing room returns an error whose field path is room" do
      body = %{"room" => %{"name" => "Friday"}}

      assert fields(Config.parse_create_params(body)) == ["room"]
    end

    test "solo cannot be supplied by the caller" do
      assert fields(Config.parse_create_params(%{"solo" => true})) == ["solo"]
    end

    test "password and is_dev_room are rejected" do
      body = %{"password" => "hunter2", "is_dev_room" => true}

      assert fields(Config.parse_create_params(body)) == ["is_dev_room", "password"]
    end

    test "an unknown key never mints an atom" do
      key = "zz_room_body_never_an_atom_#{System.unique_integer([:positive])}"

      assert fields(Config.parse_create_params(%{key => 1})) == [key]
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "an atom-keyed body is not read as a request body" do
      assert fields(Config.parse_create_params(%{name: "Friday"})) == [":name"]
    end
  end

  describe "parse_create_params/1 seats" do
    test "seat_5 and seat_1 each return an error with that dotted path" do
      assert fields(Config.parse_create_params(%{"seats" => %{"seat_5" => "ai"}})) ==
               ["seats.seat_5"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_1" => "ai"}})) ==
               ["seats.seat_1"]

      both = %{"seats" => %{"seat_5" => "ai", "seat_1" => "open"}}

      assert fields(Config.parse_create_params(both)) == ["seats.seat_1", "seats.seat_5"]
    end

    test "a seat value of private returns an error for that seat" do
      body = %{"seats" => %{"seat_2" => "ai", "seat_3" => "private"}}

      assert {:error, {:invalid_room_params, [%{field: "seats.seat_3", message: message}]}} =
               Config.parse_create_params(body)

      assert message =~ "ai"
      assert message =~ "open"
    end

    test "null, human and non-string seat values are rejected for that seat" do
      assert fields(Config.parse_create_params(%{"seats" => %{"seat_2" => nil}})) ==
               ["seats.seat_2"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_3" => "human"}})) ==
               ["seats.seat_3"]

      assert fields(Config.parse_create_params(%{"seats" => %{"seat_4" => true}})) ==
               ["seats.seat_4"]
    end

    test "seats given as a string, list or null returns an error for seats" do
      assert fields(Config.parse_create_params(%{"seats" => "ai"})) == ["seats"]
      assert fields(Config.parse_create_params(%{"seats" => ["ai", "ai", "ai"]})) == ["seats"]
      assert fields(Config.parse_create_params(%{"seats" => nil})) == ["seats"]
    end
  end

  describe "parse_create_params/1 error collection" do
    test "a body with three separate problems returns three errors" do
      body = %{
        "settings" => %{"private" => true},
        "bot_difficulty" => "expert",
        "seats" => %{"seat_5" => "ai"}
      }

      assert {:error, {:invalid_room_params, errors}} = Config.parse_create_params(body)
      assert length(errors) == 3

      assert Enum.sort(Enum.map(errors, & &1.field)) ==
               ["bot_difficulty", "seats.seat_5", "settings"]

      assert Enum.all?(errors, &(is_binary(&1.field) and is_binary(&1.message)))
      assert Enum.all?(errors, &(Enum.sort(Map.keys(&1)) == [:field, :message]))
    end

    test "errors come in a stable order: name, seats, bot_difficulty, then unknown keys sorted" do
      body = %{
        "zeta" => 1,
        "alpha" => 1,
        "bot_difficulty" => "expert",
        "seats" => %{"seat_9" => "ai", "seat_2" => "private", "seat_0" => "ai"},
        "name" => 42
      }

      assert fields(Config.parse_create_params(body)) == [
               "name",
               "seats.seat_2",
               "seats.seat_0",
               "seats.seat_9",
               "bot_difficulty",
               "alpha",
               "zeta"
             ]
    end

    test "each field path appears once" do
      body = %{"name" => 42, "bot_difficulty" => "expert"}
      paths = fields(Config.parse_create_params(body))

      assert paths == Enum.uniq(paths)
    end

    test "a body that is not a map returns a single error" do
      for body <- [nil, "name=Friday", ["name"], 42] do
        assert {:error, {:invalid_room_params, [%{field: "body", message: message}]}} =
                 Config.parse_create_params(body)

        assert is_binary(message)
      end
    end

    test "a config struct is not a request body" do
      assert fields(Config.parse_create_params(%Config{})) == ["body"]
    end
  end

  describe "serialization" do
    test "serialize/1 emits the difficulty as a string and the three fields only" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart, solo: true)

      assert Config.serialize(config) == %{name: "Friday", bot_difficulty: "smart", solo: true}
    end

    test "serialize/1 of the default config" do
      {:ok, config} = Config.new()

      assert Config.serialize(config) == %{name: nil, bot_difficulty: "basic", solo: false}
    end

    test "serialize/1 is JSON-encodable" do
      {:ok, config} = Config.new(bot_difficulty: :random)

      assert config |> Config.serialize() |> Jason.encode!() |> Jason.decode!() ==
               %{"name" => nil, "bot_difficulty" => "random", "solo" => false}
    end
  end

  describe "accepted_fields/0" do
    test "lists the accepted top-level request fields" do
      assert Config.accepted_fields() == ["name", "seats", "bot_difficulty"]
    end

    test "every accepted field is accepted and nothing else is" do
      body = %{
        "name" => "Friday",
        "seats" => %{"seat_2" => "open"},
        "bot_difficulty" => "basic"
      }

      assert Map.keys(body) -- Config.accepted_fields() == []
      assert {:ok, _, _} = Config.parse_create_params(body)
    end
  end
end

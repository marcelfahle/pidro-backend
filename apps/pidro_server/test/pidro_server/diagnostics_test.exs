defmodule PidroServer.DiagnosticsTest do
  use ExUnit.Case, async: false
  alias PidroServer.{Diagnostics, DiagnosticsFormatter}

  test "formatter retains correlation fields but drops payloads, metadata and multiline secrets" do
    data = %{
      event: "action_outcome",
      action_id: "attempt-1",
      room_code: "ABCD",
      game_instance_id: "game-1",
      user_id: "user-1",
      state_revision: 17,
      duration_ms: 3,
      server_build: "abcdef",
      token: "SECRET",
      cards: [{14, :spades}],
      state: %{hand: "PRIVATE"},
      arbitrary: "not allowed"
    }

    line =
      DiagnosticsFormatter.format(
        %{
          level: :info,
          msg: {:string, "SECRET\nPRIVATE"},
          meta: %{time: 123, diagnostic: data, authorization: "SECRET"}
        },
        %{}
      )
      |> IO.iodata_to_binary()

    assert length(String.split(line, "\n", trim: true)) == 1
    record = Jason.decode!(line)
    assert record["state_revision"] == 17
    assert record["action_id"] == "attempt-1"
    assert record["game_instance_id"] == "game-1"
    assert record["room_code"] == "ABCD"
    assert record["user_id"] == "user-1"
    assert record["server_build"] == "abcdef"
    assert record["duration_ms"] == 3

    for forbidden <- ~w(SECRET PRIVATE cards token arbitrary authorization) do
      refute line =~ forbidden
    end
  end

  test "optional correlation values are bounded and invalid fields disappear without raising" do
    assert byte_size(Diagnostics.token(String.duplicate("a", 100))) == 64
    assert byte_size(Diagnostics.action_id(String.duplicate("a", 256))) == 64
    assert Diagnostics.action_id(String.duplicate("a", 257)) == nil
    assert Diagnostics.action_id("eyJheader.eyJpayload.signature") == nil

    for invalid <- [nil, %{}, "line\nbreak", "🐈", <<255>>] do
      assert Diagnostics.token(invalid) == nil
    end

    assert Diagnostics.fields(%{state_revision: -1, duration_ms: "slow", state: %{}}) == %{}
    assert :ok == Diagnostics.emit(:action_received, %{state: %{secret: "secret"}})
    assert :ok == Diagnostics.emit(:action_received, %{}, :invalid_level)
  end

  test "runtime build follows the selected Kamal deployment including rollback, not a stale override" do
    saved = Map.new(~w(KAMAL_VERSION SERVER_BUILD), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    runtime = Path.expand("../../../../config/runtime.exs", __DIR__)
    read_build = fn -> Config.Reader.read!(runtime, env: :test)[:pidro_server][:server_build] end
    System.put_env("SERVER_BUILD", "stale-local-build")

    for sha <- [String.duplicate("a", 40), String.duplicate("b", 40)] do
      System.put_env("KAMAL_VERSION", sha)
      assert read_build.() == sha
    end

    System.delete_env("KAMAL_VERSION")
    assert read_build.() == "stale-local-build"
    System.delete_env("SERVER_BUILD")
    assert read_build.() == "unknown"

    config =
      Config.Reader.read!(Path.expand("../../../../config/config.exs", __DIR__), env: :prod)

    assert config[:logger][:level] == :info
    handler = config[:logger][:default_handler]
    assert handler[:formatter] == {PidroServer.DiagnosticsFormatter, %{}}
    assert handler[:config][:sync_mode_qlen] == handler[:config][:drop_mode_qlen]
  end
end

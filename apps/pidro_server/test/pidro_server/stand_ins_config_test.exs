defmodule PidroServer.StandInsConfigTest do
  # Reads config/runtime.exs with the process environment, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)

  # The variables the production block of config/runtime.exs requires.
  @prod_env %{
    "DATABASE_URL" => "ecto://user:pass@localhost/pidro",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "CORS_ORIGINS" => "*",
    "CLASSIC_API_URL" => "https://classic.example.com",
    "CLASSIC_CLAIM_SECRET" => "secret",
    "FB_APP_SECRET" => "secret"
  }

  # What an end-to-end suite sets to point a server at its stand-ins and
  # shorten lifetimes. Production must read none of them (PID-183).
  @stand_in_env %{
    "APPLE_JWKS_URL" => "http://127.0.0.1:4555/auth/keys",
    "CLASSIC_CLAIM_TICKET_TTL_SECONDS" => "1",
    "PASSWORD_RESET_TTL_SECONDS" => "1",
    "PASSWORD_RESET_DEBUG_TOKENS" => "false",
    "PASSWORD_RESET_URL_BASE" => "http://127.0.0.1:5173"
  }

  setup do
    names = Map.keys(@prod_env) ++ Map.keys(@stand_in_env)
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(@prod_env)
    System.put_env(@stand_in_env)
    :ok
  end

  test "production ignores the stand-in key server, lifetimes and reset overrides" do
    config = runtime_config(:prod)

    assert config[PidroServer.Accounts.ProviderIdentity][:apple_jwks_url] ==
             "https://appleid.apple.com/auth/keys"

    refute Keyword.has_key?(config, PidroServer.Accounts.ClassicClaims)
    refute Keyword.has_key?(config, :password_reset_ttl_seconds)
    refute Keyword.has_key?(config, :password_reset)
  end

  test "outside production the same variables take effect" do
    config = runtime_config(:dev)

    assert config[PidroServer.Accounts.ProviderIdentity][:apple_jwks_url] ==
             "http://127.0.0.1:4555/auth/keys"

    assert config[PidroServer.Accounts.ClassicClaims][:ticket_ttl_seconds] == 1
    assert config[:password_reset_ttl_seconds] == 1
    assert config[:password_reset][:reset_url_base] == "http://127.0.0.1:5173"
    assert config[:password_reset][:debug_tokens] == false
  end

  defp runtime_config(env) do
    # Production without SMTP settings warns on stderr; that is not under test.
    {config, _warning} =
      with_io(:stderr, fn -> Config.Reader.read!(@runtime_config, env: env, target: :host) end)

    Keyword.fetch!(config, :pidro_server)
  end
end

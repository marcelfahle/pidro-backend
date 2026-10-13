defmodule PidroServer.MailerTest do
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

  @smtp_env %{
    "SMTP_RELAY" => "smtp.example.com",
    "SMTP_USERNAME" => "user",
    "SMTP_PASSWORD" => "secret"
  }

  setup do
    names = Map.keys(@prod_env) ++ Map.keys(@smtp_env) ++ ["SMTP_PORT"]
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(names, &System.delete_env/1)
    System.put_env(@prod_env)
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok
  end

  describe "production SMTP settings" do
    test "STARTTLS verifies the relay's certificate chain and name" do
      server = tls_server("smtp.example.com")

      System.put_env(@smtp_env)
      assert {:ok, _socket} = starttls(prod_mailer(), server)

      System.put_env("SMTP_RELAY", "other.example.com")
      assert {:error, {:tls_alert, _alert}} = starttls(prod_mailer(), server)
    end

    test "half-set credentials leave mail unconfigured and say so" do
      System.put_env("SMTP_RELAY", "smtp.example.com")

      warning = capture_io(:stderr, fn -> assert prod_mailer() == nil end)

      assert warning =~ "Mail is not configured"
    end
  end

  defp prod_mailer do
    @runtime_config
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:pidro_server, PidroServer.Mailer])
  end

  # A relay certificate issued through one intermediate, the shape real providers use.
  defp tls_server(hostname) do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(hostname)]}
    rsa = [key: {:rsa, 2048, 65_537}]

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: rsa, intermediates: [rsa], peer: [extensions: [san]] ++ rsa},
        client_chain: %{root: [], intermediates: [], peer: []}
      })

    %{opts: server, root_cacerts: client[:cacerts]}
  end

  # Upgrades a plain connection the way gen_smtp does after STARTTLS, trusting
  # the test root in place of the system store.
  defp starttls(mailer, server) do
    {:ok, listen} = :ssl.listen(0, [:binary, active: false] ++ server.opts)
    {:ok, {_address, port}} = :ssl.sockname(listen)

    accept =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)
        :ssl.handshake(socket, 5_000)
      end)

    {:ok, tcp} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    tls_options =
      mailer |> Keyword.get(:tls_options, []) |> Keyword.put(:cacerts, server.root_cacerts)

    result = :smtp_socket.to_ssl_client(tcp, [:binary | tls_options], 5_000)

    Task.await(accept)
    :ssl.close(listen)
    result
  end
end

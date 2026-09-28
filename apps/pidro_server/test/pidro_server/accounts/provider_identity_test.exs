defmodule PidroServer.Accounts.ProviderIdentityTest do
  use ExUnit.Case, async: true

  alias PidroServer.Accounts.ProviderIdentity

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "accepts a correctly signed Apple token with the expected issuer, audience and expiry" do
    private_key = :public_key.generate_key({:rsa, 1024, 65_537})
    token = apple_token(private_key, %{})

    Req.Test.expect(ProviderIdentity, fn conn ->
      assert conn.request_path == "/auth/keys"
      Req.Test.json(conn, %{"keys" => [public_jwk(private_key)]})
    end)

    assert {:ok,
            %{
              "sub" => "apple-sub",
              "email" => "apple@example.com",
              "email_verified" => true
            }} =
             ProviderIdentity.apple(token)
  end

  test "rejects expired Apple tokens and tokens for another audience" do
    private_key = :public_key.generate_key({:rsa, 1024, 65_537})

    Req.Test.stub(ProviderIdentity, fn conn ->
      Req.Test.json(conn, %{"keys" => [public_jwk(private_key)]})
    end)

    assert {:error, :invalid_credentials} =
             private_key
             |> apple_token(%{"exp" => System.system_time(:second) - 1})
             |> ProviderIdentity.apple()

    assert {:error, :invalid_credentials} =
             private_key
             |> apple_token(%{"aud" => "com.example.wrong"})
             |> ProviderIdentity.apple()
  end

  test "malformed Apple JWT JSON is rejected instead of raising" do
    scalar_header =
      Base.url_encode64("1", padding: false) <>
        "." <> Base.url_encode64("{}", padding: false) <> ".AA"

    assert {:error, :invalid_credentials} = ProviderIdentity.apple(scalar_header)
  end

  test "malformed Apple JWKS key material is rejected instead of raising" do
    private_key = :public_key.generate_key({:rsa, 1024, 65_537})
    token = apple_token(private_key, %{})

    Req.Test.expect(ProviderIdentity, fn conn ->
      Req.Test.json(conn, %{
        "keys" => [%{"kid" => "test-key", "kty" => "RSA", "n" => "", "e" => ""}]
      })
    end)

    assert {:error, :invalid_credentials} = ProviderIdentity.apple(token)
  end

  test "Facebook requires the configured app and returns all business-scoped ids" do
    Req.Test.expect(ProviderIdentity, 4, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/v24.0/debug_token" ->
          assert conn.query_params["input_token"] == "facebook-token"

          assert conn.query_params["access_token"] ==
                   "345200965110578|facebook-test-secret"

          Req.Test.json(conn, %{
            "data" => %{
              "is_valid" => true,
              "app_id" => "345200965110578",
              "user_id" => "current-id"
            }
          })

        "/v24.0/me" ->
          Req.Test.json(conn, %{"id" => "current-id"})

        "/v24.0/me/ids_for_business" ->
          case conn.query_params["after"] do
            nil ->
              Req.Test.json(conn, %{
                "data" => [%{"id" => "first-page-id"}],
                "paging" => %{
                  "cursors" => %{"after" => "next-cursor"},
                  "next" => "https://facebook.test/v24.0/me/ids_for_business?after=next-cursor"
                }
              })

            "next-cursor" ->
              Req.Test.json(conn, %{
                "data" => [%{"id" => "old-id"}, %{"id" => "current-id"}]
              })
          end
      end
    end)

    assert {:ok, "current-id"} = ProviderIdentity.facebook("facebook-token")

    assert {:ok, ["first-page-id", "old-id", "current-id"]} =
             ProviderIdentity.facebook_business_ids("facebook-token")
  end

  test "Facebook rejects a token issued for another app" do
    Req.Test.expect(ProviderIdentity, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"is_valid" => true, "app_id" => "wrong-app", "user_id" => "some-id"}
      })
    end)

    assert {:error, :invalid_credentials} = ProviderIdentity.facebook("wrong-app-token")
  end

  defp apple_token(private_key, overrides) do
    header = %{"alg" => "RS256", "kid" => "test-key"}

    claims =
      Map.merge(
        %{
          "iss" => "https://appleid.apple.com",
          "aud" => "com.oneapps.pidro",
          "exp" => System.system_time(:second) + 300,
          "sub" => "apple-sub",
          "email" => "apple@example.com",
          "email_verified" => true
        },
        overrides
      )

    signed = encode(header) <> "." <> encode(claims)
    signature = :public_key.sign(signed, :sha256, private_key)
    signed <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp public_jwk({:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _}) do
    %{
      "kid" => "test-key",
      "kty" => "RSA",
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false)
    }
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end

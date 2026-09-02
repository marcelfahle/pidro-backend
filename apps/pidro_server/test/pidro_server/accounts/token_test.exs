defmodule PidroServer.Accounts.TokenTest do
  use ExUnit.Case, async: true

  alias PidroServer.Accounts.Token
  alias PidroServerWeb.Endpoint

  # Same salt as `PidroServer.Accounts.Token`. Legacy tokens were signed with
  # the bare user id under this salt; if the salt is rotated (KTD10) these
  # tests change with it, which is the intended signal.
  @signing_salt "pidro_auth_salt"
  @thirty_one_days 86_400 * 31

  defp user(version \\ 0), do: %{id: Ecto.UUID.generate(), token_version: version}

  defp sign(payload, opts \\ []), do: Phoenix.Token.sign(Endpoint, @signing_salt, payload, opts)

  describe "generate/1 and verify/1" do
    test "a fresh token round-trips to the id and version 0" do
      user = user()
      token = Token.generate(user)

      assert is_binary(token)
      assert {:ok, %{id: id, v: 0}} = Token.verify(token)
      assert id == user.id
    end

    test "signs the user's current token_version" do
      user = user(3)

      assert {:ok, %{id: id, v: 3}} = user |> Token.generate() |> Token.verify()
      assert id == user.id
    end

    test "returns exactly the id and version claims" do
      assert {:ok, claims} = user() |> Token.generate() |> Token.verify()
      assert Map.keys(claims) |> Enum.sort() == [:id, :v]
    end
  end

  describe "verify/1 with a legacy payload" do
    test "a bare user id under the same salt verifies as version 0" do
      user = user()
      legacy = sign(user.id)

      assert {:ok, %{id: id, v: 0}} = Token.verify(legacy)
      assert id == user.id
    end

    test "an expired legacy token is rejected" do
      legacy = sign(user().id, signed_at: System.system_time(:second) - @thirty_one_days)

      assert {:error, :expired} = Token.verify(legacy)
    end
  end

  describe "verify/1 errors" do
    test "rejects garbage" do
      assert {:error, :invalid} = Token.verify("invalid_token")
      assert {:error, :invalid} = Token.verify("")
    end

    test "rejects a tampered token" do
      token = Token.generate(user())

      assert {:error, :invalid} = Token.verify(String.reverse(token))
      assert {:error, :invalid} = Token.verify(token <> "x")
    end

    test "rejects an expired token" do
      user = user()

      expired =
        sign(%{id: user.id, v: 0}, signed_at: System.system_time(:second) - @thirty_one_days)

      assert {:error, :expired} = Token.verify(expired)
    end

    test "rejects a token signed under another salt" do
      user = user()
      foreign = Phoenix.Token.sign(Endpoint, "another_salt", %{id: user.id, v: 0})

      assert {:error, :invalid} = Token.verify(foreign)
    end

    test "rejects signed payloads of any other shape" do
      user = user()

      assert {:error, :invalid} = Token.verify(sign(123))
      assert {:error, :invalid} = Token.verify(sign(%{id: user.id}))
      assert {:error, :invalid} = Token.verify(sign(%{id: user.id, v: "0"}))
      assert {:error, :invalid} = Token.verify(sign(%{id: 123, v: 0}))
      assert {:error, :invalid} = Token.verify(sign(nil))
    end
  end
end

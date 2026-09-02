defmodule PidroServer.Accounts.Token do
  @moduledoc """
  Signs and verifies authentication tokens with `Phoenix.Token`.

  A token carries the user id and the user's `token_version` at mint time,
  `%{id: user_id, v: token_version}`, and is valid for 30 days. `verify/1`
  only checks the signature and the age; comparing `v` against the database
  is the job of `PidroServer.Accounts.Auth.fetch_user_for_token/1`, which
  both the `Authenticate` plug and `UserSocket.connect/3` call. Bumping a
  user's `token_version` therefore revokes every token minted before the
  bump.

  ## Legacy payloads

  Tokens minted before the versioned payload carry a bare user id. `verify/1`
  normalizes them to `%{id: id, v: 0}` so they keep working for users whose
  version is still 0. That clause is the only place that knows about the old
  shape and is removed 30 days after the production deploy of this change,
  not before 2026-10-02.

  ## Rollback

  The payload change is a one-way door. If a rollback of the verifying
  code were ever needed, rotate `@signing_salt` so every versioned token
  dies and users log in again.

  ## Usage

  Generate a token for a user:

      iex> user = %{id: "550e8400-e29b-41d4-a716-446655440000", token_version: 0}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> is_binary(token)
      true

  Verify a token:

      iex> user = %{id: "550e8400-e29b-41d4-a716-446655440000", token_version: 2}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> PidroServer.Accounts.Token.verify(token)
      {:ok, %{id: "550e8400-e29b-41d4-a716-446655440000", v: 2}}

  Verify an expired or invalid token:

      iex> PidroServer.Accounts.Token.verify("invalid_token")
      {:error, :invalid}
  """

  @signing_salt "pidro_auth_salt"
  @token_age_secs 86_400 * 30

  @typedoc "The verified claims of a token: the user id and the token version."
  @type claims :: %{id: String.t(), v: integer()}

  @doc """
  Generates a signed token for the given user.

  Takes a user struct or map with `id` and `token_version` fields and returns
  a signed token string that can be used for authentication.

  ## Parameters

    * `user` - A user struct or map with `id` and `token_version` fields

  ## Returns

    * A signed token string

  ## Example

      iex> user = %{id: "550e8400-e29b-41d4-a716-446655440000", token_version: 0}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> is_binary(token)
      true
  """
  @spec generate(user :: map() | struct()) :: String.t()
  def generate(user) do
    Phoenix.Token.sign(PidroServerWeb.Endpoint, @signing_salt, %{
      id: user.id,
      v: user.token_version
    })
  end

  @doc """
  Verifies a signed token and returns its claims if valid.

  Validates the token signature and checks that it hasn't expired. The token
  is valid for 30 days from generation. A legacy token whose payload is a bare
  user id verifies as version 0.

  ## Parameters

    * `token` - The signed token string to verify

  ## Returns

    * `{:ok, %{id: user_id, v: token_version}}` - If the token is valid and
      not expired
    * `{:error, reason}` - If the token is invalid, expired or missing

  ## Examples

      iex> user = %{id: "550e8400-e29b-41d4-a716-446655440000", token_version: 0}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> PidroServer.Accounts.Token.verify(token)
      {:ok, %{id: "550e8400-e29b-41d4-a716-446655440000", v: 0}}

      iex> PidroServer.Accounts.Token.verify("invalid_token")
      {:error, :invalid}
  """
  @spec verify(token :: String.t()) :: {:ok, claims()} | {:error, :expired | :invalid | :missing}
  def verify(token) do
    case Phoenix.Token.verify(PidroServerWeb.Endpoint, @signing_salt, token,
           max_age: @token_age_secs
         ) do
      {:ok, %{id: id, v: v}} when is_binary(id) and is_integer(v) ->
        {:ok, %{id: id, v: v}}

      # Legacy payload: a bare user id minted before token_version existed.
      # Remove this clause 30 days after the production deploy of this PR,
      # not before 2026-10-02. Whoever deploys writes the literal date here.
      # Earliest removal date: 2026-10-02
      {:ok, id} when is_binary(id) ->
        {:ok, %{id: id, v: 0}}

      {:ok, _other} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

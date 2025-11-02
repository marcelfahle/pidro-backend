defmodule PidroServer.Accounts.Token do
  @moduledoc """
  Token module for handling JWT generation and verification using Phoenix.Token.

  This module provides functions to generate and verify authentication tokens
  for users in the Pidro application. Tokens are signed with a secret salt
  and include an expiration time of 30 days.

  ## Usage

  Generate a token for a user:

      iex> user = %{id: 123}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> is_binary(token)
      true

  Verify a token:

      iex> user = %{id: 123}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> PidroServer.Accounts.Token.verify(token)
      {:ok, 123}

  Verify an expired or invalid token:

      iex> PidroServer.Accounts.Token.verify("invalid_token")
      {:error, :invalid}
  """

  @signing_salt "pidro_auth_salt"
  @token_age_secs 86_400 * 30

  @doc """
  Generates a signed token for the given user.

  Takes a user struct or map containing an `id` field and returns a signed
  JWT token string that can be used for authentication.

  ## Parameters

    * `user` - A user struct or map with an `id` field

  ## Returns

    * A signed token string

  ## Example

      iex> user = %{id: 123}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> is_binary(token)
      true
  """
  @spec generate(user :: map() | struct()) :: String.t()
  def generate(user) do
    Phoenix.Token.sign(PidroServerWeb.Endpoint, @signing_salt, user.id)
  end

  @doc """
  Verifies a signed token and returns the user ID if valid.

  Validates the token signature and checks that it hasn't expired.
  The token is valid for 30 days from generation.

  ## Parameters

    * `token` - The signed token string to verify

  ## Returns

    * `{:ok, user_id}` - If the token is valid and not expired
    * `{:error, reason}` - If the token is invalid or expired

  ## Examples

      iex> user = %{id: 123}
      iex> token = PidroServer.Accounts.Token.generate(user)
      iex> PidroServer.Accounts.Token.verify(token)
      {:ok, 123}

      iex> PidroServer.Accounts.Token.verify("invalid_token")
      {:error, :invalid}
  """
  @spec verify(token :: String.t()) :: {:ok, any()} | {:error, atom()}
  def verify(token) do
    Phoenix.Token.verify(PidroServerWeb.Endpoint, @signing_salt, token, max_age: @token_age_secs)
  end
end

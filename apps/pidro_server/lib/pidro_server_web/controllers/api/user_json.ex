defmodule PidroServerWeb.Api.UserJSON do
  @moduledoc """
  JSON view module for rendering user data in API responses.

  This module provides functions to serialize user data into JSON format,
  following a JSON:API-like structure with a data wrapper. It handles
  both user-only responses and user-with-token responses.
  """

  @doc """
  Renders a user response, optionally including an authentication token.

  Takes a map with :user and optional :token keys and returns a properly
  formatted JSON response with the user data and token if provided.

  ## Examples

      iex> show(%{user: user, token: "token123"})
      %{data: %{user: user_data, token: "token123"}}

      iex> show(%{user: user})
      %{data: %{user: user_data}}
  """
  def show(%{user: user, token: token}) do
    %{data: %{user: user(user), token: token}}
  end

  def show(%{user: user}) do
    %{data: %{user: user(user)}}
  end

  @doc """
  Renders user data in a data wrapper.

  Takes a map with a :user key and returns the serialized user data
  wrapped in a data envelope.

  ## Examples

      iex> data(%{user: user})
      %{user: user_data}
  """
  def data(%{user: user}) do
    %{user: user(user)}
  end

  @doc false
  # Private function to transform a user struct into a JSON-serializable map.
  #
  # Includes user fields (id, username, email, guest, inserted_at, updated_at)
  # but explicitly excludes password_hash for security.
  defp user(user) do
    %{
      id: user.id,
      username: user.username,
      email: user.email,
      guest: user.guest,
      inserted_at: DateTime.to_iso8601(user.inserted_at),
      updated_at: DateTime.to_iso8601(user.updated_at)
    }
  end
end

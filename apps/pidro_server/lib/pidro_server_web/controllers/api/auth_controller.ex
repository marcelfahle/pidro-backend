defmodule PidroServerWeb.API.AuthController do
  @moduledoc """
  API controller for user authentication operations.

  This controller handles user registration, login, and current user retrieval.
  All endpoints return JSON responses with user data and authentication tokens
  where applicable. Errors are delegated to the FallbackController for
  centralized error handling.

  ## Authentication

  Protected endpoints (like `me/1`) require a valid Bearer token in the
  Authorization header. Tokens are validated via the Authenticate plug.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Accounts.{Auth, Token}
  alias PidroServerWeb.API.UserJSON

  action_fallback PidroServerWeb.API.FallbackController

  @doc """
  Register a new user.

  Registers a new user with the provided parameters. On successful registration,
  generates an authentication token and returns the user data along with the token.

  Returns HTTP 201 (Created) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include a "user" key with user attributes

  ## Request Body Example

      {
        "user": {
          "username": "john_doe",
          "email": "john@example.com",
          "password": "secure_password"
        }
      }

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          },
          "token": "eyJhbGc..."
        }
      }

  ## Response Example (Error)

      {
        "errors": [
          {
            "code": "username",
            "title": "Username",
            "detail": "has already been taken"
          }
        ]
      }
  """
  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, %{"user" => user_params}) do
    with {:ok, user} <- Auth.register_user(user_params) do
      token = Token.generate(user)

      conn
      |> put_status(:created)
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token})
    end
  end

  @doc """
  Authenticate a user and retrieve a token.

  Authenticates a user by verifying their username and password. On successful
  authentication, generates an authentication token and returns the user data
  along with the token.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct
    * `params` - Request parameters, must include "username" and "password" keys

  ## Request Body Example

      {
        "username": "john_doe",
        "password": "secure_password"
      }

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          },
          "token": "eyJhbGc..."
        }
      }

  ## Response Example (Error)

      {
        "errors": [
          {
            "code": "INVALID_CREDENTIALS",
            "title": "Invalid credentials",
            "detail": "Username or password is incorrect"
          }
        ]
      }
  """
  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, %{"username" => username, "password" => password}) do
    with {:ok, user} <- Auth.authenticate_user(username, password) do
      token = Token.generate(user)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token})
    end
  end

  @doc """
  Retrieve the current authenticated user.

  Returns the authenticated user's data. Requires a valid Bearer token
  in the Authorization header. The current user is loaded via the
  Authenticate plug and available in `conn.assigns[:current_user]`.

  Returns HTTP 200 (OK) on success.

  ## Parameters

    * `conn` - The Plug.Conn connection struct (must have :current_user assigned)
    * `_params` - Request parameters (unused)

  ## Headers Required

      Authorization: Bearer <token>

  ## Response Example (Success)

      {
        "data": {
          "user": {
            "id": 1,
            "username": "john_doe",
            "email": "john@example.com",
            "guest": false,
            "inserted_at": "2024-11-02T10:30:00Z",
            "updated_at": "2024-11-02T10:30:00Z"
          }
        }
      }

  ## Response Example (Error - No Auth)

      {
        "errors": [
          {
            "code": "UNAUTHORIZED",
            "title": "Unauthorized",
            "detail": "Authentication required"
          }
        ]
      }
  """
  @spec me(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def me(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_view(UserJSON)
    |> render(:show, %{user: user})
  end
end

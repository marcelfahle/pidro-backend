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

  ## OpenAPI Documentation

  This controller includes OpenAPI 3.0 specifications for all endpoints:
  - POST /api/v1/auth/register - Register a new user account
  - POST /api/v1/auth/login - Authenticate and receive a token
  - GET /api/v1/auth/me - Retrieve current authenticated user

  All endpoints are tagged with "Authentication" in the OpenAPI specification.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.{Auth, Token}
  alias PidroServerWeb.API.UserJSON
  alias PidroServerWeb.Schemas.{UserSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Authentication"])

  operation(:register,
    summary: "Register a new user",
    description: """
    Creates a new user account with username, email, and password.
    Returns the created user data along with a JWT authentication token.

    The token should be included in subsequent requests in the Authorization header
    as a Bearer token: `Authorization: Bearer <token>`

    ## Validation Rules
    - Username must be at least 3 characters and unique
    - Email must be valid format and unique
    - Password must be at least 8 characters
    """,
    request_body: {"User registration data", "application/json", UserSchemas.RegisterRequest},
    responses: [
      created:
        {"User created successfully", "application/json", UserSchemas.UserWithTokenResponse},
      unprocessable_entity:
        {"Validation errors", "application/json", ErrorSchemas.validation_error()}
    ]
  )

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

  operation(:login,
    summary: "Authenticate a user",
    description: """
    Authenticates a user by verifying their username and password credentials.
    Returns the user data along with a JWT authentication token on success.

    The token should be included in subsequent requests in the Authorization header
    as a Bearer token: `Authorization: Bearer <token>`

    ## Error Responses
    - Returns 401 Unauthorized if credentials are invalid
    """,
    request_body: {"Login credentials", "application/json", UserSchemas.LoginRequest},
    responses: [
      ok: {"Authentication successful", "application/json", UserSchemas.UserWithTokenResponse},
      unauthorized: {"Invalid credentials", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

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

  operation(:me,
    summary: "Get current authenticated user",
    description: """
    Retrieves the current authenticated user's profile information.

    This endpoint requires authentication. The Bearer token must be included
    in the Authorization header: `Authorization: Bearer <token>`

    The current user is loaded by the authentication middleware and available
    in the request context.

    ## Error Responses
    - Returns 401 Unauthorized if token is missing, invalid, or expired
    """,
    security: [%{"bearer" => []}],
    responses: [
      ok: {"Current user retrieved successfully", "application/json", UserSchemas.UserResponse},
      unauthorized:
        {"Authentication required or invalid", "application/json",
         ErrorSchemas.unauthorized_error()}
    ]
  )

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

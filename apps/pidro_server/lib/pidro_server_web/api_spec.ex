defmodule PidroServerWeb.ApiSpec do
  @moduledoc """
  OpenAPI specification for Pidro Server API.

  This module defines the OpenAPI 3.0 specification for all REST API endpoints.
  View the interactive documentation at `/api/openapi` in development mode.
  """

  alias OpenApiSpex.{Info, OpenApi, Paths, Server, Components, SecurityScheme}
  alias PidroServerWeb.{Endpoint, Router}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        Server.from_endpoint(Endpoint)
      ],
      info: %Info{
        title: "Pidro Server API",
        version: "1.0.0",
        description: """
        # Pidro Server API Documentation

        A multiplayer card game server for Finnish Pidro built with Phoenix and Elixir.

        ## Features

        - User authentication with JWT tokens
        - Room management (create, join, leave)
        - Real-time gameplay via WebSocket channels
        - Game statistics tracking
        - Admin panel for monitoring

        ## Authentication

        Most endpoints require authentication using a JWT Bearer token obtained from the login endpoint.
        Include the token in the `Authorization` header:

        ```
        Authorization: Bearer <your-jwt-token>
        ```

        ## Rate Limiting

        Currently no rate limiting is enforced, but clients should implement reasonable request throttling.

        ## WebSocket Channels

        For real-time gameplay, connect to WebSocket channels after authenticating:

        - `lobby` - Lobby updates and room list
        - `game:<room_code>` - Real-time game events for a specific room

        See the WebSocket documentation for detailed event specifications.

        ## Error Responses

        All errors follow a consistent format:

        ```json
        {
          "errors": [
            {
              "code": "ERROR_CODE",
              "title": "Human-readable title",
              "detail": "Detailed error message"
            }
          ]
        }
        ```

        Common HTTP status codes:
        - `200 OK` - Request succeeded
        - `201 Created` - Resource created successfully
        - `204 No Content` - Request succeeded with no response body
        - `401 Unauthorized` - Authentication required or token invalid
        - `404 Not Found` - Resource not found
        - `422 Unprocessable Entity` - Validation error
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearer_auth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "JWT token obtained from login endpoint"
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end

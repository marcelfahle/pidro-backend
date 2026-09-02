defmodule PidroServerWeb.Schemas.ErrorSchemas do
  @moduledoc """
  OpenAPI error response schemas for the Pidro Server API.

  This module defines reusable error response schemas used across all API endpoints.
  All error responses follow a consistent format with an array of error objects,
  each containing a code, title, and detail message.

  ## Error Format

  All errors follow this structure:

      {
        "errors": [
          {
            "code": "ERROR_CODE",
            "title": "Human-readable title",
            "detail": "Detailed error message"
          }
        ]
      }

  ## Error Types

  - **ErrorDetail**: Individual error object with code, title, and detail
  - **ErrorResponse**: Generic error response with array of errors
  - **ValidationError**: 422 Unprocessable Entity response for validation failures
  - **UnauthorizedError**: 401 Unauthorized response for authentication failures
  - **NotFoundError**: 404 Not Found response for missing resources
  - **TooManyRequestsError**: 429 Too Many Requests response from the rate limiter
  - **ConflictError**: 409 Conflict for a table, invite or account in a state that refuses the action
  - **GoneError**: 410 Gone for an invite or table that no longer accepts players
  - **LockedError**: 423 Locked for a table the host has locked
  """

  alias OpenApiSpex.Schema

  @doc """
  Schema for an individual error object.

  Each error contains:
  - `code`: Machine-readable error code (field name for validation errors, or ERROR_CODE for specific errors)
  - `title`: Human-readable title derived from the code
  - `detail`: Detailed error message explaining what went wrong

  ## Examples

  Validation error:
      %{
        code: "username",
        title: "Username",
        detail: "has already been taken"
      }

  Business logic error:
      %{
        code: "ROOM_FULL",
        title: "Room full",
        detail: "Room already has 4 players"
      }
  """
  def error_detail do
    %Schema{
      type: :object,
      title: "ErrorDetail",
      description: "Individual error object with code, title, and detail",
      properties: %{
        code: %Schema{
          type: :string,
          description: "Machine-readable error code (field name or ERROR_CODE)",
          example: "username"
        },
        title: %Schema{
          type: :string,
          description: "Human-readable error title",
          example: "Username"
        },
        detail: %Schema{
          type: :string,
          description: "Detailed error message",
          example: "has already been taken"
        }
      },
      required: [:code, :title, :detail],
      example: %{
        "code" => "username",
        "title" => "Username",
        "detail" => "has already been taken"
      }
    }
  end

  @doc """
  Generic error response schema with array of errors.

  This is the base response schema used for all error responses. It contains
  an array of error objects that can vary in number based on the error type.

  ## Usage

  This schema is used as a fallback for error responses when more specific
  error schemas are not applicable. It can contain one or multiple error objects.
  """
  def error_response do
    %Schema{
      type: :object,
      title: "ErrorResponse",
      description: "Generic error response containing array of errors",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of error objects",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "NOT_FOUND",
            "title" => "Not found",
            "detail" => "Resource not found"
          }
        ]
      }
    }
  end

  @doc """
  Validation error response schema (422 Unprocessable Entity).

  Returned when request validation fails (e.g., required fields missing, format invalid).
  Can contain multiple error objects, one per invalid field.

  ## HTTP Status Code
  422 Unprocessable Entity

  ## Example Response

      {
        "errors": [
          {
            "code": "username",
            "title": "Username",
            "detail": "has already been taken"
          },
          {
            "code": "email",
            "title": "Email",
            "detail": "has invalid format"
          }
        ]
      }

  ## Common Validation Errors

  - Field already taken (username, email)
  - Field has invalid format (email, password)
  - Field is required but missing
  - Field value is too short or too long
  """
  def validation_error do
    %Schema{
      type: :object,
      title: "ValidationError",
      description: "Validation error response (422 Unprocessable Entity)",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of validation error objects, one per invalid field",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "username",
            "title" => "Username",
            "detail" => "has already been taken"
          },
          %{
            "code" => "email",
            "title" => "Email",
            "detail" => "has invalid format"
          }
        ]
      }
    }
  end

  @doc """
  Unauthorized error response schema (401 Unauthorized).

  Returned when:
  - Authentication is required but not provided
  - Authentication credentials are invalid
  - Authentication token is expired or invalid
  - Authentication token is missing or malformed

  ## HTTP Status Code
  401 Unauthorized

  ## Example Responses

  Invalid credentials:
      {
        "errors": [
          {
            "code": "INVALID_CREDENTIALS",
            "title": "Invalid credentials",
            "detail": "Username or password is incorrect"
          }
        ]
      }

  Missing authentication:
      {
        "errors": [
          {
            "code": "UNAUTHORIZED",
            "title": "Unauthorized",
            "detail": "Authentication required"
          }
        ]
      }

  ## Common Unauthorized Errors

  - Invalid credentials (username or password incorrect)
  - Authentication required (token missing)
  - Invalid token (malformed or expired)
  - Insufficient permissions
  """
  def unauthorized_error do
    %Schema{
      type: :object,
      title: "UnauthorizedError",
      description: "Unauthorized error response (401 Unauthorized)",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of authorization error objects",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "INVALID_CREDENTIALS",
            "title" => "Invalid credentials",
            "detail" => "Username or password is incorrect"
          }
        ]
      }
    }
  end

  @doc """
  Not Found error response schema (404 Not Found).

  Returned when a requested resource does not exist. This can apply to:
  - User not found
  - Room not found
  - Game session not found
  - Any other resource endpoint that returns 404

  ## HTTP Status Code
  404 Not Found

  ## Example Responses

  Generic not found:
      {
        "errors": [
          {
            "code": "NOT_FOUND",
            "title": "Not found",
            "detail": "Resource not found"
          }
        ]
      }

  Room not found:
      {
        "errors": [
          {
            "code": "ROOM_NOT_FOUND",
            "title": "Room not found",
            "detail": "The requested room does not exist"
          }
        ]
      }

  Player not in room:
      {
        "errors": [
          {
            "code": "NOT_IN_ROOM",
            "title": "Not in room",
            "detail": "Player is not in any room"
          }
        ]
      }

  ## Common Not Found Errors

  - Resource not found (generic)
  - Room not found
  - User not found
  - Player not in room
  """
  def not_found_error do
    %Schema{
      type: :object,
      title: "NotFoundError",
      description: "Not Found error response (404 Not Found)",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of not found error objects",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "ROOM_NOT_FOUND",
            "title" => "Room not found",
            "detail" => "The requested room does not exist"
          }
        ]
      }
    }
  end

  @doc """
  Too Many Requests error response schema (429 Too Many Requests).

  Returned by `PidroServerWeb.Plugs.RateLimit` when a route's policy window is
  exhausted. The response also carries a `Retry-After` header holding the
  number of whole seconds (rounded up, minimum 1) until the window resets.
  Clients should wait at least that long before retrying.

  ## HTTP Status Code
  429 Too Many Requests

  ## Example Response

      {
        "errors": [
          {
            "code": "RATE_LIMITED",
            "title": "Too Many Requests",
            "detail": "Rate limit exceeded, retry after 42 seconds"
          }
        ]
      }
  """
  def too_many_requests_error do
    %Schema{
      type: :object,
      title: "TooManyRequestsError",
      description:
        "Rate limit exceeded (429 Too Many Requests); the Retry-After header holds the seconds to wait",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array containing the single RATE_LIMITED error object",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "RATE_LIMITED",
            "title" => "Too Many Requests",
            "detail" => "Rate limit exceeded, retry after 42 seconds"
          }
        ]
      }
    }
  end

  @doc """
  Room codes exhausted error response schema (503 Service Unavailable).

  Returned by `PidroServerWeb.API.FallbackController` when
  `PidroServer.Games.RoomCodes.generate_unique/3` finds no free room code
  within its attempt bound. This is not a rate limit: no `Retry-After` header
  is sent. Clients should retry after a short delay.

  ## HTTP Status Code
  503 Service Unavailable

  ## Example Response

      {
        "errors": [
          {
            "code": "ROOM_CODE_EXHAUSTED",
            "title": "Room codes exhausted",
            "detail": "No free room code could be allocated, please try again shortly"
          }
        ]
      }
  """
  def room_code_exhausted_error do
    %Schema{
      type: :object,
      title: "RoomCodeExhaustedError",
      description:
        "No free room code could be allocated (503 Service Unavailable); retry after a short delay",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array containing the single ROOM_CODE_EXHAUSTED error object",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "ROOM_CODE_EXHAUSTED",
            "title" => "Room codes exhausted",
            "detail" => "No free room code could be allocated, please try again shortly"
          }
        ]
      }
    }
  end

  @doc """
  Conflict error response schema (409 Conflict).

  Returned by `PidroServerWeb.API.FallbackController` when the target is in a
  state that refuses the action right now: `SEAT_TAKEN` (with `next_open`, the
  open positions in N/E/S/W order), `TABLE_FULL`, `ROOM_NOT_WAITING`,
  `INVITE_LIMIT`, `NOT_A_GUEST`, `EMAIL_TAKEN` and `USERNAME_TAKEN`.

  ## HTTP Status Code
  409 Conflict

  ## Example Response

      {
        "errors": [
          {
            "code": "SEAT_TAKEN",
            "title": "Seat taken",
            "detail": "The requested seat is already occupied",
            "next_open": ["east", "west"]
          }
        ]
      }
  """
  def conflict_error do
    %Schema{
      type: :object,
      title: "ConflictError",
      description:
        "The target refuses the action in its current state (409 Conflict); SEAT_TAKEN carries next_open",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array containing the single conflict error object",
          items: conflict_error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "SEAT_TAKEN",
            "title" => "Seat taken",
            "detail" => "The requested seat is already occupied",
            "next_open" => ["east", "west"]
          }
        ]
      }
    }
  end

  @doc """
  Gone error response schema (410 Gone).

  Returned by `PidroServerWeb.API.FallbackController` when an invite or its
  table no longer accepts players: `TABLE_STARTED`, `TABLE_CLOSED`,
  `INVITE_EXPIRED`, `INVITE_REVOKED` and `INVITE_MOVED` (with `next_code`, the
  invite of the host's new table).

  ## HTTP Status Code
  410 Gone

  ## Example Response

      {
        "errors": [
          {
            "code": "INVITE_MOVED",
            "title": "Invite moved",
            "detail": "The host is at a new table; use the next code",
            "next_code": "7KQ4M2XB"
          }
        ]
      }
  """
  def gone_error do
    %Schema{
      type: :object,
      title: "GoneError",
      description:
        "The invite or its table no longer accepts players (410 Gone); INVITE_MOVED carries next_code",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array containing the single gone error object",
          items: gone_error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "INVITE_MOVED",
            "title" => "Invite moved",
            "detail" => "The host is at a new table; use the next code",
            "next_code" => "7KQ4M2XB"
          }
        ]
      }
    }
  end

  defp conflict_error_detail do
    extend_error_detail("ConflictErrorDetail", %{
      next_open: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: [:north, :east, :south, :west]},
        description: "Open positions in N/E/S/W order; present for SEAT_TAKEN"
      }
    })
  end

  defp gone_error_detail do
    extend_error_detail("GoneErrorDetail", %{
      next_code: %Schema{
        type: :string,
        description: "Successor invite code; present for INVITE_MOVED",
        example: "7KQ4M2XB"
      }
    })
  end

  defp extend_error_detail(title, extra_properties) do
    detail = error_detail()

    %Schema{
      detail
      | title: title,
        properties: Map.merge(detail.properties, extra_properties)
    }
  end

  @doc """
  Locked error response schema (423 Locked).

  Returned by `PidroServerWeb.API.FallbackController` as `TABLE_LOCKED` when
  the host has locked the table against joins and invite redemptions.

  ## HTTP Status Code
  423 Locked

  ## Example Response

      {
        "errors": [
          {
            "code": "TABLE_LOCKED",
            "title": "Table locked",
            "detail": "The host has locked this table"
          }
        ]
      }
  """
  def locked_error do
    %Schema{
      type: :object,
      title: "LockedError",
      description: "The host has locked the table (423 Locked)",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array containing the single TABLE_LOCKED error object",
          items: error_detail(),
          minItems: 1
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "TABLE_LOCKED",
            "title" => "Table locked",
            "detail" => "The host has locked this table"
          }
        ]
      }
    }
  end
end

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
  """

  require OpenApiSpex
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
end

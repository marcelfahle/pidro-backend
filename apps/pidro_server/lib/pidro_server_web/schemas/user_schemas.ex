defmodule PidroServerWeb.Schemas.UserSchemas do
  @moduledoc """
  OpenAPI schemas for user-related API objects.

  This module defines the OpenAPI 3.0 schemas for all user-related endpoints including:
  - User data objects
  - Authentication request/response objects
  - User statistics responses

  Uses OpenApiSpex.Schema for type safety and documentation.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  # ============================================================================
  # User Object Schemas
  # ============================================================================

  defmodule User do
    @moduledoc """
    The User schema represents a user in the system.

    Contains core user information including identification, profile data,
    and account status. Password information is never included in responses
    for security reasons.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User",
      description: "A user account in the Pidro system",
      properties: %{
        id: %Schema{
          type: :string,
          description: "Unique user identifier (UUID)",
          example: "550e8400-e29b-41d4-a716-446655440000"
        },
        username: %Schema{
          type: :string,
          description: "Unique username for login and display",
          minLength: 3,
          example: "john_doe"
        },
        email: %Schema{
          type: :string,
          format: :email,
          description: "User's email address",
          example: "john@example.com"
        },
        guest: %Schema{
          type: :boolean,
          description: "Whether this is a guest account (temporary, unauthenticated)",
          example: false
        },
        inserted_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the user was created",
          example: "2024-11-02T10:30:00Z"
        },
        updated_at: %Schema{
          type: :string,
          format: "date-time",
          description: "ISO 8601 timestamp when the user was last updated",
          example: "2024-11-02T15:45:30Z"
        }
      },
      required: [:id, :username, :email, :guest, :inserted_at, :updated_at],
      example: %{
        "id" => "550e8400-e29b-41d4-a716-446655440000",
        "username" => "john_doe",
        "email" => "john@example.com",
        "guest" => false,
        "inserted_at" => "2024-11-02T10:30:00Z",
        "updated_at" => "2024-11-02T10:30:00Z"
      }
    })
  end

  defmodule UserResponse do
    @moduledoc """
    Response containing a single user object.

    Used for endpoints that return user information without authentication tokens,
    such as retrieving the current user's profile.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User Response",
      description: "Response containing user data",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope",
          properties: %{
            user: User
          },
          required: [:user]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "username" => "john_doe",
            "email" => "john@example.com",
            "guest" => false,
            "inserted_at" => "2024-11-02T10:30:00Z",
            "updated_at" => "2024-11-02T10:30:00Z"
          }
        }
      }
    })
  end

  defmodule UserWithTokenResponse do
    @moduledoc """
    Response containing user data and an authentication JWT token.

    Used for successful authentication endpoints (login, register) that need
    to return both the user information and a JWT token for subsequent requests.
    The token should be included in the Authorization header as a Bearer token.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User with Token Response",
      description: "Response containing user data and authentication token",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope",
          properties: %{
            user: User,
            token: %Schema{
              type: :string,
              description:
                "JWT authentication token for subsequent requests. Include as Bearer token in Authorization header",
              example:
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI1NTBlODQwMC1lMjliLTQxZDQtYTcxNi00NDY2NTU0NDAwMDAiLCJpYXQiOjE3MzA1MzgyMDB9.signature"
            }
          },
          required: [:user, :token]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user" => %{
            "id" => "550e8400-e29b-41d4-a716-446655440000",
            "username" => "john_doe",
            "email" => "john@example.com",
            "guest" => false,
            "inserted_at" => "2024-11-02T10:30:00Z",
            "updated_at" => "2024-11-02T10:30:00Z"
          },
          "token" =>
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI1NTBlODQwMC1lMjliLTQxZDQtYTcxNi00NDY2NTU0NDAwMDAiLCJpYXQiOjE3MzA1MzgyMDB9.signature"
        }
      }
    })
  end

  # ============================================================================
  # Request Schemas
  # ============================================================================

  defmodule RegisterRequest do
    @moduledoc """
    Request body schema for user registration.

    Clients should provide a user object containing username, email, and password.
    The password must be at least 8 characters long. Username must be at least 3 characters.
    Both username and email must be unique in the system.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Register Request",
      description: "Request body for user registration",
      properties: %{
        user: %Schema{
          type: :object,
          description: "User registration data",
          properties: %{
            username: %Schema{
              type: :string,
              description: "Unique username for the account",
              minLength: 3,
              maxLength: 255,
              example: "john_doe"
            },
            email: %Schema{
              type: :string,
              format: :email,
              description: "Email address for the account",
              example: "john@example.com"
            },
            password: %Schema{
              type: :string,
              description: "Account password (minimum 8 characters)",
              minLength: 8,
              maxLength: 255,
              example: "secure_password_123"
            }
          },
          required: [:username, :email, :password]
        }
      },
      required: [:user],
      example: %{
        "user" => %{
          "username" => "john_doe",
          "email" => "john@example.com",
          "password" => "secure_password_123"
        }
      }
    })
  end

  defmodule LoginRequest do
    @moduledoc """
    Request body schema for user login.

    Clients should provide username and password credentials. Both fields are required.
    On successful authentication, the server returns the user data and a JWT token.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Login Request",
      description: "Request body for user login/authentication",
      properties: %{
        username: %Schema{
          type: :string,
          description: "Username of the account to authenticate",
          minLength: 3,
          example: "john_doe"
        },
        password: %Schema{
          type: :string,
          description: "Password for the account",
          minLength: 1,
          example: "secure_password_123"
        }
      },
      required: [:username, :password],
      example: %{
        "username" => "john_doe",
        "password" => "secure_password_123"
      }
    })
  end

  # ============================================================================
  # Statistics Schemas
  # ============================================================================

  defmodule UserStatsResponse do
    @moduledoc """
    Response containing user game statistics.

    Aggregates game-related metrics for a user including total games played,
    win/loss records, win rate percentage, time spent playing, and average bid amounts.
    All numeric fields are calculated from the user's game history.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "User Stats Response",
      description: "Response containing aggregated user game statistics",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope containing user statistics",
          properties: %{
            games_played: %Schema{
              type: :integer,
              description: "Total number of games the user has participated in",
              minimum: 0,
              example: 42
            },
            wins: %Schema{
              type: :integer,
              description: "Total number of games won by the user",
              minimum: 0,
              example: 25
            },
            losses: %Schema{
              type: :integer,
              description: "Total number of games lost by the user",
              minimum: 0,
              example: 17
            },
            win_rate: %Schema{
              type: :number,
              format: :double,
              description: "Win rate as a decimal (0.0 to 1.0, or 0 if no games played)",
              minimum: 0.0,
              maximum: 1.0,
              example: 0.595
            },
            total_duration_seconds: %Schema{
              type: :integer,
              description: "Total time spent playing in seconds",
              minimum: 0,
              example: 12600
            },
            average_bid: %Schema{
              type: :number,
              format: :double,
              description: "Average bid amount across all games",
              minimum: 0.0,
              example: 10.5
            }
          },
          required: [
            :games_played,
            :wins,
            :losses,
            :win_rate,
            :total_duration_seconds,
            :average_bid
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "games_played" => 42,
          "wins" => 25,
          "losses" => 17,
          "win_rate" => 0.595,
          "total_duration_seconds" => 12_600,
          "average_bid" => 10.5
        }
      }
    })
  end

  # ============================================================================
  # Error Response Schemas
  # ============================================================================

  defmodule ErrorResponse do
    @moduledoc """
    Standard error response schema used across all API endpoints.

    Errors are returned in a consistent format with error codes, titles, and details.
    Multiple errors can be returned in a single response (e.g., validation errors).
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Error Response",
      description: "Standard error response format",
      properties: %{
        errors: %Schema{
          type: :array,
          description: "Array of errors",
          items: %Schema{
            type: :object,
            properties: %{
              code: %Schema{
                type: :string,
                description: "Error code (field name for validation errors, or error type)",
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
            required: [:code, :title, :detail]
          }
        }
      },
      required: [:errors],
      example: %{
        "errors" => [
          %{
            "code" => "username",
            "title" => "Username",
            "detail" => "has already been taken"
          }
        ]
      }
    })
  end

  defmodule UnauthorizedError do
    @moduledoc """
    Error response for unauthorized access (401).

    Returned when authentication is required but not provided, or when
    the provided token is invalid or expired.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Unauthorized Error",
      description: "Error response for unauthorized access",
      properties: %{
        errors: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              code: %Schema{
                type: :string,
                example: "UNAUTHORIZED"
              },
              title: %Schema{
                type: :string,
                example: "Unauthorized"
              },
              detail: %Schema{
                type: :string,
                example: "Authentication required"
              }
            }
          }
        }
      },
      example: %{
        "errors" => [
          %{
            "code" => "UNAUTHORIZED",
            "title" => "Unauthorized",
            "detail" => "Authentication required"
          }
        ]
      }
    })
  end
end

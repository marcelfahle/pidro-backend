defmodule PidroServerWeb.API.FallbackController do
  @moduledoc """
  Fallback controller for handling errors in API responses.

  This controller implements the fallback pattern used in Phoenix API applications.
  It serves as a centralized error handler for all API endpoints, converting various
  error tuples into properly formatted JSON responses with appropriate HTTP status codes.

  ## Pattern Matches

  Handles the following error types:
  - `{:error, %Ecto.Changeset{}}` - Validation errors from Ecto changesets
  - `{:error, :invalid_credentials}` - Authentication failures
  - `{:error, :not_found}` - Resource not found errors
  """

  use PidroServerWeb, :controller

  @doc """
  Handles Ecto changeset validation errors.

  Extracts all errors from the changeset and formats them into a JSON response.
  Each error includes a code, humanized title, and detailed message.

  Returns HTTP 422 (Unprocessable Entity).

  ## Examples

  When called with a changeset error, returns:

      %{
        errors: [
          %{
            code: "username",
            title: "Username",
            detail: "has already been taken"
          }
        ]
      }
  """
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    formatted_errors =
      Enum.map(errors, fn {field, messages} ->
        Enum.map(messages, fn message ->
          %{
            code: to_string(field),
            title: humanize_field(field),
            detail: message
          }
        end)
      end)
      |> List.flatten()

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: formatted_errors})
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      errors: [
        %{
          code: "INVALID_CREDENTIALS",
          title: "Invalid credentials",
          detail: "Username or password is incorrect"
        }
      ]
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_FOUND",
          title: "Not found",
          detail: "Resource not found"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_FOUND",
          title: "Room not found",
          detail: "The requested room does not exist"
        }
      ]
    })
  end

  def call(conn, {:error, :room_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_FULL",
          title: "Room full",
          detail: "Room already has 4 players"
        }
      ]
    })
  end

  def call(conn, {:error, :already_in_room}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_IN_ROOM",
          title: "Already in room",
          detail: "User is already in another room"
        }
      ]
    })
  end

  def call(conn, {:error, :already_in_this_room}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_IN_THIS_ROOM",
          title: "Already in this room",
          detail: "User is already in this room"
        }
      ]
    })
  end

  def call(conn, {:error, :not_in_room}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_IN_ROOM",
          title: "Not in room",
          detail: "Player is not in any room"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_available_for_spectators}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_AVAILABLE_FOR_SPECTATORS",
          title: "Room not available for spectators",
          detail: "Can only spectate games that are playing or finished"
        }
      ]
    })
  end

  def call(conn, {:error, :spectators_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SPECTATORS_FULL",
          title: "Spectators full",
          detail: "Room has reached maximum number of spectators"
        }
      ]
    })
  end

  def call(conn, {:error, :already_spectating}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_SPECTATING",
          title: "Already spectating",
          detail: "User is already spectating a room"
        }
      ]
    })
  end

  def call(conn, {:error, :not_spectating}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      errors: [
        %{
          code: "NOT_SPECTATING",
          title: "Not spectating",
          detail: "User is not spectating any room"
        }
      ]
    })
  end

  @doc false
  # Convert field names from underscores to human-readable format
  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end

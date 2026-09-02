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
  - Invite and host-control atoms (KTD5): `:table_full`, `:room_not_waiting`,
    `:invite_limit`, `:not_a_guest`, `:email_taken` and `:username_taken` answer
    409; `:table_started`, `:table_closed`, `:invite_expired`, `:invite_revoked`
    and `{:invite_moved, next_code}` answer 410; `:table_locked` answers 423;
    `:kicked` answers 403; `{:seat_taken, next_open}` answers 409 with the open
    positions while the bare `:seat_taken` keeps its 422 for room joins
  - Any other atom answers 422 with the atom upcased as the code
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

  def call(conn, {:error, :invalid_or_expired_password_reset_token}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "INVALID_OR_EXPIRED_PASSWORD_RESET_TOKEN",
          title: "Invalid reset link",
          detail: "Password reset link is invalid or expired"
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

  def call(conn, {:error, :seat_taken}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_TAKEN",
          title: "Seat taken",
          detail: "The requested seat is already occupied",
          available_positions: []
        }
      ]
    })
  end

  def call(conn, {:error, :team_full}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "TEAM_FULL",
          title: "Team full",
          detail: "The requested team is fully occupied",
          available_positions: []
        }
      ]
    })
  end

  def call(conn, {:error, :invalid_position}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "INVALID_POSITION",
          title: "Invalid position",
          detail: "The position parameter is invalid"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_available}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_AVAILABLE",
          title: "Room not available",
          detail: "Room is not available for joining"
        }
      ]
    })
  end

  def call(conn, {:error, :not_owner}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "NOT_OWNER",
          title: "Not owner",
          detail: "Only the room owner can perform this action"
        }
      ]
    })
  end

  def call(conn, {:error, :room_not_playing}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ROOM_NOT_PLAYING",
          title: "Room not playing",
          detail: "Room must be in playing status for this action"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_bot_substitute}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_BOT_SUBSTITUTE",
          title: "Seat not bot substitute",
          detail: "The seat must be occupied by a substitute bot"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_vacant}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_VACANT",
          title: "Seat not vacant",
          detail: "The seat must be vacant to close it"
        }
      ]
    })
  end

  def call(conn, {:error, :already_seated}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "ALREADY_SEATED",
          title: "Already seated",
          detail: "Player is already seated in this room"
        }
      ]
    })
  end

  def call(conn, {:error, :no_vacant_seat}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "NO_VACANT_SEAT",
          title: "No vacant seat",
          detail: "No vacant seat is available for joining"
        }
      ]
    })
  end

  # ==================== Invite and host-control errors (KTD5) ====================
  #
  # Every clause below must stay above the `is_atom(reason)` catch-all, which
  # would answer 422. The bare `:seat_taken` atom keeps its 422 above so
  # `POST /rooms/:code/join` is unchanged; the tuple form is the invite redeem
  # answer (R5).

  def call(conn, {:error, {:seat_taken, next_open}}) when is_list(next_open) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: [
        %{
          code: "SEAT_TAKEN",
          title: "Seat taken",
          detail: "The requested seat is already occupied",
          next_open: Enum.map(next_open, &Atom.to_string/1)
        }
      ]
    })
  end

  def call(conn, {:error, :table_full}) do
    conflict(conn, "TABLE_FULL", "Table full", "Every seat at the table is taken")
  end

  def call(conn, {:error, :room_not_waiting}) do
    conflict(
      conn,
      "ROOM_NOT_WAITING",
      "Room not waiting",
      "The room is no longer waiting for players"
    )
  end

  def call(conn, {:error, :invite_limit}) do
    conflict(conn, "INVITE_LIMIT", "Invite limit", "This room has reached its invite limit")
  end

  def call(conn, {:error, :not_a_guest}) do
    conflict(conn, "NOT_A_GUEST", "Not a guest", "Only a guest account can be upgraded")
  end

  def call(conn, {:error, :email_taken}) do
    conflict(conn, "EMAIL_TAKEN", "Email taken", "Another account uses that email address")
  end

  def call(conn, {:error, :username_taken}) do
    conflict(conn, "USERNAME_TAKEN", "Username taken", "Another account uses that username")
  end

  def call(conn, {:error, :table_started}) do
    gone(conn, "TABLE_STARTED", "Table started", "The game at this table has already started")
  end

  def call(conn, {:error, :table_closed}) do
    gone(conn, "TABLE_CLOSED", "Table closed", "The table this invite opened no longer exists")
  end

  def call(conn, {:error, :invite_expired}) do
    gone(conn, "INVITE_EXPIRED", "Invite expired", "This invite has expired")
  end

  def call(conn, {:error, :invite_revoked}) do
    gone(conn, "INVITE_REVOKED", "Invite revoked", "The host revoked this invite")
  end

  def call(conn, {:error, {:invite_moved, next_code}}) do
    conn
    |> put_status(:gone)
    |> json(%{
      errors: [
        %{
          code: "INVITE_MOVED",
          title: "Invite moved",
          detail: "The host is at a new table; use the next code",
          next_code: next_code
        }
      ]
    })
  end

  def call(conn, {:error, :table_locked}) do
    conn
    |> put_status(:locked)
    |> json(%{
      errors: [
        %{
          code: "TABLE_LOCKED",
          title: "Table locked",
          detail: "The host has locked this table"
        }
      ]
    })
  end

  def call(conn, {:error, :kicked}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      errors: [
        %{
          code: "KICKED",
          title: "Kicked",
          detail: "The host removed you from this table"
        }
      ]
    })
  end

  def call(conn, {:error, :seat_not_kickable}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: "SEAT_NOT_KICKABLE",
          title: "Seat not kickable",
          detail: "Only a seated non-host player can be kicked"
        }
      ]
    })
  end

  # Must stay above the `is_atom(reason)` catch-all, which would answer 422.
  def call(conn, {:error, :room_code_exhausted}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      errors: [
        %{
          code: "ROOM_CODE_EXHAUSTED",
          title: "Room codes exhausted",
          detail: "No free room code could be allocated, please try again shortly"
        }
      ]
    })
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: [
        %{
          code: String.upcase(Atom.to_string(reason)),
          title: reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
          detail: "Operation failed: #{Atom.to_string(reason)}"
        }
      ]
    })
  end

  defp conflict(conn, code, title, detail), do: error(conn, :conflict, code, title, detail)

  defp gone(conn, code, title, detail), do: error(conn, :gone, code, title, detail)

  defp error(conn, status, code, title, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: [%{code: code, title: title, detail: detail}]})
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

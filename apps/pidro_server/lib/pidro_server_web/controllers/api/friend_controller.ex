defmodule PidroServerWeb.API.FriendController do
  @moduledoc "Friends and player discovery for registered accounts."
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Friends
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Schemas.{ErrorSchemas, FriendSchemas, RoomSchemas}

  action_fallback PidroServerWeb.API.FallbackController
  plug :require_account
  tags(["Friends"])
  security([%{"bearer_auth" => []}])

  operation(:index,
    summary: "List friends, requests waiting for you and requests you sent",
    responses: [
      ok: {"Full friends list", "application/json", FriendSchemas.ListResponse},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def index(conn, _params), do: json(conn, %{data: Friends.list(conn.assigns.current_user.id)})

  operation(:add,
    summary: "Add a player, or accept their incoming edge, idempotently",
    description: "A block in either direction answers 404 USER_NOT_FOUND without revealing it.",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Full friends list", "application/json", FriendSchemas.ListResponse},
      bad_request: {"Cannot friend self", "application/json", FriendSchemas.Error},
      not_found: {"Player unavailable", "application/json", FriendSchemas.Error},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  def add(conn, %{"user_id" => id}) do
    respond(conn, Friends.add(conn.assigns.current_user.id, id))
  end

  operation(:remove,
    summary: "Remove a friendship, or cancel a request you sent",
    description:
      "Deletes your edge, and theirs only if you were friends. An incoming request is untouched.",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Full friends list", "application/json", FriendSchemas.ListResponse},
      bad_request: {"Cannot friend self", "application/json", FriendSchemas.Error},
      not_found: {"Player unavailable", "application/json", FriendSchemas.Error},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def remove(conn, %{"user_id" => id}) do
    respond(conn, Friends.remove(conn.assigns.current_user.id, id))
  end

  operation(:ignore,
    summary: "Hide an incoming request from your list; the sender is not told",
    description:
      "Their edge stays, so adding them back later makes you friends at once. A request they cancel and send again stays hidden until you un-ignore or add them.",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Full friends list", "application/json", FriendSchemas.ListResponse},
      bad_request: {"Cannot friend self", "application/json", FriendSchemas.Error},
      not_found: {"Player unavailable", "application/json", FriendSchemas.Error},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def ignore(conn, %{"user_id" => id}) do
    respond(conn, Friends.ignore(conn.assigns.current_user.id, id))
  end

  operation(:unignore,
    summary: "Undo an ignore, restoring the incoming request",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Full friends list", "application/json", FriendSchemas.ListResponse},
      bad_request: {"Cannot friend self", "application/json", FriendSchemas.Error},
      not_found: {"Player unavailable", "application/json", FriendSchemas.Error},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def unignore(conn, %{"user_id" => id}) do
    respond(conn, Friends.unignore(conn.assigns.current_user.id, id))
  end

  operation(:join,
    summary: "Sit down at a mutual friend's table in one tap",
    description: """
    Takes the friend's partner seat when it is open to the caller, else the first
    open seat they may take; `join_as` in the friends list says which beforehand.
    A seat held for someone else, a password seat (there is no password to give
    here), or one whose `min_games` the caller misses is not open to them; a
    substitute seat at a playing table asks for neither. The seat is then joined
    exactly as `POST /rooms/:code/join` with that `position`, so its rules and
    errors apply unchanged (a blocked host still answers 422 `SEAT_TAKEN`). Not a mutual friend, or a block either way: 404
    `USER_NOT_FOUND`. The friend is not seated at a waiting, ready or playing table:
    404 `ROOM_NOT_FOUND`. No seat the caller may take: 409 `NO_SEAT_FOR_YOU`.
    Limited at policy `room_join` (per user).
    """,
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Seated at the friend's table", "application/json", RoomSchemas.RoomResponse},
      not_found:
        {"USER_NOT_FOUND or ROOM_NOT_FOUND", "application/json",
         %OpenApiSpex.Schema{oneOf: [FriendSchemas.Error, ErrorSchemas.not_found_error()]}},
      conflict: {"NO_SEAT_FOR_YOU", "application/json", ErrorSchemas.conflict_error()},
      forbidden:
        {"Account required, kicked, or SEAT_REQUIRES_GAMES", "application/json",
         %OpenApiSpex.Schema{oneOf: [FriendSchemas.Error, RoomSchemas.SeatRequiresGames]}},
      unprocessable_entity:
        {"Room full, seat taken or already in room", "application/json",
         ErrorSchemas.validation_error()},
      locked: {"Table locked", "application/json", ErrorSchemas.locked_error()},
      service_unavailable:
        {"PROFILE_UNAVAILABLE; retry later", "application/json", ErrorSchemas.error_response()},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  def join(conn, %{"user_id" => id}) do
    with {:ok, room, position} <- Friends.join(conn.assigns.current_user, id) do
      conn
      |> put_view(RoomJSON)
      |> render(:show, %{room: room, assigned_position: position})
    end
  end

  operation(:search,
    summary: "Search registered players by folded display-name prefix",
    description:
      "At least three NFKC-normalized graphemes; at most ten results, excluding self and blocked pairs in either direction.",
    parameters: [q: [in: :query, type: :string, required: true]],
    responses: [
      ok: {"Players with relation and presence", "application/json", FriendSchemas.UsersResponse},
      bad_request: {"Query too short", "application/json", FriendSchemas.Error},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  def search(conn, params) do
    case Friends.search(conn.assigns.current_user.id, params["q"]) do
      {:ok, users} -> json(conn, %{data: %{users: users}})
      error -> respond(conn, error)
    end
  end

  operation(:recent,
    summary: "Recent human tablemates, excluding mutual friends and self",
    description:
      "Most recent first, ten results from the caller's last twenty completed games, excluding blocked pairs in either direction.",
    responses: [
      ok: {"Players with relation and presence", "application/json", FriendSchemas.UsersResponse},
      forbidden: {"Account required", "application/json", FriendSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def recent(conn, _params) do
    json(conn, %{data: %{users: Friends.recent(conn.assigns.current_user.id)}})
  end

  defp require_account(%{assigns: %{current_user: %{guest: true}}} = conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(ErrorContract.add(%{error: "ACCOUNT_REQUIRED"}, :account_required))
    |> halt()
  end

  defp require_account(conn, _opts), do: conn

  defp respond(conn, {:ok, list}), do: json(conn, %{data: list})

  defp respond(conn, {:error, :cannot_friend_self}),
    do:
      conn
      |> put_status(:bad_request)
      |> json(ErrorContract.add(%{error: "CANNOT_FRIEND_SELF"}, :cannot_friend_self))

  defp respond(conn, {:error, :user_not_found}),
    do:
      conn
      |> put_status(:not_found)
      |> json(ErrorContract.add(%{error: "USER_NOT_FOUND"}, :user_not_found))

  defp respond(conn, {:error, :query_too_short}),
    do:
      conn
      |> put_status(:bad_request)
      |> json(ErrorContract.add(%{error: "QUERY_TOO_SHORT"}, :query_too_short))
end

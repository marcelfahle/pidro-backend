defmodule PidroServerWeb.API.FriendController do
  @moduledoc "Friends and player discovery for registered accounts."
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Friends
  alias PidroServerWeb.ErrorContract
  alias PidroServerWeb.Schemas.{ErrorSchemas, FriendSchemas}

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
    description: "Their edge stays, so adding them back later makes you friends at once.",
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

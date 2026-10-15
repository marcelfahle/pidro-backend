defmodule PidroServerWeb.API.BlockController do
  @moduledoc "The registered player's private blocked list."
  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Blocks
  alias PidroServerWeb.Schemas.{BlockSchemas, ErrorSchemas}

  plug :require_account
  tags(["Blocks"])
  security([%{"bearer_auth" => []}])

  operation(:index,
    summary: "List players you blocked, without presence",
    responses: [
      ok: {"Blocked list", "application/json", BlockSchemas.ListResponse},
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def index(conn, _params), do: json(conn, %{data: Blocks.list(conn.assigns.current_user.id)})

  operation(:block,
    summary: "Block a player idempotently and remove friendship both ways",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Blocked list", "application/json", BlockSchemas.ListResponse},
      bad_request: {"Cannot block self", "application/json", BlockSchemas.Error},
      not_found: {"Player unavailable", "application/json", BlockSchemas.Error},
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def block(conn, %{"user_id" => id}),
    do: respond(conn, Blocks.block(conn.assigns.current_user.id, id))

  operation(:unblock,
    summary: "Unblock a player without restoring any friendship",
    parameters: [user_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Blocked list", "application/json", BlockSchemas.ListResponse},
      bad_request: {"Cannot block self", "application/json", BlockSchemas.Error},
      not_found: {"Player unavailable", "application/json", BlockSchemas.Error},
      forbidden: {"Account required", "application/json", BlockSchemas.Error},
      unauthorized:
        {"Authentication required", "application/json", ErrorSchemas.unauthorized_error()}
    ]
  )

  def unblock(conn, %{"user_id" => id}),
    do: respond(conn, Blocks.unblock(conn.assigns.current_user.id, id))

  defp require_account(%{assigns: %{current_user: %{guest: true}}} = conn, _opts) do
    conn |> put_status(:forbidden) |> json(%{error: "ACCOUNT_REQUIRED"}) |> halt()
  end

  defp require_account(conn, _opts), do: conn

  defp respond(conn, {:ok, list}), do: json(conn, %{data: list})

  defp respond(conn, {:error, :cannot_block_self}),
    do: conn |> put_status(:bad_request) |> json(%{error: "CANNOT_BLOCK_SELF"})

  defp respond(conn, {:error, :user_not_found}),
    do: conn |> put_status(:not_found) |> json(%{error: "USER_NOT_FOUND"})

  defp respond(conn, {:error, :account_required}),
    do: conn |> put_status(:forbidden) |> json(%{error: "ACCOUNT_REQUIRED"})
end

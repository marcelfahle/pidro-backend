defmodule PidroServerWeb.API.ClassicClaimController do
  @moduledoc "Redeems a verified Classic claim ticket for the current user or fresh install."

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.{Auth, ClassicClaims, Token}
  alias PidroServerWeb.API.UserJSON
  alias PidroServerWeb.Schemas.{ClassicClaimSchemas, ErrorSchemas, UserSchemas}

  action_fallback PidroServerWeb.API.FallbackController
  tags(["Authentication"])

  operation(:create,
    summary: "Attach a verified Classic account",
    description:
      "Redeems a short-lived claim ticket. A Bearer token attaches to that user; without one, the install-bound ticket creates a recoverable account.",
    request_body: {"Classic claim", "application/json", ClassicClaimSchemas.ClaimRequest},
    responses: [
      ok: {"Claim completed", "application/json", UserSchemas.UserWithTokenResponse},
      unauthorized:
        {"Invalid Bearer token", "application/json", ErrorSchemas.unauthorized_error()},
      conflict:
        {"Classic account or provider already linked", "application/json",
         ErrorSchemas.conflict_error()},
      gone: {"Claim ticket expired", "application/json", ErrorSchemas.gone_error()},
      unprocessable_entity:
        {"Invalid claim or account data", "application/json", ErrorSchemas.validation_error()}
    ]
  )

  def create(conn, %{"ticket" => ticket} = params) do
    with {:ok, user} <- ClassicClaims.redeem(ticket, conn.assigns[:current_user], params) do
      token = Token.generate(user)
      Auth.touch_last_seen(user)

      conn
      |> put_view(UserJSON)
      |> render(:show, %{user: user, token: token})
    end
  end

  def create(_conn, _params), do: {:error, :invalid_claim_ticket}
end

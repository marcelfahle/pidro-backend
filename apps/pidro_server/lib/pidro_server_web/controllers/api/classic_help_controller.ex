defmodule PidroServerWeb.API.ClassicHelpController do
  @moduledoc "Sends a Classic account help request to support."

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.ClassicHelp
  alias PidroServerWeb.Schemas.{ClassicClaimSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController
  tags(["Authentication"])

  operation(:create,
    summary: "Ask support to help find a Classic account",
    description:
      "Emails the name, contact address and details to support. A Bearer token is optional. 503 means the mail could not be sent.",
    request_body: {"Classic help", "application/json", ClassicClaimSchemas.HelpRequest},
    responses: [
      no_content: "Sent",
      unprocessable_entity:
        {"Invalid name, email or details", "application/json", ErrorSchemas.validation_error()},
      service_unavailable: {"Mail unavailable", "application/json", ErrorSchemas.error_response()}
    ]
  )

  def create(conn, params) do
    with :ok <- ClassicHelp.request(params, conn.assigns[:current_user]) do
      send_resp(conn, :no_content, "")
    end
  end
end

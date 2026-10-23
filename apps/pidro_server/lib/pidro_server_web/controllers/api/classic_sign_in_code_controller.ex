defmodule PidroServerWeb.API.ClassicSignInCodeController do
  @moduledoc "Requests and verifies emailed Classic ownership codes."

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PidroServer.Accounts.ClassicSignInCodes
  alias PidroServer.Mailer
  alias PidroServerWeb.Schemas.{ClassicClaimSchemas, ErrorSchemas}

  action_fallback PidroServerWeb.API.FallbackController
  tags(["Authentication"])

  operation(:create,
    summary: "Email a six-digit Classic sign-in code",
    request_body: {"Classic login", "application/json", ClassicClaimSchemas.SignInCodeRequest},
    responses: [
      ok: {"Code requested", "application/json", ClassicClaimSchemas.SignInCodeResponse},
      not_found:
        {"Classic account not found", "application/json", ErrorSchemas.not_found_error()},
      unauthorized:
        {"Invalid Bearer token", "application/json", ErrorSchemas.unauthorized_error()},
      unprocessable_entity:
        {"Missing email or invalid request", "application/json", ErrorSchemas.validation_error()},
      service_unavailable:
        {"Classic unavailable", "application/json", ErrorSchemas.error_response()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  operation(:verify,
    summary: "Verify a Classic sign-in code",
    request_body:
      {"Classic code", "application/json", ClassicClaimSchemas.SignInCodeVerifyRequest},
    responses: [
      ok: {"Classic account verified", "application/json", ClassicClaimSchemas.VerifyResponse},
      unauthorized:
        {"Invalid or expired code", "application/json", ErrorSchemas.unauthorized_error()},
      service_unavailable:
        {"Classic unavailable", "application/json", ErrorSchemas.error_response()},
      too_many_requests:
        {"Rate limited", "application/json", ErrorSchemas.too_many_requests_error()}
    ]
  )

  def create(conn, params) do
    with {:ok, result, email} <- ClassicSignInCodes.request(params, conn.assigns[:current_user]) do
      conn = json(conn, %{data: result})

      Task.Supervisor.start_child(PidroServer.TaskSupervisor, fn ->
        Mailer.deliver_logged(email, "Classic sign-in code")
      end)

      conn
    end
  end

  def verify(conn, params) do
    with {:ok, result} <- ClassicSignInCodes.verify(params, conn.assigns[:current_user]) do
      json(conn, %{data: result})
    end
  end
end

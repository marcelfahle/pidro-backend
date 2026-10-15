defmodule PidroServerWeb.API.FallbackControllerTest do
  use PidroServerWeb.ConnCase, async: true

  alias PidroServerWeb.API.FallbackController

  test "unknown atoms preserve legacy fields but use the generic localization code", %{conn: conn} do
    assert conn
           |> FallbackController.call({:error, :unexpected_backend_failure})
           |> json_response(422) == %{
             "errors" => [
               %{
                 "code" => "UNEXPECTED_BACKEND_FAILURE",
                 "title" => "Unexpected backend failure",
                 "detail" => "Operation failed: unexpected_backend_failure"
               }
             ],
             "error_code" => "request_failed",
             "error_params" => %{}
           }
  end

  test "arbitrary strings and tuples remain unhandled instead of becoming 422s", %{conn: conn} do
    for reason <- ["private backend failure", {:unexpected, "private backend failure"}] do
      assert_raise FunctionClauseError, fn -> FallbackController.call(conn, {:error, reason}) end
    end
  end
end

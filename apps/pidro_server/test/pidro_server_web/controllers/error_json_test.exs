defmodule PidroServerWeb.ErrorJSONTest do
  use PidroServerWeb.ConnCase, async: true

  test "renders 404" do
    assert PidroServerWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"},
             error_code: "not_found",
             error_params: %{}
           }
  end

  test "renders 500" do
    assert PidroServerWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               errors: %{detail: "Internal Server Error"},
               error_code: "request_failed",
               error_params: %{}
             }
  end

  test "renders auth status codes without exposing exception details" do
    for {status, code, detail} <- [
          {"401", "unauthorized", "Unauthorized"},
          {"403", "forbidden", "Forbidden"},
          {"422", "request_failed", "Unprocessable Content"}
        ] do
      assert PidroServerWeb.ErrorJSON.render("#{status}.json", %{reason: "private failure"}) == %{
               errors: %{detail: detail},
               error_code: code,
               error_params: %{}
             }
    end
  end
end

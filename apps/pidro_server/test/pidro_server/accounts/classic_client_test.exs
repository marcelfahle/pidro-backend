defmodule PidroServer.Accounts.ClassicClientTest do
  use ExUnit.Case, async: true

  alias PidroServer.Accounts.ClassicClient

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "uses the restricted Classic password endpoint with the shared bearer secret" do
    Req.Test.expect(ClassicClient, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/internal/claims/verify_password"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer classic-test-secret"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"login" => "old@example.com", "password" => "secret"}
      Req.Test.json(conn, %{"id" => 99, "username" => "Veteran"})
    end)

    assert {:ok, %{"id" => 99}} = ClassicClient.verify_password("old@example.com", "secret")
  end

  test "looks up a social identity without accepting a public Classic id" do
    Req.Test.expect(ClassicClient, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/internal/claims/lookup"
      assert conn.query_params == %{"fbid" => "old-app-id"}
      Req.Test.json(conn, %{"id" => 100})
    end)

    assert {:ok, %{"id" => 100}} = ClassicClient.lookup(:fbid, "old-app-id")
  end
end

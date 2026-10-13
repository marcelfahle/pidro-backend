defmodule PidroServerWeb.API.ClassicHelpControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Swoosh.TestAssertions

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures

  defmodule ErrorMailer do
    use Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :provider_down}
  end

  defmodule ExitMailer do
    use Swoosh.Adapter
    # Like Swoosh.Adapters.Local without its storage: the exit reason holds the email.
    def deliver(email, _config), do: GenServer.call({:global, :no_mail_storage}, {:push, email})
  end

  @valid %{"name" => "Old Hand", "email" => "old@example.com", "details" => "Played in 2012"}

  test "mails support with the player's address as reply-to", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/classic/help", @valid)

    assert response(conn, 204) == ""

    assert_email_sent(fn email ->
      assert email.to == [{"", "support@pidro.net"}]
      assert email.reply_to == {"", "old@example.com"}
      assert email.subject == "Help finding a Classic account: Old Hand"
      assert email.text_body =~ "Name: Old Hand"
      assert email.text_body =~ "Email: old@example.com"
      assert email.text_body =~ "Details: Played in 2012"
      refute email.text_body =~ "Signed in"
      assert email.html_body == nil
    end)
  end

  test "names the player when signed in and accepts missing details", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
      |> post(~p"/api/v1/classic/help", Map.delete(@valid, "details"))

    assert response(conn, 204)
    assert_email_sent(fn email -> assert email.text_body =~ "Signed in as player: #{user.id}" end)
  end

  describe "validation" do
    test "name is required", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/classic/help", Map.delete(@valid, "name"))

      assert [%{"code" => "name", "detail" => "can't be blank"}] =
               json_response(conn, 422)["errors"]

      assert_no_email_sent()
    end

    test "name is at most 60 characters", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/classic/help", %{@valid | "name" => String.duplicate("a", 61)})
      assert [%{"code" => "name"}] = json_response(conn, 422)["errors"]
    end

    test "name cannot carry line breaks", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/classic/help", %{@valid | "name" => "a\r\nBcc: x@y.z"})
      assert [%{"code" => "name"}] = json_response(conn, 422)["errors"]
      assert_no_email_sent()
    end

    test "email is required and must look like an address", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/classic/help", Map.delete(@valid, "email"))
      assert [%{"code" => "email"}] = json_response(conn, 422)["errors"]

      conn = post(build_conn(), ~p"/api/v1/classic/help", %{@valid | "email" => "not an email"})
      assert [%{"code" => "email"}] = json_response(conn, 422)["errors"]
    end

    test "details are at most 600 characters", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/classic/help", %{@valid | "details" => String.duplicate("a", 601)})

      assert [%{"code" => "details"}] = json_response(conn, 422)["errors"]
    end
  end

  for {failure, mailer} <- [{"returns an error", ErrorMailer}, {"exits", ExitMailer}] do
    test "answers 503 when the mailer #{failure}", %{conn: conn} do
      mailer_env = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
      Application.put_env(:pidro_server, PidroServer.Mailer, adapter: unquote(mailer))
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post(conn, ~p"/api/v1/classic/help", @valid)
          assert [%{"code" => "MAIL_UNAVAILABLE"}] = json_response(conn, 503)["errors"]
        end)

      refute log =~ "Played in 2012"
    end
  end

  test "is rate limited by address", %{conn: conn} do
    PidroServerWeb.RateLimitCase.with_limit(:classic_help, 1, 60_000)

    assert post(conn, ~p"/api/v1/classic/help", @valid).status == 204
    assert post(build_conn(), ~p"/api/v1/classic/help", @valid).status == 429
  end
end

defmodule PidroServerWeb.Dev.EmailMigrationLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails

  test "renders the email studio editor", %{conn: conn} do
    AccountsFixtures.user_fixture(%{username: "mail_ui_player", email: "mail-ui@example.com"})
    {:ok, template} = Emails.create_template(:transactional)

    {:ok, view, html} = live(conn, ~p"/dev/emails")

    assert html =~ "Email Studio"
    assert html =~ "Export contacts"
    assert html =~ template.name
    assert html =~ "EmailEditor"
    assert html =~ "contenteditable"
    assert html =~ "Saved in database"
    refute html =~ "PID-11"
    refute html =~ "Sends"
    refute html =~ "Published"

    html = render_click(view, "new_template", %{"kind" => "campaign"})

    assert html =~ "Campaign"
    assert html =~ "Untitled campaign"

    campaign = Emails.list_templates(:campaign) |> List.first()

    html =
      render_submit(view, "save_template", %{
        "template" => %{
          "name" => "April campaign",
          "subject" => "April at the Pidro table",
          "preview_text" => "A short player update",
          "from_name" => "Pidro",
          "from_email" => "hello@pidro.online",
          "reply_to" => "support@pidro.net",
          "html_body" => "<p>Hello players</p>",
          "variables_text" => "{{first_name}}\n{{unsubscribe_url}}"
        }
      })

    assert html =~ "April campaign"
    updated = Emails.get_template!(campaign.id)
    assert updated.subject == "April at the Pidro table"
    assert updated.html_body == "<p>Hello players</p>"
    assert updated.variables == ["{{first_name}}", "{{unsubscribe_url}}"]
  end

  test "deletes an email draft", %{conn: conn} do
    {:ok, template} = Emails.create_template(:transactional)

    {:ok, view, html} = live(conn, ~p"/dev/emails")

    assert html =~ template.name

    html = render_click(view, "request_delete", %{"id" => template.id})

    assert html =~ "Delete #{template.name}?"
    assert html =~ "already-sent emails are not affected"

    html = render_click(view, "confirm_delete")

    assert Emails.get_template(template.id) == nil
    assert html =~ "No Transactional emails yet"
  end

  test "downloads the Keila contact export", %{conn: conn} do
    AccountsFixtures.user_fixture(%{
      username: "mail_export_player",
      email: "mail-export@example.com"
    })

    conn = get(conn, ~p"/dev/emails/export.csv")

    assert response(conn, 200) =~ "mail-export@example.com"
    assert response(conn, 200) =~ "email,username,first_name,last_name,subscribed"
    assert ["text/csv; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "pidro-keila-contacts-"
  end
end

defmodule PidroServerWeb.Dev.EmailMigrationLiveTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails

  setup :register_and_log_in_admin
  setup :set_swoosh_global

  setup do
    PidroServer.Repo.delete_all(PidroServer.Emails.EmailTemplate)
    :ok
  end

  defmodule BlockingMailer do
    use Swoosh.Adapter

    def deliver(email, config) do
      send(config[:test_pid], {:mail_waiting, self(), email})

      receive do
        :deliver -> Swoosh.Adapters.Test.deliver(email, [])
        :fail -> {:error, {:rejected, email}}
      end
    end
  end

  test "preview renders samples at both widths; warnings allow saving and recover from typos", %{
    conn: conn
  } do
    {:ok, template} = Emails.create_template(:transactional)
    {:ok, view, _html} = live(conn, ~p"/admin/emails")
    assert preview_html(view) =~ "Hi Aino Korhonen"
    refute preview_html(view) =~ "{{"
    assert has_element?(view, "[data-email-preview][sandbox=''][style='width:390px;']")

    params = %{
      "subject" => "Hello {{username}}",
      "preview_text" => "Code {{code}}",
      "html_body" => "<p>Hello {{username}}</p>",
      "variables_text" => "{{username}}\n{{code}}"
    }

    render_change(view, "preview_template", %{"template_id" => template.id, "template" => params})
    assert has_element?(view, "#email-preview-metadata", "Hello Aino Korhonen")
    assert has_element?(view, "#email-preview-metadata", "Code 028641")
    assert has_element?(view, "[data-email-hidden-html]", "<p>Hello {{username}}</p>")
    render_click(view, "preview_width", %{"width" => "640"})
    assert has_element?(view, "[data-email-preview][style='width:640px;']")
    assert has_element?(view, "[phx-value-width='640'][aria-pressed='true']")
    assert preview_html(view) =~ "Hello Aino Korhonen"
    assert Emails.get_template!(template.id).subject == template.subject

    typo = Map.put(params, "html_body", "<p>{{usernmae}}</p>")
    render_change(view, "preview_template", %{"template_id" => template.id, "template" => typo})
    assert has_element?(view, "#placeholder-warnings", "Used but undeclared: usernmae")
    assert has_element?(view, "#email-preview-error", "No sample value for: usernmae")
    assert preview_html(view) == ""
    assert has_element?(view, "#send-test-email[disabled]")
    render_submit(view, "save_template", %{"template_id" => template.id, "template" => typo})
    assert Emails.get_template!(template.id).html_body == "<p>{{usernmae}}</p>"

    render_change(view, "preview_template", %{
      "template_id" => template.id,
      "template" => Map.put(params, "variables_text", "")
    })

    assert has_element?(view, "#placeholder-warnings", "Used but undeclared: code, username")
    assert preview_html(view) =~ "Hello Aino Korhonen"
    refute has_element?(view, "#send-test-email[disabled]")
  end

  test "test send matches the unsaved preview and the sixth is refused after remount", %{
    conn: conn
  } do
    {:ok, template} = Emails.create_template(:transactional)
    {:ok, view, _html} = live(conn, ~p"/admin/emails")

    params = %{
      "subject" => "Draft for {{username}}",
      "html_body" => "<p>Unsaved {{username}}</p>"
    }

    render_change(view, "preview_template", %{"template_id" => template.id, "template" => params})
    expected_html = preview_html(view)

    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        for index <- 1..5 do
          render_submit(view, "send_test_email", %{
            "template_id" => template.id,
            "recipient" => "test#{index}@example.com"
          })

          assert render_async(view) =~ "Sent #{template.name} to test#{index}@example.com."

          assert_email_sent(fn email ->
            assert email.subject == "Draft for Aino Korhonen"
            assert email.html_body == expected_html
            assert email.text_body == "Unsaved Aino Korhonen"
            assert email.to == [{"", "test#{index}@example.com"}]
          end)
        end
      end)

    assert log =~ "action=send_test_email"
    assert Emails.get_template!(template.id).subject == template.subject

    {:ok, remounted, _html} = live(conn, ~p"/admin/emails")

    render_submit(remounted, "send_test_email", %{
      "template_id" => template.id,
      "recipient" => "sixth@example.com"
    })

    assert render_async(remounted) =~ "Five-test limit reached"
    assert_no_email_sent()
  end

  test "pending send survives template selection, ignores duplicates and reports failure safely",
       %{conn: conn} do
    {:ok, first} = Emails.create_template(:transactional)
    {:ok, other} = Emails.create_template(:transactional)
    original = Application.fetch_env!(:pidro_server, PidroServer.Mailer)

    Application.put_env(:pidro_server, PidroServer.Mailer,
      adapter: BlockingMailer,
      test_pid: self()
    )

    on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, original) end)
    {:ok, view, _html} = live(conn, ~p"/admin/emails")
    render_click(view, "select_template", %{"id" => first.id})

    render_submit(view, "send_test_email", %{
      "template_id" => first.id,
      "recipient" => "first@example.com"
    })

    assert_receive {:mail_waiting, sender, _email}
    render_click(view, "select_template", %{"id" => other.id})

    render_submit(view, "send_test_email", %{
      "template_id" => other.id,
      "recipient" => "duplicate@example.com"
    })

    assert has_element?(view, "#send-test-email[disabled]")
    refute_receive {:mail_waiting, _, _}
    send(sender, :fail)
    assert render_async(view) =~ "The mail could not be sent"
    refute render(view) =~ "rejected"
    refute has_element?(view, "#send-test-email[disabled]")

    Application.put_env(:pidro_server, PidroServer.Mailer, original)

    render_submit(view, "send_test_email", %{
      "template_id" => other.id,
      "recipient" => "retry@example.com"
    })

    assert render_async(view) =~ "Sent"
    assert_email_sent()
  end

  test "revoked admin session cannot send from an open studio", %{conn: conn} do
    {:ok, template} = Emails.create_template(:transactional)
    {:ok, view, _html} = live(conn, ~p"/admin/emails")
    conn |> get_session(:admin_token) |> PidroServer.Admins.delete_admin_session_token()

    assert {:error, {:redirect, %{to: "/admin/login"}}} =
             render_submit(view, "send_test_email", %{
               "template_id" => template.id,
               "recipient" => "revoked@example.com"
             })

    assert_no_email_sent()
  end

  test "late editor events cannot change, save or send a different selected template", %{
    conn: conn
  } do
    {:ok, first} = Emails.create_template(:transactional)
    {:ok, second} = Emails.create_template(:transactional)
    {:ok, view, _html} = live(conn, ~p"/admin/emails")
    render_click(view, "select_template", %{"id" => second.id})

    late = %{
      "template_id" => first.id,
      "template" => %{"subject" => "Stale draft", "html_body" => "<p>Wrong editor</p>"}
    }

    render_change(view, "preview_template", late)
    render_submit(view, "save_template", late)

    render_submit(view, "send_test_email", %{
      "template_id" => first.id,
      "recipient" => "wrong@example.com"
    })

    refute preview_html(view) =~ "Wrong editor"
    assert Emails.get_template!(second.id).subject == second.subject
    assert_no_email_sent()

    render_click(view, "filter_kind", %{"kind" => "campaign"})
    render_change(view, "preview_template", late)
    render_submit(view, "save_template", late)

    render_submit(view, "send_test_email", %{
      "template_id" => first.id,
      "recipient" => "wrong@example.com"
    })

    assert has_element?(view, "h3", "No email selected")
    assert_no_email_sent()
  end

  test "renders the email studio editor", %{conn: conn} do
    AccountsFixtures.user_fixture(%{username: "mail_ui_player", email: "mail-ui@example.com"})
    {:ok, template} = Emails.create_template(:transactional)

    {:ok, view, html} = live(conn, ~p"/admin/emails")

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
        "template_id" => campaign.id,
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

    {:ok, view, html} = live(conn, ~p"/admin/emails")

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

    conn = get(conn, ~p"/admin/emails/export.csv")

    assert response(conn, 200) =~ "mail-export@example.com"
    assert response(conn, 200) =~ "email,username,first_name,last_name,subscribed"
    assert ["text/csv; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "pidro-keila-contacts-"
  end

  defp preview_html(view) do
    view
    |> element("[data-email-preview]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("srcdoc")
    |> hd()
  end
end

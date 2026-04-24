defmodule PidroServer.EmailMigrationTest do
  use PidroServer.DataCase, async: false

  import Swoosh.TestAssertions

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails

  setup :set_swoosh_global

  test "subscriber_summary counts exportable contacts" do
    AccountsFixtures.user_fixture(%{username: "mail_registered", email: "registered@example.com"})

    AccountsFixtures.user_fixture(%{
      username: "mail_guest",
      email: "guest@example.com",
      guest: true
    })

    {:ok, _user} =
      Auth.register_user(%{
        username: "mail_without_email",
        password: AccountsFixtures.valid_user_password()
      })

    summary = Emails.subscriber_summary()

    assert summary.total_users == 3
    assert summary.contacts_with_email == 2
    assert summary.registered_contacts == 1
    assert summary.guest_contacts == 1
    assert summary.missing_email == 1
  end

  test "export_contacts_csv includes Keila headers and escapes fields" do
    AccountsFixtures.user_fixture(%{
      username: ~s(Name, "Pilot"),
      email: "pilot@example.com"
    })

    csv = Emails.export_contacts_csv()

    assert csv =~
             "email,username,first_name,last_name,subscribed,guest,created_at,updated_at,source"

    assert csv =~ "pilot@example.com"
    assert csv =~ ~s("Name, ""Pilot""")
    assert csv =~ ",true,false,"
    assert csv =~ "pidro_server"
  end

  test "creates and updates email templates in the database" do
    {:ok, template} = Emails.create_template(:transactional)

    assert template.kind == :transactional
    assert template.key =~ "transactional_email_"
    assert template.name == "Untitled transactional email"
    refute Map.has_key?(template, :sends)
    refute Map.has_key?(template, :opens)

    {:ok, updated} =
      Emails.update_template(template, %{
        "key" => "welcome_email",
        "name" => "Welcome email",
        "subject" => "Welcome to Pidro",
        "html_body" => "<p>Hi {{username}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert updated.name == "Welcome email"
    assert updated.key == "welcome_email"
    assert updated.subject == "Welcome to Pidro"
    assert updated.variables == ["{{username}}", "{{support_email}}"]
    assert Emails.get_transactional_template(:welcome_email).id == updated.id
    assert Emails.template_summary().transactional == 1

    assert {:ok, _deleted} = Emails.delete_template(updated)
    assert Emails.get_template(updated.id) == nil
    assert Emails.template_summary().transactional == 0
  end

  test "renders and delivers a transactional email by key" do
    user =
      AccountsFixtures.user_fixture(%{
        username: "mail_delivery_player",
        email: "mail-delivery@example.com"
      })

    {:ok, template} = Emails.create_template(:transactional)

    {:ok, _template} =
      Emails.update_template(template, %{
        "key" => "welcome_email",
        "name" => "Welcome email",
        "subject" => "Welcome {{username}}",
        "preview_text" => "Start playing, {{username}}",
        "from_name" => "Pidro",
        "from_email" => "noreply@pidro.online",
        "reply_to" => "support@pidro.net",
        "html_body" => "<p>Hi {{username}}</p><p>Ask {{support_email}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert {:ok, _metadata} =
             Emails.deliver_transactional(:welcome_email, user, %{
               username: "<Pilot>",
               support_email: "support@pidro.net"
             })

    assert_email_sent(fn email ->
      assert email.subject == "Welcome <Pilot>"
      assert email.to == [{"mail_delivery_player", "mail-delivery@example.com"}]
      assert email.from == {"Pidro", "noreply@pidro.online"}
      assert email.reply_to == {"", "support@pidro.net"}
      assert email.html_body =~ "Hi &lt;Pilot&gt;"
      assert email.text_body =~ "Hi <Pilot>"
      true
    end)
  end

  test "returns missing variable errors before sending transactional email" do
    {:ok, template} = Emails.create_template(:transactional)

    {:ok, template} =
      Emails.update_template(template, %{
        "key" => "account_deletion",
        "subject" => "Account deletion for {{username}}",
        "html_body" => "<p>Ask {{support_email}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert {:error, {:missing_variables, ["support_email"]}} =
             Emails.render_template(template, %{username: "Pilot"})

    assert {:error, {:missing_variables, ["support_email"]}} =
             Emails.deliver_transactional("account_deletion", "pilot@example.com", %{
               username: "Pilot"
             })
  end
end

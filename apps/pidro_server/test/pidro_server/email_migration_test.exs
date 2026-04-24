defmodule PidroServer.EmailMigrationTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Emails

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
    assert template.name == "Untitled transactional email"
    refute Map.has_key?(template, :sends)
    refute Map.has_key?(template, :opens)

    {:ok, updated} =
      Emails.update_template(template, %{
        "name" => "Welcome email",
        "subject" => "Welcome to Pidro",
        "html_body" => "<p>Hi {{username}}</p>",
        "variables_text" => "{{username}}\n{{support_email}}"
      })

    assert updated.name == "Welcome email"
    assert updated.subject == "Welcome to Pidro"
    assert updated.variables == ["{{username}}", "{{support_email}}"]
    assert Emails.template_summary().transactional == 1

    assert {:ok, _deleted} = Emails.delete_template(updated)
    assert Emails.get_template(updated.id) == nil
    assert Emails.template_summary().transactional == 0
  end
end

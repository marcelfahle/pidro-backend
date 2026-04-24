defmodule PidroServer.Emails do
  @moduledoc """
  Email admin context for contact export and draft templates.
  """

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Emails.EmailTemplate
  alias PidroServer.Repo

  @ses_relay "email-smtp.eu-west-1.amazonaws.com"
  @contact_headers [
    "email",
    "username",
    "first_name",
    "last_name",
    "subscribed",
    "guest",
    "created_at",
    "updated_at",
    "source"
  ]

  @variable_groups [
    %{
      name: "Player",
      variables: [
        %{key: "{{username}}", label: "Username"},
        %{key: "{{first_name}}", label: "First name"},
        %{key: "{{last_played_at}}", label: "Last played"}
      ]
    },
    %{
      name: "Links",
      variables: [
        %{key: "{{reset_url}}", label: "Reset URL"},
        %{key: "{{unsubscribe_url}}", label: "Unsubscribe URL"},
        %{key: "{{offer_url}}", label: "Offer URL"},
        %{key: "{{app_store_url}}", label: "iOS URL"},
        %{key: "{{play_store_url}}", label: "Android URL"}
      ]
    },
    %{
      name: "Support",
      variables: [
        %{key: "{{support_email}}", label: "Support email"},
        %{key: "{{purchase_platform}}", label: "Purchase platform"},
        %{key: "{{renewal_date}}", label: "Renewal date"}
      ]
    }
  ]

  def subscriber_summary do
    total_users = Repo.aggregate(User, :count, :id)
    contacts_query = exportable_contacts_query()
    contacts_with_email = Repo.aggregate(contacts_query, :count, :id)

    guest_contacts =
      contacts_query
      |> where([u], u.guest == true)
      |> Repo.aggregate(:count, :id)

    %{
      total_users: total_users,
      contacts_with_email: contacts_with_email,
      registered_contacts: contacts_with_email - guest_contacts,
      guest_contacts: guest_contacts,
      missing_email: total_users - contacts_with_email
    }
  end

  def list_contact_export_rows do
    exportable_contacts_query()
    |> order_by([u], asc: u.inserted_at)
    |> select([u], %{
      email: u.email,
      username: u.username,
      guest: u.guest,
      inserted_at: u.inserted_at,
      updated_at: u.updated_at
    })
    |> Repo.all()
  end

  def export_contacts_csv do
    rows =
      list_contact_export_rows()
      |> Enum.map(fn row ->
        [
          row.email,
          row.username,
          nil,
          nil,
          true,
          row.guest,
          row.inserted_at,
          row.updated_at,
          "pidro_server"
        ]
      end)

    [csv_row(@contact_headers) | Enum.map(rows, &csv_row/1)]
    |> IO.iodata_to_binary()
  end

  def contact_export_filename do
    "pidro-keila-contacts-#{Date.utc_today()}.csv"
  end

  def list_templates(kind \\ :all)

  def list_templates(kind) when kind in [:transactional, :campaign] do
    EmailTemplate
    |> where([template], template.kind == ^kind)
    |> order_by([template], desc: template.updated_at, asc: template.name)
    |> Repo.all()
  end

  def list_templates(_kind) do
    EmailTemplate
    |> order_by([template], asc: template.kind, desc: template.updated_at, asc: template.name)
    |> Repo.all()
  end

  def get_template(id), do: Repo.get(EmailTemplate, id)
  def get_template!(id), do: Repo.get!(EmailTemplate, id)

  def first_template(kind) do
    kind
    |> list_templates()
    |> List.first()
  end

  def create_template(kind) when kind in [:transactional, :campaign] do
    %EmailTemplate{}
    |> EmailTemplate.changeset(default_template_attrs(kind))
    |> Repo.insert()
  end

  def create_template(kind) when is_binary(kind) do
    kind
    |> normalize_kind()
    |> create_template()
  end

  def change_template(%EmailTemplate{} = template, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new("variables_text", Enum.join(template.variables || [], "\n"))

    EmailTemplate.changeset(template, attrs)
  end

  def update_template(%EmailTemplate{} = template, attrs) do
    template
    |> EmailTemplate.changeset(attrs)
    |> Repo.update()
  end

  def delete_template(%EmailTemplate{} = template) do
    Repo.delete(template)
  end

  def template_summary do
    total = Repo.aggregate(EmailTemplate, :count, :id)

    transactional =
      Repo.aggregate(from(t in EmailTemplate, where: t.kind == :transactional), :count, :id)

    campaigns = Repo.aggregate(from(t in EmailTemplate, where: t.kind == :campaign), :count, :id)

    %{total: total, transactional: transactional, campaigns: campaigns}
  end

  def variable_groups, do: @variable_groups

  def delivery_setup do
    mailer_config = Application.get_env(:pidro_server, PidroServer.Mailer, [])

    %{
      mailer_adapter: inspect(Keyword.get(mailer_config, :adapter, Swoosh.Adapters.Local)),
      relay: System.get_env("SES_SMTP_RELAY") || @ses_relay,
      from_address: System.get_env("MAIL_FROM_ADDRESS") || "noreply@pidro.online",
      reply_to: System.get_env("MAIL_REPLY_TO") || "support@pidro.net"
    }
  end

  def normalize_kind(kind) when kind in [:transactional, :campaign], do: kind
  def normalize_kind("campaign"), do: :campaign
  def normalize_kind("transactional"), do: :transactional
  def normalize_kind(_kind), do: :transactional

  defp default_template_attrs(:transactional) do
    %{
      kind: :transactional,
      name: "Untitled transactional email",
      subject: "Untitled Pidro email",
      preview_text: "",
      from_name: "Pidro",
      from_email: "noreply@pidro.online",
      reply_to: "support@pidro.net",
      html_body: """
      <p>Hi {{username}},</p>
      <p>Write the email body here.</p>
      """,
      variables_text: "{{username}}\n{{support_email}}"
    }
  end

  defp default_template_attrs(:campaign) do
    %{
      kind: :campaign,
      name: "Untitled campaign",
      subject: "Untitled Pidro campaign",
      preview_text: "",
      from_name: "Pidro",
      from_email: "hello@pidro.online",
      reply_to: "support@pidro.net",
      html_body: """
      <p>Hi {{first_name}},</p>
      <p>Write the campaign body here.</p>
      <p><a href="{{unsubscribe_url}}">Unsubscribe</a></p>
      """,
      variables_text: "{{first_name}}\n{{unsubscribe_url}}\n{{support_email}}"
    }
  end

  defp exportable_contacts_query do
    from u in User,
      where: not is_nil(u.email) and u.email != ""
  end

  defp csv_row(values) do
    [values |> Enum.map(&csv_cell/1) |> Enum.intersperse(","), "\n"]
  end

  defp csv_cell(nil), do: ""
  defp csv_cell(true), do: "true"
  defp csv_cell(false), do: "false"

  defp csv_cell(%DateTime{} = value) do
    value
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp csv_cell(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      escaped = String.replace(value, "\"", "\"\"")
      [?\", escaped, ?\"]
    else
      value
    end
  end
end

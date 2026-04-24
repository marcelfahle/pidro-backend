defmodule PidroServer.Emails do
  @moduledoc """
  Email admin context for contact export and draft templates.
  """

  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias PidroServer.Accounts.User
  alias PidroServer.Emails.EmailTemplate
  alias PidroServer.Mailer
  alias PidroServer.Repo

  @ses_relay "email-smtp.eu-west-1.amazonaws.com"
  @placeholder_regex ~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/
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

  def get_template_by_key(kind, key) do
    Repo.get_by(EmailTemplate, kind: normalize_kind(kind), key: normalize_template_key(key))
  end

  def get_transactional_template(key), do: get_template_by_key(:transactional, key)

  def first_template(kind) do
    kind
    |> list_templates()
    |> List.first()
  end

  def create_template(kind) when kind in [:transactional, :campaign] do
    attrs =
      kind
      |> default_template_attrs()
      |> Map.put(:key, default_template_key(kind))

    %EmailTemplate{}
    |> EmailTemplate.changeset(attrs)
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

  def render_template(%EmailTemplate{} = template, variables \\ %{}) do
    variables = normalize_variables(variables)

    missing_variables =
      template
      |> required_variable_names()
      |> Enum.reject(&Map.has_key?(variables, &1))

    if missing_variables == [] do
      html_body = render_placeholders(template.html_body || "", variables, :html)

      {:ok,
       %{
         subject: render_placeholders(template.subject || "", variables, :text),
         preview_text: render_placeholders(template.preview_text || "", variables, :text),
         html_body: html_body,
         text_body: html_to_text(html_body)
       }}
    else
      {:error, {:missing_variables, missing_variables}}
    end
  end

  def deliver_transactional(key, recipient, variables \\ %{}) do
    case get_transactional_template(key) do
      nil ->
        {:error, :template_not_found}

      %EmailTemplate{} = template ->
        deliver_template(template, recipient, variables)
    end
  end

  def deliver_template(%EmailTemplate{} = template, recipient, variables \\ %{}) do
    with {:ok, recipient_mailbox} <- recipient_to_mailbox(recipient),
         {:ok, rendered} <- render_template(template, variables) do
      new()
      |> to(recipient_mailbox)
      |> Swoosh.Email.from(sender_mailbox(template))
      |> maybe_reply_to(template.reply_to)
      |> subject(rendered.subject)
      |> html_body(rendered.html_body)
      |> text_body(rendered.text_body)
      |> Mailer.deliver()
    end
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

  def normalize_template_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> normalize_template_key()
  end

  def normalize_template_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
  end

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

  defp default_template_key(kind) do
    suffix =
      Ecto.UUID.generate()
      |> String.slice(0, 8)
      |> String.replace("-", "_")

    "#{kind}_email_#{suffix}"
  end

  defp required_variable_names(%EmailTemplate{} = template) do
    [template.subject, template.preview_text, template.html_body]
    |> Enum.flat_map(fn source ->
      @placeholder_regex
      |> Regex.scan(source || "")
      |> Enum.map(fn [_match, key] -> key end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_variables(variables) when is_map(variables) do
    variables
    |> Enum.map(fn {key, value} -> {normalize_variable_key(key), variable_to_string(value)} end)
    |> Map.new()
  end

  defp normalize_variables(_variables), do: %{}

  defp normalize_variable_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_variable_key(key) do
    key = key |> to_string() |> String.trim()

    case Regex.run(@placeholder_regex, key) do
      [_match, variable_key] -> variable_key
      _other -> key
    end
  end

  defp variable_to_string(nil), do: ""
  defp variable_to_string(%Date{} = value), do: Date.to_iso8601(value)
  defp variable_to_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp variable_to_string(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp variable_to_string(value), do: to_string(value)

  defp render_placeholders(source, variables, mode) do
    Regex.replace(@placeholder_regex, source, fn _match, key ->
      value = Map.fetch!(variables, key)

      case mode do
        :html ->
          value
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()

        :text ->
          value
      end
    end)
  end

  defp html_to_text(html_body) do
    html_body
    |> String.replace(~r/<\s*br\s*\/?>/i, "\n")
    |> String.replace(~r/<\s*\/\s*(p|div|h[1-6]|li)\s*>/i, "\n")
    |> String.replace(~r/<\s*li[^>]*>/i, "- ")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_basic_html_entities()
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp decode_basic_html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp recipient_to_mailbox(%User{email: email, username: username}) do
    mailbox(username, email)
  end

  defp recipient_to_mailbox({name, email}), do: mailbox(name, email)
  defp recipient_to_mailbox(email) when is_binary(email), do: mailbox(nil, email)
  defp recipient_to_mailbox(_recipient), do: {:error, :invalid_recipient}

  defp mailbox(name, email) do
    email = email |> to_string() |> String.trim()
    name = if is_binary(name), do: String.trim(name), else: nil

    cond do
      email == "" ->
        {:error, :missing_recipient_email}

      not valid_email?(email) ->
        {:error, :invalid_recipient_email}

      is_binary(name) and name != "" ->
        {:ok, {name, email}}

      true ->
        {:ok, email}
    end
  end

  defp sender_mailbox(%EmailTemplate{} = template) do
    delivery = delivery_setup()
    from_email = present_or_default(template.from_email, delivery.from_address)
    from_name = present_or_default(template.from_name, "Pidro")

    {from_name, from_email}
  end

  defp maybe_reply_to(email, reply_to_address) do
    reply_to_address = reply_to_address |> to_string() |> String.trim()

    if reply_to_address == "" do
      email
    else
      reply_to(email, reply_to_address)
    end
  end

  defp present_or_default(value, default) do
    value = value |> to_string() |> String.trim()

    if value == "", do: default, else: value
  end

  defp valid_email?(email) do
    String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
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

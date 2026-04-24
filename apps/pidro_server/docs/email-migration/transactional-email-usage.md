# Transactional Email Usage

Transactional emails are authored in `/dev/emails` and sent by Pidro server code through `PidroServer.Emails`.

Campaigns are different: use `/dev/emails/export.csv` to export contacts, then run campaign sends in Keila. Do not call campaign templates from game-server code.

## Admin Workflow

1. Open `/dev/emails`.
2. Choose `Transactional`.
3. Create or select an email.
4. Set a stable `Code key`, for example `welcome_email` or `password_reset`.
5. Write the subject, preview text, sender fields, and body.
6. Add any variables the email needs, one per line, such as `{{username}}` and `{{reset_url}}`.
7. Save.

The `Internal name` is for admins and can change. The `Code key` is the app contract and should be changed only with a matching code change.

## Variable Syntax

Templates use double-curly variables:

```text
{{username}}
{{reset_url}}
{{support_email}}
```

Variables are replaced at send time. HTML body variables are escaped before delivery, so player-controlled values cannot inject markup into the email.

If a template references a variable that code does not provide, delivery returns:

```elixir
{:error, {:missing_variables, ["reset_url"]}}
```

No email is sent in that case.

## Sending From Server Code

Use the transactional code key:

```elixir
alias PidroServer.Emails

Emails.deliver_transactional(:welcome_email, user, %{
  username: user.username,
  support_email: "support@pidro.net"
})
```

The recipient can be a `%PidroServer.Accounts.User{}`, a plain email string, or a `{name, email}` tuple:

```elixir
Emails.deliver_transactional(:password_reset, {"Jocke", "jocke@example.com"}, %{
  username: "Jocke",
  reset_url: reset_url
})
```

The function returns the normal Swoosh result:

```elixir
{:ok, metadata}
{:error, reason}
```

For user-facing flows such as registration, do not fail the account creation just because email delivery fails. Log the failure after the user has been created:

```elixir
case Emails.deliver_transactional(:welcome_email, user, %{username: user.username}) do
  {:ok, _metadata} ->
    :ok

  {:error, reason} ->
    Logger.warning("welcome_email delivery failed: #{inspect(reason)}")
end
```

## Registration Example

After the registration database operation succeeds:

```elixir
with {:ok, user} <- Auth.register_user(params) do
  Emails.deliver_transactional(:welcome_email, user, %{
    username: user.username,
    support_email: "support@pidro.net"
  })

  {:ok, user}
end
```

Only wire this once the `welcome_email` transactional template exists in the database.

## Local And Test Verification

In development, Swoosh uses the local mailbox. After sending a transactional email, open:

```text
/dev/mailbox
```

In tests, use `Swoosh.Adapters.Test` and assert on the delivered email.

## Production Checklist

Transactional sending is usable when:

- The template exists in `/dev/emails`.
- The template has the expected `Code key`.
- All variables used by the template are supplied by code.
- SES SMTP env vars are configured.
- `PidroServer.Mailer` is using the SES SMTP adapter in production.
- A Swoosh smoke test succeeds.
- Registration/reset/purchase flows log delivery failures instead of breaking the player action.

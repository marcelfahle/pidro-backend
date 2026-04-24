# Email Migration: Loops to Keila + SES

This playbook covers the remaining work for Linear PID-11 through PID-23.

The Pidro app now owns:

- `/dev/emails` email studio for creating and editing transactional emails and campaign drafts.
- `/dev/emails/export.csv` Keila contact CSV export for local users with email addresses.
- Database-backed email draft records, generated email HTML, preview, variable insertion, save, download, and copy actions.
- A small delivery setup readout using real runtime config.

The admin panel is not the source of truth for Linear ticket status or historical Loops metrics. Do not copy Loops send/open/delivery numbers into Pidro; recreate the email content here and move finished campaign execution into Keila.

External systems still own AWS SES, DNS, Keila hosting, Loops suppression export, bounce handling, and final Loops cancellation.

## 1. SES Identity And IAM

Linear: PID-11, PID-13, PID-14

1. In AWS SES, use `eu-west-1`.
2. Create IAM user `pidro-ses-sender`.
3. Attach the minimum policy needed for SES sending. The ticket says `AmazonSESFullAccess`; tighten it later once sending is proven.
4. Create a domain identity for `pidro.online`.
5. Request SES production access.

Use case for the production access form:

- Transactional email from the Pidro game app.
- Product/newsletter campaigns from Keila.
- Expected volume: about 70,000 contacts/month during normal full-list campaigns.
- Bounce and complaint handling: SES configuration set plus SNS, wired into Keila or a webhook.

After production access is approved, create SES SMTP credentials for `eu-west-1`.

SMTP values:

```text
Host: email-smtp.eu-west-1.amazonaws.com
Port: 587
TLS: STARTTLS
Auth: always
```

## 2. DNS

Linear: PID-12, PID-16

Publish the DKIM records SES gives you for `pidro.online`.

Recommended SPF record:

```text
TXT pidro.online "v=spf1 include:amazonses.com ~all"
```

Recommended DMARC record:

```text
TXT _dmarc.pidro.online "v=DMARC1; p=quarantine; pct=100"
```

Create the Keila host:

```text
A mail.pidro.online <server-ip>
```

Only cancel Loops after DKIM, SPF, DMARC, Keila, transactional mail, and bounce handling have all been verified.

## 3. Keila Deployment

Linear: PID-15, PID-16, PID-17

Use `docker-compose.keila.yml` from this folder on the server that will host Keila.

Create secrets:

```sh
openssl rand -base64 48
```

Store them in a private `.env` file on the server. Start Keila:

```sh
docker compose --env-file .env -f docker-compose.keila.yml up -d
docker compose -f docker-compose.keila.yml logs -f keila
```

Put nginx in front of Keila with `nginx-keila.conf`, then issue SSL:

```sh
sudo certbot --nginx -d mail.pidro.online
```

In Keila:

1. Create the first admin user.
2. Create project `Pidro Newsletter`.
3. Create sender identity `Pidro <hello@pidro.online>` or `Pidro <noreply@pidro.online>`.
4. Set reply-to to `support@pidro.net` unless support has moved.
5. Send a test message and confirm DKIM passes.

## 4. Contact Import

Linear: PID-18, PID-19

Export local app contacts:

```sh
curl -u "$DEV_BASIC_AUTH_USERNAME:$DEV_BASIC_AUTH_PASSWORD" \
  https://<pidro-admin-host>/dev/emails/export.csv \
  -o pidro-keila-contacts.csv
```

Export Loops subscribers and unsubscribed contacts from Loops:

- email
- firstName
- lastName
- subscribed/unsubscribed state
- custom fields
- createdAt

Important: the Pidro app does not currently store unsubscribe/suppression state. The app CSV marks rows as `subscribed=true`. Merge the Loops unsubscribed export before importing into Keila so opted-out players stay suppressed.

In Keila:

1. Open project `Pidro Newsletter`.
2. Import contacts.
3. Map fields: `email`, `username`, `first_name`, `last_name`, `subscribed`, `guest`, `created_at`, `source`.
4. Import unsubscribed/suppressed contacts as unsubscribed.
5. Verify final counts against Loops and `/dev/emails`.

## 5. Pidro Transactional Mail

Linear: PID-20

Swoosh is already in the Pidro app. SMTP delivery needs `gen_smtp`, which was not present in the current lockfile. Add it when the build environment has network access:

```elixir
# apps/pidro_server/mix.exs
{:gen_smtp, "~> 1.1", only: :prod}
```

Then run:

```sh
mix deps.get --only prod
mix deps.compile swoosh gen_smtp
```

Add this runtime config in the umbrella `config/runtime.exs` production block:

```elixir
config :pidro_server, :email,
  provider: System.get_env("EMAIL_PROVIDER") || "ses_smtp",
  from_name: System.get_env("MAIL_FROM_NAME") || "Pidro",
  from_address: System.get_env("MAIL_FROM_ADDRESS") || "noreply@pidro.online",
  reply_to: System.get_env("MAIL_REPLY_TO") || "support@pidro.net"

ses_smtp_user = System.get_env("SES_SMTP_USER")
ses_smtp_password = System.get_env("SES_SMTP_PASSWORD")

if is_binary(ses_smtp_user) and ses_smtp_user != "" and
     is_binary(ses_smtp_password) and ses_smtp_password != "" do
  config :pidro_server, PidroServer.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SES_SMTP_RELAY") || "email-smtp.eu-west-1.amazonaws.com",
    port: String.to_integer(System.get_env("SES_SMTP_PORT") || "587"),
    username: ses_smtp_user,
    password: ses_smtp_password,
    tls: :always,
    ssl: false,
    auth: :always,
    retries: 2
end
```

Production env vars:

```text
EMAIL_PROVIDER=ses_smtp
MAIL_FROM_NAME=Pidro
MAIL_FROM_ADDRESS=noreply@pidro.online
MAIL_REPLY_TO=support@pidro.net
SES_SMTP_RELAY=email-smtp.eu-west-1.amazonaws.com
SES_SMTP_PORT=587
SES_SMTP_USER=<from AWS SES SMTP credentials>
SES_SMTP_PASSWORD=<from AWS SES SMTP credentials>
```

Smoke test in a production console:

```elixir
import Swoosh.Email

new()
|> from({"Pidro", "noreply@pidro.online"})
|> to("you@example.com")
|> subject("Pidro SES smoke test")
|> text_body("SES SMTP is delivering through Swoosh.")
|> PidroServer.Mailer.deliver()
```

## 6. Warm-Up

Linear: PID-21

Use Keila segments and send gradually:

| Week | Audience | Target |
| --- | ---: | --- |
| 1 | 5k-10k | Most engaged players |
| 2 | 20k | Engaged + recent players |
| 3 | 50k | Broader active list |
| 4 | 70k | Full healthy list |

Watch:

- Bounce rate under 5%, ideally under 2%.
- Complaint rate under 0.1%.
- SES reputation dashboard stays healthy.
- DKIM/SPF/DMARC pass in seed inboxes.
- Keila unsubscribe links work.

## 7. Bounces And Complaints

Linear: PID-22

1. Create SNS topic `ses-bounces-complaints`.
2. Create SES configuration set `pidro-main`.
3. Add SES event destination for Bounce and Complaint to SNS.
4. Configure Keila to use the configuration set:

```text
MAILER_SES_CONFIGURATION_SET=pidro-main
```

5. Subscribe Keila webhook or a monitored email/SNS consumer.
6. Test with SES simulator addresses, including `bounce@simulator.amazonses.com`.

Do not run full campaigns until bounces and complaints change contact state somewhere Keila respects.

## 8. Cutover And Cancel Loops

Linear: PID-23

Cutover criteria:

- Keila admin and sender identity are live.
- SES production access is approved.
- DNS passes DKIM/SPF/DMARC.
- `/dev/emails/export.csv` contact count is reconciled with Loops.
- Loops unsubscribes are imported into Keila.
- Swoosh transactional smoke test passes.
- Keila campaign test passes.
- Bounce and complaint handling is verified.
- Warm-up sends are healthy for two weeks.

After that:

1. Export final Loops backup: subscribers, unsubscribes, campaign HTML, metrics.
2. Disable Loops API keys or sending automation.
3. Cancel Loops billing.
4. Keep the export archive in a private operations folder.

## Rollback

If SES or Keila fails during warm-up:

1. Pause Keila campaigns.
2. Revert transactional mailer env vars to the previous provider or local fallback.
3. Keep Loops active until the issue is fixed.
4. Do not re-import contacts repeatedly without deduping and preserving suppression state.

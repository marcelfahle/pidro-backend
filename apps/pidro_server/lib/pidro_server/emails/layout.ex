defmodule PidroServer.Emails.Layout do
  @moduledoc "The shared document around transactional email content."

  @doc "Wraps already-rendered HTML; only the support address is escaped here."
  def wrap(inner_html, support_email) do
    support_email = support_email |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    host = System.get_env("PIDRO_HOST")
    base_url = if host, do: "https://#{host}", else: PidroServerWeb.Endpoint.url()
    logo_url = base_url <> "/images/logo-email.png"

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <meta name="supported-color-schemes" content="light dark">
      <title>Pidro</title>
      <style>
        @media (prefers-color-scheme: dark) {
          body, .email-background { background-color: #1e0e04 !important; }
          .email-card { background-color: #07264c !important; color: #ffffff !important; }
          .email-card a:not(.email-button) { color: #f1d078 !important; }
          .email-footer, .email-footer a { color: #f1d078 !important; }
        }
      </style>
    </head>
    <body style="margin:0;padding:0;background-color:#f5f1e9;">
      <table role="presentation" class="email-background" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f5f1e9;">
        <tr><td align="center" style="padding:24px 12px;">
          <!--[if mso]><table role="presentation" width="600"><tr><td><![endif]-->
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;font-family:Nunito,'Helvetica Neue',Arial,sans-serif;">
            <tr><td align="center" style="padding:24px;background-color:#0d5087;border-bottom:4px solid #e1ad3a;">
              <img src="#{logo_url}" width="71" height="48" alt="" style="display:block;margin:0 auto 8px;">
              <span style="font-family:'Bree Serif',Georgia,serif;font-size:42px;line-height:1.2;color:#ffffff;">Pidro</span>
            </td></tr>
            <tr><td class="email-card" style="padding:28px 24px;background-color:#ffffff;color:#07264c;font-size:20px;line-height:1.6;overflow-wrap:anywhere;word-break:break-word;">
              #{inner_html}
            </td></tr>
            <tr><td class="email-footer" align="center" style="padding:24px 16px;color:#5a3515;font-size:16px;line-height:1.6;">
              Sent by Pidro<br>
              <a href="mailto:#{support_email}" style="color:#5a3515;">#{support_email}</a>
            </td></tr>
          </table>
          <!--[if mso]></td></tr></table><![endif]-->
        </td></tr>
      </table>
    </body>
    </html>
    """
  end
end

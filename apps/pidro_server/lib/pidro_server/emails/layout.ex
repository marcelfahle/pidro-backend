defmodule PidroServer.Emails.Layout do
  @moduledoc "The shared document around transactional email content."

  @doc "Wraps rendered HTML, escaping the support address and preview text."
  def wrap(inner_html, %{support_email: support_email, preview_text: preview_text}) do
    support_email = support_email |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    preview_text = preview_text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

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
          body, .bg { background-color: #140a03 !important; }
          .card { background-color: #0b2f5c !important; border-color: #1d4a7a !important; color: #f6f1e7 !important; }
          .h1 { color: #ffffff !important; }
          .muted { color: #c9d6e6 !important; }
          .card a.link, .card a:not(.email-button) { color: #f1d078 !important; }
          .card .btn a { color: #1e0e04 !important; }
          .codebox { background-color: #07264c !important; border-color: #1d5a94 !important; color: #f1d078 !important; }
          .footer, .footer a { color: #c8a26a !important; }
        }
        @media only screen and (max-width: 480px) {
          .card { padding: 28px 22px !important; }
          .h1 { font-size: 26px !important; }
          .btn a { display: block !important; }
          .codebox { font-size: 40px !important; letter-spacing: 8px !important; }
        }
      </style>
    </head>
    <body style="margin:0;padding:0;background-color:#f3eee4;">
      <div style="display:none;max-height:0;overflow:hidden;opacity:0;">#{preview_text}</div>
      <table role="presentation" class="bg" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f3eee4;">
        <tr><td align="center" style="padding:28px 12px 40px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;font-family:Nunito,'Helvetica Neue',Arial,sans-serif;">
            <tr><td align="center" style="padding:0 0 18px;">
              <img src="#{logo_url}" width="200" height="124" alt="Pidro" style="display:block;width:200px;height:auto;border:0;">
            </td></tr>
            <tr><td class="card" style="padding:36px 36px 32px;background-color:#ffffff;border-radius:16px;border:1px solid #e6ddc9;color:#1c2a3a;font-size:18px;line-height:1.6;overflow-wrap:anywhere;word-break:break-word;">
              #{inner_html}
            </td></tr>
            <tr><td class="footer" align="center" style="padding:26px 16px 0;color:#7a5a36;font-size:14px;line-height:1.7;">
              Pidro, the card game from Ostrobothnia<br>
              Questions? Write to <a href="mailto:#{support_email}" style="color:#7a5a36;">#{support_email}</a>
            </td></tr>
          </table>
        </td></tr>
      </table>
    </body>
    </html>
    """
  end
end

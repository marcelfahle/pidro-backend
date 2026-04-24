defmodule PidroServerWeb.Dev.EmailExportController do
  @moduledoc false

  use PidroServerWeb, :controller

  alias PidroServer.Emails

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{Emails.contact_export_filename()}")
    )
    |> send_resp(200, Emails.export_contacts_csv())
  end
end

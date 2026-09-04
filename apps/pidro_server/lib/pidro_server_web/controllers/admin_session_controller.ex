defmodule PidroServerWeb.AdminSessionController do
  use PidroServerWeb, :controller

  alias PidroServer.Admins
  alias PidroServerWeb.AdminAuth

  def new(conn, _params) do
    render(conn, :new, form: Phoenix.Component.to_form(%{"email" => ""}, as: :admin))
  end

  def create(conn, %{"admin" => admin_params}) do
    email = Map.get(admin_params, "email", "")
    password = Map.get(admin_params, "password", "")

    if admin = Admins.get_admin_by_email_and_password(email, password) do
      AdminAuth.log_in_admin(conn, admin)
    else
      conn
      |> put_flash(:error, "Invalid email or password.")
      |> render(:new,
        form: Phoenix.Component.to_form(%{"email" => email}, as: :admin)
      )
    end
  end

  def delete(conn, _params) do
    AdminAuth.log_out_admin(conn)
  end
end

defmodule PidroServerWeb.PageController do
  use PidroServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

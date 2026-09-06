defmodule PidroServerWeb.API.AvatarController do
  use PidroServerWeb, :controller
  alias PidroServer.Accounts.Avatars

  def create(conn, %{"avatar" => upload}) do
    case Avatars.put(conn.assigns.current_user.id, upload) do
      {:ok, url} -> json(conn, %{data: %{avatar_url: url}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _), do: error(conn, :missing_file)

  def delete(conn, _params) do
    Avatars.delete(conn.assigns.current_user.id)
    json(conn, %{data: %{avatar_url: nil}})
  end

  def show(conn, %{"user_id" => user_id, "version" => version}) do
    case Avatars.fetch(user_id, version) do
      nil ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "")

      bytes ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("etag", ~s("#{version}"))
        |> send_resp(200, bytes)
    end
  end

  defp error(conn, reason) do
    message =
      case reason do
        :too_large -> "avatar must be at most 5 MiB"
        :dimensions -> "avatar dimensions exceed the 16 megapixel or 8192 pixel limit"
        :unsupported_type -> "unsupported avatar type; upload JPEG or PNG"
        :missing_file -> "multipart field avatar is required"
        :result_too_large -> "processed avatar exceeds 64 KiB"
        :busy -> "photo processing is busy; please try again"
        _ -> "invalid avatar image"
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if(reason == :busy, do: 503, else: 422))
    |> json(%{errors: %{avatar: [message]}})
  end
end

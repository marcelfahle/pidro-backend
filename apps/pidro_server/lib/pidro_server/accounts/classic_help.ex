defmodule PidroServer.Accounts.ClassicHelp do
  @moduledoc """
  Forwards a "help me find my Classic account" request to support by email.

  Nothing is stored or logged: the message goes out as a plain text mail with
  the player's address as reply-to.
  """

  import Ecto.Changeset
  import Swoosh.Email

  alias PidroServer.Accounts.User
  alias PidroServer.Mailer

  @types %{name: :string, email: :string, details: :string}

  @doc """
  Validates `params` and mails them to support.

  Returns `:ok`, `{:error, changeset}` for invalid fields, or
  `{:error, :mail_unavailable}` when the mail could not be delivered.
  `user` is the signed-in player, or `nil`.
  """
  def request(params, user) do
    with {:ok, help} <- validate(params) do
      help |> build_email(user) |> deliver()
    end
  end

  defp validate(params) do
    {%{}, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:name, :email])
    |> validate_length(:name, max: 60)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u, message: "has invalid characters")
    |> validate_length(:email, max: 160)
    |> User.validate_email()
    |> validate_length(:details, max: 600)
    |> apply_action(:insert)
  end

  defp build_email(help, user) do
    new()
    |> to(System.get_env("MAIL_SUPPORT_ADDRESS") || "support@pidro.net")
    |> from({"Pidro", System.get_env("MAIL_FROM_ADDRESS") || "noreply@pidro.online"})
    |> reply_to(help.email)
    |> subject("Help finding a Classic account: #{help.name}")
    |> text_body("""
    Name: #{help.name}
    Email: #{help.email}
    Details: #{help[:details]}
    #{user_line(user)}
    """)
  end

  defp user_line(%{id: id}), do: "Signed in as player: #{id}"
  defp user_line(_user), do: ""

  defp deliver(email) do
    case Mailer.deliver_logged(email, "Classic help") do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> {:error, :mail_unavailable}
    end
  end
end

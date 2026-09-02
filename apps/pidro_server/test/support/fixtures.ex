defmodule PidroServer.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `PidroServer.Accounts` context.
  """

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_username, do: "user#{System.unique_integer()}"
  def valid_user_password, do: "hello world!"

  @doc """
  Registers a user through `Auth.register_user/1`.

  `guest` is not castable from public params, so it is popped from `attrs`
  and, when truthy, applied afterwards through `User.admin_changeset/2`. Every
  other attribute, including an email, reaches the row as given.
  """
  def user_fixture(attrs \\ %{}) do
    {guest, attrs} =
      attrs
      |> Enum.into(%{
        email: unique_user_email(),
        username: unique_username(),
        password: valid_user_password()
      })
      |> Map.pop(:guest)

    {:ok, user} = Auth.register_user(attrs)

    if guest do
      {:ok, user} =
        user
        |> User.admin_changeset(%{guest: true})
        |> Repo.update()

      user
    else
      user
    end
  end
end

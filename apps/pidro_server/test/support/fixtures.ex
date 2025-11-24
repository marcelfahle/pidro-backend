defmodule PidroServer.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `PidroServer.Accounts` context.
  """

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def unique_username, do: "user#{System.unique_integer()}"
  def valid_user_password, do: "hello world!"

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: unique_user_email(),
        username: unique_username(),
        password: valid_user_password()
      })
      |> PidroServer.Accounts.Auth.register_user()

    user
  end
end

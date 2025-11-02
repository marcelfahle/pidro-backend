defmodule PidroServerWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and interact with channels.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PidroServerWeb.ChannelCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import PidroServerWeb.ChannelCase

      # The default endpoint for testing
      @endpoint PidroServerWeb.Endpoint
    end
  end

  setup tags do
    PidroServer.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Helper function to create a valid JWT token for testing.

  ## Parameters

    - `user` - A user struct or map with an `id` field

  ## Returns

    - A valid JWT token string

  ## Examples

      user = insert(:user)
      token = create_token(user)
  """
  def create_token(user) do
    PidroServer.Accounts.Token.generate(user)
  end

  @doc """
  Helper function to create and authenticate a socket for testing.

  ## Parameters

    - `user` - A user struct or map with an `id` field

  ## Returns

    - `{:ok, socket}` on successful authentication
    - `:error` on authentication failure

  ## Examples

      user = insert(:user)
      {:ok, socket} = create_socket(user)
  """
  defmacro create_socket(user) do
    quote do
      token = create_token(unquote(user))
      connect(PidroServerWeb.UserSocket, %{"token" => token})
    end
  end
end

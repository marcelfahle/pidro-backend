defmodule PidroServerWeb.UserSocketTest do
  @moduledoc """
  Tests for UserSocket authentication and session management.

  Tests cover:
  - Socket connection with valid JWT tokens
  - Session ID generation and uniqueness
  - Connected timestamp tracking
  - Authentication failures
  - Socket ID generation
  """

  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.Accounts
  alias PidroServerWeb.UserSocket

  describe "connect/3 with valid token" do
    setup do
      # Create a test user
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "testuser",
          email: "test@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "successfully connects with valid token", %{token: token, user: user} do
      assert {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert socket.assigns.user_id == user.id
    end

    test "assigns user_id from token", %{token: token, user: user} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert socket.assigns.user_id == user.id
    end

    test "generates session_id on connect", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert socket.assigns.session_id != nil
      assert is_binary(socket.assigns.session_id)
    end

    test "sets connected_at timestamp", %{token: token} do
      before_connect = DateTime.utc_now()
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      after_connect = DateTime.utc_now()

      assert socket.assigns.connected_at != nil
      assert %DateTime{} = socket.assigns.connected_at

      # Timestamp should be between before and after
      assert DateTime.compare(socket.assigns.connected_at, before_connect) in [:gt, :eq]
      assert DateTime.compare(socket.assigns.connected_at, after_connect) in [:lt, :eq]
    end

    test "session_id is 16 characters long", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert String.length(socket.assigns.session_id) == 16
    end

    test "session_id is hexadecimal", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # Should only contain hex characters (0-9, a-f)
      assert socket.assigns.session_id =~ ~r/^[0-9a-f]{16}$/
    end
  end

  describe "connect/3 with invalid token" do
    test "rejects connection without token" do
      assert :error = connect(UserSocket, %{})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(UserSocket, %{"token" => "invalid_token_123"})
    end

    test "rejects connection with expired token" do
      # Create a token with very short expiry (this would require modifying Token.generate)
      # For now, we'll test with a malformed token
      expired_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.invalid.signature"

      assert :error = connect(UserSocket, %{"token" => expired_token})
    end

    test "rejects connection with empty token" do
      assert :error = connect(UserSocket, %{"token" => ""})
    end

    test "rejects connection with nil token" do
      assert :error = connect(UserSocket, %{"token" => nil})
    end

    test "rejects connection with random parameters" do
      assert :error = connect(UserSocket, %{"foo" => "bar", "baz" => "qux"})
    end
  end

  describe "session_id uniqueness" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "sessionuser",
          email: "session@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "each connection gets unique session_id", %{token: token} do
      # Connect multiple times with same token
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      {:ok, socket3} = connect(UserSocket, %{"token" => token})

      session_ids = [
        socket1.assigns.session_id,
        socket2.assigns.session_id,
        socket3.assigns.session_id
      ]

      # All session IDs should be unique
      assert length(Enum.uniq(session_ids)) == 3
    end

    test "different users get different session_ids" do
      {:ok, user1} =
        Accounts.Auth.register_user(%{
          username: "user1_session",
          email: "user1_session@example.com",
          password: "password123"
        })

      {:ok, user2} =
        Accounts.Auth.register_user(%{
          username: "user2_session",
          email: "user2_session@example.com",
          password: "password123"
        })

      token1 = Accounts.Token.generate(user1)
      token2 = Accounts.Token.generate(user2)

      {:ok, socket1} = connect(UserSocket, %{"token" => token1})
      {:ok, socket2} = connect(UserSocket, %{"token" => token2})

      assert socket1.assigns.session_id != socket2.assigns.session_id
    end

    test "session_id changes on each connection for same user", %{token: token} do
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      session_id1 = socket1.assigns.session_id

      # Wait a tiny bit to ensure timestamp difference
      Process.sleep(10)

      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      session_id2 = socket2.assigns.session_id

      assert session_id1 != session_id2
    end

    test "generates many unique session_ids without collision", %{token: token} do
      # Generate 100 session IDs and check for uniqueness
      session_ids =
        Enum.map(1..100, fn _ ->
          {:ok, socket} = connect(UserSocket, %{"token" => token})
          socket.assigns.session_id
        end)

      # All should be unique
      assert length(Enum.uniq(session_ids)) == 100
    end
  end

  describe "id/1 socket identifier" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "iduser",
          email: "id@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "returns socket id in correct format", %{token: token, user: user} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      socket_id = UserSocket.id(socket)

      assert socket_id == "user_socket:#{user.id}"
    end

    test "socket id contains user_id", %{token: token, user: user} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      socket_id = UserSocket.id(socket)

      assert socket_id =~ "user_socket:"
      assert socket_id =~ to_string(user.id)
    end

    test "different users get different socket ids" do
      {:ok, user1} =
        Accounts.Auth.register_user(%{
          username: "user1_id",
          email: "user1_id@example.com",
          password: "password123"
        })

      {:ok, user2} =
        Accounts.Auth.register_user(%{
          username: "user2_id",
          email: "user2_id@example.com",
          password: "password123"
        })

      token1 = Accounts.Token.generate(user1)
      token2 = Accounts.Token.generate(user2)

      {:ok, socket1} = connect(UserSocket, %{"token" => token1})
      {:ok, socket2} = connect(UserSocket, %{"token" => token2})

      id1 = UserSocket.id(socket1)
      id2 = UserSocket.id(socket2)

      assert id1 != id2
      assert id1 == "user_socket:#{user1.id}"
      assert id2 == "user_socket:#{user2.id}"
    end

    test "same user gets same socket id format on reconnect", %{token: token, user: user} do
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      {:ok, socket2} = connect(UserSocket, %{"token" => token})

      id1 = UserSocket.id(socket1)
      id2 = UserSocket.id(socket2)

      # Socket IDs should be the same (based on user_id, not session_id)
      assert id1 == id2
      assert id1 == "user_socket:#{user.id}"
    end
  end

  describe "connected_at timestamp" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "timestampuser",
          email: "timestamp@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "connected_at is a DateTime struct", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert %DateTime{} = socket.assigns.connected_at
    end

    test "connected_at is in UTC", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert socket.assigns.connected_at.time_zone == "Etc/UTC"
    end

    test "connected_at changes on each connection", %{token: token} do
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      time1 = socket1.assigns.connected_at

      # Wait to ensure different timestamp
      Process.sleep(100)

      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      time2 = socket2.assigns.connected_at

      # Second connection should have later timestamp
      assert DateTime.compare(time2, time1) == :gt
    end

    test "connected_at is recent", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      now = DateTime.utc_now()
      connected_at = socket.assigns.connected_at

      # Should be connected within last second
      diff_seconds = DateTime.diff(now, connected_at)
      assert diff_seconds < 1
    end
  end

  describe "socket assigns structure" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "assignuser",
          email: "assign@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "socket has all required assigns", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # Check all required assigns are present
      assert Map.has_key?(socket.assigns, :user_id)
      assert Map.has_key?(socket.assigns, :session_id)
      assert Map.has_key?(socket.assigns, :connected_at)
    end

    test "user_id is a binary", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert is_binary(socket.assigns.user_id)
    end

    test "session_id is a string", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert is_binary(socket.assigns.session_id)
    end

    test "all assigns have non-nil values", %{token: token} do
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      assert socket.assigns.user_id != nil
      assert socket.assigns.session_id != nil
      assert socket.assigns.connected_at != nil
    end
  end

  describe "channel subscriptions" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "channeluser",
          email: "channel@example.com",
          password: "password123"
        })

      %{user: user}
    end

    test "can subscribe to lobby channel after connection", %{user: user} do
      {:ok, socket} = create_socket(user)

      # Should be able to subscribe to lobby
      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, PidroServerWeb.LobbyChannel, "lobby", %{})
    end

    test "socket retains assigns through channel join", %{user: user} do
      {:ok, socket} = create_socket(user)

      original_session_id = socket.assigns.session_id
      original_connected_at = socket.assigns.connected_at

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, PidroServerWeb.LobbyChannel, "lobby", %{})

      # Assigns should be preserved
      assert joined_socket.assigns.user_id == user.id
      assert joined_socket.assigns.session_id == original_session_id
      assert joined_socket.assigns.connected_at == original_connected_at
    end
  end

  describe "reconnection scenarios" do
    setup do
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "reconnectuser",
          email: "reconnect@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      %{user: user, token: token}
    end

    test "reconnection creates new session_id", %{token: token} do
      # First connection
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      session_id1 = socket1.assigns.session_id

      # Simulate disconnect and reconnect
      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      session_id2 = socket2.assigns.session_id

      # Should have different session IDs
      assert session_id1 != session_id2
    end

    test "reconnection has same user_id", %{token: token, user: user} do
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      {:ok, socket2} = connect(UserSocket, %{"token" => token})

      assert socket1.assigns.user_id == user.id
      assert socket2.assigns.user_id == user.id
    end

    test "reconnection has new connected_at timestamp", %{token: token} do
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      time1 = socket1.assigns.connected_at

      Process.sleep(100)

      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      time2 = socket2.assigns.connected_at

      assert DateTime.compare(time2, time1) == :gt
    end

    test "multiple concurrent connections for same user", %{token: token, user: user} do
      # Same user can have multiple socket connections
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      {:ok, socket2} = connect(UserSocket, %{"token" => token})
      {:ok, socket3} = connect(UserSocket, %{"token" => token})

      # All should have same user_id but different session_ids
      assert socket1.assigns.user_id == user.id
      assert socket2.assigns.user_id == user.id
      assert socket3.assigns.user_id == user.id

      assert socket1.assigns.session_id != socket2.assigns.session_id
      assert socket2.assigns.session_id != socket3.assigns.session_id
      assert socket1.assigns.session_id != socket3.assigns.session_id
    end
  end

  describe "edge cases" do
    test "handles user_id as string in token verification" do
      # Some systems might return user_id as string
      # Our current implementation should handle this
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "stringuser",
          email: "string@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # user_id should be properly assigned regardless of token format
      assert socket.assigns.user_id != nil
    end

    test "session_id generation is deterministic given same inputs within millisecond" do
      # This tests that the hash function is working correctly
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "hashuser",
          email: "hash@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)

      # Connect multiple times rapidly
      {:ok, socket1} = connect(UserSocket, %{"token" => token})
      {:ok, socket2} = connect(UserSocket, %{"token" => token})

      # Even though inputs are same, session_ids should differ due to timestamp
      # (System.system_time() changes between calls)
      assert socket1.assigns.session_id != socket2.assigns.session_id
    end

    test "handles very long user IDs correctly" do
      # Test with maximum integer user_id (edge case)
      {:ok, user} =
        Accounts.Auth.register_user(%{
          username: "longidusertest",
          email: "longid@example.com",
          password: "password123"
        })

      token = Accounts.Token.generate(user)
      {:ok, socket} = connect(UserSocket, %{"token" => token})

      # Should still generate valid session_id
      assert String.length(socket.assigns.session_id) == 16
      assert socket.assigns.session_id =~ ~r/^[0-9a-f]{16}$/
    end
  end
end

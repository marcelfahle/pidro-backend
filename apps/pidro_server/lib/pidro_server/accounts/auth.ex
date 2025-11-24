defmodule PidroServer.Accounts.Auth do
  @moduledoc """
  The Auth context for user authentication and retrieval operations.

  This module provides functions for user registration, authentication, and user lookups.
  It handles password hashing using Bcrypt and interacts with the database through
  PidroServer.Repo.

  ## Examples

      # Register a new user
      iex> PidroServer.Accounts.Auth.register_user(%{
      ...>   username: "john_doe",
      ...>   email: "john@example.com",
      ...>   password: "secure_password"
      ...> })
      {:ok, %PidroServer.Accounts.User{}}

      # Authenticate a user
      iex> PidroServer.Accounts.Auth.authenticate_user("john_doe", "secure_password")
      {:ok, %PidroServer.Accounts.User{}}

      # Get user by ID
      iex> PidroServer.Accounts.Auth.get_user(1)
      %PidroServer.Accounts.User{} | nil

      # Get user by username
      iex> PidroServer.Accounts.Auth.get_user_by_username("john_doe")
      %PidroServer.Accounts.User{} | nil
  """

  import Ecto.Query
  alias PidroServer.Accounts.User
  alias PidroServer.Repo

  @doc """
  Registers a new user with the given attributes.

  Expects a map with at least the following keys:
    - `:username` (string) - The user's username
    - `:email` (string) - The user's email address
    - `:password` (string) - The user's password (will be hashed)

  ## Returns

    - `{:ok, user}` - User was successfully created
    - `{:error, changeset}` - Validation or database error

  ## Examples

      iex> PidroServer.Accounts.Auth.register_user(%{
      ...>   username: "jane_doe",
      ...>   email: "jane@example.com",
      ...>   password: "secure_pass123"
      ...> })
      {:ok, %PidroServer.Accounts.User{id: 1, username: "jane_doe"}}

      iex> PidroServer.Accounts.Auth.register_user(%{username: "jane_doe"})
      {:error, %Ecto.Changeset{}}
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by verifying their username and password.

  Retrieves the user by username and verifies the provided password against
  the stored hashed password using Bcrypt.

  ## Returns

    - `{:ok, user}` - Credentials are valid
    - `{:error, :invalid_credentials}` - Username not found or password is incorrect

  ## Examples

      iex> PidroServer.Accounts.Auth.authenticate_user("jane_doe", "secure_pass123")
      {:ok, %PidroServer.Accounts.User{username: "jane_doe"}}

      iex> PidroServer.Accounts.Auth.authenticate_user("jane_doe", "wrong_password")
      {:error, :invalid_credentials}

      iex> PidroServer.Accounts.Auth.authenticate_user("nonexistent_user", "password")
      {:error, :invalid_credentials}
  """
  def authenticate_user(username, password) do
    case get_user_by_username(username) do
      nil ->
        {:error, :invalid_credentials}

      user ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Fetches a user by their ID.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given ID exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user(1)
      %PidroServer.Accounts.User{id: 1}

      iex> PidroServer.Accounts.Auth.get_user(999)
      nil
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Fetches a user by their ID.

  Raises `Ecto.NoResultsError` if no user with the given ID exists.

  ## Returns

    - `user` - The user struct if found

  ## Raises

    - `Ecto.NoResultsError` - If no user with the given ID exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user!(1)
      %PidroServer.Accounts.User{id: 1}

      iex> PidroServer.Accounts.Auth.get_user!(999)
      ** (Ecto.NoResultsError) expected at least one result but got none
  """
  def get_user!(id) do
    Repo.get!(User, id)
  end

  @doc """
  Fetches a user by their username.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given username exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user_by_username("jane_doe")
      %PidroServer.Accounts.User{username: "jane_doe"}

      iex> PidroServer.Accounts.Auth.get_user_by_username("nonexistent")
      nil
  """
  def get_user_by_username(username) do
    Repo.one(from u in User, where: u.username == ^username)
  end

  @doc """
  Fetches a user by their email address.

  ## Returns

    - `user` - The user struct if found
    - `nil` - If no user with the given email exists

  ## Examples

      iex> PidroServer.Accounts.Auth.get_user_by_email("jane@example.com")
      %PidroServer.Accounts.User{email: "jane@example.com"}

      iex> PidroServer.Accounts.Auth.get_user_by_email("nonexistent@example.com")
      nil
  """
  def get_user_by_email(email) do
    Repo.one(from u in User, where: u.email == ^email)
  end

  @doc """
  Fetches a map of users by their IDs.

  Returns a map where keys are user IDs and values are user structs.
  Only returns users that exist.

  ## Examples

      iex> PidroServer.Accounts.Auth.get_users_map(["1", "999"])
      %{"1" => %User{id: 1, ...}}
  """
  def get_users_map(user_ids) do
    # Filter out non-UUID IDs (like bot IDs or "dev_host")
    valid_uuids = Enum.filter(user_ids, &valid_uuid?/1)

    from(u in User, where: u.id in ^valid_uuids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end
  defp valid_uuid?(_), do: false

  @doc """
  Lists recent users for development purposes.

  ## Parameters

    - `limit` (integer) - Maximum number of users to return (default: 10)

  ## Returns

    - `[user]` - List of user structs

  ## Examples

      iex> PidroServer.Accounts.Auth.list_recent_users(5)
      [%User{}, ...]
  """
  def list_recent_users(limit \\ 10) do
    Repo.all(from u in User, order_by: [desc: u.inserted_at], limit: ^limit)
  end
end

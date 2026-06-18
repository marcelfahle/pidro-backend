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

  @default_user_page_size 30
  @password_reset_token_bytes 32
  @password_reset_max_age_seconds 60 * 60

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
  Requests a password reset for a username or email address.

  Returns `{:ok, nil}` when the account does not exist so callers can avoid
  account enumeration. When a user is found, stores a hashed reset token and
  returns the raw token for delivery.
  """
  def request_password_reset(identifier) when is_binary(identifier) do
    case get_user_by_username_or_email(identifier) do
      nil ->
        {:ok, nil}

      %User{} = user ->
        token = generate_password_reset_token()
        token_hash = hash_password_reset_token(token)

        with {:ok, user} <-
               user
               |> User.password_reset_changeset(%{
                 password_reset_token_hash: token_hash,
                 password_reset_sent_at: DateTime.utc_now()
               })
               |> Repo.update() do
          {:ok, %{user: user, token: token}}
        end
    end
  end

  def request_password_reset(_identifier), do: {:ok, nil}

  @doc """
  Resets a user's password with a valid password-reset token.
  """
  def reset_user_password(token, password) when is_binary(token) and is_binary(password) do
    token_hash = hash_password_reset_token(token)
    cutoff = DateTime.add(DateTime.utc_now(), -@password_reset_max_age_seconds, :second)

    query =
      from u in User,
        where: u.password_reset_token_hash == ^token_hash,
        where: u.password_reset_sent_at > ^cutoff

    case Repo.one(query) do
      nil ->
        {:error, :invalid_or_expired_password_reset_token}

      %User{} = user ->
        user
        |> User.password_changeset(%{password: password})
        |> Repo.update()
    end
  end

  def reset_user_password(_token, _password),
    do: {:error, :invalid_or_expired_password_reset_token}

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

  @doc """
  Lists users for admin screens with search, account-type filtering, sorting,
  and pagination.
  """
  def list_users(opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> normalize_positive_integer(1)

    per_page =
      opts
      |> Keyword.get(:per_page, @default_user_page_size)
      |> normalize_positive_integer(@default_user_page_size)

    query =
      User
      |> search_users(Keyword.get(opts, :search, ""))
      |> filter_guest(Keyword.get(opts, :guest, :all))

    total = Repo.aggregate(query, :count, :id)

    total_pages = max(ceil_div(total, per_page), 1)
    page = min(page, total_pages)

    entries =
      query
      |> sort_users(Keyword.get(opts, :sort, :recent))
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      entries: entries,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end

  @doc """
  Returns high-level account counts for the admin user management dashboard.
  """
  def user_admin_summary do
    total = Repo.aggregate(User, :count, :id)
    guests = Repo.aggregate(from(u in User, where: u.guest == true), :count, :id)
    registered = total - guests
    with_email = Repo.aggregate(from(u in User, where: not is_nil(u.email)), :count, :id)

    %{
      total: total,
      guests: guests,
      registered: registered,
      with_email: with_email
    }
  end

  @doc """
  Builds a changeset for admin profile edits.
  """
  def change_user(%User{} = user, attrs \\ %{}) do
    user
    |> User.changeset(admin_user_attrs(attrs))
  end

  @doc """
  Updates user profile fields managed from the admin panel.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(admin_user_attrs(attrs))
    |> Repo.update()
  end

  @doc """
  Deletes a user account. Historical game stats keep the raw player id.
  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp get_user_by_username_or_email(identifier) do
    normalized = String.trim(identifier)
    normalized_email = String.downcase(normalized)

    Repo.one(
      from u in User,
        where:
          u.username == ^normalized or
            fragment("lower(?)", u.email) == ^normalized_email,
        limit: 1
    )
  end

  defp generate_password_reset_token do
    @password_reset_token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_password_reset_token(token) do
    :crypto.hash(:sha256, token)
  end

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

  defp search_users(query, nil), do: query
  defp search_users(query, ""), do: query

  defp search_users(query, search) when is_binary(search) do
    search = String.trim(search)

    if search == "" do
      query
    else
      term = "%#{search}%"

      from u in query,
        where:
          ilike(u.username, ^term) or ilike(u.email, ^term) or
            fragment("CAST(? AS TEXT) ILIKE ?", u.id, ^term)
    end
  end

  defp filter_guest(query, guest) when guest in [:guest, "guest"] do
    from u in query, where: u.guest == true
  end

  defp filter_guest(query, guest) when guest in [:registered, "registered"] do
    from u in query, where: u.guest == false
  end

  defp filter_guest(query, _guest), do: query

  defp sort_users(query, sort) when sort in [:username, "username"] do
    from u in query, order_by: [asc: fragment("lower(?)", u.username), desc: u.inserted_at]
  end

  defp sort_users(query, sort) when sort in [:oldest, "oldest"] do
    from u in query, order_by: [asc: u.inserted_at]
  end

  defp sort_users(query, sort) when sort in [:updated, "updated"] do
    from u in query, order_by: [desc: u.updated_at]
  end

  defp sort_users(query, _sort) do
    from u in query, order_by: [desc: u.inserted_at]
  end

  defp admin_user_attrs(attrs) when is_map(attrs) do
    %{}
    |> maybe_put_attr(:username, Map.get(attrs, "username", Map.get(attrs, :username)))
    |> maybe_put_attr(:email, Map.get(attrs, "email", Map.get(attrs, :email)))
    |> maybe_put_attr(:guest, Map.get(attrs, "guest", Map.get(attrs, :guest)))
  end

  defp admin_user_attrs(_attrs), do: %{}

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp normalize_positive_integer(value, _fallback) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} when integer > 0 -> integer
      _ -> fallback
    end
  end

  defp normalize_positive_integer(_value, fallback), do: fallback

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end

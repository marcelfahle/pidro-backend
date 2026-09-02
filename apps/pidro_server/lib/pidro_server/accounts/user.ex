defmodule PidroServer.Accounts.User do
  @moduledoc """
  User schema for the Pidro Server.

  Represents a user account in the system, including both regular and guest users.
  Handles user registration, authentication, and account management.

  ## Changesets

  Each changeset owns a purpose, and the `guest` flag is never cast from
  public params:

    * `registration_changeset/2` and `changeset/2` serve the public API. They
      cast `username`, `email`, `password` and `display_name` only.
    * `guest_changeset/2` builds a guest row from `username` and
      `display_name` and forces `guest: true`. It is internal to the server.
    * `admin_changeset/2` is `changeset/2` plus `guest`, for the dev admin
      panel and test fixtures.

  `token_version` defaults to 0 both in the schema and in the database so a
  freshly inserted struct signs a valid token without a reload.
  `last_seen_at` and `install_id` are reserved for later phases: no changeset
  casts them, they are never logged, and the API does not expose them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @display_name_max_length 40

  @typedoc "A user row."
  @type t :: %__MODULE__{}

  schema "users" do
    field(:username, :string)
    field(:email, :string)
    field(:display_name, :string)
    field(:password, :string, virtual: true)
    field(:password_hash, :string)
    field(:password_reset_token_hash, :binary)
    field(:password_reset_sent_at, :utc_datetime_usec)
    field(:guest, :boolean, default: false)
    field(:token_version, :integer, default: 0)
    field(:last_seen_at, :utc_datetime_usec)
    field(:install_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for user registration.

  This changeset is used when creating new user accounts. It validates and
  prepares user data for storage, including password hashing.

  ## Parameters
    - user: The user struct (typically a new/empty one)
    - attrs: The attributes map containing user data

  ## Returns
    A changeset with validation results and prepared data
  """
  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> validate_required(:password)
    |> validate_length(:password, min: 8)
    |> put_password_hash()
  end

  @doc """
  Builds a changeset for user updates.

  Handles casting and validation of user fields. This changeset can be used for
  both registration and profile updates, but does not require a password.

  The `guest` flag is deliberately not cast here: public params must never be
  able to flag an account as a guest. Use `guest_changeset/2` or
  `admin_changeset/2` for that.

  ## Parameters
    - user: The user struct to update
    - attrs: The attributes map containing updated data

  ## Returns
    A changeset with validation results and prepared data
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password, :display_name])
    |> validate_required([:username])
    |> validate_length(:username, min: 3)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_display_name()
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  @doc """
  Builds a changeset for creating a guest account.

  Guests are created by the server, never from public params: this changeset
  casts only `username` and `display_name`, forces `guest: true`, and leaves
  `email` and `password_hash` nil. Username is required, at least 3 characters
  and unique.

  ## Parameters
    - user: The user struct (typically a new/empty one)
    - attrs: The attributes map with `username` and optional `display_name`

  ## Returns
    A changeset with validation results and `guest` set to true
  """
  def guest_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name])
    |> validate_required([:username])
    |> validate_length(:username, min: 3)
    |> validate_display_name()
    |> unique_constraint(:username)
    |> put_change(:guest, true)
  end

  @doc """
  Builds a changeset for admin edits, which may also toggle `guest`.

  This is `changeset/2` plus the `guest` flag. It is used by the dev admin
  panel and by test fixtures, and must not be reachable from public params.

  ## Parameters
    - user: The user struct to update
    - attrs: The attributes map containing updated data, optionally `guest`

  ## Returns
    A changeset with validation results and prepared data
  """
  def admin_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:guest])
  end

  @doc """
  Builds a changeset for updating a user's password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required(:password)
    |> validate_length(:password, min: 8)
    |> put_password_hash()
    |> put_change(:password_reset_token_hash, nil)
    |> put_change(:password_reset_sent_at, nil)
  end

  @doc """
  Stores password-reset token metadata.
  """
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password_reset_token_hash, :password_reset_sent_at])
  end

  # Trims display_name and bounds its length. Applied by every changeset that
  # casts display_name so the rule lives in one place (R30).
  defp validate_display_name(changeset) do
    changeset
    |> update_change(:display_name, &String.trim/1)
    |> validate_length(:display_name, max: @display_name_max_length)
  end

  @doc false
  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp put_password_hash(changeset) do
    changeset
  end
end

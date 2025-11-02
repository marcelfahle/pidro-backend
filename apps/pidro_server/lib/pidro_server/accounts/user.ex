defmodule PidroServer.Accounts.User do
  @moduledoc """
  User schema for the Pidro Server.

  Represents a user account in the system, including both regular and guest users.
  Handles user registration, authentication, and account management.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field(:username, :string)
    field(:email, :string)
    field(:password, :string, virtual: true)
    field(:password_hash, :string)
    field(:guest, :boolean, default: false)

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

  ## Parameters
    - user: The user struct to update
    - attrs: The attributes map containing updated data

  ## Returns
    A changeset with validation results and prepared data
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password, :guest])
    |> validate_required([:username])
    |> validate_length(:username, min: 3)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email address")
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  @doc false
  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp put_password_hash(changeset) do
    changeset
  end
end

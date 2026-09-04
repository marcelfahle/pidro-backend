defmodule PidroServer.Admins.Admin do
  @moduledoc """
  A password-authenticated operator account, deliberately separate from players.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @password_min_length 10
  @password_max_length 72

  schema "admins" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :force_password_change, :boolean, default: true

    has_many :tokens, PidroServer.Admins.AdminToken

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the changeset used for seeded and hand-provisioned admins."
  def registration_changeset(admin, attrs, opts \\ []) do
    admin
    |> cast(attrs, [:email, :password])
    |> validate_email()
    |> validate_password(opts)
    |> put_change(:force_password_change, Keyword.get(opts, :force_password_change, true))
  end

  @doc "Builds an email-only changeset for the add-admin form."
  def email_changeset(admin, attrs \\ %{}) do
    admin
    |> cast(attrs, [:email])
    |> validate_email()
  end

  @doc "Builds and verifies the change-own-password changeset."
  def password_changeset(admin, attrs, opts \\ []) do
    admin
    |> cast(attrs, [:current_password, :password, :password_confirmation])
    |> validate_required([:current_password, :password, :password_confirmation])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
    |> validate_current_password()
    |> put_change(:force_password_change, false)
  end

  @doc "Checks a plaintext password without leaking timing for missing accounts."
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_admin, _password) do
    Bcrypt.no_user_verify()
    false
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required(:email)
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_length(:email, max: 160)
    |> validate_format(:email, @email_format, message: "must be a valid email address")
    |> unique_constraint(:email, name: :admins_lower_email_index)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required(:password)
    |> validate_length(:password, min: @password_min_length, max: @password_max_length)
    |> maybe_hash_password(opts)
  end

  defp validate_current_password(changeset) do
    if valid_password?(changeset.data, get_change(changeset, :current_password)) do
      changeset
    else
      add_error(changeset, :current_password, "is not valid")
    end
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? and changeset.valid? and is_binary(password) do
      changeset
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end

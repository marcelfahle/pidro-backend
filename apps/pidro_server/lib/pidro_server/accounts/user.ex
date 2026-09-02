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
    * `guest_changeset/2` builds a guest row from `username`, `display_name`
      and `install_id` and forces `guest: true`. It is internal to the server.
    * `upgrade_changeset/2` turns a guest into a registered account: it casts
      `email`, `password` and an optional `username` and forces `guest: false`.
    * `admin_changeset/2` is `changeset/2` plus `guest`, for the dev admin
      panel and test fixtures.

  ## Display names

  One rule for every account (KD11, R11), applied by each changeset that
  casts `display_name`: the value is NFKC-normalized and trimmed, must not
  contain control or format characters (Unicode `Cc` and `Cf`, which covers
  the zero-width joiner and bidi overrides), and is 2 to 20 graphemes long.
  `name_key/1` derives the look-alike key guest creation compares against.

  `token_version` defaults to 0 both in the schema and in the database so a
  freshly inserted struct signs a valid token without a reload.
  `last_seen_at` is written only by `PidroServer.Accounts.Auth.touch_last_seen/1`;
  `install_id` is stored at guest creation. Neither is logged or exposed by
  the API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @display_name_min_graphemes 2
  @display_name_max_graphemes 20
  @install_id_max_length 64
  @username_min_length 3
  @password_min_length 8
  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  # Unicode categories Cc (control) and Cf (format). The `u` modifier makes
  # the property classes match codepoints rather than bytes.
  @forbidden_name_chars ~r/[\p{Cc}\p{Cf}]/u
  @combining_marks ~r/\p{Mn}/u
  @non_alphanumerics ~r/[^\p{L}\p{N}]/u

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
    |> validate_length(:password, min: @password_min_length)
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
    |> validate_length(:username, min: @username_min_length)
    |> validate_format(:email, @email_format, message: "must be a valid email address")
    |> validate_display_name()
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  @doc """
  Builds a changeset for creating a guest account.

  Guests are created by the server, never from public params: this changeset
  casts only `username`, `display_name` and `install_id` (at most 64
  characters), forces `guest: true`, and leaves `email` and `password_hash`
  nil. Username is required, at least 3 characters and unique.

  ## Parameters
    - user: The user struct (typically a new/empty one)
    - attrs: The attributes map with `username`, optional `display_name` and
      optional `install_id`

  ## Returns
    A changeset with validation results and `guest` set to true
  """
  def guest_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :install_id])
    |> validate_required([:username])
    |> validate_length(:username, min: @username_min_length)
    |> validate_length(:install_id, max: @install_id_max_length)
    |> validate_display_name()
    |> unique_constraint(:username)
    |> put_change(:guest, true)
  end

  @doc """
  Builds the changeset that upgrades a guest into a registered account (R13).

  Casts `email`, `password` and an optional `username`; requires email and
  password; applies the email format of `changeset/2`, the password minimum
  of `registration_changeset/2` and the username minimum when a username is
  given; hashes the password and forces `guest: false`. The row keeps its id,
  display name and, unless a username is given, its generated guest username.

  ## Parameters
    - user: The guest's user struct
    - attrs: The attributes map with `email`, `password` and optional `username`

  ## Returns
    A changeset with validation results, the password hash and `guest` false
  """
  def upgrade_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :username])
    |> validate_required([:username, :email, :password])
    |> validate_length(:username, min: @username_min_length)
    |> validate_format(:email, @email_format, message: "must be a valid email address")
    |> validate_length(:password, min: @password_min_length)
    |> put_password_hash()
    |> put_change(:guest, false)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
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
    |> validate_length(:password, min: @password_min_length)
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

  @doc """
  Derives the look-alike key of a display name (R11).

  NFKD-decomposes the name, strips combining marks, downcases it and keeps
  only letters and digits, so `Marcél`, `MARCEL` and `m a r c e l` share the
  key `marcel`. When nothing alphanumeric remains (an emoji-only name), the
  key is the NFKC-normalized, trimmed, downcased name itself, so two different
  emoji names stay distinct. `nil` keys to `nil`.

  ## Examples

      iex> PidroServer.Accounts.User.name_key("Marcél")
      "marcel"

      iex> PidroServer.Accounts.User.name_key("m a r c e l")
      "marcel"
  """
  @spec name_key(String.t() | nil) :: String.t() | nil
  def name_key(nil), do: nil

  def name_key(name) when is_binary(name) do
    key =
      name
      |> nfkd()
      |> String.replace(@combining_marks, "")
      |> String.downcase()
      |> String.replace(@non_alphanumerics, "")

    if key == "" do
      name |> nfkc() |> String.trim() |> String.downcase()
    else
      key
    end
  end

  # The one display-name rule (KTD6): NFKC normalize and trim, reject control
  # and format characters, then bound the grapheme count. Applied by every
  # changeset that casts display_name. A blank name normalizes to nil, which
  # clears the field.
  defp validate_display_name(changeset) do
    changeset
    |> update_change(:display_name, &normalize_display_name/1)
    |> validate_change(:display_name, &forbid_control_and_format/2)
    |> validate_length(:display_name,
      min: @display_name_min_graphemes,
      max: @display_name_max_graphemes
    )
  end

  defp normalize_display_name(nil), do: nil

  defp normalize_display_name(name) when is_binary(name) do
    case name |> nfkc() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp forbid_control_and_format(:display_name, name) do
    if String.valid?(name) and not Regex.match?(@forbidden_name_chars, name) do
      []
    else
      [display_name: "must not contain control or format characters"]
    end
  end

  # :unicode answers an error tuple for invalid UTF-8; the name then flows
  # unchanged into forbid_control_and_format/2, which rejects it.
  defp nfkc(name) do
    case :unicode.characters_to_nfkc_binary(name) do
      normalized when is_binary(normalized) -> normalized
      _invalid -> name
    end
  end

  defp nfkd(name) do
    case :unicode.characters_to_nfkd_binary(name) do
      normalized when is_binary(normalized) -> normalized
      _invalid -> name
    end
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

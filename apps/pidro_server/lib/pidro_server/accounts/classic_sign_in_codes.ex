defmodule PidroServer.Accounts.ClassicSignInCodes do
  @moduledoc "Emailed, single-use Classic ownership proofs bound to a user or install."

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias PidroServer.Accounts.{ClassicClient, ClassicVerification, User}
  alias PidroServer.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "classic_sign_in_codes" do
    field :classic_user_id, :integer
    field :code_hash, :binary
    field :install_id, :string
    belongs_to :user, User
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Stores a new proof and returns the masked address and mail for delivery after the response."
  def request(params, current_user) do
    with {:ok, binding} <- ClassicVerification.binding(current_user, params),
         {:ok, %{login: login}} <- validate_login(params),
         {:ok, profile} <- lookup(login),
         {:ok, email, hint} <- email_hint(profile["email"]) do
      code = generate_code()

      with {:ok, _row} <-
             Repo.transaction(fn ->
               lock_account(profile["id"])
               Repo.delete_all(from c in __MODULE__, where: c.classic_user_id == ^profile["id"])

               %__MODULE__{}
               |> change(
                 Map.merge(binding, %{
                   classic_user_id: profile["id"],
                   code_hash: hash(profile["id"], code),
                   expires_at: DateTime.add(DateTime.utc_now(), 15 * 60, :second)
                 })
               )
               |> Repo.insert!()
             end) do
        {:ok, %{email_hint: hint}, build_email(email, code)}
      end
    else
      {:error, :not_found} -> {:error, :classic_account_not_found}
      error -> error
    end
  end

  @doc "Consumes a valid proof and issues the existing Classic verification response atomically."
  def verify(params, current_user) do
    with {:ok, binding} <- ClassicVerification.binding(current_user, params),
         {:ok, %{login: login}} <- validate_login(params),
         {:ok, profile} <- lookup(login) do
      Repo.transaction(fn ->
        lock_account(profile["id"])

        row =
          Repo.one(
            from c in __MODULE__, where: c.classic_user_id == ^profile["id"], lock: "FOR UPDATE"
          )

        now = DateTime.utc_now()

        if usable?(row, binding, now) do
          check_code(row, fetch(params, :code), binding, profile, current_user, now)
        else
          {:error, :classic_code_invalid}
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :provider_unavailable} = error -> error
      _invalid -> {:error, :classic_code_invalid}
    end
  end

  defp validate_login(params) do
    {%{}, %{login: :string}}
    |> cast(params, [:login])
    |> update_change(:login, &String.trim/1)
    |> validate_required([:login])
    |> apply_action(:insert)
  end

  defp lookup(login) do
    with {:ok, profile} <- ClassicClient.lookup(:login, login) do
      cond do
        profile["account_deleted"] == true or profile["account_visible"] == false ->
          {:error, :not_found}

        true ->
          case Ecto.Type.cast(:integer, profile["id"]) do
            {:ok, id} when is_integer(id) -> {:ok, Map.put(profile, "id", id)}
            _invalid -> {:error, :provider_unavailable}
          end
      end
    else
      {:error, :ambiguous} -> {:error, :not_found}
      error -> error
    end
  end

  defp usable?(nil, _binding, _now), do: false

  defp usable?(row, binding, now) do
    is_nil(row.consumed_at) and row.attempts < 5 and DateTime.after?(row.expires_at, now) and
      row.user_id == binding[:user_id] and row.install_id == binding[:install_id]
  end

  defp check_code(row, code, binding, profile, current_user, now) do
    if is_binary(code) and Regex.match?(~r/\A[0-9]{6}\z/, code) and
         Plug.Crypto.secure_compare(row.code_hash, hash(row.classic_user_id, code)) do
      row |> change(consumed_at: now) |> Repo.update!()

      case ClassicVerification.issue_ticket(
             binding,
             :password,
             profile,
             nil,
             :email,
             current_user
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      attempts = row.attempts + 1

      row
      |> change(attempts: attempts, consumed_at: if(attempts >= 5, do: now))
      |> Repo.update!()

      # Return, don't roll back: wrong attempts must remain counted.
      {:error, :classic_code_invalid}
    end
  end

  # Also serializes requests when there is not yet a row to lock.
  defp lock_account(id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "classic-sign-in-code:#{id}"
    ])
  end

  defp generate_code do
    <<number::unsigned-32>> = :crypto.strong_rand_bytes(4)
    number |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  defp hash(id, code), do: :crypto.hash(:sha256, Integer.to_string(id) <> code)

  defp email_hint(email) when is_binary(email) do
    case String.split(String.trim(email), "@") do
      [local, domain] when local != "" and domain != "" ->
        prefix = String.slice(local, 0, if(String.length(local) < 3, do: 1, else: 2))
        {:ok, String.trim(email), prefix <> "•••••@" <> domain}

      [""] ->
        {:error, :classic_email_missing}

      _invalid ->
        {:error, :provider_unavailable}
    end
  end

  defp email_hint(_email), do: {:error, :classic_email_missing}

  defp build_email(email, code) do
    new()
    |> to(email)
    |> Swoosh.Email.from({"Pidro", System.get_env("MAIL_FROM_ADDRESS") || "noreply@pidro.online"})
    |> subject("Your Pidro sign-in code")
    |> text_body("""
    #{code}

    It works for 15 minutes

    If you did not ask for this, ignore this mail
    """)
  end

  defp fetch(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end

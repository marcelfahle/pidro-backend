defmodule PidroServer.Accounts.FacebookNonce do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias PidroServer.Repo

  @primary_key {:nonce_hash, :binary, autogenerate: false}
  schema "facebook_nonces" do
    field :expires_at, :utc_datetime_usec
  end

  def consume(nonce, expires_at) when is_binary(nonce) and is_struct(expires_at, DateTime) do
    now = DateTime.utc_now()
    Repo.delete_all(from n in __MODULE__, where: n.expires_at <= ^now)

    %__MODULE__{}
    |> changeset(%{nonce_hash: :crypto.hash(:sha256, nonce), expires_at: expires_at})
    |> Repo.insert()
    |> case do
      {:ok, _nonce} -> :ok
      {:error, _changeset} -> {:error, :invalid_credentials}
    end
  end

  defp changeset(nonce, attrs) do
    nonce
    |> cast(attrs, [:nonce_hash, :expires_at])
    |> validate_required([:nonce_hash, :expires_at])
    |> unique_constraint(:nonce_hash, name: :facebook_nonces_pkey)
  end
end

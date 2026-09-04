defmodule PidroServer.Admins.AdminToken do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Query

  alias PidroServer.Admins.Admin

  @session_validity_in_days 14

  @primary_key false
  @foreign_key_type :binary_id

  schema "admin_tokens" do
    field :token, :binary, primary_key: true
    field :context, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :admin, Admin

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def build_session_token(admin) do
    token = :crypto.strong_rand_bytes(32)

    {token,
     %__MODULE__{
       token: hash_token(token),
       context: "session",
       admin_id: admin.id,
       last_used_at: DateTime.utc_now()
     }}
  end

  def verify_session_token_query(token) do
    query =
      from token_record in by_token_and_context_query(token, "session"),
        join: admin in assoc(token_record, :admin),
        where: token_record.last_used_at > ago(@session_validity_in_days, "day"),
        select: admin

    {:ok, query}
  end

  def by_token_and_context_query(token, context) do
    hashed_token = hash_token(token)
    from __MODULE__, where: [token: ^hashed_token, context: ^context]
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)
end

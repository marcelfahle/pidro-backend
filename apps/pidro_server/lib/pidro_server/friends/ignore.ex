defmodule PidroServer.Friends.Ignore do
  @moduledoc "A player's quiet ignore of another's requests, kept across a cancel and resend."
  use Ecto.Schema

  @primary_key false
  schema "friend_ignores" do
    field :user_id, :binary_id
    field :ignored_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule PidroServer.Friends.Friendship do
  @moduledoc "A directed edge; mutual friendship is derived from the reverse edge."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "friendships" do
    field :user_id, :binary_id
    field :friend_id, :binary_id
    # Set by the recipient only; the sender's view never changes.
    field :ignored_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(user_id, friend_id) do
    %__MODULE__{user_id: user_id, friend_id: friend_id}
    |> change()
    |> validate_required([:user_id, :friend_id])
    |> check_constraint(:friend_id, name: :cannot_friend_self)
    |> unique_constraint([:user_id, :friend_id])
  end
end

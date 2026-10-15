defmodule PidroServer.Blocks.Block do
  @moduledoc "A directed block; admission and discovery check both directions."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "blocks" do
    field :user_id, :binary_id
    field :blocked_id, :binary_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(user_id, blocked_id) do
    %__MODULE__{user_id: user_id, blocked_id: blocked_id}
    |> change()
    |> validate_required([:user_id, :blocked_id])
    |> check_constraint(:blocked_id, name: :cannot_block_self)
    |> unique_constraint([:user_id, :blocked_id])
  end
end

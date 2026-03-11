defmodule PidroServer.Stats.AbandonmentEvent do
  @moduledoc """
  Records that a player abandoned a game after the reconnect grace period.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "abandonment_events" do
    field :user_id, :string
    field :room_code, :string
    field :position, :string

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :room_code, :position])
    |> validate_required([:user_id, :room_code, :position])
    |> validate_inclusion(:position, ["north", "east", "south", "west"])
    |> unique_constraint([:user_id, :room_code],
      name: :abandonment_events_user_id_room_code_index
    )
  end
end

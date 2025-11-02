defmodule PidroServer.Stats.GameStats do
  @moduledoc """
  Schema for storing game statistics and history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_stats" do
    field :room_code, :string
    field :winner, :string
    field :final_scores, :map
    field :bid_amount, :integer
    field :bid_team, :string
    field :duration_seconds, :integer
    field :completed_at, :utc_datetime
    field :player_ids, {:array, :binary_id}

    timestamps()
  end

  @doc false
  def changeset(game_stats, attrs) do
    game_stats
    |> cast(attrs, [
      :room_code,
      :winner,
      :final_scores,
      :bid_amount,
      :bid_team,
      :duration_seconds,
      :completed_at,
      :player_ids
    ])
    |> validate_required([:room_code, :completed_at])
    |> validate_inclusion(:winner, [:north_south, :east_west],
      message: "must be :north_south or :east_west"
    )
    |> validate_number(:bid_amount, greater_than_or_equal_to: 6, less_than_or_equal_to: 14)
    |> validate_number(:duration_seconds, greater_than: 0)
  end
end

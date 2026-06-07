defmodule PidroServer.Profiles.Achievement do
  @moduledoc """
  One permanent, idempotent award row: a user earned an achievement.

  One row per `(user_id, achievement_key)` (a unique index enforces this). The
  `tier` is stored for display/ordering; tiered achievements use distinct keys
  per tier (e.g. `:winstreak`, future `:winstreak_ii`), so the unique key stays
  simple and each tier is a write-once row — there is no upsert that mutates
  `tier` upward (which could downgrade on a stale rebuild).

  Mirrors `PlayerProfile` conventions: binary_id PK, loose `user_id` (no FK,
  matching `game_stats.player_ids`), `utc_datetime_usec` timestamps.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "player_achievements" do
    field :user_id, :binary_id
    field :achievement_key, :string
    field :tier, :integer, default: 1
    field :awarded_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @castable [:user_id, :achievement_key, :tier, :awarded_at, :metadata]

  @doc false
  def changeset(achievement, attrs) do
    achievement
    |> cast(attrs, @castable)
    |> validate_required([:user_id, :achievement_key, :awarded_at])
    |> unique_constraint([:user_id, :achievement_key])
  end
end

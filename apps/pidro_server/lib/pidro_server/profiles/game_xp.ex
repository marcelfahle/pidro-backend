defmodule PidroServer.Profiles.GameXp do
  @moduledoc """
  The XP one player earned in one completed game (PID-198).

  One row per `(user_id, game_stats_id)`, written in the completion transaction
  next to the `veteran_xp` increment, from the same delta. `earned_at` is the
  game's `completed_at`. Bots never get rows, and the Classic import writes
  none: Classic XP is lifetime only.

  Rows are summed per period by `PidroServer.Profiles.xp_since/2`. Weeks
  (Monday 00:00 to Sunday 24:00) and months are UTC, because the server has no
  timezone database. Weekly leagues will need the player's local time.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_xp" do
    field :user_id, :binary_id
    field :game_stats_id, :binary_id
    field :xp, :integer
    field :earned_at, :utc_datetime

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

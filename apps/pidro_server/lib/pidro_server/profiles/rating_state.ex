defmodule PidroServer.Profiles.RatingState do
  @moduledoc """
  Singleton row holding the rerating replay cursor.

  Exactly one row exists (`id == 1`, enforced by a DB check constraint). It
  stores the full composite cursor `{last_completed_at, last_inserted_at,
  last_game_id}` of the last `game_stats` row processed by the rating replay.

  `completed_at` is second-precision and non-unique, so the honest "what have we
  already processed?" marker is the whole tuple — a `max(completed_at)` probe
  cannot disambiguate games sharing the boundary second. The columns are
  nullable: a null cursor means "no replay has run yet" (incremental then
  behaves like a full run).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @singleton_id 1

  @primary_key {:id, :integer, autogenerate: false}
  @foreign_key_type :binary_id

  schema "rating_state" do
    field :last_completed_at, :utc_datetime
    field :last_inserted_at, :naive_datetime
    field :last_game_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The fixed primary key of the singleton row."
  @spec singleton_id() :: pos_integer()
  def singleton_id, do: @singleton_id

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:id, :last_completed_at, :last_inserted_at, :last_game_id])
    |> put_change(:id, @singleton_id)
  end
end

defmodule PidroServer.Repo.Migrations.CreateRatingState do
  use Ecto.Migration

  def change do
    create table(:rating_state, primary_key: false) do
      # Singleton row: id is fixed to 1, enforced by a check constraint so a
      # second row can never be inserted.
      add :id, :integer, primary_key: true

      # The replay cursor — the full composite key the ordered pass uses
      # (completed_at is second-precision and non-unique, so we remember the
      # whole {completed_at, inserted_at, id} tuple). Nullable: no run yet.
      add :last_completed_at, :utc_datetime
      add :last_inserted_at, :naive_datetime
      add :last_game_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:rating_state, :rating_state_singleton, check: "id = 1")
  end
end

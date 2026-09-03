defmodule PidroServer.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  def change do
    create table(:invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # The 8-symbol secret, stored upper-cased. The unique index is the last
      # word on collisions; PidroServer.Invites.create_invite/2 redraws once.
      add :code, :string, null: false
      # Stable room identity (Room.id) next to the display code, so a recycled
      # 4-character room code never resolves an old invite to a new table.
      add :room_id, :binary_id, null: false
      add :room_code, :string, null: false
      # Loose binary_id, NO FK — mirrors player_achievements / game_stats.player_ids.
      add :host_user_id, :binary_id, null: false
      add :seat_hint, :string
      add :label, :string
      add :redeem_count, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      # Real self-reference: play again and regenerate point the old row at its
      # successor. Invites are never deleted; nilify only guards a manual purge.
      add :superseded_by, references(:invites, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invites, [:code])
    create index(:invites, [:room_id])
    create index(:invites, [:host_user_id])
    create index(:invites, [:superseded_by], where: "superseded_by IS NOT NULL")

    # Insert-only ledger: one row per successful first-time redeem (R8).
    create table(:invite_redemptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :invite_id, references(:invites, type: :binary_id, on_delete: :delete_all), null: false
      # Loose binary_id, NO FK (see invites.host_user_id).
      add :user_id, :binary_id, null: false
      add :position, :string, null: false
      add :platform, :string, null: false, default: "unknown"
      add :source, :string, null: false, default: "unknown"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:invite_redemptions, [:invite_id, :user_id])
    create index(:invite_redemptions, [:user_id])

    # Insert-only funnel: kind is validated in the schema, not the database, so
    # later phases add kinds without a migration.
    create table(:invite_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :invite_id, references(:invites, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :platform, :string, null: false, default: "unknown"
      add :ua_class, :string
      # Loose binary_id, NO FK; nil for anonymous events such as landing views.
      add :user_id, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:invite_events, [:invite_id])
    create index(:invite_events, [:user_id], where: "user_id IS NOT NULL")
  end
end

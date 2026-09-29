defmodule PidroServer.Repo.Migrations.CreateClassicNameReservations do
  use Ecto.Migration

  def change do
    create table(:classic_name_reservations, primary_key: false) do
      add :classic_user_id, :bigint, primary_key: true
      add :username, :text, null: false
      add :name_key, :text, null: false
      add :imported_at, :utc_datetime_usec, null: false
    end

    create index(:classic_name_reservations, [:name_key])
  end
end

defmodule PidroServer.Repo.Migrations.CreateUserAvatars do
  use Ecto.Migration

  def change do
    create table(:user_avatars, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :image, :binary, null: false
      add :version, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end

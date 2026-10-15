defmodule PidroServer.Repo.Migrations.BindInvitesToSeats do
  use Ecto.Migration

  def change do
    alter table(:invites) do
      add :position, :string
      add :invited_user_id, :binary_id
    end
  end
end

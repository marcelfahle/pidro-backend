defmodule PidroServer.Repo.Migrations.AddAgeAndTermsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:age_band, :string, null: false, default: "unknown")
      add(:age_declared_at, :utc_datetime_usec)
      add(:terms_version, :string)
      add(:terms_accepted_at, :utc_datetime_usec)
    end
  end
end

defmodule PidroServer.GameReports.Report do
  @moduledoc "Private, bounded client diagnostics; never game state or credentials."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "game_reports" do
    field :user_id, :binary_id
    field :room_code, :string
    field :game_instance_id, :string
    field :app_version, :string
    field :build, :string
    field :platform, :string
    field :events, {:array, :map}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

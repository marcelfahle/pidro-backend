defmodule PidroServer.GameArchive.Archive do
  @moduledoc "Private archive metadata and durable snapshot pointers."
  use Ecto.Schema

  @primary_key {:game_instance_id, :string, autogenerate: false}
  schema "game_archives" do
    field :room_code, :string
    field :format_version, :integer
    field :versions, :map
    field :participants, :map
    field :user_ids, {:array, :string}
    field :participation_truncated, :boolean, default: false
    field :status, :string
    field :termination_reason, :string
    field :evidence_status, :string
    field :failed_checkpoints, :integer
    field :missing_revision_count, :integer
    field :last_revision, :integer
    field :initial_snapshot, :map
    field :initial_deal, :map
    field :last_snapshot, :map
    field :started_at, :utc_datetime_usec
    field :saved_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end
end

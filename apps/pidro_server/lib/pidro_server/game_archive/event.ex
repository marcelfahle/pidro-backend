defmodule PidroServer.GameArchive.Event do
  @moduledoc "One atomic authoritative revision, including its resulting checkpoint."
  use Ecto.Schema

  @type t :: %__MODULE__{}
  @primary_key false
  schema "game_archive_events" do
    field :game_instance_id, :string, primary_key: true
    field :revision, :integer, primary_key: true
    field :occurred_at, :utc_datetime_usec
    field :saved_at, :utc_datetime_usec
    field :payload, :map
    field :snapshot, :map
  end
end

defmodule PidroServer.Accounts.UserAvatar do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :binary_id, autogenerate: false}
  schema "user_avatars" do
    field :image, :binary
    field :version, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(avatar, attrs) do
    avatar
    |> cast(attrs, [:user_id, :image, :version])
    |> validate_required([:user_id, :image, :version])
  end
end

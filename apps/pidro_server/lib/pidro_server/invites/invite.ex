defmodule PidroServer.Invites.Invite do
  @moduledoc """
  One invite link for one table (KD1–KD3).

  A row is minted by the host of a waiting room and carries the 8-symbol secret
  `code`, the room it opens (`room_id`, the stable identity, next to the
  display `room_code`), the optional `seat_hint` and `label`, a 24-hour
  `expires_at`, and two tombstone markers: `revoked_at` and `superseded_by`.
  Rows are never deleted or reissued; revoke marks them, play again and
  regenerate point them at a successor. Everything else about an invite —
  open, full, moved, closed — is derived at read time by
  `PidroServer.Invites.state/2`, so nothing here is written when a room dies.

  Loose ids: `host_user_id` has no foreign key, matching every existing table
  (`player_achievements`, `game_stats.player_ids`). `superseded_by` is a real
  self-reference, exposed as the `:successor` association.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Invites.Codes
  alias PidroServer.Invites.Event
  alias PidroServer.Invites.Redemption

  @type t :: %__MODULE__{}

  @seat_hints ~w(north east south west north_south east_west partner)
  @label_max_length 40
  @castable [:seat_hint, :label]
  @identity [:code, :room_id, :room_code, :host_user_id, :expires_at]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invites" do
    field :code, :string
    field :room_id, :binary_id
    field :room_code, :string
    field :host_user_id, :binary_id
    field :seat_hint, :string
    field :label, :string
    field :redeem_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :successor, __MODULE__, foreign_key: :superseded_by
    has_many :redemptions, Redemption
    has_many :events, Event

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The seat hints a host may attach to an invite."
  @spec seat_hints() :: [String.t()]
  def seat_hints, do: @seat_hints

  @doc """
  Casts the host-editable fields and checks the invariants every row must hold.

  Only `seat_hint` and `label` are castable; `code`, `room_id`, `room_code`,
  `host_user_id` and `expires_at` are set on the struct by the context and only
  validated here. Serves both the mint and the second-mint hint update.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @castable)
    |> validate_inclusion(:seat_hint, @seat_hints)
    |> validate_length(:label, max: @label_max_length)
    |> validate_required(@identity)
    |> validate_code()
    |> unique_constraint(:code)
  end

  defp validate_code(changeset) do
    case get_field(changeset, :code) do
      code when is_binary(code) ->
        if Codes.valid?(code), do: changeset, else: add_error(changeset, :code, "is invalid")

      _missing ->
        changeset
    end
  end
end

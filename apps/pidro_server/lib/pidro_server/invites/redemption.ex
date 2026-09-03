defmodule PidroServer.Invites.Redemption do
  @moduledoc """
  One successful first-time redeem of an invite by one user (R8).

  The ledger row behind `redeem_count`: who sat down (`user_id`, a loose id
  with no foreign key), where (`position`), from which client (`platform`) and
  how the link travelled (`source`). Insert-only, so no `updated_at`. Written
  by `PidroServer.Invites.record_redemption/2` after the seat is taken (KTD3):
  a missing row is a missing funnel entry, never an occupied-seat lie.

  `platform` and `source` are analytics vocabularies, not rules: a value
  outside the known lists, or no value at all, is stored as `"unknown"` rather
  than rejected. `PidroServer.Invites.Event` shares the platform list.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Invites.Invite

  @type t :: %__MODULE__{}

  @platforms ~w(ios android web)
  @sources ~w(wa im sms qr copy deferred typed)
  @positions ~w(north east south west)
  @unknown "unknown"
  @castable [:position, :platform, :source]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invite_redemptions" do
    belongs_to :invite, Invite
    field :user_id, :binary_id
    field :position, :string
    field :platform, :string, default: @unknown
    field :source, :string, default: @unknown

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The client platforms a redeem or event may report."
  @spec platforms() :: [String.t()]
  def platforms, do: @platforms

  @doc "The public share channels and internal arrival sources a redeem may report."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Casts `position`, `platform` and `source`; `invite_id` and `user_id` are set
  on the struct by the context.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(redemption, attrs) do
    redemption
    |> cast(attrs, @castable)
    |> coerce_known(:platform, @platforms)
    |> coerce_known(:source, @sources)
    |> validate_required([:invite_id, :user_id, :position])
    |> validate_inclusion(:position, @positions)
    |> foreign_key_constraint(:invite_id)
    |> unique_constraint(:user_id, name: :invite_redemptions_invite_id_user_id_index)
  end

  @doc """
  Replaces a value of `field` outside `known` (or a missing one) with
  `"unknown"`. Shared with `PidroServer.Invites.Event`.
  """
  @spec coerce_known(Ecto.Changeset.t(), atom(), [String.t()]) :: Ecto.Changeset.t()
  def coerce_known(changeset, field, known) do
    value = get_field(changeset, field)

    if is_binary(value) and value in known do
      changeset
    else
      put_change(changeset, field, @unknown)
    end
  end
end

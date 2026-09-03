defmodule PidroServer.Invites.Event do
  @moduledoc """
  One funnel event on an invite (R8): the link was created, shared, opened,
  redeemed, upgraded, and so on.

  `kind` is validated against the origin's list (`kinds/0`), so a later phase
  adds a kind by editing that list, without a migration. `platform` follows
  the redemption vocabulary (`PidroServer.Invites.Redemption.platforms/0`) and
  is stored as `"unknown"` when absent or unrecognised; `ua_class` is a short
  free-form class such as `"crawler"` or `"mobile"`; `user_id` is a loose id
  (no foreign key), nil for anonymous events such as a landing-page view.
  Insert-only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PidroServer.Invites.Invite
  alias PidroServer.Invites.Redemption

  @type t :: %__MODULE__{}

  # The origin's kind list, in funnel order.
  @kinds ~w(created shared landing_viewed crawler_viewed open_app_clicked store_clicked
            app_opened_via_link deferred_matched code_typed guest_created seat_claimed
            game_completed guest_upgraded expired revoked)
  @ua_class_max_length 40
  @castable [:kind, :platform, :ua_class]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invite_events" do
    belongs_to :invite, Invite
    field :kind, :string
    field :platform, :string, default: "unknown"
    field :ua_class, :string
    field :user_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Every event kind the funnel accepts."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Casts `kind`, `platform` and `ua_class`; `invite_id` and `user_id` are set on
  the struct by the context.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> Redemption.coerce_known(:platform, Redemption.platforms())
    |> validate_required([:invite_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:ua_class, max: @ua_class_max_length)
    |> foreign_key_constraint(:invite_id)
  end
end

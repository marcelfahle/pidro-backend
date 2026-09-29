defmodule PidroServer.Accounts.ClassicNameReservation do
  @moduledoc """
  A Classic username reserved to the account that owned it at the fixed import cutoff.

  `classic_user_id` is the key so a repeated import can add missing rows but can
  never transfer or rename an existing reservation. `name_key` deliberately
  follows the Classic reservation contract rather than the table look-alike
  rules: trim, collapse whitespace, and lowercase.
  """

  use Ecto.Schema

  @primary_key {:classic_user_id, :integer, autogenerate: false}

  schema "classic_name_reservations" do
    field :username, :string
    field :name_key, :string
    field :imported_at, :utc_datetime_usec
  end
end

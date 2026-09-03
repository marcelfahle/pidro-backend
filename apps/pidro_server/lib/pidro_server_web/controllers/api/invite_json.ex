defmodule PidroServerWeb.API.InviteJSON do
  @moduledoc """
  JSON view module for invite responses (R1, R4, R5).

  Three shapes, each in the usual `data` envelope:

    * `invite/1` - the host's view after a mint, an in-place update or a
      regenerate: `code`, `url`, `share_text`, `seat_hint`, `label`,
      `expires_at` and the derived `state`.
    * `preview/1` - the public landing view: `code`, `state`, `host`,
      `seats_taken`, `seats_total`, `seat_hint`, `label`, `expires_at` and, only
      when the state is `moved`, `next_code`. The room code never appears here
      (KD2).
    * `redeem/1` - the seated player's view: the room as
      `PidroServerWeb.API.RoomJSON` renders it, `position` and `hint_honored`.
  """

  alias PidroServer.Invites
  alias PidroServer.Invites.Invite
  alias PidroServerWeb.API.RoomJSON

  @seats_total 4

  @doc """
  Renders the host's invite: the mint, update and regenerate response.
  """
  def invite(%{invite: %Invite{} = invite, state: state}) do
    %{
      data: %{
        invite: %{
          code: invite.code,
          url: Invites.url(invite),
          share_text: Invites.share_text(invite),
          seat_hint: invite.seat_hint,
          label: invite.label,
          expires_at: DateTime.to_iso8601(invite.expires_at),
          state: state
        }
      }
    }
  end

  @doc """
  Renders the public preview. `host` is the host's display name or username
  (nil once the account is gone); `seats_taken` is 0 when the table is closed.
  """
  def preview(%{invite: %Invite{} = invite, state: state, host: host, seats_taken: seats_taken}) do
    preview = %{
      code: invite.code,
      state: state,
      host: host,
      seats_taken: seats_taken,
      seats_total: @seats_total,
      seat_hint: invite.seat_hint,
      label: invite.label,
      expires_at: DateTime.to_iso8601(invite.expires_at)
    }

    %{data: %{invite: maybe_put_next_code(preview, state, invite)}}
  end

  @doc """
  Renders a successful redeem: the room, the seat taken and whether the hint
  was honoured.
  """
  def redeem(%{room: room, position: position, hint_honored: hint_honored}) do
    %{data: %{room: RoomJSON.room(room), position: position, hint_honored: hint_honored}}
  end

  @doc """
  The code of the invite that superseded this one, when it is loaded.
  """
  @spec next_code(Invite.t()) :: String.t() | nil
  def next_code(%Invite{successor: %Invite{code: code}}), do: code
  def next_code(%Invite{}), do: nil

  defp maybe_put_next_code(preview, :moved, invite),
    do: Map.put(preview, :next_code, next_code(invite))

  defp maybe_put_next_code(preview, _state, _invite), do: preview
end

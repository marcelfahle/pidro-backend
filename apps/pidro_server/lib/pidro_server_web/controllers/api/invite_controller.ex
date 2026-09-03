defmodule PidroServerWeb.API.InviteController do
  @moduledoc """
  API controller for invite links: the public preview, redeeming a seat, and
  the host's revoke and regenerate (R4–R8).

  Minting lives on the room (`PidroServerWeb.API.RoomController.create_invite/2`)
  because it is a room action; everything keyed by an invite code lives here.

  ## State derivation

  Every action derives the invite's state at read time with
  `PidroServer.Invites.state/2` fed by `RoomManager.get_room/1` (R3, KTD1).
  `derive_state/1` and `state_error/2` are public so the room and auth
  controllers derive the same answer for a mint response and for guest
  creation; `note_invites/2` recomputes the room's `invite_live_until` after
  every mint, revoke and regenerate (KTD12).

  ## Redeem (KTD3)

  Validate, claim, record: the state check answers the KTD5 errors, one
  `RoomManager.claim_seat/4` call takes the seat, and only then is the ledger
  written (redemption row, `redeem_count`, `seat_claimed` event) in one
  transaction. A failed ledger write is logged and never unseats the player. A
  caller already seated at the table gets their seat back and writes nothing.

  ## Errors

  Delegated to `PidroServerWeb.API.FallbackController`: an unknown code is 404,
  a non-host is 403 `NOT_OWNER`, and the non-open states map to 409, 410 and
  423 as documented on each operation.
  """

  use PidroServerWeb, :controller
  use OpenApiSpex.ControllerSpecs
  require Logger

  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Invites
  alias PidroServer.Invites.Invite
  alias PidroServerWeb.API.InviteJSON
  alias PidroServerWeb.InvitePreview
  alias PidroServerWeb.Schemas.{ErrorSchemas, InviteSchemas}

  action_fallback PidroServerWeb.API.FallbackController

  tags(["Invites"])

  @hints %{
    "north" => :north,
    "east" => :east,
    "south" => :south,
    "west" => :west,
    "north_south" => :north_south,
    "east_west" => :east_west,
    "partner" => :partner
  }

  @positions %{"north" => :north, "east" => :east, "south" => :south, "west" => :west}

  @code_parameter [
    code: [
      in: :path,
      type: :string,
      description: "Invite code; dashes and lower case are accepted, I/L read as 1 and O as 0",
      required: true,
      example: "7KQ4-M2XB"
    ]
  ]

  # ==================== Preview ====================

  operation(:show,
    summary: "Preview an invite",
    description: """
    Public, rate-limited landing-page data for an invite: its derived state, the
    host's name, how many seats are taken, the seat hint and label, and, when the
    host has moved to a new table, `next_code`. The room code is never included.

    Unknown codes answer 404. Limited at policy `invite_preview` (per client IP).
    """,
    parameters: @code_parameter,
    responses: [
      ok: {"Invite preview", "application/json", InviteSchemas.InvitePreviewResponse},
      not_found: {"Unknown invite code", "application/json", ErrorSchemas.not_found_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Renders the public preview (R4). Never includes the room code (KD2).
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"code" => code}) do
    with {:ok, preview} <- InvitePreview.get(code) do
      conn
      |> put_view(InviteJSON)
      |> render(:preview, preview)
    end
  end

  # ==================== Redeem ====================

  operation(:redeem,
    summary: "Redeem an invite and take a seat",
    description: """
    Seats the authenticated user at the invite's table. Without `position` the
    invite's seat hint is tried first and any open seat is the fallback
    (`hint_honored: false`); with `position` a taken seat answers 409
    `SEAT_TAKEN` with `next_open`. A caller already seated at this table gets
    their current seat back and no new redemption is recorded.

    Non-open states: `full` 409 `TABLE_FULL`; `locked` 423 `TABLE_LOCKED`;
    `started` 410 `TABLE_STARTED`; `closed` 410 `TABLE_CLOSED`; `expired` 410
    `INVITE_EXPIRED`; `revoked` 410 `INVITE_REVOKED`; `moved` 410 `INVITE_MOVED`
    with `next_code`. A kicked caller answers 403 `KICKED`; a caller connected in
    another room answers 422 `ALREADY_IN_ROOM`.

    Limited at policy `invite_redeem` (per user).
    """,
    security: [%{"bearer_auth" => []}],
    parameters: @code_parameter,
    request_body:
      {"Optional seat and analytics", "application/json", InviteSchemas.RedeemRequest},
    responses: [
      ok: {"Seated", "application/json", InviteSchemas.RedeemResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden: {"Kicked from this table", "application/json", ErrorSchemas.error_response()},
      not_found: {"Unknown invite code", "application/json", ErrorSchemas.not_found_error()},
      conflict: {"Seat taken or table full", "application/json", ErrorSchemas.conflict_error()},
      gone:
        {"Invite or table no longer accepts players", "application/json",
         ErrorSchemas.gone_error()},
      unprocessable_entity:
        {"Invalid position or already in another room", "application/json",
         ErrorSchemas.validation_error()},
      locked: {"Table locked", "application/json", ErrorSchemas.locked_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Claims a seat for the caller (R5) and records the redemption (R8).
  """
  @spec redeem(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem(conn, %{"code" => code} = params) do
    user = conn.assigns[:current_user]

    with {:ok, position} <- parse_optional_position(params["position"]),
         {:ok, invite} <- Invites.get_by_code(code),
         :ok <- ensure_open(invite),
         already_seated? = seated_here?(invite, user.id),
         {:ok, room, seat, hint_honored} <- claim_seat(invite, user, position) do
      unless already_seated?, do: record_claim(invite, user.id, seat, params)

      conn
      |> put_view(InviteJSON)
      |> render(:redeem, %{room: room, position: seat, hint_honored: hint_honored})
    end
  end

  # ==================== Revoke ====================

  operation(:delete,
    summary: "Revoke an invite",
    description: """
    Marks an invite the caller hosts as revoked; the row is kept and the code is
    never reissued. Redeeming it afterwards answers 410 `INVITE_REVOKED`.
    """,
    security: [%{"bearer_auth" => []}],
    parameters: @code_parameter,
    responses: [
      no_content: {"Revoked", "application/json", %OpenApiSpex.Schema{type: :object}},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden:
        {"Not the host of this invite", "application/json", ErrorSchemas.error_response()},
      not_found: {"Unknown invite code", "application/json", ErrorSchemas.not_found_error()}
    ]
  )

  @doc """
  Revokes an invite the caller hosts (R6) and recomputes the room's invite window.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    with {:ok, invite} <- Invites.get_by_code(code),
         :ok <- ensure_host(invite, user.id),
         {:ok, revoked} <- Invites.revoke(invite) do
      log_event(revoked, %{kind: "revoked", user_id: user.id})
      note_invites(revoked.room_code, revoked.room_id)
      send_resp(conn, :no_content, "")
    end
  end

  # ==================== Regenerate ====================

  operation(:regenerate,
    summary: "Regenerate an invite",
    description: """
    Revokes the invite and mints a new one for the same table with the same seat
    hint and label. The old code never forwards to the new one: regenerate exists
    to kill a leaked link. The room's 20-invite lifetime cap still applies.
    Limited at policy `invite_mint` (per user).
    """,
    security: [%{"bearer_auth" => []}],
    parameters: @code_parameter,
    responses: [
      created: {"The new invite", "application/json", InviteSchemas.InviteResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorSchemas.unauthorized_error()},
      forbidden:
        {"Not the host of this invite", "application/json", ErrorSchemas.error_response()},
      not_found: {"Unknown invite code", "application/json", ErrorSchemas.not_found_error()},
      conflict: {"Room invite limit reached", "application/json", ErrorSchemas.conflict_error()},
      gone: {"Invite already revoked", "application/json", ErrorSchemas.gone_error()},
      unprocessable_entity:
        {"The new invite could not be minted", "application/json",
         ErrorSchemas.validation_error()},
      too_many_requests:
        {"Rate limit exceeded; see Retry-After", "application/json",
         ErrorSchemas.too_many_requests_error()}
    ]
  )

  @doc """
  Revokes the invite and mints its successor (R7, KD8).
  """
  @spec regenerate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def regenerate(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]

    with {:ok, old} <- Invites.get_by_code(code),
         :ok <- ensure_host(old, user.id),
         {:ok, new} <- Invites.regenerate(old) do
      log_event(old, %{kind: "revoked", user_id: user.id})
      log_event(new, %{kind: "created", user_id: user.id})
      note_invites(new.room_code, new.room_id)

      conn
      |> put_status(:created)
      |> put_view(InviteJSON)
      |> render(:invite, %{invite: new, state: derive_state(new)})
    end
  end

  # ==================== Shared helpers ====================

  @doc false
  # The invite's state (R3) read against the live RoomManager.
  @spec derive_state(Invite.t()) :: Invites.state()
  def derive_state(%Invite{} = invite), do: InvitePreview.state(invite)

  @doc false
  # The KTD5 error for a state that refuses a redeem. `:open` has no error.
  @spec state_error(Invites.state(), Invite.t()) ::
          {:error, atom() | {:invite_moved, String.t() | nil}}
  def state_error(:full, _invite), do: {:error, :table_full}
  def state_error(:locked, _invite), do: {:error, :table_locked}
  def state_error(:started, _invite), do: {:error, :table_started}
  def state_error(:closed, _invite), do: {:error, :table_closed}
  def state_error(:expired, _invite), do: {:error, :invite_expired}
  def state_error(:revoked, _invite), do: {:error, :invite_revoked}
  def state_error(:moved, invite), do: {:error, {:invite_moved, InviteJSON.next_code(invite)}}

  @doc false
  # Writes one funnel event; a failure is logged, never surfaced (R8).
  @spec log_event(Invite.t(), map()) :: :ok
  def log_event(%Invite{} = invite, attrs) do
    case Invites.record_event(invite, attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Invite event #{inspect(Map.get(attrs, :kind))} failed for #{invite.code}: #{inspect(reason)}"
        )
    end
  end

  @doc false
  # Recomputes the room's `invite_live_until` from its active invites (KTD12);
  # a room that is gone, or whose code now belongs to another room, is skipped.
  @spec note_invites(String.t(), Ecto.UUID.t()) :: :ok
  def note_invites(room_code, room_id) do
    with {:ok, _room} <- live_room(room_code, room_id) do
      live_until =
        case Invites.active_for_room(room_id) do
          %Invite{expires_at: expires_at} -> expires_at
          nil -> nil
        end

      RoomManager.note_invite(room_code, live_until)
    end

    :ok
  end

  # ==================== Private helpers ====================

  defp ensure_open(%Invite{} = invite) do
    case derive_state(invite) do
      :open -> :ok
      state -> state_error(state, invite)
    end
  end

  defp ensure_host(%Invite{host_user_id: host_id}, host_id), do: :ok
  defp ensure_host(%Invite{}, _user_id), do: {:error, :not_owner}

  defp claim_seat(%Invite{} = invite, user, position) do
    RoomManager.claim_seat(invite.room_code, invite.room_id, user.id,
      hint: Map.get(@hints, invite.seat_hint),
      position: position,
      display_name: user.display_name || user.username
    )
  end

  defp seated_here?(%Invite{room_code: room_code, room_id: room_id}, user_id) do
    case live_room(room_code, room_id) do
      {:ok, room} -> Positions.has_player?(room, user_id)
      {:error, _reason} -> false
    end
  end

  # The redemption row, the count bump and the `seat_claimed` event in one
  # transaction, after the seat is taken (KTD3). A failure is logged: the seat
  # wins over the ledger.
  defp record_claim(%Invite{} = invite, user_id, position, params) do
    platform = analytics_value(params["platform"])
    source = analytics_value(params["source"])

    result =
      Invites.record_claim(invite, %{
        user_id: user_id,
        position: position,
        platform: platform,
        source: source
      })

    case result do
      {:ok, _redemption, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Invite ledger write failed for #{invite.code}: #{inspect(reason)}")
    end
  end

  defp analytics_value(value) when is_binary(value), do: value
  defp analytics_value(_value), do: nil

  defp parse_optional_position(nil), do: {:ok, nil}

  defp parse_optional_position(position) do
    case Map.fetch(@positions, position) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_position}
    end
  end

  # The live room behind an invite; a recycled code belonging to another room
  # is `:room_not_found` (KTD1).
  defp live_room(room_code, room_id) do
    case RoomManager.get_room(room_code) do
      {:ok, %Room{id: ^room_id} = room} -> {:ok, room}
      {:ok, %Room{}} -> {:error, :room_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end

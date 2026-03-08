defmodule PidroServer.Games.Room.Seat do
  @moduledoc """
  Represents a position at the table that can be occupied by a human, bot, or
  left vacant.

  Each seat tracks its occupant type, connection status, and the disconnect
  cascade state. All transition functions validate the current state and return
  `{:ok, updated_seat}` or `{:error, reason}`.

  ## Valid State Transitions

      connected -> reconnecting       (disconnect/1)
      reconnecting -> connected        (reclaim/2)
      reconnecting -> grace            (start_grace/2)
      grace -> connected               (reclaim/2)
      grace -> bot_substitute          (substitute_bot/2)
      bot_substitute -> connected      (reclaim/2, when reserved_for matches)
      bot_substitute -> vacant         (open_for_substitute/1)
      vacant -> connected              (fill_seat/2)
  """

  @type position :: :north | :east | :south | :west
  @type occupant_type :: :human | :bot | :vacant
  @type status :: :connected | :reconnecting | :grace | :bot_substitute

  @type t :: %__MODULE__{
          position: position(),
          occupant_type: occupant_type(),
          user_id: String.t() | nil,
          bot_pid: pid() | nil,
          status: status() | nil,
          disconnected_at: DateTime.t() | nil,
          grace_expires_at: DateTime.t() | nil,
          reserved_for: String.t() | nil,
          is_owner: boolean(),
          joined_at: DateTime.t() | nil
        }

  defstruct [
    :position,
    :occupant_type,
    :user_id,
    :bot_pid,
    :status,
    :disconnected_at,
    :grace_expires_at,
    :reserved_for,
    is_owner: false,
    joined_at: nil
  ]

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new seat occupied by a connected human player.

  ## Options

    * `:is_owner` - whether this player is the room owner (default: `false`)
    * `:joined_at` - when the player joined (default: `DateTime.utc_now/0`)
  """
  @spec new_human(position(), String.t(), keyword()) :: t()
  def new_human(position, user_id, opts \\ []) do
    %__MODULE__{
      position: position,
      occupant_type: :human,
      user_id: user_id,
      status: :connected,
      is_owner: Keyword.get(opts, :is_owner, false),
      joined_at: Keyword.get(opts, :joined_at, DateTime.utc_now())
    }
  end

  @doc "Creates a new seat occupied by a bot."
  @spec new_bot(position(), pid()) :: t()
  def new_bot(position, bot_pid) do
    %__MODULE__{
      position: position,
      occupant_type: :bot,
      bot_pid: bot_pid,
      status: :connected
    }
  end

  @doc "Creates a new vacant seat."
  @spec new_vacant(position()) :: t()
  def new_vacant(position) do
    %__MODULE__{
      position: position,
      occupant_type: :vacant,
      status: nil
    }
  end

  # ---------------------------------------------------------------------------
  # State Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Marks a connected human seat as reconnecting. Sets `disconnected_at`.

  Valid from: `:connected` (human only)
  """
  @spec disconnect(t()) :: {:ok, t()} | {:error, atom()}
  def disconnect(%__MODULE__{status: :connected, occupant_type: :human} = seat) do
    {:ok, %{seat | status: :reconnecting, disconnected_at: DateTime.utc_now()}}
  end

  def disconnect(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Transitions a reconnecting seat to grace period. Sets `grace_expires_at` and
  `reserved_for` so the original player can reclaim later.

  Valid from: `:reconnecting`
  """
  @spec start_grace(t(), DateTime.t()) :: {:ok, t()} | {:error, atom()}
  def start_grace(%__MODULE__{status: :reconnecting, user_id: user_id} = seat, grace_expires_at) do
    {:ok, %{seat | status: :grace, grace_expires_at: grace_expires_at, reserved_for: user_id}}
  end

  def start_grace(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Replaces the human with a substitute bot. Swaps occupant_type to `:bot`,
  stores the bot pid, and clears the human user_id.

  Valid from: `:grace`
  """
  @spec substitute_bot(t(), pid()) :: {:ok, t()} | {:error, atom()}
  def substitute_bot(%__MODULE__{status: :grace} = seat, bot_pid) do
    {:ok, %{seat | status: :bot_substitute, occupant_type: :bot, bot_pid: bot_pid, user_id: nil}}
  end

  def substitute_bot(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Makes a bot substitute permanent by clearing `reserved_for`. The original
  human can no longer reclaim this seat.

  Valid from: `:bot_substitute`
  """
  @spec make_permanent_bot(t()) :: {:ok, t()} | {:error, atom()}
  def make_permanent_bot(%__MODULE__{status: :bot_substitute} = seat) do
    {:ok, %{seat | reserved_for: nil}}
  end

  def make_permanent_bot(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Reclaims a seat for the original human. Restores the seat to `:connected`
  with occupant_type `:human`. Only succeeds if `user_id` matches the
  `reserved_for` field (or the seat's own `user_id` during Phase 1).

  Valid from: `:reconnecting`, `:grace`, or `:bot_substitute` (with `reserved_for`)
  """
  @spec reclaim(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def reclaim(%__MODULE__{status: :reconnecting, user_id: user_id} = seat, reclaiming_user_id)
      when user_id == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         disconnected_at: nil
     }}
  end

  def reclaim(
        %__MODULE__{status: :grace, reserved_for: reserved_for} = seat,
        reclaiming_user_id
      )
      when reserved_for == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: reclaiming_user_id,
         bot_pid: nil,
         disconnected_at: nil,
         grace_expires_at: nil,
         reserved_for: nil
     }}
  end

  def reclaim(
        %__MODULE__{status: :bot_substitute, reserved_for: reserved_for} = seat,
        reclaiming_user_id
      )
      when reserved_for != nil and reserved_for == reclaiming_user_id do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: reclaiming_user_id,
         bot_pid: nil,
         disconnected_at: nil,
         grace_expires_at: nil,
         reserved_for: nil
     }}
  end

  def reclaim(%__MODULE__{status: status}, _)
      when status in [:reconnecting, :grace, :bot_substitute],
      do: {:error, :user_mismatch}

  def reclaim(%__MODULE__{}, _), do: {:error, :invalid_transition}

  @doc """
  Opens a bot-substitute seat for a new human to join.

  Valid from: `:bot_substitute`
  """
  @spec open_for_substitute(t()) :: {:ok, t()} | {:error, atom()}
  def open_for_substitute(%__MODULE__{status: :bot_substitute} = seat) do
    {:ok,
     %{
       seat
       | status: nil,
         occupant_type: :vacant,
         bot_pid: nil,
         user_id: nil,
         reserved_for: nil,
         disconnected_at: nil,
         grace_expires_at: nil
     }}
  end

  def open_for_substitute(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Fills a vacant seat with a new human player.

  Valid from: vacant (status `nil`, occupant_type `:vacant`)
  """
  @spec fill_seat(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def fill_seat(%__MODULE__{occupant_type: :vacant, status: nil} = seat, user_id) do
    {:ok,
     %{
       seat
       | status: :connected,
         occupant_type: :human,
         user_id: user_id,
         joined_at: DateTime.utc_now()
     }}
  end

  def fill_seat(%__MODULE__{}, _), do: {:error, :invalid_transition}

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Returns true if the seat has a connected human occupant."
  @spec connected_human?(t()) :: boolean()
  def connected_human?(%__MODULE__{status: :connected, occupant_type: :human}), do: true
  def connected_human?(%__MODULE__{}), do: false

  @doc "Returns true if the seat has an active bot (connected or substitute)."
  @spec active_bot?(t()) :: boolean()
  def active_bot?(%__MODULE__{occupant_type: :bot, bot_pid: pid}) when is_pid(pid), do: true
  def active_bot?(%__MODULE__{}), do: false

  @doc "Returns true if the given user_id can reclaim this seat."
  @spec can_reclaim?(t(), String.t()) :: boolean()
  def can_reclaim?(%__MODULE__{status: :reconnecting, user_id: uid}, user_id), do: uid == user_id

  def can_reclaim?(%__MODULE__{status: :grace, reserved_for: reserved}, user_id),
    do: reserved == user_id

  def can_reclaim?(%__MODULE__{}, _), do: false

  @doc "Returns true if the seat is vacant."
  @spec vacant?(t()) :: boolean()
  def vacant?(%__MODULE__{occupant_type: :vacant}), do: true
  def vacant?(%__MODULE__{}), do: false

  @doc "Returns true if this seat belongs to the room owner."
  @spec owner?(t()) :: boolean()
  def owner?(%__MODULE__{is_owner: true}), do: true
  def owner?(%__MODULE__{}), do: false

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Converts a Seat to a JSON-safe map. Pids are excluded, DateTimes are
  converted to ISO 8601 strings.
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = seat) do
    %{
      position: seat.position,
      occupant_type: seat.occupant_type,
      user_id: seat.user_id,
      status: seat.status,
      is_owner: seat.is_owner,
      disconnected_at: maybe_to_iso8601(seat.disconnected_at),
      grace_expires_at: maybe_to_iso8601(seat.grace_expires_at),
      reserved_for: seat.reserved_for,
      joined_at: maybe_to_iso8601(seat.joined_at)
    }
  end

  defp maybe_to_iso8601(nil), do: nil
  defp maybe_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end

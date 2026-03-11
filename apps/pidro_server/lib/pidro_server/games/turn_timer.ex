defmodule PidroServer.Games.TurnTimer do
  @moduledoc """
  Helpers for a single active room action timer.
  """

  @type key ::
          {:seat, atom(), atom(), non_neg_integer()}
          | {:room, :dealer_selection, non_neg_integer()}

  @type t :: %{
          ref: reference(),
          timer_id: integer(),
          key: key(),
          scope: :seat | :room,
          actor_position: atom() | nil,
          phase: atom(),
          duration_ms: non_neg_integer(),
          transition_delay_ms: non_neg_integer(),
          started_at_mono: integer(),
          deadline_mono: integer()
        }

  @type paused_t :: %{
          key: key(),
          actor_position: atom() | nil,
          phase: atom(),
          remaining_ms: non_neg_integer()
        }

  @spec start_timer(pid(), String.t(), key(), :seat | :room, atom() | nil, atom(), non_neg_integer(), non_neg_integer()) ::
          t()
  def start_timer(
        target_pid,
        room_code,
        key,
        scope,
        actor_position,
        phase,
        duration_ms,
        transition_delay_ms \\ 0
      ) do
    total_ms = duration_ms + transition_delay_ms
    timer_id = System.unique_integer([:positive, :monotonic])
    started_at_mono = System.monotonic_time(:millisecond)
    deadline_mono = started_at_mono + total_ms

    ref =
      Process.send_after(
        target_pid,
        {:turn_timer_expired, room_code, timer_id, key},
        total_ms
      )

    %{
      ref: ref,
      timer_id: timer_id,
      key: key,
      scope: scope,
      actor_position: actor_position,
      phase: phase,
      duration_ms: duration_ms,
      transition_delay_ms: transition_delay_ms,
      started_at_mono: started_at_mono,
      deadline_mono: deadline_mono
    }
  end

  @spec cancel_timer(t() | nil) :: :ok
  def cancel_timer(nil), do: :ok

  def cancel_timer(%{ref: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  @spec pause_timer(t() | nil) :: paused_t() | nil
  def pause_timer(nil), do: nil

  def pause_timer(%{
        ref: ref,
        key: key,
        actor_position: actor_position,
        phase: phase,
        deadline_mono: deadline_mono
      }) do
    Process.cancel_timer(ref)
    now_mono = System.monotonic_time(:millisecond)

    %{
      key: key,
      actor_position: actor_position,
      phase: phase,
      remaining_ms: max(deadline_mono - now_mono, 0)
    }
  end

  @spec remaining_ms(t()) :: non_neg_integer()
  def remaining_ms(%{deadline_mono: deadline_mono}) do
    max(deadline_mono - System.monotonic_time(:millisecond), 0)
  end

  @spec event_seq(key()) :: non_neg_integer()
  def event_seq({:seat, _position, _phase, event_seq}), do: event_seq
  def event_seq({:room, :dealer_selection, event_seq}), do: event_seq
end

defmodule PidroServer.Games.Bots.GameHelpers do
  @moduledoc """
  Helper functions for quick game actions using bots.

  Provides convenience functions for:
  - Auto-bidding: Automatically complete the bidding phase
  - Fast-forward: Play game to completion with bot strategies
  """

  require Logger
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.Bots.Strategies.RandomStrategy
  alias PidroServer.Games.GameAdapter

  @spec auto_bid(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def auto_bid(room_code, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 500)

    case GameAdapter.get_state(room_code) do
      {:ok, state} ->
        if state.phase == :bidding do
          auto_bid_loop(room_code, delay_ms, 0)
        else
          {:error, :not_in_bidding_phase}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec fast_forward(String.t(), keyword()) :: {:ok, :started} | {:error, term()}
  def fast_forward(room_code, opts \\ []) do
    delay_ms = Keyword.get(opts, :delay_ms, 100)
    strategy = Keyword.get(opts, :strategy, :random)

    positions = [:north, :south, :east, :west]

    resume_results =
      Enum.map(positions, fn position ->
        BotManager.resume_bot(room_code, position)
      end)

    current_bots = BotManager.list_bots(room_code)

    start_results =
      positions
      |> Enum.reject(fn position -> Map.has_key?(current_bots, position) end)
      |> Enum.map(fn position ->
        BotManager.start_bot(room_code, position, strategy, delay_ms)
      end)

    all_results = resume_results ++ start_results

    success? =
      Enum.all?(all_results, fn
        :ok -> true
        {:ok, _} -> true
        {:error, :not_found} -> true
        _ -> false
      end)

    if success? do
      {:ok, :started}
    else
      failed = Enum.filter(all_results, &match?({:error, _}, &1))
      {:error, {:failed_to_start_bots, failed}}
    end
  end

  @spec stop_fast_forward(String.t()) :: :ok
  def stop_fast_forward(room_code) do
    positions = [:north, :south, :east, :west]

    Enum.each(positions, fn position ->
      BotManager.pause_bot(room_code, position)
    end)

    :ok
  end

  # Private Functions

  defp auto_bid_loop(room_code, delay_ms, iteration) do
    if iteration > 50 do
      {:error, :max_iterations_exceeded}
    else
      case GameAdapter.get_state(room_code) do
        {:ok, state} ->
          if state.phase != :bidding do
            {:ok, state}
          else
            current_player = state.current_player

            case GameAdapter.get_legal_actions(room_code, current_player) do
              {:ok, legal_actions} ->
                # Fix: destructure the {:ok, action, reasoning} return
                {:ok, action, _reasoning} = RandomStrategy.pick_action(legal_actions, state)

                case GameAdapter.apply_action(room_code, current_player, action) do
                  {:ok, _new_state} ->
                    if delay_ms > 0, do: Process.sleep(delay_ms)
                    auto_bid_loop(room_code, delay_ms, iteration + 1)

                  {:error, reason} ->
                    Logger.error("Auto-bid action failed: #{inspect(reason)}")
                    {:error, reason}
                end

              {:error, reason} ->
                {:error, reason}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end

if Mix.env() == :dev do
  defmodule PidroServer.Dev.GameHelpers do
    @moduledoc """
    Helper functions for dev UI quick actions.

    Provides convenience functions for:
    - Auto-bidding: Automatically complete the bidding phase
    - Fast-forward: Play game to completion with bot strategies
    - Other quick testing actions

    These functions are only available in development environment.
    """

    require Logger
    alias PidroServer.Dev.BotManager
    alias PidroServer.Dev.Strategies.RandomStrategy
    alias PidroServer.Games.GameAdapter

    @doc """
    Automatically completes the bidding phase using random bids.

    Loops through players and makes random bids or passes until bidding is complete.
    Uses a configurable delay between actions for observability.

    ## Parameters

    - `room_code` - The room code
    - `opts` - Options keyword list
      - `:delay_ms` - Delay between actions in milliseconds (default: 500)

    ## Returns

    - `{:ok, final_state}` - When bidding completes successfully
    - `{:error, reason}` - If auto-bidding fails

    ## Examples

        iex> GameHelpers.auto_bid("A3F9")
        {:ok, %{phase: :declaring, ...}}

        iex> GameHelpers.auto_bid("A3F9", delay_ms: 1000)
        {:ok, %{phase: :declaring, ...}}
    """
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

    @doc """
    Fast-forwards the game to completion using bot strategies.

    Enables all bots with minimal delay and lets them play until the game ends.
    This is useful for quickly testing full game scenarios.

    ## Parameters

    - `room_code` - The room code
    - `opts` - Options keyword list
      - `:delay_ms` - Delay between bot actions in milliseconds (default: 100)
      - `:strategy` - Bot strategy to use (default: :random)

    ## Returns

    - `{:ok, :started}` - When fast-forward begins
    - `{:error, reason}` - If fast-forward fails to start

    ## Examples

        iex> GameHelpers.fast_forward("A3F9")
        {:ok, :started}

        iex> GameHelpers.fast_forward("A3F9", delay_ms: 50)
        {:ok, :started}
    """
    @spec fast_forward(String.t(), keyword()) :: {:ok, :started} | {:error, term()}
    def fast_forward(room_code, opts \\ []) do
      delay_ms = Keyword.get(opts, :delay_ms, 100)
      strategy = Keyword.get(opts, :strategy, :random)

      # Resume all paused bots
      positions = [:north, :south, :east, :west]

      resume_results =
        Enum.map(positions, fn position ->
          BotManager.resume_bot(room_code, position)
        end)

      # Start bots for positions that don't have one
      # List current bots
      current_bots = BotManager.list_bots(room_code)

      start_results =
        positions
        |> Enum.reject(fn position -> Map.has_key?(current_bots, position) end)
        |> Enum.map(fn position ->
          BotManager.start_bot(room_code, position, strategy, delay_ms)
        end)

      all_results = resume_results ++ start_results

      # Check if all operations succeeded or if bots were already in desired state
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

    @doc """
    Stops all bots for a game, effectively pausing fast-forward.

    ## Parameters

    - `room_code` - The room code

    ## Returns

    - `:ok` - Always returns :ok

    ## Examples

        iex> GameHelpers.stop_fast_forward("A3F9")
        :ok
    """
    @spec stop_fast_forward(String.t()) :: :ok
    def stop_fast_forward(room_code) do
      positions = [:north, :south, :east, :west]

      Enum.each(positions, fn position ->
        BotManager.pause_bot(room_code, position)
      end)

      :ok
    end

    # Private Functions

    # Loops through bidding actions until phase changes
    @spec auto_bid_loop(String.t(), non_neg_integer(), non_neg_integer()) ::
            {:ok, term()} | {:error, term()}
    defp auto_bid_loop(room_code, delay_ms, iteration) do
      # Safety check: max 50 iterations
      if iteration > 50 do
        {:error, :max_iterations_exceeded}
      else
        case GameAdapter.get_state(room_code) do
          {:ok, state} ->
            if state.phase != :bidding do
              # Bidding complete
              {:ok, state}
            else
              # Make a bid for current player
              current_player = state.current_player

              case GameAdapter.get_legal_actions(room_code, current_player) do
                {:ok, legal_actions} ->
                  # Pick a random action
                  action = RandomStrategy.pick_action(legal_actions, state)

                  case GameAdapter.apply_action(room_code, current_player, action) do
                    {:ok, _new_state} ->
                      # Wait before next action
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
end

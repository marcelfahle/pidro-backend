if Mix.env() == :dev do
  defmodule PidroServer.Dev.BotManager do
    @moduledoc """
    Placeholder for bot management system.

    This module will be implemented in Phase 2 (FR-11).
    For now, it provides stub functions that allow the UI to be built.
    """

    def start_bots(_room_code, _bot_count, _difficulty) do
      # TODO: Implement in Phase 2
      :ok
    end
  end
end

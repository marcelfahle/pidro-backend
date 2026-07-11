defmodule PidroServer.RoomManagerCase do
  @moduledoc false

  alias PidroServer.Games.RoomManager

  @spec cleanup() :: :ok
  def cleanup do
    if Process.whereis(RoomManager), do: RoomManager.reset_for_test(), else: :ok
  end
end

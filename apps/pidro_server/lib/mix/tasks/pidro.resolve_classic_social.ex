defmodule Mix.Tasks.Pidro.ResolveClassicSocial do
  @moduledoc """
  Retries stored Classic social facts for one Classic ID, or all claimed users.

      mix pidro.resolve_classic_social [classic_user_id]

  Replays the stored facts, including friendships removed or blocks unblocked
  since the claim. Use for recovery, not as a recurring synchronization job.
  """
  use Mix.Task
  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.{ClassicSocial, Repo}

  @shortdoc "Resolves stored Classic friendships and blocks"

  @impl Mix.Task
  def run(args) do
    query = users(args)
    Mix.Task.run("app.start")

    failures =
      query
      |> Repo.all()
      |> Enum.count(&(ClassicSocial.resolve_classic(&1) != :ok))

    if failures > 0, do: Mix.raise("Classic social resolution failed for #{failures} users")
    Mix.shell().info("Classic social resolution complete")
  end

  defp users([]), do: from(u in User, where: not is_nil(u.classic_user_id))

  defp users([id]) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> from(u in User, where: u.classic_user_id == ^id)
      _ -> usage()
    end
  end

  defp users(_args), do: usage()
  defp usage, do: Mix.raise("Usage: mix pidro.resolve_classic_social [classic_user_id]")
end

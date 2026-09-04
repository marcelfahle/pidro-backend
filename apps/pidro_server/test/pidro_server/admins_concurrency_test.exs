defmodule PidroServer.AdminsConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Admins
  alias PidroServer.Admins.Admin
  alias PidroServer.Repo

  test "concurrent bootstrap attempts create exactly one first admin" do
    original_email = Application.get_env(:pidro_server, :admin_seed_email)
    Application.put_env(:pidro_server, :admin_seed_email, "bootstrap-race@example.com")
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              receive do
                :go -> Admins.seed_first_admin()
              end
            after
              Sandbox.checkin(Repo)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.count(results, fn
               {:ok, %Admin{}, temporary_password} -> is_binary(temporary_password)
               _other -> false
             end) == 1

      assert Enum.count(results, &(&1 == {:ok, :already_seeded})) == 1
      assert Repo.aggregate(Admin, :count) == 1
    after
      Repo.delete_all(Admin)
      Sandbox.checkin(Repo)

      if original_email do
        Application.put_env(:pidro_server, :admin_seed_email, original_email)
      else
        Application.delete_env(:pidro_server, :admin_seed_email)
      end
    end
  end
end

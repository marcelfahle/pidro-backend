defmodule PidroServer.Accounts.ClassicSignInCodesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PidroServer.Accounts.{ClassicClaimTicket, ClassicClient, ClassicSignInCodes}
  alias PidroServer.Repo

  test "simultaneous correct verifications issue exactly one ticket" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    params = %{login: "race177", install_id: "race177-install"}

    Req.Test.stub(ClassicClient, fn conn ->
      Req.Test.json(conn, %{
        classic: %{
          id: 177_002,
          username: "race177",
          email: "race177@example.com",
          level: 14,
          games: %{total_game: 88}
        }
      })
    end)

    try do
      {:ok, _, email} = ClassicSignInCodes.request(params, nil)
      [code] = Regex.run(~r/^\d{6}$/m, email.text_body)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), backend})

              receive do
                :go -> ClassicSignInCodes.verify(Map.put(params, :code, code), nil)
              after
                5_000 -> raise "verification barrier timed out"
              end
            end)
          end)
        end

      assert_receive {:ready, first, first_backend}, 2_000
      assert_receive {:ready, second, second_backend}, 2_000
      refute first_backend == second_backend
      send(first, :go)
      send(second, :go)

      results = Enum.map(tasks, &Task.await(&1, 5_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :classic_code_invalid})) == 1

      assert Repo.aggregate(
               from(t in ClassicClaimTicket, where: t.classic_user_id == 177_002),
               :count
             ) == 1

      assert %DateTime{} = Repo.get_by!(ClassicSignInCodes, classic_user_id: 177_002).consumed_at
    after
      Repo.delete_all(from t in ClassicClaimTicket, where: t.classic_user_id == 177_002)
      Repo.delete_all(from c in ClassicSignInCodes, where: c.classic_user_id == 177_002)
      Sandbox.checkin(Repo)
    end
  end
end

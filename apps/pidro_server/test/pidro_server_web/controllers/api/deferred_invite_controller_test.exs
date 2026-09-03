defmodule PidroServerWeb.API.DeferredInviteControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Ecto.Query

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Invites
  alias PidroServer.Invites.DeferredMatcher
  alias PidroServer.Invites.Event
  alias PidroServer.Repo

  @install_id "1418b4d4-5698-4f09-8cd1-a9ef4d90db57"
  @fingerprint %{
    "platform" => "ios",
    "os_major" => "18",
    "screen_class" => "compact",
    "locale" => "en-US",
    "timezone" => "Europe/Madrid"
  }

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    restart_matcher()

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      restart_matcher()
    end)

    :ok
  end

  test "a known Android install referrer wins and returns only the code", %{conn: conn} do
    invite = open_invite!()

    response =
      conn
      |> from_ip({203, 0, 113, 61})
      |> resolve(%{
        "platform" => "android",
        "install_id" => @install_id,
        "referrer" => "utm_source=invite&invite=#{String.downcase(invite.code)}"
      })
      |> json_response(200)

    assert response == %{"data" => %{"invite" => %{"code" => invite.code}}}
    refute inspect(response) =~ invite.room_code
    assert [%Event{kind: "deferred_matched", platform: "android"}] = events(invite)
  end

  test "duplicate, malformed, and unknown referrers use the same empty envelope", %{conn: conn} do
    invite = open_invite!()

    for referrer <- [
          "invite=#{invite.code}&invite=#{invite.code}",
          "invite=%ZZ",
          "invite=ZZZZZZZZ",
          "https://www.pidro.online/j/#{invite.code}",
          "other=#{invite.code}"
        ] do
      response =
        conn
        |> recycle()
        |> from_ip({203, 0, 113, 62})
        |> resolve(%{
          "platform" => "android",
          "install_id" => Ecto.UUID.generate(),
          "referrer" => referrer
        })
        |> json_response(200)

      assert response == %{"data" => %{"invite" => nil}}
    end

    assert events(invite) == []
  end

  test "a unique coarse hint is consumed once and Android checks the reduced-UA variant", %{
    conn: conn
  } do
    invite = open_invite!()
    signature = signature(@fingerprint, {203, 0, 113, 63}, %{platform: "android", os_major: "10"})
    assert :created = DeferredMatcher.capture(invite.code, signature)

    params =
      @fingerprint
      |> Map.merge(%{"platform" => "android", "os_major" => "16"})
      |> Map.put("install_id", @install_id)

    assert %{"data" => %{"invite" => %{"code" => code}}} =
             conn
             |> from_ip({203, 0, 113, 63})
             |> resolve(params)
             |> json_response(200)

    assert code == invite.code

    assert %{"data" => %{"invite" => nil}} =
             build_conn()
             |> from_ip({203, 0, 113, 63})
             |> resolve(%{params | "install_id" => Ecto.UUID.generate()})
             |> json_response(200)
  end

  test "ambiguous fallback is empty and consumes every queried bucket", %{conn: conn} do
    first = open_invite!()
    second = open_invite!()
    signature = signature(@fingerprint, {203, 0, 113, 64})
    assert :created = DeferredMatcher.capture(first.code, signature)
    assert :created = DeferredMatcher.capture(second.code, signature)

    params = Map.put(@fingerprint, "install_id", @install_id)

    assert %{"data" => %{"invite" => nil}} =
             conn
             |> from_ip({203, 0, 113, 64})
             |> resolve(params)
             |> json_response(200)

    assert :none = DeferredMatcher.consume([signature])
    assert events(first) == []
    assert events(second) == []
  end

  test "a valid referrer consumes but does not use a fallback bucket", %{conn: conn} do
    referred = open_invite!()
    fallback = open_invite!()
    android = Map.merge(@fingerprint, %{"platform" => "android", "os_major" => "16"})
    signature = signature(android, {203, 0, 113, 65})
    assert :created = DeferredMatcher.capture(fallback.code, signature)

    assert %{"data" => %{"invite" => %{"code" => code}}} =
             conn
             |> from_ip({203, 0, 113, 65})
             |> resolve(
               android
               |> Map.put("install_id", @install_id)
               |> Map.put("referrer", "invite=#{referred.code}")
             )
             |> json_response(200)

    assert code == referred.code
    assert :none = DeferredMatcher.consume([signature])
  end

  test "resolve counts empty attempts against both IP and install fairness limits", %{conn: conn} do
    with_limit(:invite_deferred, 1, 1_800_000)
    with_limit(:invite_deferred_install, 1, 1_800_000)

    params = %{"platform" => "ios", "install_id" => @install_id}

    assert %{"data" => %{"invite" => nil}} =
             conn
             |> from_ip({203, 0, 113, 66})
             |> resolve(params)
             |> json_response(200)

    assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} =
             build_conn()
             |> from_ip({203, 0, 113, 66})
             |> resolve(%{params | "install_id" => Ecto.UUID.generate()})
             |> json_response(429)

    assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} =
             build_conn()
             |> from_ip({203, 0, 113, 67})
             |> resolve(params)
             |> json_response(429)
  end

  test "the runtime feature gate disables deterministic referrer resolution", %{conn: conn} do
    invite = open_invite!()
    original = Application.fetch_env!(:pidro_server, DeferredMatcher)
    Application.put_env(:pidro_server, DeferredMatcher, Keyword.put(original, :enabled, false))
    restart_matcher()

    on_exit(fn ->
      Application.put_env(:pidro_server, DeferredMatcher, original)
      restart_matcher()
    end)

    assert %{"data" => %{"invite" => nil}} =
             conn
             |> from_ip({203, 0, 113, 68})
             |> resolve(%{
               "platform" => "android",
               "install_id" => @install_id,
               "referrer" => "invite=#{invite.code}"
             })
             |> json_response(200)

    assert events(invite) == []
  end

  defp resolve(conn, params), do: post(conn, ~p"/api/v1/invites/deferred", params)

  defp signature(params, ip, overrides \\ %{}) do
    Map.merge(
      %{
        ip: ip |> :inet.ntoa() |> List.to_string(),
        platform: String.downcase(params["platform"]),
        os_major: params["os_major"],
        screen_class: params["screen_class"],
        locale: String.downcase(params["locale"]),
        timezone: String.downcase(params["timezone"])
      },
      overrides
    )
  end

  defp events(invite) do
    Repo.all(from event in Event, where: event.invite_id == ^invite.id)
  end

  defp open_invite! do
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})

    {:ok, invite} =
      Invites.create_invite(%{
        room_id: room.id,
        room_code: room.code,
        host_user_id: host.id
      })

    invite
  end

  defp restart_matcher do
    case Supervisor.terminate_child(PidroServer.Supervisor, DeferredMatcher) do
      :ok -> Supervisor.restart_child(PidroServer.Supervisor, DeferredMatcher)
      {:error, :not_found} -> :ok
    end

    :ok
  end
end

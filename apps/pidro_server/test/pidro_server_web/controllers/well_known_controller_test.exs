defmodule PidroServerWeb.WellKnownControllerTest do
  # async: false — several tests swap the controller's application env, which is
  # global; running them concurrently with other ConnCase tests would race.
  use PidroServerWeb.ConnCase, async: false

  alias PidroServerWeb.WellKnownController

  doctest WellKnownController

  @config_key PidroServerWeb.WellKnownController

  @app_ids [
    "LSFK7YF82G.com.oneapps.pidro",
    "LSFK7YF82G.com.marcelfahle.pidro3.dev",
    "LSFK7YF82G.com.marcelfahle.pidro3.preview"
  ]

  @fingerprint "11:24:29:B7:D0:61:FA:FF:89:D2:F0:04:92:12:FF:18:24:90:C1:EF:CF:71:00:5D:51:6A:D6:92:66:88:1A:31"

  setup do
    original = Application.get_env(:pidro_server, @config_key)
    on_exit(fn -> Application.put_env(:pidro_server, @config_key, original) end)
    :ok
  end

  describe "GET /.well-known/apple-app-site-association" do
    test "serves the AASA built from the default config", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/apple-app-site-association")

      assert [detail] = json_response(conn, 200)["applinks"]["details"]
      assert detail["appIDs"] == @app_ids

      assert [
               %{"/" => "/j/*", "comment" => "invite links"},
               %{"/" => "/app/*", "comment" => "invite links"}
             ] = detail["components"]

      assert_association_headers(conn)
    end

    test "returns 200 JSON for Accept: text/html (AE8)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get(~p"/.well-known/apple-app-site-association")

      assert [detail] = json_response(conn, 200)["applinks"]["details"]
      assert detail["appIDs"] == @app_ids
      assert [%{"/" => "/j/*"} | _] = detail["components"]
    end

    test "HEAD returns 200 with an empty body", %{conn: conn} do
      conn = head(conn, ~p"/.well-known/apple-app-site-association")

      assert response(conn, 200) == ""
      assert_association_headers(conn)
    end

    test "serves only the overridden ids when AASA_APP_IDS is set", %{conn: conn} do
      override_config(%{
        "AASA_APP_IDS" => "LSFK7YF82G.com.example.one, LSFK7YF82G.com.example.two"
      })

      conn = get(conn, ~p"/.well-known/apple-app-site-association")

      assert [detail] = json_response(conn, 200)["applinks"]["details"]
      assert detail["appIDs"] == ["LSFK7YF82G.com.example.one", "LSFK7YF82G.com.example.two"]
      # paths were not overridden, so the defaults stay in place
      assert [%{"/" => "/j/*"}, %{"/" => "/app/*"}] = detail["components"]
    end
  end

  describe "GET /apple-app-site-association (legacy root path)" do
    test "serves the same body as the well-known path", %{conn: conn} do
      well_known = get(conn, ~p"/.well-known/apple-app-site-association")
      legacy = get(conn, ~p"/apple-app-site-association")

      assert json_response(legacy, 200) == json_response(well_known, 200)
      assert_association_headers(legacy)
    end
  end

  describe "GET /.well-known/assetlinks.json" do
    test "serves the statement list built from the default config", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/assetlinks.json")

      assert [statement] = json_response(conn, 200)
      assert statement["relation"] == ["delegate_permission/common.handle_all_urls"]

      assert statement["target"] == %{
               "namespace" => "android_app",
               "package_name" => "com.oneapps.pidro",
               "sha256_cert_fingerprints" => [@fingerprint]
             }

      assert_association_headers(conn)
    end

    test "returns 200 JSON for Accept: text/html", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get(~p"/.well-known/assetlinks.json")

      assert [%{"target" => %{"package_name" => "com.oneapps.pidro"}}] = json_response(conn, 200)
    end

    test "HEAD returns 200 with an empty body", %{conn: conn} do
      conn = head(conn, ~p"/.well-known/assetlinks.json")

      assert response(conn, 200) == ""
      assert_association_headers(conn)
    end

    test "serves a lower-case fingerprint from config upper-cased", %{conn: conn} do
      put_config(:android_packages, [
        %{package: "com.oneapps.pidro", fingerprints: [String.downcase(@fingerprint)]}
      ])

      conn = get(conn, ~p"/.well-known/assetlinks.json")

      assert [%{"target" => %{"sha256_cert_fingerprints" => [@fingerprint]}}] =
               json_response(conn, 200)
    end

    test "serves every configured package when ASSETLINKS lists several", %{conn: conn} do
      second =
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"

      override_config(%{
        "ASSETLINKS" => "com.oneapps.pidro:#{@fingerprint}|#{second},com.example.dev:#{second}"
      })

      conn = get(conn, ~p"/.well-known/assetlinks.json")

      assert [
               %{
                 "target" => %{
                   "package_name" => "com.oneapps.pidro",
                   "sha256_cert_fingerprints" => [@fingerprint, ^second]
                 }
               },
               %{
                 "target" => %{
                   "package_name" => "com.example.dev",
                   "sha256_cert_fingerprints" => [^second]
                 }
               }
             ] = json_response(conn, 200)
    end
  end

  describe "env_overrides/1" do
    test "unset variables leave the defaults untouched" do
      assert WellKnownController.env_overrides(%{}) == []
      assert WellKnownController.env_overrides(%{"UNRELATED" => "value"}) == []
    end

    test "parses AASA_APP_IDS and AASA_PATHS as trimmed comma lists" do
      overrides =
        WellKnownController.env_overrides(%{
          "AASA_APP_IDS" => " LSFK7YF82G.com.example.one ,LSFK7YF82G.com.example.two, ",
          "AASA_PATHS" => "/j/*, /app/*"
        })

      assert overrides == [
               ios_app_ids: ["LSFK7YF82G.com.example.one", "LSFK7YF82G.com.example.two"],
               ios_paths: ["/j/*", "/app/*"]
             ]
    end

    test "parses ASSETLINKS and upper-cases fingerprints" do
      lower = String.downcase(@fingerprint)

      assert WellKnownController.env_overrides(%{"ASSETLINKS" => "com.oneapps.pidro:#{lower}"}) ==
               [android_packages: [%{package: "com.oneapps.pidro", fingerprints: [@fingerprint]}]]
    end

    test "raises with a clear message on a malformed fingerprint" do
      too_short = "11:24:29"
      not_hex = String.replace(@fingerprint, "11:", "ZZ:", global: false)

      for bad <- [too_short, not_hex] do
        assert_raise ArgumentError, ~r/ASSETLINKS.*fingerprint/, fn ->
          WellKnownController.env_overrides(%{"ASSETLINKS" => "com.oneapps.pidro:#{bad}"})
        end
      end
    end

    test "raises on an entry without a fingerprint or a set-but-empty variable" do
      assert_raise ArgumentError, ~r/ASSETLINKS/, fn ->
        WellKnownController.env_overrides(%{"ASSETLINKS" => "com.oneapps.pidro"})
      end

      assert_raise ArgumentError, ~r/AASA_APP_IDS/, fn ->
        WellKnownController.env_overrides(%{"AASA_APP_IDS" => " , "})
      end
    end
  end

  # Mirrors the merge config/runtime.exs performs so the request path is the one production takes.
  defp override_config(env) do
    existing = Application.get_env(:pidro_server, @config_key, [])
    overrides = WellKnownController.env_overrides(env)
    Application.put_env(:pidro_server, @config_key, Keyword.merge(existing, overrides))
  end

  defp put_config(key, value) do
    existing = Application.get_env(:pidro_server, @config_key, [])
    Application.put_env(:pidro_server, @config_key, Keyword.put(existing, key, value))
  end

  defp assert_association_headers(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/json")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
  end
end

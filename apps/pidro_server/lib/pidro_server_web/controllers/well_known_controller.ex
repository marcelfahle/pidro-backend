defmodule PidroServerWeb.WellKnownController do
  @moduledoc """
  Serves the domain-association files that iOS universal links and Android app
  links are verified against:

    * `GET /.well-known/apple-app-site-association` (also at the legacy root
      path `/apple-app-site-association`) — Apple App Site Association (AASA)
    * `GET /.well-known/assetlinks.json` — Android Digital Asset Links

  Both documents are built at request time from
  `config :pidro_server, PidroServerWeb.WellKnownController`:

    * `:ios_app_ids` — `["TEAMID.bundle.id", ...]`
    * `:ios_paths` — path patterns in order, e.g. `["/j/*", "/app/*"]`
    * `:android_packages` — `[%{package: "...", fingerprints: ["AA:BB:...", ...]}]`

  Defaults live in `config/config.exs` for every environment. `config/runtime.exs`
  overrides them from `AASA_APP_IDS`, `AASA_PATHS` and `ASSETLINKS` through
  `env_overrides/1`, which validates a set variable at boot and raises on
  malformed input, so a bad deploy fails its health check instead of serving a
  broken file.

  Responses go out through `send_resp/3` with an explicit `application/json`
  content type and `cache-control: public, max-age=3600`, so any `Accept` header
  (Apple's CDN and Google's verifier send whatever they like) gets the JSON. The
  router pipeline in front of these routes deliberately has no `accepts` plug.
  """

  use PidroServerWeb, :controller

  @app_ids_var "AASA_APP_IDS"
  @paths_var "AASA_PATHS"
  @assetlinks_var "ASSETLINKS"

  @cache_control "public, max-age=3600"
  @handle_all_urls "delegate_permission/common.handle_all_urls"

  @spec apple_app_site_association(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def apple_app_site_association(conn, _params) do
    config = config()

    components =
      Enum.map(Keyword.fetch!(config, :ios_paths), &%{"/" => &1, "comment" => "invite links"})

    body = %{
      applinks: %{
        details: [%{appIDs: Keyword.fetch!(config, :ios_app_ids), components: components}]
      }
    }

    send_json(conn, body)
  end

  @spec assetlinks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assetlinks(conn, _params) do
    statements =
      for %{package: package, fingerprints: fingerprints} <-
            Keyword.fetch!(config(), :android_packages) do
        %{
          relation: [@handle_all_urls],
          target: %{
            namespace: "android_app",
            package_name: package,
            sha256_cert_fingerprints: Enum.map(fingerprints, &String.upcase/1)
          }
        }
      end

    send_json(conn, statements)
  end

  @doc """
  Turns the `AASA_APP_IDS`, `AASA_PATHS` and `ASSETLINKS` entries of an
  environment map (normally `System.get_env/0`) into config overrides for this
  controller.

  Only a variable that is present produces an entry, so an unset variable keeps
  the `config/config.exs` default. A present variable is validated: comma lists
  must contain at least one value, `ASSETLINKS` entries must have the shape
  `package:fp1|fp2,package2:fp3`, and every fingerprint is upper-cased and must be
  32 colon-separated hex pairs. Malformed input raises `ArgumentError`.

  ## Examples

      iex> PidroServerWeb.WellKnownController.env_overrides(%{})
      []

      iex> PidroServerWeb.WellKnownController.env_overrides(%{"AASA_APP_IDS" => "T.com.a, T.com.b"})
      [ios_app_ids: ["T.com.a", "T.com.b"]]
  """
  @spec env_overrides(%{optional(String.t()) => String.t()}) :: keyword()
  def env_overrides(env) when is_map(env) do
    [
      ios_app_ids: parse_var(env, @app_ids_var, &comma_list!/2),
      ios_paths: parse_var(env, @paths_var, &comma_list!/2),
      android_packages: parse_var(env, @assetlinks_var, &assetlinks!/2)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_var(env, name, parser) do
    case Map.fetch(env, name) do
      {:ok, value} -> parser.(value, name)
      :error -> nil
    end
  end

  defp comma_list!(value, name) do
    case split_list(value, ",") do
      [] -> raise ArgumentError, "environment variable #{name} is set but contains no values"
      values -> values
    end
  end

  defp assetlinks!(value, name) do
    value
    |> comma_list!(name)
    |> Enum.map(&package_entry!(&1, name))
  end

  defp package_entry!(entry, name) do
    {package, fingerprints} =
      case String.split(entry, ":", parts: 2) do
        [package, fingerprints] -> {String.trim(package), split_list(fingerprints, "|")}
        _ -> {"", []}
      end

    if package == "" or fingerprints == [] do
      raise ArgumentError,
            "environment variable #{name} has a malformed entry #{inspect(entry)}; " <>
              "expected package:fp1|fp2"
    end

    %{package: package, fingerprints: Enum.map(fingerprints, &fingerprint!(&1, package, name))}
  end

  defp fingerprint!(fingerprint, package, name) do
    normalized = String.upcase(fingerprint)

    if Regex.match?(~r/\A(?:[0-9A-F]{2}:){31}[0-9A-F]{2}\z/, normalized) do
      normalized
    else
      raise ArgumentError,
            "environment variable #{name} has a malformed SHA-256 fingerprint " <>
              "#{inspect(fingerprint)} for package #{package}; " <>
              "expected 32 colon-separated hex pairs"
    end
  end

  defp split_list(value, separator) do
    value
    |> String.split(separator)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp config, do: Application.get_env(:pidro_server, __MODULE__, [])

  defp send_json(conn, body) do
    conn
    |> put_resp_content_type("application/json", nil)
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(200, Jason.encode_to_iodata!(body))
  end
end

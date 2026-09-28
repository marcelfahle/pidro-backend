defmodule PidroServer.Accounts.ClassicClient do
  @moduledoc "Read-only client for Classic account ownership and profile data."

  @callback verify_password(String.t(), String.t()) ::
              {:ok, map()} | {:error, :invalid_credentials | :provider_unavailable}
  @callback lookup(:email | :fbid, String.t()) ::
              {:ok, map()} | {:error, :not_found | :provider_unavailable}

  def verify_password(login, password) do
    request(:post, "/internal/claims/verify_password", json: %{login: login, password: password})
    |> verified_profile()
  end

  def lookup(field, value) when field in [:email, :fbid] do
    request(:get, "/internal/claims/lookup", params: [{field, value}])
    |> lookup_result()
  end

  defp request(method, path, options) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)

    options =
      Keyword.merge(
        [
          method: method,
          url: Keyword.fetch!(config, :base_url) <> path,
          auth: {:bearer, Keyword.fetch!(config, :secret)},
          receive_timeout: 5_000
        ],
        options
      )

    Req.request(Keyword.merge(options, Keyword.get(config, :req_options, [])))
  end

  defp verified_profile({:ok, %{status: 200, body: profile}}) when is_map(profile),
    do: {:ok, profile}

  defp verified_profile({:ok, %{status: status}}) when status in [401, 404],
    do: {:error, :invalid_credentials}

  defp verified_profile(_response), do: {:error, :provider_unavailable}

  defp lookup_result({:ok, %{status: 200, body: profile}}) when is_map(profile),
    do: {:ok, profile}

  defp lookup_result({:ok, %{status: 404}}), do: {:error, :not_found}
  defp lookup_result(_response), do: {:error, :provider_unavailable}
end

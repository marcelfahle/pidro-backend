defmodule PidroServer.Accounts.FacebookCredential do
  @moduledoc false

  def parse(params) when is_map(params) do
    access_token = fetch(params, :access_token)
    authentication_token = fetch(params, :authentication_token)
    nonce = fetch(params, :nonce)

    case {present?(access_token), present?(authentication_token), present?(nonce)} do
      {true, false, false} -> {:ok, {:access_token, access_token}}
      {false, true, true} -> {:ok, {:authentication_token, authentication_token, nonce}}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  def parse(_params), do: {:error, :invalid_credentials}

  defp present?(value), do: is_binary(value) and value != ""
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

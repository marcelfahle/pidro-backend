defmodule PidroServer.Accounts.ProviderIdentity do
  @moduledoc "Validates Apple and Facebook credentials against their providers."

  @apple_issuer "https://appleid.apple.com"

  def apple(identity_token) when is_binary(identity_token) do
    with {:ok, header, claims, signed, signature} <- decode_jwt(identity_token),
         true <- header["alg"] == "RS256" or {:error, :invalid_credentials},
         {:ok, key} <- apple_key(header["kid"]),
         true <- verify_signature(key, signed, signature) or {:error, :invalid_credentials},
         :ok <- validate_apple_claims(claims) do
      {:ok, claims}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def apple(_identity_token), do: {:error, :invalid_credentials}

  def facebook(access_token) when is_binary(access_token) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    app_id = Keyword.fetch!(config, :facebook_app_id)

    with {:ok, %{"data" => %{"is_valid" => true, "app_id" => ^app_id} = debug}} <-
           facebook_get("/debug_token",
             input_token: access_token,
             access_token: app_id <> "|" <> Keyword.fetch!(config, :facebook_app_secret)
           ),
         {:ok, %{"id" => id}} <- facebook_get("/me", access_token: access_token),
         true <- (is_binary(id) and id == debug["user_id"]) or {:error, :invalid_credentials} do
      {:ok, id}
    else
      {:ok, _invalid} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def facebook(_access_token), do: {:error, :invalid_credentials}

  def facebook_business_ids(access_token) when is_binary(access_token) do
    facebook_business_ids_page(access_token, nil, %{}, [])
  end

  defp facebook_business_ids_page(access_token, after_cursor, seen_cursors, ids) do
    params =
      [access_token: access_token]
      |> then(fn params ->
        if after_cursor, do: Keyword.put(params, :after, after_cursor), else: params
      end)

    case facebook_get("/me/ids_for_business", params) do
      {:ok, %{"data" => identities} = body} when is_list(identities) ->
        ids = ids ++ Enum.flat_map(identities, &identity_id/1)

        case next_cursor(body) do
          nil ->
            {:ok, ids}

          cursor when is_binary(cursor) ->
            if Map.has_key?(seen_cursors, cursor) do
              {:error, :provider_unavailable}
            else
              facebook_business_ids_page(
                access_token,
                cursor,
                Map.put(seen_cursors, cursor, true),
                ids
              )
            end

          :missing ->
            {:error, :provider_unavailable}
        end

      {:ok, _invalid} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_jwt(token) do
    with [encoded_header, encoded_claims, encoded_signature] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, claims_json} <- Base.url_decode64(encoded_claims, padding: false),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(header_json),
         {:ok, claims} when is_map(claims) <- Jason.decode(claims_json) do
      {:ok, header, claims, encoded_header <> "." <> encoded_claims, signature}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp apple_key(kid) when is_binary(kid) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)

    case Req.get(
           Keyword.fetch!(config, :apple_jwks_url),
           Keyword.merge([receive_timeout: 5_000], Keyword.get(config, :req_options, []))
         ) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        case Enum.find(keys, fn
               %{"kid" => key_kid, "kty" => "RSA"} -> key_kid == kid
               _invalid -> false
             end) do
          %{"n" => modulus, "e" => exponent}
          when is_binary(modulus) and is_binary(exponent) ->
            rsa_key(modulus, exponent)

          _missing ->
            {:error, :invalid_credentials}
        end

      _response ->
        {:error, :provider_unavailable}
    end
  end

  defp apple_key(_kid), do: {:error, :invalid_credentials}

  defp rsa_key(modulus, exponent) do
    with {:ok, modulus} <- Base.url_decode64(modulus, padding: false),
         {:ok, exponent} <- Base.url_decode64(exponent, padding: false) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}
    else
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_signature(key, signed, signature) do
    :public_key.verify(signed, :sha256, signature, key)
  rescue
    _error -> false
  end

  defp validate_apple_claims(claims) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    audience = Keyword.fetch!(config, :apple_audience)
    now = System.system_time(:second)

    if claims["iss"] == @apple_issuer and audience?(claims["aud"], audience) and
         is_integer(claims["exp"]) and claims["exp"] > now and
         is_binary(claims["sub"]) and claims["sub"] != "" do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  defp audience?(audience, expected) when is_binary(audience), do: audience == expected
  defp audience?(audiences, expected) when is_list(audiences), do: expected in audiences
  defp audience?(_audience, _expected), do: false

  defp facebook_get(path, params) do
    config = Application.fetch_env!(:pidro_server, __MODULE__)
    base_url = Keyword.fetch!(config, :facebook_graph_url)
    options = [url: base_url <> path, params: params, receive_timeout: 5_000]

    case Req.get(Keyword.merge(options, Keyword.get(config, :req_options, []))) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} when status in 400..499 -> {:error, :invalid_credentials}
      _response -> {:error, :provider_unavailable}
    end
  end

  defp identity_id(%{"id" => id}) when is_binary(id), do: [id]
  defp identity_id(_identity), do: []

  defp next_cursor(%{"paging" => %{"next" => next} = paging}) when is_binary(next) do
    case get_in(paging, ["cursors", "after"]) do
      cursor when is_binary(cursor) and cursor != "" -> cursor
      _missing -> :missing
    end
  end

  defp next_cursor(_body), do: nil
end

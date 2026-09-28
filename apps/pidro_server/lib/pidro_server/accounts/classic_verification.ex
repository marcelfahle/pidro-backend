defmodule PidroServer.Accounts.ClassicVerification do
  @moduledoc "Verifies Classic ownership and issues an account-bound claim ticket."

  alias PidroServer.Accounts.{ClassicClaims, ClassicClient, ProviderIdentity}
  alias PidroServer.Profiles.LegacyProgression

  def verify(params, current_user, opts \\ [])

  def verify(params, current_user, opts) when is_map(params) do
    classic = Keyword.get(opts, :classic_client, ClassicClient)
    providers = Keyword.get(opts, :provider_identity, ProviderIdentity)

    with {:ok, binding} <- binding(current_user, params),
         {:ok, method} <- method(params),
         {:ok, profile, provider_id} <- verify_method(method, params, classic, providers),
         {:ok, classic_user_id} <- classic_user_id(profile),
         legacy = legacy_data(profile),
         {:ok, ticket} <-
           ClassicClaims.issue_ticket(
             binding
             |> Map.merge(%{
               classic_user_id: classic_user_id,
               method: method,
               provider_id: provider_id,
               legacy_data: legacy
             })
           ) do
      {:ok, Map.put(ticket, :classic, preview(legacy))}
    end
  end

  def verify(_params, _current_user, _opts), do: {:error, :invalid_credentials}

  defp binding(%{id: user_id}, _params), do: {:ok, %{user_id: user_id}}

  defp binding(nil, params) do
    case fetch(params, :install_id) do
      install_id
      when is_binary(install_id) and install_id != "" and byte_size(install_id) <= 64 ->
        {:ok, %{install_id: install_id}}

      _invalid ->
        {:error, :claim_binding_required}
    end
  end

  defp method(params) do
    case fetch(params, :method) do
      "password" -> {:ok, :password}
      "apple" -> {:ok, :apple}
      "facebook" -> {:ok, :facebook}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:password, params, classic, _providers) do
    with login when is_binary(login) and login != "" <- fetch(params, :login),
         password when is_binary(password) and password != "" <- fetch(params, :password),
         {:ok, profile} <- classic.verify_password(login, password) do
      {:ok, profile, nil}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:apple, params, classic, providers) do
    with token when is_binary(token) <- fetch(params, :identity_token),
         {:ok, %{"sub" => subject, "email" => email} = claims} <- providers.apple(token),
         true <- claims["email_verified"] in [true, "true"] or {:error, :invalid_credentials},
         true <- (is_binary(email) and email != "") or {:error, :invalid_credentials},
         {:ok, profile} <- lookup(classic, :email, email) do
      {:ok, profile, subject}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify_method(:facebook, params, classic, providers) do
    with token when is_binary(token) <- fetch(params, :access_token),
         {:ok, primary_id} <- providers.facebook(token),
         {:ok, business_ids} <- providers.facebook_business_ids(token),
         {:ok, profile} <- lookup_facebook(classic, [primary_id | business_ids]) do
      {:ok, profile, primary_id}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp lookup(classic, field, value) do
    case classic.lookup(field, value) do
      {:error, :not_found} -> {:error, :invalid_credentials}
      result -> result
    end
  end

  defp lookup_facebook(classic, ids) do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:error, :invalid_credentials}, fn id, _not_found ->
      case classic.lookup(:fbid, id) do
        {:ok, profile} -> {:halt, {:ok, profile}}
        {:error, :not_found} -> {:cont, {:error, :invalid_credentials}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp classic_user_id(profile) do
    case fetch(profile, :id) do
      id when is_integer(id) -> {:ok, id}
      id when is_binary(id) -> parse_integer(id)
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp legacy_data(profile) do
    profile
    |> Map.put("classic_username", classic_name(profile))
    |> Map.put("classic_level", fetch(profile, :level))
    |> Map.put("legacy_played_games", fetch(profile, :played_games))
    |> Map.put("legacy_victories", fetch(profile, :victories))
    |> Map.put("legacy_losses", fetch(profile, :losses))
    |> Map.put("games_played_counter", fetch(profile, :total_game))
    |> Map.put("wins", fetch(profile, :win_game))
    |> Map.put("losses", fetch(profile, :lost_game))
    |> Map.put("games_logged", fetch(profile, :xpoints_count) || fetch(profile, :xpoints))
    |> Map.put("games_started", fetch(profile, :started))
    |> Map.put("games_ended", fetch(profile, :ended))
    |> Map.put("member_since", fetch(profile, :inserted_at))
    |> Map.put("premium", premium?(fetch(profile, :premium_until)))
    |> LegacyProgression.new()
    |> Map.from_struct()
  end

  defp preview(legacy) do
    %{
      name: legacy.classic_username,
      games_played: legacy.games_played_counter || legacy.legacy_played_games,
      level: legacy.classic_level,
      member_since: legacy.member_since,
      name_allowed: legacy.classic_name_allowed
    }
  end

  defp classic_name(profile) do
    case fetch(profile, :username) do
      username when is_binary(username) ->
        case String.trim(username) do
          "" -> fetch(profile, :firstname)
          name -> name
        end

      _blank ->
        fetch(profile, :firstname)
    end
  end

  defp premium?(nil), do: nil

  defp premium?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> DateTime.after?(expires_at, DateTime.utc_now())
      _invalid -> nil
    end
  end

  defp premium?(_value), do: nil

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

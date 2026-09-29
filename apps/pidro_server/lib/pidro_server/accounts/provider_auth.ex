defmodule PidroServer.Accounts.ProviderAuth do
  @moduledoc "Apple and Facebook sign-in, Classic discovery, and first-time registration."

  import Ecto.Query

  alias PidroServer.Accounts.{
    ClassicNameReservations,
    ClassicVerification,
    GuestNames,
    ProviderIdentity,
    User
  }

  alias PidroServer.Repo

  @name_attempts 2

  @type provider :: :apple | :facebook
  @type result :: {:ok, User.t()} | {:classic_found, map()}

  @spec authenticate(provider(), String.t(), map(), keyword()) ::
          result()
          | {:error,
             :invalid_credentials | :provider_unavailable | :claim_binding_required | term()}
  def authenticate(provider, token, params \\ %{}, opts \\ [])

  def authenticate(provider, token, params, opts)
      when provider in [:apple, :facebook] and is_binary(token) and is_map(params) do
    providers =
      Keyword.get_lazy(opts, :provider_identity, fn ->
        Application.get_env(:pidro_server, :provider_identity, ProviderIdentity)
      end)

    with {:ok, provider_id, lookup_ids} <- verify(provider, token, providers) do
      case user_for(provider, provider_id) do
        %User{} = user ->
          {:ok, user}

        nil ->
          authenticate_unlinked(provider, provider_id, lookup_ids, token, params, providers, opts)
      end
    end
  end

  def authenticate(_provider, _token, _params, _opts), do: {:error, :invalid_credentials}

  defp verify(:apple, token, providers) do
    with {:ok, %{"sub" => provider_id} = claims} <- providers.apple(token),
         true <- valid_id?(provider_id) or {:error, :invalid_credentials} do
      lookup_ids =
        case claims do
          %{"email" => email, "email_verified" => verified}
          when is_binary(email) and email != "" and verified in [true, "true"] ->
            [email]

          _without_verified_email ->
            []
        end

      {:ok, provider_id, lookup_ids}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp verify(:facebook, token, providers) do
    with {:ok, provider_id} <- providers.facebook(token),
         true <- valid_id?(provider_id) or {:error, :invalid_credentials} do
      {:ok, provider_id, :fetch_business_ids}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_credentials}
    end
  end

  defp authenticate_unlinked(
         :facebook,
         provider_id,
         :fetch_business_ids,
         token,
         params,
         providers,
         opts
       ) do
    with {:ok, business_ids} when is_list(business_ids) <-
           providers.facebook_business_ids(token),
         true <- Enum.all?(business_ids, &valid_id?/1) or {:error, :provider_unavailable} do
      find_classic_or_create(:facebook, provider_id, [provider_id | business_ids], params, opts)
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp authenticate_unlinked(:apple, provider_id, lookup_ids, _token, params, _providers, opts),
    do: find_classic_or_create(:apple, provider_id, lookup_ids, params, opts)

  defp find_classic_or_create(provider, provider_id, lookup_ids, params, opts) do
    verification = Keyword.get(opts, :classic_verification, ClassicVerification)
    classic = Keyword.get(opts, :classic_client, PidroServer.Accounts.ClassicClient)

    case verification.verify_provider(provider, provider_id, lookup_ids, params,
           classic_client: classic
         ) do
      {:ok, result} -> {:classic_found, result}
      {:error, :not_found} -> create_user(provider, provider_id, opts, @name_attempts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_user(provider, provider_id, opts, attempts_left) do
    guest_names =
      Keyword.get_lazy(opts, :guest_names, fn ->
        Application.get_env(:pidro_server, :guest_names, GuestNames)
      end)

    with {:ok, name} <- guest_names.generate() do
      changeset =
        %User{}
        |> User.provider_registration_changeset(
          %{username: name, display_name: name},
          provider,
          provider_id
        )
        |> ClassicNameReservations.validate_changes()

      case Repo.insert(changeset) do
        {:ok, user} ->
          {:ok, user}

        {:error, changeset} ->
          recover_creation(provider, provider_id, opts, attempts_left, changeset)
      end
    end
  end

  defp recover_creation(provider, provider_id, opts, attempts_left, changeset) do
    case user_for(provider, provider_id) do
      %User{} = user ->
        {:ok, user}

      nil ->
        if attempts_left > 1 and unique_error?(changeset, :username) do
          create_user(provider, provider_id, opts, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp user_for(:apple, provider_id),
    do: Repo.one(from u in User, where: u.apple_sub == ^provider_id, limit: 1)

  defp user_for(:facebook, provider_id),
    do: Repo.one(from u in User, where: u.facebook_id == ^provider_id, limit: 1)

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp valid_id?(id), do: is_binary(id) and id != ""
end

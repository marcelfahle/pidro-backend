defmodule PidroServer.Accounts.ProviderAuth do
  @moduledoc "Social sign-in after a verified Apple or Facebook identity has been linked."

  import Ecto.Query

  alias PidroServer.Accounts.User
  alias PidroServer.Repo

  @spec authenticate(:apple | :facebook, String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid_credentials | :provider_unavailable}
  def authenticate(provider, token, opts \\ [])

  def authenticate(provider, token, opts)
      when provider in [:apple, :facebook] and is_binary(token) do
    verifier =
      Keyword.get_lazy(opts, :verifier, fn ->
        Application.get_env(
          :pidro_server,
          :provider_verifier,
          PidroServer.Accounts.UnavailableProviderVerifier
        )
      end)

    with {:ok, provider_id} <- verifier.verify(provider, token),
         %User{} = user <- user_for(provider, provider_id) do
      {:ok, user}
    else
      nil -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  def authenticate(_provider, _token, _opts), do: {:error, :invalid_credentials}

  defp user_for(:apple, provider_id),
    do: Repo.one(from u in User, where: u.apple_sub == ^provider_id, limit: 1)

  defp user_for(:facebook, provider_id),
    do: Repo.one(from u in User, where: u.facebook_id == ^provider_id, limit: 1)
end

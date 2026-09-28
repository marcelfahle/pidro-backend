defmodule PidroServer.Accounts.ExternalProviderVerifier do
  @moduledoc false
  @behaviour PidroServer.Accounts.ProviderVerifier

  alias PidroServer.Accounts.ProviderIdentity

  @impl true
  def verify(:apple, token) do
    with {:ok, claims} <- ProviderIdentity.apple(token), do: {:ok, claims["sub"]}
  end

  def verify(:facebook, token), do: ProviderIdentity.facebook(token)
end

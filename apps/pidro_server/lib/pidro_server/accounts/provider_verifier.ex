defmodule PidroServer.Accounts.ProviderVerifier do
  @moduledoc """
  Boundary implemented by PID-143's Apple and Facebook token verification.

  PID-144 consumes only the verified stable provider subject. Raw subjects from
  clients are never accepted.
  """

  @callback verify(:apple | :facebook, String.t()) ::
              {:ok, String.t()} | {:error, :invalid_credentials | :provider_unavailable}
end

defmodule PidroServer.Accounts.UnavailableProviderVerifier do
  @moduledoc false
  @behaviour PidroServer.Accounts.ProviderVerifier

  @impl true
  def verify(_provider, _token), do: {:error, :provider_unavailable}
end

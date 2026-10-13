defmodule PidroServer.Mailer do
  use Swoosh.Mailer, otp_app: :pidro_server

  require Logger

  @doc """
  Delivers `email` like `deliver/1`, but an adapter that raises or exits
  returns `{:error, reason}` too, and every failure is logged under `label`.

  The log never holds the email: an adapter that exits inside a
  `GenServer.call`, like `Swoosh.Adapters.Local` without its storage, carries
  the whole message in its exit reason, reset links included.
  """
  def deliver_logged(email, label) do
    case deliver(email) do
      {:ok, _metadata} = sent -> sent
      {:error, reason} -> failed(label, reason)
    end
  catch
    kind, reason -> failed(label, {kind, summary(reason)})
  end

  defp failed(label, reason) do
    Logger.error("#{label} email delivery failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp summary(exception) when is_exception(exception), do: exception.__struct__
  defp summary({reason, {_module, _function, _args}}), do: summary(reason)
  defp summary(reason) when is_atom(reason), do: reason
  defp summary(_reason), do: :unknown
end

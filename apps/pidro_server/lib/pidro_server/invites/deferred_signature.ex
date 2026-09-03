defmodule PidroServer.Invites.DeferredSignature do
  @moduledoc """
  Validates and canonicalizes the coarse deferred-invite signature.

  Browser and native clients supply only device-class fields. Phoenix adds the
  trusted, normalized request address before the signature reaches the
  short-lived matcher.
  """

  alias PidroServerWeb.Plugs.RateLimit

  @platforms ~w(ios android)
  @screen_classes ~w(compact medium large)
  @locale_regex ~r/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/
  @timezone_regex ~r/^[A-Za-z0-9_+\/-]{1,64}$/

  @spec build(:inet.ip_address(), map()) :: {:ok, map()} | :error
  def build(remote_ip, params) when is_map(params) do
    with {:ok, platform} <- member(params["platform"], @platforms),
         {:ok, os_major} <- os_major(params["os_major"]),
         {:ok, screen_class} <- member(params["screen_class"], @screen_classes),
         {:ok, locale} <- normalized_match(params["locale"], @locale_regex, 35),
         {:ok, timezone} <- normalized_match(params["timezone"], @timezone_regex, 64) do
      {:ok,
       %{
         ip: RateLimit.ip_key(remote_ip),
         platform: platform,
         os_major: os_major,
         screen_class: screen_class,
         locale: locale,
         timezone: timezone
       }}
    else
      _invalid -> :error
    end
  end

  defp member(value, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in allowed, do: {:ok, normalized}, else: :error
  end

  defp member(_value, _allowed), do: :error

  defp os_major(value) when is_binary(value) do
    normalized = String.trim(value)

    case Integer.parse(normalized) do
      {major, ""} when major in 1..999 -> {:ok, Integer.to_string(major)}
      _invalid -> :error
    end
  end

  defp os_major(_value), do: :error

  defp normalized_match(value, regex, max_length) when is_binary(value) do
    normalized = value |> String.trim() |> String.replace("_", "-") |> String.downcase()

    if normalized != "" and String.length(normalized) <= max_length and
         Regex.match?(regex, normalized) do
      {:ok, normalized}
    else
      :error
    end
  end

  defp normalized_match(_value, _regex, _max_length), do: :error
end

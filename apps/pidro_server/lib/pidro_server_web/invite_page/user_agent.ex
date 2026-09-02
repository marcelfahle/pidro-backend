defmodule PidroServerWeb.InvitePage.UserAgent do
  @moduledoc "Pure, presentation-only classification of invite-page user agents."

  @crawler_tokens ~w(
    applebot
    discordbot
    facebookexternalhit
    facebot
    imessage
    linkedinbot
    slackbot
    telegrambot
    twitterbot
    whatsapp
  )

  @type classification :: :crawler | :ios | :android | :desktop

  @doc "Classifies a user agent conservatively; unknown agents get the desktop-safe page."
  @spec classify(String.t() | nil) :: classification()
  def classify(user_agent) when is_binary(user_agent) do
    normalized = String.downcase(user_agent)

    cond do
      Enum.any?(@crawler_tokens, &String.contains?(normalized, &1)) -> :crawler
      String.contains?(normalized, ["iphone", "ipad", "ipod"]) -> :ios
      String.contains?(normalized, "macintosh") and String.contains?(normalized, "mobile") -> :ios
      String.contains?(normalized, "android") -> :android
      true -> :desktop
    end
  end

  def classify(_user_agent), do: :desktop
end

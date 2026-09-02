defmodule PidroServerWeb.InvitePageTest do
  use ExUnit.Case, async: true

  alias PidroServer.Invites.Invite
  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent

  describe "present/2" do
    test "open copy includes live seat context and only desktop builds a QR" do
      preview = preview(:open, seats_taken: 2)

      ios = InvitePage.present(preview, :ios)
      desktop = InvitePage.present(preview, :desktop)

      assert ios.description =~ "2 of 4 seats"
      assert ios.table_action == :join
      assert ios.qr_data_uri == nil
      assert desktop.qr_data_uri =~ "data:image/svg+xml;base64,"
    end

    test "moved invites consistently hand off to and display the successor" do
      successor = %Invite{code: "BBBBBBBB"}
      invite = %Invite{code: "AAAAAAAA", successor: successor}
      page = InvitePage.present(preview(:moved, invite: invite), :desktop)

      assert page.code == successor.code
      assert page.target_code == successor.code
      assert page.target_url =~ successor.code
      assert page.canonical_url =~ invite.code
      assert page.android_url =~ "/j/#{successor.code}#Intent"
    end

    test "every inactive state has honest copy and no join action" do
      states = [
        full: "full",
        started: "started",
        locked: "locked",
        closed: "closed",
        expired: "expired",
        revoked: "no longer active"
      ]

      Enum.each(states, fn {state, message} ->
        page = state |> preview() |> InvitePage.present(:ios)

        assert page.heading =~ message
        assert page.table_action == :none
        assert page.show_qr == false
        assert page.qr_data_uri == nil
      end)
    end
  end

  describe "UserAgent.classify/1" do
    test "recognizes supported share crawlers before device families" do
      for token <- ~w(
            Applebot Discordbot facebookexternalhit Facebot iMessage LinkedInBot Slackbot
            TelegramBot Twitterbot WhatsApp
          ) do
        assert UserAgent.classify("Mozilla/5.0 #{token} iPhone Android") == :crawler
      end
    end

    test "classifies iOS, iPad desktop mode, Android and unknown agents" do
      assert UserAgent.classify("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)") == :ios
      assert UserAgent.classify("Mozilla/5.0 (Macintosh) AppleWebKit Mobile/15E148") == :ios
      assert UserAgent.classify("Mozilla/5.0 (Linux; Android 15)") == :android
      assert UserAgent.classify(nil) == :desktop
      assert UserAgent.classify("curl/8.7.1") == :desktop
    end
  end

  defp preview(state, overrides \\ []) do
    invite = Keyword.get(overrides, :invite, %Invite{code: "AAAAAAAA"})

    %{
      invite: invite,
      state: state,
      host: "Marcel",
      seats_taken: Keyword.get(overrides, :seats_taken, 1)
    }
  end
end

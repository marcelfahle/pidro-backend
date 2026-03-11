defmodule PidroServer.Games.PacingSettingsTest do
  use ExUnit.Case, async: false

  alias PidroServer.Games.{Lifecycle, PacingSettings}

  setup do
    original = Application.get_env(:pidro_server, Lifecycle, [])

    on_exit(fn ->
      Application.put_env(:pidro_server, Lifecycle, original)
    end)

    :ok
  end

  test "validate parses all editable pacing fields" do
    params = %{
      "bot_delay_ms" => "2100",
      "bot_delay_variance_ms" => "900",
      "bot_min_delay_ms" => "400",
      "trick_transition_delay_ms" => "1700",
      "hand_transition_delay_ms" => "3200"
    }

    assert {:ok,
            %{
              bot_delay_ms: 2100,
              bot_delay_variance_ms: 900,
              bot_min_delay_ms: 400,
              trick_transition_delay_ms: 1700,
              hand_transition_delay_ms: 3200
            }} = PacingSettings.validate(params)
  end

  test "validate returns field errors for invalid values" do
    assert {:error, _form, errors} =
             PacingSettings.validate(%{
               "bot_delay_ms" => "-1",
               "bot_delay_variance_ms" => "abc",
               "bot_min_delay_ms" => "",
               "trick_transition_delay_ms" => "99999",
               "hand_transition_delay_ms" => "15"
             })

    assert errors["bot_delay_ms"] =~ "between"
    assert errors["bot_delay_variance_ms"] =~ "between"
    assert errors["bot_min_delay_ms"] =~ "between"
    assert errors["trick_transition_delay_ms"] =~ "between"
    refute Map.has_key?(errors, "hand_transition_delay_ms")
  end

  test "save updates runtime lifecycle config and reset restores defaults" do
    PacingSettings.save(%{
      bot_delay_ms: 2500,
      bot_delay_variance_ms: 200,
      bot_min_delay_ms: 600,
      trick_transition_delay_ms: 1800,
      hand_transition_delay_ms: 3600
    })

    assert Lifecycle.config(:bot_delay_ms) == 2500
    assert Lifecycle.config(:trick_transition_delay_ms) == 1800

    defaults = Lifecycle.defaults()
    PacingSettings.reset()

    assert Lifecycle.config(:bot_delay_ms) == defaults.bot_delay_ms
    assert Lifecycle.config(:hand_transition_delay_ms) == defaults.hand_transition_delay_ms
  end

  test "preview reports the effective bot delay range" do
    preview =
      PacingSettings.preview(%{
        "bot_delay_ms" => "1500",
        "bot_delay_variance_ms" => "800",
        "bot_min_delay_ms" => "900"
      })

    assert preview == %{bot_delay_min_ms: 900, bot_delay_max_ms: 2300}
  end
end

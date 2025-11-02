defmodule PidroEngine.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/marcelfahle/pidro-backend"

  def project do
    [
      app: :pidro_engine,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Documentation
      name: "Pidro Engine",
      description: "Finnish Pidro card game engine with pure functional core and event sourcing",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"],
      authors: ["Pidro Team"],
      before_closing_body_tag: &before_closing_body_tag/1,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp extras do
    [
      "README.md",
      "IEX_HELPERS.md",
      "EXAMPLE_SESSION.md",
      "masterplan.md",
      "masterplan-redeal.md",
      "guides/getting_started.md",
      "guides/game_rules.md",
      "guides/architecture.md",
      "guides/property_testing.md",
      "guides/event_sourcing.md",
      "specs/pidro_complete_specification.md",
      "specs/redeal.md",
      "specs/game_properties.md"
    ]
  end

  defp groups_for_extras do
    [
      Guides: ~r/guides\/.*/,
      Specifications: ~r/specs\/.*/,
      Development: [
        "masterplan.md",
        "masterplan-redeal.md",
        "IEX_HELPERS.md",
        "EXAMPLE_SESSION.md"
      ]
    ]
  end

  defp groups_for_modules do
    [
      "Core Types": [
        Pidro.Core.Types,
        Pidro.Core.Card,
        Pidro.Core.Deck,
        Pidro.Core.Player,
        Pidro.Core.Trick,
        Pidro.Core.GameState,
        Pidro.Core.Events,
        Pidro.Core.Binary
      ],
      "Game Engine": [
        Pidro.Game.Engine,
        Pidro.Game.StateMachine,
        Pidro.Game.Dealing,
        Pidro.Game.Bidding,
        Pidro.Game.Trump,
        Pidro.Game.Discard,
        Pidro.Game.Play,
        Pidro.Game.Replay,
        Pidro.Game.Errors
      ],
      "Finnish Variant": [
        Pidro.Finnish.Rules,
        Pidro.Finnish.Scorer
      ],
      "OTP Layer": [
        Pidro.Server,
        Pidro.Supervisor,
        Pidro.MoveCache
      ],
      Utilities: [
        Pidro.Notation,
        Pidro.Perf,
        Pidro.IEx
      ]
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script>
      // Add copy buttons to code blocks
      document.addEventListener('DOMContentLoaded', (event) => {
        document.querySelectorAll('pre code').forEach((block) => {
          const button = document.createElement('button');
          button.className = 'copy-button';
          button.textContent = 'Copy';
          button.addEventListener('click', () => {
            navigator.clipboard.writeText(block.textContent);
            button.textContent = 'Copied!';
            setTimeout(() => { button.textContent = 'Copy'; }, 2000);
          });
          block.parentNode.appendChild(button);
        });
      });
    </script>
    <style>
      .copy-button {
        position: absolute;
        top: 5px;
        right: 5px;
        padding: 4px 8px;
        font-size: 12px;
        background: #4CAF50;
        color: white;
        border: none;
        border-radius: 3px;
        cursor: pointer;
      }
      pre { position: relative; }
    </style>
    """
  end

  defp before_closing_body_tag(_), do: ""

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime dependencies
      {:typed_struct, "~> 0.3"},
      {:accessible, "~> 0.3"},

      # Test dependencies
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Dev/Test dependencies
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Dev-only dependencies
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end

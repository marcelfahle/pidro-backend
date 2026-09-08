defmodule PidroBackend.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        ignore_warnings: "dialyzer.ignore-warnings",
        list_unused_filters: true
      ],
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  # The EEF feed omits the fixed-version boundary for CVE-2026-32686.
  # The maintainer identifies 3.0.0 as fixed; our verified 3.1.1 includes
  # bounded parsing. Remove this exception when the feed is corrected:
  # https://github.com/ericmj/decimal/security/advisories/GHSA-rhv4-8758-jx7v
  # Pin the exception to the reviewed lock version so upgrades are audited.
  defp decimal_audit_exceptions do
    case Mix.Dep.Lock.read(Path.join(__DIR__, "mix.lock"))[:decimal] do
      {:hex, :decimal, "3.1.1", _, _, _, _, _} -> ["CVE-2026-32686"]
      _ -> []
    end
  end

  defp aliases do
    [
      precommit: [
        &hex_audit/1,
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --raise",
        &credo_diff/1,
        "dialyzer"
      ]
    ]
  end

  defp hex_audit(_args) do
    # Hex can initialize while loading an umbrella child, before the root
    # project settings apply. Pass the exception to a fresh audit process.
    {_, status} =
      System.cmd("mix", ["hex.audit"],
        into: IO.stream(),
        env: [
          {"MIX_ENV", Atom.to_string(Mix.env())},
          {"HEX_IGNORE_ADVISORIES", Enum.join(decimal_audit_exceptions(), ",")}
        ]
      )

    if status != 0, do: Mix.raise("Hex dependency audit failed")
  end

  defp credo_diff(_args) do
    if Mix.shell().cmd("ops/credo-diff") != 0 do
      Mix.raise("Credo found new high-priority issues")
    end
  end
end

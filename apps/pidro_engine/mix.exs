defmodule PidroEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :pidro_engine,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

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

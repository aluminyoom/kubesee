defmodule Kubesee.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/aluminyoom/kubesee"

  def project do
    [
      app: :kubesee,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "kubernetes event exporter - export k8s events to multiple sinks",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Kubesee.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:k8s, "~> 2.8"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:con_cache, "~> 1.1"},
      {:prom_ex, "~> 1.11"},
      {:plug_cowboy, "~> 2.7"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp aliases do
    [
      test: ["test --trace"]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end

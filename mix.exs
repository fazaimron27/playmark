defmodule Playmark.MixProject do
  use Mix.Project

  def project do
    [
      app: :playmark,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Playmark.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_ratatui, "~> 0.11"},
      {:ecto_sqlite3, "~> 0.17"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.0"}
    ]
  end
end

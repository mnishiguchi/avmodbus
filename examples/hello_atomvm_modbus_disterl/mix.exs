defmodule DisterlProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :disterl_probe,
      version: "0.1.0",
      elixir: "~> 1.19.0",
      deps: deps(),
      atomvm: [start: DisterlProbe]
    ]
  end

  def application, do: []

  defp deps do
    [
      {:avmodbus, path: "../.."},
      {:exatomvm, github: "atomvm/exatomvm", runtime: false},
      {:atomvm, "~> 0.7.0-beta.0", runtime: false},
      {:pythonx, "~> 0.4.0", runtime: false},
      {:req, "~> 0.7.0", runtime: false}
    ]
  end
end

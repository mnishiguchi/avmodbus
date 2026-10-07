defmodule SampleApp.MixProject do
  use Mix.Project

  def project do
    start_module =
      if System.get_env("MODBUS_RESOURCE_PROBE") in ["1", "true", "yes"],
        do: SampleApp.ResourceProbe,
        else: SampleApp

    [
      app: :sample_app,
      version: "0.1.0",
      elixir: "~> 1.19.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      atomvm: [start: start_module]
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:avmodbus, path: "../.."},
      {:exatomvm, github: "atomvm/exatomvm", runtime: false},
      {:atomvm, "~> 0.7.0-beta.0", runtime: false},
      {:pythonx, "~> 0.4.0", runtime: false},
      {:req, "~> 0.7.0", runtime: false}
    ]
  end

  defp aliases do
    [
      "atomvm.size": [
        "atomvm.packbeam",
        "cmd ../../scripts/check_avm_size.sh"
      ]
    ]
  end
end

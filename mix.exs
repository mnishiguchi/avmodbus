defmodule AVModbus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/piyopiyoex/avmodbus"

  def project do
    [
      app: :avmodbus,
      version: @version,
      elixir: "~> 1.19.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Modbus RTU, ASCII, and TCP library designed for AtomVM",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [
        summary: [threshold: 80],
        ignore_modules: [AVModbus.Test.DuplexTransport, AVModbus.Test.PTYTransport]
      ]
    ]
  end

  def application do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:atomvm, "~> 0.7.0-beta.0", optional: true, runtime: false},
      {:stream_data, "~> 1.1", only: :test, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib docs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE) ++
          ["examples/hello_atomvm_modbus/README.md"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", [filename: "readme", title: "AVModbus"]},
        {"docs/modbus-basics.md", [filename: "modbus-basics", title: "Modbus の基礎"]},
        {"docs/getting-started.md", [filename: "getting-started", title: "はじめ方"]},
        {"examples/hello_atomvm_modbus/README.md",
         [filename: "atomvm-example", title: "XIAO ESP32-C5 で試す"]},
        {"docs/development/hardware-tests.md",
         [filename: "atomvm-example-development", title: "実機での追加検証"]},
        {"docs/development.md", [filename: "development", title: "開発者ガイド"]},
        {"docs/architecture.md", [filename: "architecture", title: "アーキテクチャ"]},
        {"docs/compatibility.md", [filename: "compatibility", title: "動作確認済みの構成"]},
        "CHANGELOG.md",
        "LICENSE"
      ],
      source_ref: "main",
      groups_for_modules: [
        "Clients and servers": [
          AVModbus,
          AVModbus.Client,
          AVModbus.Server,
          AVModbus.Server.RTU,
          AVModbus.Server.ASCII,
          AVModbus.Server.TCP,
          AVModbus.Memory
        ],
        Encoding: [AVModbus.PDU, AVModbus.TCP, AVModbus.RTU, AVModbus.ASCII]
      ]
    ]
  end
end

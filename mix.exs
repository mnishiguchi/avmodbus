defmodule AVModbus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mnishiguchi/avmodbus"

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
      docs: docs()
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
      extras:
        [
          {"README.md", [filename: "readme", title: "AVModbus"]},
          "CHANGELOG.md",
          "LICENSE",
          "docs/ARCHITECTURE.md",
          "docs/ROADMAP.md",
          "docs/ARTIFACT_SIZE.md",
          "docs/MEMORY_FOOTPRINT.md",
          {"docs/adr/README.md", [filename: "adr", title: "Architecture decisions"]},
          {"docs/worklog/README.md", [filename: "worklog", title: "Worklog"]},
          {"examples/hello_atomvm_modbus/README.md",
           [filename: "atomvm-example", title: "AtomVM example"]}
        ] ++ Path.wildcard("docs/adr/0*.md"),
      source_ref: "v#{@version}",
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

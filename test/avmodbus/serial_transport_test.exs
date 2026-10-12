defmodule AVModbus.SerialTransportTest do
  use ExUnit.Case, async: true

  alias AVModbus.{Client, Serial, UART}
  alias AVModbus.Serial.Config
  alias AVModbus.Server.RTU, as: RTUServer

  defmodule ConfiguredTransport do
    @behaviour AVModbus.Serial.Transport

    def start_link(owner), do: Agent.start_link(fn -> owner end, name: __MODULE__)

    @impl true
    def open(options) do
      send(Agent.get(__MODULE__, & &1), {:serial_options, options})
      {:ok, :configured_handle}
    end

    @impl true
    def read(_handle, timeout_ms) do
      Process.sleep(timeout_ms)
      {:error, :timeout}
    end

    @impl true
    def write(_handle, _data), do: :ok

    @impl true
    def close(_handle), do: :ok
  end

  defmodule MissingOpenTransport do
    def open, do: {:ok, :legacy_handle}
  end

  test "passes per-instance serial options to transports that implement open/1" do
    {:ok, transport} = ConfiguredTransport.start_link(self())

    {:ok, client} =
      Client.start_link(ConfiguredTransport,
        transport: :rtu,
        serial: [speed: 19_200, bus: :secondary],
        gap: 0
      )

    assert_receive {:serial_options, [speed: 19_200, bus: :secondary]}
    assert Client.status(client) == :connected

    :ok = Client.stop(client)
    Agent.stop(transport)
  end

  test "passes per-instance serial options through the managed server" do
    {:ok, transport} = ConfiguredTransport.start_link(self())
    handler = fn _unit_id, _request -> {:ok, [0]} end

    {:ok, server} =
      RTUServer.start_link(ConfiguredTransport, handler,
        units: [1],
        serial: [speed: 38_400, bus: :secondary],
        gap: 0
      )

    assert_receive {:serial_options, [speed: 38_400, bus: :secondary]}
    assert RTUServer.status(server) == :connected

    :ok = RTUServer.stop(server)
    Agent.stop(transport)
  end

  test "requires the instance-aware open/1 transport callback" do
    assert Serial.open_transport(MissingOpenTransport, []) ==
             {:error, :transport_open_not_supported}

    assert Serial.open_transport(MissingOpenTransport, speed: 9_600) ==
             {:error, :transport_open_not_supported}

    assert Serial.open_transport("invalid", []) == {:error, :invalid_transport}
  end

  test "validates built-in UART instance options without opening hardware" do
    assert UART.validate_options(
             peripheral: "UART2",
             speed: 38_400,
             tx: 4,
             rx: 5,
             data_bits: 8,
             stop_bits: 1,
             parity: :even,
             rx_idle_timeout: 5
           ) == :ok

    assert UART.validate_options(speed: 0) ==
             {:error, {:invalid_serial_option, {:speed, 0}}}

    assert UART.validate_options(direction_pin: 6) ==
             {:error, {:invalid_serial_option, {:direction_pin, 6}}}

    assert UART.validate_options(rx_idle_timeout: 0) ==
             {:error, {:invalid_serial_option, {:rx_idle_timeout, 0}}}
  end

  test "derives RTU gap and receive silence from the same instance speed" do
    assert Config.defaults(:rtu, speed: 300) == {:ok, %{gap: 129, silence: 258}}
    assert Config.defaults(:rtu, speed: 115_200) == {:ok, %{gap: 2, silence: 20}}
    assert Config.defaults(:ascii, speed: 300) == {:ok, %{gap: 0, silence: 20}}
  end

  test "treats the configured RTU gap as a lower bound" do
    assert Config.effective_rtu_gap(5, 0) == 5
    assert Config.effective_rtu_gap(5, 1) == 5
    assert Config.effective_rtu_gap(5, 5) == 5
    assert Config.effective_rtu_gap(5, 6) == 6
  end
end

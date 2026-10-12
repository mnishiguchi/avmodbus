import Config

parse_integer = fn name, fallback ->
  case System.get_env(name) do
    value when is_binary(value) ->
      case Integer.parse(value) do
        {integer, ""} -> integer
        _ -> fallback
      end

    _ ->
      fallback
  end
end

uart_parity =
  case System.get_env("ATOMVM_UART_PARITY") do
    "even" -> :even
    "odd" -> :odd
    _ -> :none
  end

modbus_echo = System.get_env("MODBUS_ECHO") in ["1", "true", "yes"]
measure_memory = System.get_env("MODBUS_MEASURE_MEMORY") in ["1", "true", "yes"]
resource_probe = System.get_env("MODBUS_RESOURCE_PROBE") in ["1", "true", "yes"]
workflow_probe = System.get_env("MODBUS_WORKFLOW_PROBE") in ["1", "true", "yes"]

modbus_role =
  case System.get_env("MODBUS_ROLE") do
    "server" -> :server
    _ -> :client
  end

modbus_mode =
  case System.get_env("MODBUS_MODE") do
    "ascii" -> :ascii
    "tcp" -> :tcp
    _ -> :rtu
  end

serial = [
  peripheral: System.get_env("ATOMVM_UART_PERIPHERAL") || "UART1",
  speed: parse_integer.("ATOMVM_UART_SPEED", 9_600),
  tx: parse_integer.("ATOMVM_UART_TX_PIN", 23),
  rx: parse_integer.("ATOMVM_UART_RX_PIN", 24),
  data_bits: parse_integer.("ATOMVM_UART_DATA_BITS", 8),
  stop_bits: parse_integer.("ATOMVM_UART_STOP_BITS", 1),
  parity: uart_parity,
  rx_idle_timeout: parse_integer.("ATOMVM_UART_RX_IDLE_TIMEOUT_MS", 20)
]

# XIAO ESP32-C5: keep UART0 on D6/GPIO11 + D7/GPIO12 available for the
# AtomVM console, and route application Modbus traffic through UART1 on D4/D5.
config :avmodbus,
  uart_peripheral: serial[:peripheral],
  uart_speed: serial[:speed],
  uart_tx_pin: serial[:tx],
  uart_rx_pin: serial[:rx],
  uart_data_bits: serial[:data_bits],
  uart_stop_bits: serial[:stop_bits],
  uart_parity: serial[:parity],
  uart_rx_idle_timeout_ms: serial[:rx_idle_timeout],
  modbus_echo: modbus_echo,
  modbus_rtu_gap_ms: parse_integer.("MODBUS_RTU_GAP_MS", 0),
  modbus_silence_ms: parse_integer.("MODBUS_SILENCE_MS", 20),
  modbus_broadcast_turnaround_ms: parse_integer.("MODBUS_BROADCAST_TURNAROUND_MS", 100),
  modbus_handler_timeout_ms: parse_integer.("MODBUS_HANDLER_TIMEOUT_MS", 10_000),
  modbus_reconnect_backoff:
    {parse_integer.("MODBUS_RECONNECT_MIN_MS", 100),
     parse_integer.("MODBUS_RECONNECT_MAX_MS", 5_000)}

config :sample_app,
  modbus_role: modbus_role,
  modbus_mode: modbus_mode,
  modbus_serial: serial,
  modbus_tcp_host: System.get_env("MODBUS_TCP_HOST") || "127.0.0.1",
  modbus_tcp_port: parse_integer.("MODBUS_TCP_PORT", 502),
  modbus_unit_id: parse_integer.("MODBUS_UNIT_ID", 1),
  modbus_start_address: parse_integer.("MODBUS_START_ADDRESS", 0),
  modbus_quantity: parse_integer.("MODBUS_QUANTITY", 1),
  modbus_response_timeout_ms: parse_integer.("MODBUS_RESPONSE_TIMEOUT_MS", 1_000),
  modbus_request_interval_ms: parse_integer.("MODBUS_REQUEST_INTERVAL_MS", 5_000),
  modbus_health_interval_ms: parse_integer.("MODBUS_HEALTH_INTERVAL_MS", 0),
  resource_probe: resource_probe,
  resource_probe_cycles: parse_integer.("MODBUS_RESOURCE_PROBE_CYCLES", 3),
  resource_probe_connections: parse_integer.("MODBUS_RESOURCE_PROBE_CONNECTIONS", 4),
  workflow_probe: workflow_probe,
  workflow_probe_cycles: parse_integer.("MODBUS_WORKFLOW_PROBE_CYCLES", 3),
  workflow_probe_gap_ms: parse_integer.("MODBUS_WORKFLOW_GAP_MS", 20),
  measure_memory: measure_memory

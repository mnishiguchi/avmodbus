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

# XIAO ESP32-C5: keep UART0 on D6/GPIO11 + D7/GPIO12 available for the
# AtomVM console, and route application Modbus traffic through UART1 on D4/D5.
config :avmodbus,
  uart_peripheral: System.get_env("ATOMVM_UART_PERIPHERAL") || "UART1",
  uart_speed: parse_integer.("ATOMVM_UART_SPEED", 9_600),
  uart_tx_pin: parse_integer.("ATOMVM_UART_TX_PIN", 23),
  uart_rx_pin: parse_integer.("ATOMVM_UART_RX_PIN", 24),
  uart_data_bits: parse_integer.("ATOMVM_UART_DATA_BITS", 8),
  uart_stop_bits: parse_integer.("ATOMVM_UART_STOP_BITS", 1),
  uart_parity: uart_parity,
  modbus_echo: modbus_echo,
  modbus_silence_ms: parse_integer.("MODBUS_SILENCE_MS", 20),
  modbus_broadcast_turnaround_ms: parse_integer.("MODBUS_BROADCAST_TURNAROUND_MS", 100),
  modbus_handler_timeout_ms: parse_integer.("MODBUS_HANDLER_TIMEOUT_MS", 10_000),
  modbus_reconnect_backoff:
    {parse_integer.("MODBUS_RECONNECT_MIN_MS", 100),
     parse_integer.("MODBUS_RECONNECT_MAX_MS", 5_000)}

config :sample_app,
  modbus_role: modbus_role,
  modbus_mode: modbus_mode,
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
  measure_memory: measure_memory

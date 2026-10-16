import Config

parse_integer = fn name, default ->
  case Integer.parse(System.get_env(name) || "") do
    {value, ""} -> value
    _ -> default
  end
end

mode = if System.get_env("MODBUS_EXPERIMENT") == "disterl", do: :disterl, else: :transport
role = if System.get_env("MODBUS_ROLE") == "server", do: :server, else: :client
ping_payload_bytes = parse_integer.("DISTERL_PAYLOAD_BYTES", 0)

if ping_payload_bytes < 0 do
  raise ArgumentError, "DISTERL_PAYLOAD_BYTES must be a non-negative integer"
end

serial = [
  peripheral: System.get_env("ATOMVM_UART_PERIPHERAL") || "UART1",
  speed: parse_integer.("ATOMVM_UART_SPEED", 9_600),
  tx: parse_integer.("ATOMVM_UART_TX_PIN", 23),
  rx: parse_integer.("ATOMVM_UART_RX_PIN", 24),
  data_bits: 8,
  stop_bits: 1,
  parity: :none,
  rx_idle_timeout: 20
]

# Keep AtomVM's UART0 console free; use UART1 for Modbus on XIAO ESP32-C5.
config :avmodbus,
  uart_peripheral: serial[:peripheral],
  uart_speed: serial[:speed],
  uart_tx_pin: serial[:tx],
  uart_rx_pin: serial[:rx],
  uart_data_bits: serial[:data_bits],
  uart_stop_bits: serial[:stop_bits],
  uart_parity: serial[:parity],
  uart_rx_idle_timeout_ms: serial[:rx_idle_timeout],
  modbus_rtu_gap_ms: 0,
  modbus_silence_ms: 20

config :disterl_probe,
  mode: mode,
  role: role,
  serial: serial,
  unit_id: parse_integer.("MODBUS_UNIT_ID", 1),
  start_delay_ms: parse_integer.("MODBUS_START_DELAY_MS", 0),
  timeout_ms:
    parse_integer.("MODBUS_RESPONSE_TIMEOUT_MS", if(mode == :disterl, do: 500, else: 1_000)),
  poll_ms: parse_integer.("MODBUS_POLL_INTERVAL_MS", if(mode == :disterl, do: 20, else: 1_000)),
  node_alias: System.get_env("ATOMVM_NODE_ALIAS") || if(role == :server, do: "b", else: "a"),
  peer_alias: System.get_env("ATOMVM_PEER_ALIAS") || if(role == :server, do: "a", else: "b"),
  cookie: System.get_env("ATOMVM_COOKIE") || "AtomVM",
  ping_count: parse_integer.("DISTERL_PING_COUNT", 3),
  ping_delay_ms: parse_integer.("DISTERL_PING_DELAY_MS", 2_000),
  pong_timeout_ms: parse_integer.("DISTERL_PONG_TIMEOUT_MS", 15_000),
  ping_payload_bytes: ping_payload_bytes

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
chunk_payload_bytes = parse_integer.("MODBUS_CHUNK_PAYLOAD_BYTES", 96)
max_queued_bytes = parse_integer.("MODBUS_MAX_QUEUED_BYTES", 16_384)
max_queued_chunks = parse_integer.("MODBUS_MAX_QUEUED_CHUNKS", 256)
default_start_delay_ms = if mode == :disterl and role == :client, do: 3_000, else: 0
start_delay_ms = parse_integer.("MODBUS_START_DELAY_MS", default_start_delay_ms)

if ping_payload_bytes < 0 do
  raise ArgumentError, "DISTERL_PAYLOAD_BYTES must be a non-negative integer"
end

if chunk_payload_bytes < 1 or chunk_payload_bytes > 232 do
  raise ArgumentError, "MODBUS_CHUNK_PAYLOAD_BYTES must be between 1 and 232"
end

if max_queued_bytes < 1 do
  raise ArgumentError, "MODBUS_MAX_QUEUED_BYTES must be a positive integer"
end

if max_queued_chunks < 1 or max_queued_chunks > 65_535 do
  raise ArgumentError, "MODBUS_MAX_QUEUED_CHUNKS must be between 1 and 65535"
end

if start_delay_ms < 0 do
  raise ArgumentError, "MODBUS_START_DELAY_MS must be a non-negative integer"
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
  start_delay_ms: start_delay_ms,
  timeout_ms:
    parse_integer.("MODBUS_RESPONSE_TIMEOUT_MS", if(mode == :disterl, do: 500, else: 1_000)),
  bulk_timeout_ms: parse_integer.("MODBUS_BULK_RESPONSE_TIMEOUT_MS", 2_000),
  chunk_payload_bytes: chunk_payload_bytes,
  max_queued_bytes: max_queued_bytes,
  max_queued_chunks: max_queued_chunks,
  poll_ms: parse_integer.("MODBUS_POLL_INTERVAL_MS", if(mode == :disterl, do: 20, else: 1_000)),
  trace_transactions: System.get_env("MODBUS_TRACE_TRANSACTIONS") in ["1", "true"],
  node_alias: System.get_env("ATOMVM_NODE_ALIAS") || if(role == :server, do: "b", else: "a"),
  peer_alias: System.get_env("ATOMVM_PEER_ALIAS") || if(role == :server, do: "a", else: "b"),
  cookie: System.get_env("ATOMVM_COOKIE") || "AtomVM",
  ping_count: parse_integer.("DISTERL_PING_COUNT", 3),
  ping_delay_ms: parse_integer.("DISTERL_PING_DELAY_MS", 2_000),
  pong_timeout_ms: parse_integer.("DISTERL_PONG_TIMEOUT_MS", 15_000),
  ping_payload_bytes: ping_payload_bytes

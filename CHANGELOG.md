# Changelog

## 0.1.0

Initial development release:

- Modbus application protocol client and server support for the public function codes
- managed RTU and ASCII clients and servers over the AtomVM UART adapter
- managed Modbus TCP client with concurrent transactions and reconnect policy
- managed Modbus TCP server with isolated connections and bounded admission
- IPv4 and IPv6 literal support for managed Modbus TCP clients and servers
- OTP-supervised clients with raw PID and registered-name APIs
- OTP-supervised RTU, ASCII, and TCP servers with consistent lifecycle APIs
- unified `AVModbus.Server` startup and supervision facade across transports
- consistent tagged startup errors for options, handlers, and registered names
- opt-in retries for idempotent reads across transient timeout and disconnect errors
- per-request keyword options for synchronous timeout/retry and asynchronous delivery
- configurable client-wide default request timeout with per-request overrides
- deterministic zero-timeout probes when an immediate transmission requires no serial gap
- explicit fail-closed errors for unsupported Modbus/TCP Security options on AtomVM
- TCP half-close, reset, invalid-stream, and silent-peer recovery coverage
- sustained RTU/ASCII noise, checksum-corruption, fragmentation, and frame-burst stress coverage
- concurrent TCP client, pipelined request, and slow-handler load coverage
- repeated serial timeout, bad-CRC, disconnect, and reopen recovery coverage
- deadline-bounded exactly-once asynchronous results under serial and TCP queue pressure
- reproducible AtomVM production artifact-size check with a documented regression budget
- opt-in ESP32 memory probe and recorded RTU client/server footprint baseline
- configurable RTU, ASCII, and TCP client/server soak harness with resource bounds
- opt-in periodic ESP32 health telemetry for device soak runs
- bounded TCP client wait queues with explicit saturation and recovery behavior
- AtomVM-compatible TCP response and eviction paths without unavailable `Map.pop/2`
- opt-in ESP32 TCP socket/process/heap pressure and recovery probe
- sparse in-memory data model, diagnostics, broadcast, authorization, and device identification
- Modbus V1.1b3 application examples and malformed-frame conformance vectors
- property tests and bidirectional pymodbus TCP, RTU, and ASCII interoperability tests,
  including registered custom-function and generic-MEI PDUs
- bidirectional libmodbus TCP and RTU interoperability tests

The package targets AtomVM `v0.7.0-beta.0` and has no runtime dependencies.

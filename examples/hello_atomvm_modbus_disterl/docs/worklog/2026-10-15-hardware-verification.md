# Hardware verification — 2026-10-15

## Environment

- Host: Linux (Debian / LMDE), timezone Asia/Tokyo
- Board A / Client: XIAO ESP32-C5, `/dev/ttyACM1`, USB serial `38:44:BE:A5:05:14`
- Board B / Server: XIAO ESP32-C5, `/dev/ttyACM0`, USB serial `38:44:BE:A5:04:DC`
- AtomVM: `v0.7.0-beta.0+git.8d3e051` (`v0.7.0-beta.0-dirty` build info)
- ESP-IDF: `v5.5.5`
- 2 × HW-519, 2-wire RS485, 9,600 baud, 8N1
- UART1: TX GPIO23, RX GPIO24
- Modbus Unit ID 1, custom Function Code 100

`mix atomvm.esp32.info` identified both devices as ESP32-C5 and reported AtomVM installed.

## Phase 1 result

The Server queued three messages before receiving a request. The Client independently queued
three messages and initiated every physical transaction.

Server:

```text
disterl_probe: mode=transport role=server unit=1 function=100
disterl_probe: server ready; 3 replies queued independently
disterl_probe: server received "client message 1"
disterl_probe: server received "client message 2"
disterl_probe: server received "client message 3"
```

Client:

```text
disterl_probe: mode=transport role=client unit=1 function=100
disterl_probe: client started; 3 messages queued
disterl_probe: client received "server message 1"
disterl_probe: client received "server message 2"
disterl_probe: client received "server message 3"
disterl_probe: complete (3 ordered messages each way; all acknowledged)
```

Ordering and duplicate suppression were also covered by host tests. A lost response is modeled
by asking the unchanged sender state for its next packet; the encoded sequence and payload are
identical, and the receiver delivers that sequence only once.

## Timeout and recovery

The Server was built with `MODBUS_START_DELAY_MS=60000`. The Client was reset while the Server
had not opened UART1. It timed out four times, retained its in-flight sequence, and completed
without manual intervention after the Server became available.

```text
disterl_probe: client started; 3 messages queued
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: exchange failed :timeout; retrying
disterl_probe: client received "server message 1"
disterl_probe: client received "server message 2"
disterl_probe: client received "server message 3"
disterl_probe: complete (3 ordered messages each way; all acknowledged)
```

The Server then logged all three Client messages in order.

## Phase 2 result

`DisterlProbe.ModbusUART` was supplied to AtomVM `serial_dist` as `uart_module`. No AtomVM or
AVModbus core source was modified. The test used a 20 ms Client poll interval and a 500 ms
Modbus response timeout. Both boards were reset together before the measurement.

Client (`a@modbus.local`):

```text
modbus_disterl: sending ping 1 to :b@modbus.local
modbus_uart: queued bytes=32
modbus_uart: queued bytes=37
modbus_uart: delivered bytes=11
modbus_uart: delivered bytes=41
modbus_uart: queued bytes=29
modbus_uart: delivered bytes=25
modbus_uart: queued bytes=107
modbus_uart: delivered bytes=101
modbus_disterl: received pong 1 from :b@modbus.local rtt_ms=2671
modbus_disterl: first remote reply connection_ms=12840
modbus_disterl: sending ping 2 to :b@modbus.local
modbus_disterl: received pong 2 from :b@modbus.local rtt_ms=802
modbus_disterl: sending ping 3 to :b@modbus.local
modbus_disterl: received pong 3 from :b@modbus.local rtt_ms=802
modbus_disterl: complete 3 remote ping/pong messages
```

Server (`b@modbus.local`):

```text
modbus_uart: delivered bytes=32
modbus_uart: delivered bytes=37
modbus_uart: queued bytes=11
modbus_uart: queued bytes=41
modbus_uart: delivered bytes=29
modbus_uart: queued bytes=25
modbus_uart: delivered bytes=107
modbus_disterl: received ping 1 from :a@modbus.local
modbus_uart: queued bytes=101
modbus_disterl: received ping 2 from :a@modbus.local
modbus_uart: queued bytes=101
modbus_disterl: received ping 3 from :a@modbus.local
modbus_uart: queued bytes=101
```

The first ping was deliberately delayed 10 seconds after boot so both monitors could attach.
Therefore `connection_ms=12840` includes that 10-second delay. The first RTT includes the
distribution handshake; the later 802 ms values represent the observed steady-state remote
message round trip in this configuration.

After the messages, both sides continued to exchange 10-byte `serial_dist` tick frames for the
remainder of the 45-second observation without a crash or UART error.

## Integration findings

- The virtual UART approach is suitable: `serial_dist` already allows a custom `uart_module`.
- The adapter must implement both `read(handle)` and `read(handle, :infinity)`; the latter is
  used during `dist_util` handshake receive.
- A timed-out handshake can leave a blocked virtual read owned by a controller that exits. The
  adapter replaces that stale reader when the link manager starts its next read.
- A dedicated `modbus_dist` carrier is not required for this proof of concept.
- Independent board reboot is not yet robust because the FC-100 header has no boot/session ID.
  An observed symptom is `:invalid_acknowledgment` until both endpoints are reset. A future
  carrier should add session negotiation and explicit resynchronization.
- AtomVM's fixed 7-second distribution setup timer and Modbus's request/response latency are the
  main timing constraint. The verified 20 ms poll interval completed the handshake in time.
- PackBEAM reported `erlang:phash2/2` in generated Elixir `GenServer` error-reporting code. The
  verified normal paths did not enter that unsupported code, but it remains a build-time warning.

The session and independent-reboot limitation recorded here was addressed in a follow-up experiment.
See [Session-aware reboot recovery — 2026-10-16](2026-10-16-session-recovery.md).

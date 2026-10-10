# AtomVM ESP32-C5 TCP hard-limit report

This document records a runtime blocker found while testing AVModbus resource
exhaustion. It is written so that the observations can be transferred to an
AtomVM issue without presenting the failure as an AVModbus error.

## Summary

On a Seeed Studio XIAO ESP32-C5, bounded Modbus/TCP pressure completes and
recovers repeatedly. Increasing socket pressure beyond that known-good case
does not return a recoverable socket resource error to Elixir. The observed
failure is instead either a timer-manager timeout followed by application
termination, or an ESP-IDF native abort.

The hard-limit test therefore cannot yet establish AVModbus behavior for
`:emfile`, `:enfile`, `:enobufs`, `:enomem`, or `:system_limit` on this target.
For the current official runtime, this is recorded as a platform limitation:
AVModbus cannot recover from an error that is never returned. The project
acceptance boundary is the repeatedly recovered four-client device control plus
the host-OS exhaustion tests, where the runtime does return `:emfile`. The
roadmap item is resolved at that boundary and must be reassessed if an official
AtomVM image changes the relevant runtime path.

## Environment

- Board: Seeed Studio XIAO ESP32-C5
- Runtime reported at boot: AtomVM `0.7.0-beta.0+git.8d3e051`
- Firmware image:
  `examples/hello_atomvm_modbus/firmware_images/AtomVM-esp32c5-elixir-v0.7.0-beta.0.img`
- Firmware SHA-256:
  `2fcf4c8aa3c3df5c7a0c6a4be18fc437342baf6765e355ea75275ba7b89e38ad`
- Transport: TCP loopback, `127.0.0.1`, using AtomVM's ESP32 socket driver
- Application: the production example's compile-time resource probe

The nearby AtomVM source checkout used to inspect the socket event path was
`cccd8fbcf32a333f5bb0d231a277c7511ce2499c`. It is not the exact firmware
revision and must not be used to symbolize the address below.

## `release-0.7` target audit

AVModbus targets AtomVM's
[`release-0.7`](https://github.com/atomvm/AtomVM/tree/release-0.7) branch. On
2026-10-11 its head was `1f37255903c34909c06c83f866810ff9f9e43a8a` (commit
date 2026-10-04). The installed beta.0 firmware commit
`8d3e051bce9652ac1d9f52ef32b0a5f8b5fc0d65` is an ancestor of that head.

There are four commits between them: version metadata and a MAP_EXT key-order
fix. `socket_driver.c`, the ESP32 event-queue implementation, the timer manager,
and scheduler timer code are unchanged. In particular, the installed firmware
already contains the earlier ESP32 socket-lock fixes from `e1c74523` and
`dc60886f`.

The official
[`v0.7.0-beta.0` release](https://github.com/atomvm/AtomVM/releases/tag/v0.7.0-beta.0)
publishes ESP32-C5 images and checksums but no matching ELF, map, or debug-symbol
asset. Reflashing the current branch head would therefore not exercise a newer
socket path, while rebuilding is still required to obtain trustworthy symbols.
The hard-limit blocker is current for the target branch until that path changes
or a symbol-bearing reproduction identifies the native failure.

Normal AVModbus device testing remains pinned to that official image. A locally
built runtime is useful only for upstream native-crash diagnosis because it can
retain a matching ELF and map; it is not interchangeable with the release
artifact and is not acceptance evidence for this roadmap item.

## Known-good control

The repository retains a bounded, repeatable probe. Build and flash it with:

```sh
cd examples/hello_atomvm_modbus
MIX_ENV=prod mix clean
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod mix atomvm.packbeam
MODBUS_RESOURCE_PROBE=true MIX_ENV=prod \
  mix atomvm.esp32.flash --port /dev/ttyACM0
mix atomvm.esp32.monitor --port /dev/ttyACM0
```

The default probe warms up the network stack, then runs three cycles with four
managed clients. Each client has three accepted requests and one expected
`:queue_full` result. Every cycle returned to four processes:

| Cycle | Process count (before/peak/after) | Free heap in bytes (before/peak/after) |
| --- | --- | --- |
| 1 | `4 / 27 / 4` | `136088 / 116784 / 135532` |
| 2 | `4 / 27 / 4` | `135368 / 116072 / 134808` |
| 3 | `4 / 27 / 4` | `134652 / 116028 / 134772` |

The largest free block remained at 86,016 bytes after warm-up, and the probe
finished with `modbus_resource_probe result=ok cycles=3`.

This is the control case: AVModbus's bounded queue, request completion, process
cleanup, and heap recovery all work under pressure.

The retained production probe fails closed before opening a socket when
`MODBUS_RESOURCE_PROBE_CONNECTIONS` is outside `1..4`, or when the cycle count
is not positive. This prevents an ordinary configuration change from crossing
the known-safe boundary. Hard-limit experiments require a temporary diagnostic
build so their risk is explicit.

## Host OS exhaustion control

An opt-in Linux test runs AVModbus in a subprocess with a 64-descriptor soft
limit and opens loopback listeners until the OS returns `:emfile`. It verifies
both sides of the library contract:

- the managed TCP client exposes `{:disconnected, :emfile}`, reconnects after
  descriptors are released, and completes a Modbus request;
- TCP server startup returns `{:error, :emfile}`, then starts normally after
  descriptors are released.

Run the control with:

```sh
RESOURCE_EXHAUSTION_TEST=true mix test \
  test/avmodbus/tcp_resource_exhaustion_test.exs
```

This demonstrates AVModbus recovery when the runtime returns a resource error.
It does not close the AtomVM item because the ESP32 runtime still aborts or
loses timer-service responsiveness before returning an equivalent error.

## Hard-limit observations

Temporary diagnostic variants were used to raise socket pressure. They were
removed after testing because they can leave the board's USB CDC console
unresponsive until a physical USB power cycle.

### Concurrent managed-client startup

Starting eight managed loopback clients concurrently did not return a socket
resource error. A call to AtomVM's timer manager timed out after five seconds,
then the application terminated.

### Sequential socket pressure

Sequential managed-client creation also failed to produce a recoverable
resource error and caused loss of the USB CDC console before a useful error
could be captured.

A lower-level loopback socket variant reached an ESP-IDF `abort()` at program
counter `0x4201fa15`. The installed firmware directory does not contain the
matching symbol-bearing ELF, so that address cannot be resolved reliably.

In none of these runs did Elixir receive one of the expected hard-limit errors:
`:emfile`, `:enfile`, `:enobufs`, `:enomem`, or `:system_limit`.

## Related socket event warning

Closing several loopback sockets can print either of these messages:

```text
socket: failed to enqueue: ... to netconn_events.
socket: failed to enqueue: ... to event_queue.
```

Those strings are present in the installed firmware. In the inspected AtomVM
source, the ESP32 socket callback uses a 32-entry `netconn_events` FreeRTOS
queue and forwards notification through the platform's 16-entry `event_queue`.
The warning is therefore consistent with bounded platform event-queue
backpressure.

The warning also occurs in the known-good three-cycle probe, where process and
heap recovery succeed. It should not by itself be treated as evidence of an
AVModbus resource leak. The hard-limit abort and timer-manager failure are the
unresolved behaviors.

## Expected behavior

Socket creation or connection should return a documented, recoverable error
when the runtime or network stack reaches its resource limit. The scheduler,
timer manager, existing processes, and console should remain responsive, so an
application can release resources and continue or restart under supervision.

## Safe reproduction requirements

- Use a spare or physically accessible board; the failure may require removing
  and reconnecting USB power.
- First run the retained four-client probe and confirm the known-good control.
- Increase pressure only by changing the guard in a temporary diagnostic
  build, not in the production example or on both boards at once.
- Keep one board on the normal image so RS485 client/server recovery remains
  available.
- Capture the complete serial log and retain the exact symbol-bearing ELF for
  the flashed AtomVM image.
- Resolve `0x4201fa15` only against that matching ELF, then inspect the failing
  native path before changing AVModbus behavior.

## Re-evaluation trigger

1. Keep normal compatibility and bounded-resource tests on the official
   `v0.7.0-beta.0` image.
2. When an official image changes the relevant socket, event-queue, or timer
   path, reopen this boundary and repeat the managed-client hard-limit run.
3. If upstream crash diagnosis is pursued independently, build a one-off runtime
   with a matching ELF/map, reproduce on one board, and symbolize the complete
   ESP-IDF backtrace. Do not use that local image as roadmap acceptance evidence.
4. Determine whether queue saturation, lwIP allocation failure, or timer
   service starvation prevents the native layer from returning an error.
5. Record the returned error and verify that AVModbus releases resources and
   resumes requests without rebooting on an official image.


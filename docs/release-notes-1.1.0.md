# DWI 1.1.0 — release notes

Status: **prepared 2026-11-17; not yet published to pub.dev.**

DWI 1.1.0 adds named ports (ADR-032). It is additive: no API from 1.0.0 is removed or
changed, and the protocol is unchanged (version 2), so worker artefacts do not need a
rebuild.

## What is new

- `Dwi.createPort(name, {scope, listeners, bufferSize})` and `Dwi.port(name)` manage
  named host ports.
- `DwiPortScope.hostOnly` keeps a port to host code. `DwiPortScope.workers` lets a
  worker reach it by name.
- `DwiPortListeners.single` allows one listener. `DwiPortListeners.broadcast` lets every
  listener receive each message delivered after it listens.
- `DwiPort.send` copies a value; `DwiPort.sendBytes` transfers bytes (ADR-010).
- `DwiWorker.bindPort(port)` returns a `DwiPortBinding`. Task code in that worker calls
  `DwiWorkerChannels.find('port:<name>')`.

## Delivery rules

- Messages are never dropped, coalesced or reordered.
- A full listener queue makes the sender wait, in both listener modes.
- With no listener, a host port holds up to `bufferSize` messages and then throws
  `DwiChannelBufferException`.
- A host `send` on a `workers` port with no bound worker throws `DwiChannelStateException`.
- Port names are at most 58 characters.

## Limits

- No `SendPort`/`ReceivePort` objects. A port is a registry entry, not a transferable
  object (limitation 3 and ADR-032).
- Ports exist only in the host process; a worker reaches one only through a binding.
- A bound worker that is closed or fails ends its binding with the error that ended the
  worker.
- A port does not survive a page reload.

## Evidence

- Unit tests for the port core: `packages/dwi_core/test/port_test.dart` (21 tests).
- Facade tests with real workers: `packages/dwi/test/named_port_test.dart` (6 tests).
- Browser tests: `packages/dwi_builder/test/browser_named_port_test.dart`, all sixteen
  cells (host dart2js or dart2wasm, worker dart2js or dart2wasm) in Chrome, Safari,
  Firefox and Edge. Run on macOS 26.5.1 arm64.

## Upgrade notes

- No action is needed. Rebuilding worker artefacts is optional.

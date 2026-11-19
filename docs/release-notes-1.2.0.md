# DWI 1.2.0 — release notes

Status: **released 2026-11-19. All eight packages at 1.2.0.**

DWI 1.2.0 adds callback-scoped ports (ADR-033). It is additive: no API from 1.1.0 is
removed or changed, and the protocol is unchanged (version 2).

## What is new

- `Dwi.withPort(name, body, {listeners, bufferSize})` creates a host-only port for one
  callback and closes it when the callback returns, throws, or fails.
- `DwiWorker.withPort(name, body, {listeners, bufferSize})` binds that port to the
  handle you pass before the callback runs. The worker keeps running afterwards.
- A name that is already open throws `DwiChannelStateException`; the first port is not
  closed.
- If the worker stops or the binding fails while the callback waits, the scope fails
  with a typed error. A callback error is the result, and cleanup does not replace it.

## Fixes

- A worker stop or failure fails a port binding even while the host listener is paused
  by backpressure (ADR-033 precondition).

## Upgrade notes

- No action is needed. `dwi` 1.2.0 requires `dwi_core` 1.2.0.

## Evidence

- Core: `packages/dwi_core/test/port_scoped_probe_test.dart` (backpressure and close
  ordering probes) and the existing port tests.
- Facade: `packages/dwi/test/scoped_port_test.dart` (14 tests), including worker failure,
  paused delivery, manual close and same-name races.
- Browser: `packages/dwi_builder/test/browser_scoped_port_test.dart`, all sixteen cells
  in Chrome 158, Safari 26.5, Firefox 160 and Edge 157 (see `docs/browser-matrix.md` §10).
- Regression: `browser_named_port_test.dart` (ADR-032) still passes.

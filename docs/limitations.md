# Limitations

Known gaps, stated plainly. This file is part of the public contract: if a
limitation is not here or in `compatibility-matrix.md`, that is a bug.

## Semantic limitations

1. **No closure or function-value execution.** Work is selected by task name from
   a precompiled registry. `Dwi.run(() => ...)` does not exist. This is the
   largest difference from `Isolate.run` (R004 §2).
2. **No shared mutable Dart state, and no shared immutable state either.** Every
   payload is copied or transferred; there is no equivalent of the VM's canonical
   object sharing (R001 §2, R003 §3).
3. **No `SendPort`/`ReceivePort`.** A later port model can only be an emulation
   over one transport, with logical IDs (R001 §3, R003 §5).
4. **`kill` is `terminate()`.** No pause, resume, `Isolate.ping`, or graceful
   `Isolate.exit`; in-flight work and queued work are lost.
5. **Startup cost is paid per worker.** Pooling amortises it; there is no
   zero-cost spawn (M001, R003 §7).
6. **Errors are reconstructed, not propagated.** A `DwiRemoteException` carries
   what the worker captured; the local stack trace is the host side only.

## Engineering limitations

7. **Worker compilation is a separate build step.** `flutter build web` compiles
   one entrypoint; DWI requires a compiled worker artefact and a served path
   (R002 §4, R007).
8. **JS backend only in v0.2.** Wasm requires a `.wasm` + `.mjs` loader pair and a
   module worker (R005). No Wasm support is claimed.
9. **Serialization is structural.** Custom classes need generated or hand-written
   codecs; structured clone loses prototypes (R003 §3, R006).
10. **Payload and queue limits are mandatory.** Large payloads and deep queues are
    rejected rather than allowed to exhaust the worker (protocol §Security).
11. **Only Chrome has been measured.** Firefox, Safari and Edge are unverified
    (M001_FINDINGS, docs/browser-matrix.md).
12. **No Flutter `compute()` integration.** Changing Flutter's web `compute()`
    is an upstream proposal, not a package feature.

## Operational limitations

13. **CSP and hosting matter.** Worker scripts need `worker-src` permission and a
   same-origin (or CORS) URL. Blob workers are not supported by design.
14. **No cross-origin isolation requirement for the JS backend**, but any future
   shared-memory work would require COOP/COEP and change deployment.
15. **Stale artefacts are fatal by design.** A missing or outdated worker build
   fails loudly; DWI never silently falls back to the main thread.

## Research debt (unresolved, tracked)

- Generated-registry tree shaking (R004 unresolved).
- ESM output from `dart compile js` for module workers.
- WasmGC and `js-string` browser support matrix.
- Worker memory limits on mobile browsers.
- Flutter Wasm runtime inside a worker.

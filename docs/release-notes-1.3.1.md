# DWI 1.3.1 release notes

Date: 2026-11-24. Patch release. No public API change and no protocol change, so
worker artefacts need no rebuild.

## What changed

- **Cyclic raw payloads fail with a path.** `dwi_web` walks raw web payloads with
  an identity set of the collections currently being visited, so a cycle through
  lists, maps and sets throws `DwiSerializationException` naming the entry that
  closes it instead of recursing until the stack overflows. `validateDwiPayload`
  is internal (`lib/src/payload.dart`, not exported), so this is a behaviour fix
  only. Verified in `packages/dwi_web/test/payload_test.dart`, including a
  list → map → set cycle and a repeated reference that is not a cycle.
- **Web argument and header regression test.** `packages/dwi_builder/test/browser_payload_types_test.dart`
  now asserts `crossOriginIsolated` in both realms, an ordinary argument at the
  configured budget boundary, `DwiSerializationException` for oversized inputs,
  oversized results and cyclic inputs, and a successful call after those
  rejections. All four host and worker pairings pass in Chrome 158.0.8127.88,
  Edge 158.0.4370.33, Firefox 160.0 and Safari 26.5. Each realm reported
  `crossOriginIsolated: false`, so none of these paths needs COOP/COEP.
  Recorded in `docs/browser-matrix.md`.
- **Wasm hosts, headers and payload budget documented.** The `dwi` and `dwi_web`
  READMEs cover `dart compile wasm` and `flutter build web --wasm`, the module
  loader, COOP/COEP, worker MIME types and CSP, and the configurable 64 MiB
  `DwiConfig.maxPayloadBytes` budget. `docs/serialization.md` now separates raw
  wire values from generated-code conversion and states the estimate; `docs/limitations.md`
  points at it.
- **`tooling/mobile_probe` compiles again.** The probe imports
  `package:material_ui/material_ui.dart` but did not declare the dependency, so
  analysis reported unresolved Flutter types. The dependency is now declared.
- **All eight packages aligned at 1.3.1.** `dwi_annotations`, `dwi_builder`,
  `dwi_core`, `dwi_flutter`, `dwi_native` and `dwi_protocol` carry the version
  only; `dwi_builder` also extends its browser payload fixture to the boundary and
  isolation assertions. No API change in any of the six.

## Not in this release

- **No API or protocol change.** `dwi_web` exports `WebBackend` and
  `WebWorkerHandle`; the payload validator stays internal.
- **No performance claim.** `DwiConfig.maxPayloadBytes` is still an estimate, not
  an exact wire size, and no timing or memory benchmark was run.
- **Native (VM) payload rules are unchanged.** Cycles remain reachable only
  through the VM's own isolate sendability rules.

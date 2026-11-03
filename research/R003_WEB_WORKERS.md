# R003 — Browser Workers

Status: research report · Agent: 4 (Browser workers) · Evidence: WHATWG/MDN
pages fetched 2026-11-03, `package:web` 1.1.2 in the local pub cache
(`/Users/christophechanteur/.pub-cache/hosted/pub.dev/web-1.1.2`).

Sources are named explicitly. Claims about *current engine support* are marked
**UNVERIFIED** unless a page was fetched; no version numbers are invented.

## Summary

- A dedicated `Worker` is the only worker type that gives CPU work its own
  thread with a private global scope; `SharedWorker` shares one scope between
  documents, and `ServiceWorker` is an event-driven network proxy with a
  lifetime controlled by the browser.
- Workers are constructed from a URL. The script is subject to CSP
  (`worker-src`, falling back to `script-src`/`child-src`) and to the page's
  origin rules; cross-origin script loads now surface as an `error` event rather
  than a synchronous `SecurityError` (MDN, Worker, "Cross-origin worker error
  behavior").
- `postMessage` uses the structured clone algorithm. Functions, DOM nodes and
  class prototypes are not cloned; `DataCloneError` is thrown for uncloneable
  values (MDN, structured clone algorithm).
- Transferables move ownership instead of copying. For `ArrayBuffer` the memory
  is moved zero-copy and the source buffer is detached (MDN, transferable
  objects). `MessagePort` and `OffscreenCanvas` are also transferable.
- `SharedArrayBuffer` requires a secure context **and** cross-origin isolation
  (`crossOriginIsolated`), which is created by COOP/COEP headers (MDN,
  SharedArrayBuffer).
- Dart reaches all of this through `package:web` extension types, with no
  wrapper required: `Worker` factory (`html.dart:12804`), `WorkerOptions`
  (`:12836`), `WorkerGlobalScope` (`:12461`), `DedicatedWorkerGlobalScope`
  (`:12659`, `postMessage` at `:12682`), `MessagePort.postMessage` (`:12372`),
  `StructuredSerializeOptions` (`:12394`), `navigator.hardwareConcurrency`
  (`:11957`, worker-side `:13058`).

## 1. Worker types

| Type | Global scope | Lifetime | Use for CPU work |
| --- | --- | --- | --- |
| `Worker` (dedicated) | private to one document | until terminated / page closed | **yes** — the initial DWI backend |
| `SharedWorker` | shared by same-origin documents | while any client is connected | possible, but adds addressing complexity |
| `ServiceWorker` | event-driven, no DOM | browser-managed | no — network/proxy semantics |
| Worklet | tiny, render/audio-specific | tied to rendering | no — not general compute |

MDN positions `Worker` as the primitive for running scripts in background
threads; the other types are listed as "other kinds of workers" (MDN, Worker).

## 2. Construction, loading, CSP

`package:web` (`html.dart`):

```dart
external factory Worker(JSAny scriptURL, [WorkerOptions options]);   // :12804
external factory WorkerOptions({String type, String name, ...});     // :12836
```

`type: 'module'` creates a module worker; the default is a classic script.
Consequences:

- **Classic worker**: can use `importScripts()`; the script must be a single
  file (or import scripts explicitly).
- **Module worker**: can use ES `import`; needed to load a dart2wasm `.mjs`
  loader (R005).
- URL resolution is relative to the *document* for the constructor, and relative
  to the *worker script* for imports/fetches inside the worker. DWI must resolve
  worker URLs against the app base URL, not the current route.
- CSP: worker script loading is governed by `worker-src` (falling back to
  `child-src`, then `script-src`). A `blob:` worker needs `worker-src blob:`.
- Cross-origin: the worker script must be same-origin or CORS-enabled; modern
  engines report failures through the worker's `error` event rather than a
  synchronous throw (MDN, Worker).
- `blob:` and `data:` workers exist, but they complicate CSP and debugging;
  DWI should prefer a real URL served from the app.

**UNVERIFIED**: exact CSP fallback order per engine; test per browser in M001.

## 3. Messaging and structured clone

The structured clone algorithm supports, per MDN (structured clone algorithm):

- primitives (`null`, `undefined`, booleans, numbers, bigints, strings),
- `Array`, plain objects, `Map`, `Set`, `Date`, `RegExp`, `ArrayBuffer`,
  `DataView`, typed arrays, `Blob`, `File`, `FileList`, `ImageData`, `Error`
  types, `MessagePort` (transferable), `ReadableStream`/`WritableStream`/
  `TransformStream` in supporting engines.

It does **not** clone:

- functions (throws `DataCloneError`),
- DOM nodes (throws `DataCloneError`),
- class prototypes: "The prototype chain is not walked or duplicated",
- property descriptors, getters/setters, class private fields,
- symbols, `WeakMap`/`WeakSet`.

Dart mapping:

| Dart value | Structured clone result |
| --- | --- |
| `num`, `bool`, `String`, `null` | survives |
| `List`, `Map` (literal-shaped) | survives as JS array/object, loses Dart types |
| `Uint8List` | survives as a typed array (and can be transferred) |
| custom class instance | becomes a plain object; methods and type are lost |
| closure / function tear-off | `DataCloneError` |
| `SendPort`-like capability | no equivalent; use a transferred `MessagePort` or an ID |

This is why DWI must define its own envelope and encode payloads; “send any Dart
object” is not a thing the browser offers.

## 4. Transferables

MDN (transferable objects):

- `ArrayBuffer` transfer moves the memory zero-copy and detaches the source;
  the original buffer becomes unusable.
- Other transferable objects may be copied then removed from the old context.
- Supported list includes `ArrayBuffer`, `MessagePort`, `OffscreenCanvas`,
  `ImageBitmap`, `ReadableStream`/`WritableStream`/`TransformStream`.

API shape in `package:web`:

```dart
external void postMessage(JSAny? message, [JSObject optionsOrTransfer]);  // Worker :12826
external void postMessage(JSAny? message, [JSObject optionsOrTransfer]);  // DedicatedWorkerGlobalScope :12682
```

`optionsOrTransfer` is typically `StructuredSerializeOptions(transfer: [...])`
(`html.dart:12394`).

DWI consequence: a `Uint8List` result can cross without a copy, but ownership
transfers — the sender must not touch it afterwards. That is close to Dart's
`TransferableTypedData` single-use rule (R001), and a good primitive to expose.

## 5. Ports and `MessageChannel`

- `MessagePort` is transferable; `MessageChannel` creates two entangled ports.
- Once transferred, the port works in the other realm and can be used for
  bidirectional traffic without routing through `window`.
- A port cannot be cloned repeatedly like a VM `SendPort`; once transferred it
  is gone from the sender.
- For DWI's port model this means: model logical ports as IDs routed through one
  transport, and optionally upgrade to a real `MessageChannel` per long-lived
  channel.

## 6. Errors and lifecycle

`package:web` exposes `Worker` as an `EventTarget` (`html.dart:12803`), so:

- `error` event: script failed to load / uncaught error in the worker.
- `messageerror`: a message arrived that could not be deserialised.
- `terminate()`: abrupt; in-flight work is discarded, no cleanup code runs.
- `self.close()` inside the worker: orderly termination, but the parent only
  observes it indirectly (no standard "closed" event on `Worker`).
- An unhandled promise rejection inside a worker is not reliably reported to the
  parent; the worker runtime must catch it.

DWI consequence: the protocol needs its own `ready`, `error`, `closed` and
`heartbeat` messages; the platform events alone are insufficient (R007/R010).

## 7. Concurrency limits

- `navigator.hardwareConcurrency` (`html.dart:11957`, worker-side `:13058`)
  reports logical cores; MDN notes it is a hint and can be capped or inaccurate.
- Practical guidance: pool size `min(hardwareConcurrency - 1, configuredMax)`,
  because the main thread also needs a core. Do not spawn one worker per task.
- Worker startup is a script fetch + compile + realm creation; for a Dart
  payload this includes the full compiled runtime (R004). Reuse workers.
- **UNVERIFIED**: memory ceiling per worker, mobile Safari limits, and actual
  startup timings on this machine — M001 measures startup and message latency.

## 8. Capabilities inside a worker

Available in `DedicatedWorkerGlobalScope`: `fetch`, `WebAssembly`, `crypto`,
`IndexedDB`, `CacheStorage`, `OffscreenCanvas`, `performance`, `setTimeout`,
`postMessage`, `close`, `importScripts` (classic only).

Not available: `document`, `window`, DOM manipulation, `localStorage` (use
`IndexedDB`), `alert`, synchronous XHR.

## 9. Constraints that shape DWI

1. Worker payloads must be encoded, not passed as Dart objects.
2. Worker scripts must be served from a resolvable URL and satisfy CSP.
3. A worker must own its lifecycle: ready handshake, error envelope, heartbeat,
   and explicit termination.
4. Transferables are the only zero-copy path; everything else is copied.
5. Module workers are required for the Wasm loader and are preferable for
   ESM-based tooling; classic workers remain the simplest for dart2js output.
6. `hardwareConcurrency` is a hint; the pool must be configurable.

## Unresolved

- Exact per-engine CSP fallback behaviour and error surfaces.
- Whether `messageerror` fires for uncloneable sends in all engines, or whether
  the sender gets a synchronous `DataCloneError`.
- Worker memory limits on mobile browsers.
- Whether a dedicated worker can be reused after `terminate()` (it cannot; a new
  `Worker` is required) — treated as settled by spec, not measured here.

## Verification status

- **Verified**: `package:web` declarations and line numbers; MDN statements on
  structured clone, transferables, SharedArrayBuffer isolation, cross-origin
  worker errors.
- **Unverified**: engine-specific CSP behaviour, memory limits, startup cost.
- **Could not determine**: any browser API not exposed by `package:web` 1.1.2 —
  the surface was checked only for the declarations cited above.

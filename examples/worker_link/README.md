# Worker link

Connects two dedicated `DwiWorker` handles with `DwiWorker.link` (ADR-023,
since 0.10.0). Task code in each worker finds its end of the link by name with
`DwiWorkerChannels.find`, and the host relays the messages. A slow reader
paces an awaiting writer instead of failing it. This example runs on native
isolates; the same API works in browser workers.

```bash
cd examples/worker_link
dart pub get
dart run bin/main.dart
```

Expected output:

```text
sent 100 squares, consumer summed 338350
```

The link is relayed through the host, so every message is copied once more
than on a direct channel. It is not a transferred `SendPort`: see
`docs/limitations.md` §36.

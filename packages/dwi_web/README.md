# dwi_web

Run DWI work in dedicated browser workers compiled to JavaScript or Wasm.

Most apps should use [dwi](https://pub.dev/packages/dwi) for cross-platform
selection. To use this backend directly, add `dwi_web` and `dwi_core` to
a web host project. Declare and compile a task named `sum` following the
[dwi_builder](https://pub.dev/packages/dwi_builder) quick start. The example
expects a single integer input. Create `lib/tasks.dart` with:

```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int sum(int n) => n * (n + 1) ~/ 2;
```

Copy the basic example into the host project as `lib/main.dart`. Run
`dart compile js -o web/main.dart.js lib/main.dart`, add
`<script defer src="main.dart.js"></script>` to `web/index.html`, and
serve the `web/` directory over HTTP. Open the browser console for the
result. Serve worker assets from the same origin.

The advanced example uses a dedicated handle and sends repeated calls to
one worker context. Choose Wasm using `DwiWorkerBackend.wasm` and the
matching generated entry asset. See the Wasm deployment example linked
from the dwi guide for MIME and CSP settings. The dispatcher and runtime
exports serve custom worker integration. The standard builder generates
that wiring for the application.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_web/example/dwi_web_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)

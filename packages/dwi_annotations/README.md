# dwi_annotations

Declare tasks and transferable payload shapes for the DWI generator.

Add `dwi_annotations` as an app dependency and set up
[dwi_builder](https://pub.dev/packages/dwi_builder). Put annotated
declarations in `lib/` so the builder can discover them.

```dart
import 'package:dwi_annotations/dwi_annotations.dart';

@DwiTask()
int doubleIt(int value) => value * 2;
```

Run `dart run dwi_builder:dwi build`; then import `dwi_tasks.g.dart` and
call `await DwiTasks.doubleIt(21)`.

Tasks are public top-level functions or eligible public static methods.
Use zero arguments or one required positional argument. Use a record to
group several inputs. `@DwiTask(name: '...')` changes the runtime task name.
Annotations mark declarations for generation. The Example tab's basic
program calls them directly to show their return values.

The advanced example adds a static task, a record, a stream and a
`@DwiPayload` class. Payload classes need a public unnamed constructor and
a matching public field or getter for each constructor parameter. The
generator reconstructs the value on the receiving side.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_annotations/example/dwi_annotations_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)

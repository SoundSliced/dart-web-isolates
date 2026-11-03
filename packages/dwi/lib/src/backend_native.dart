import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_native/dwi_native.dart';

/// Creates the isolate-backed backend. Selected when `dart:io`-style isolates
/// are available (native VM).
DwiBackend createBackend(DwiTaskRegistry registry) => NativeBackend(registry);

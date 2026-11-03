import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_web/dwi_web.dart';

/// Creates the worker-backed backend on web.
DwiBackend createBackend(DwiTaskRegistry registry) => WebBackend();

import 'package:dwi/dwi.dart';

import 'dwi_tasks.g.dart';
import 'tasks.dart';

/// Calls the unannotated function through `DwiFunctions` (ADR-030).
Future<int> callTwiceByReference(int value) =>
    DwiFunctions.run(twiceByReference, value);

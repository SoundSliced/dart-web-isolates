import 'package:dwi_annotations/dwi_annotations.dart';

import 'src/barrel.dart';
import 'src/part_host.dart';
import 'src/transitive.dart';

/// Top-level const table read by a task.
const List<String> lookupTable = ['SENT_CONST_a1', 'SENT_CONST_b2'];

@DwiTask()
String viaExport(String x) => exportedHelper(x);

@DwiTask()
String viaPart(String x) => partHelper(x);

@DwiTask()
String viaConst(int i) => lookupTable[i % lookupTable.length];

@DwiTask()
Future<String> viaFuture(String x) async {
  await Future<void>.delayed(Duration.zero);
  return '$x SENT_FUTURE_5c2';
}

@DwiTask()
String viaLocalFunction(String x) {
  String decorate(String s) => '$s SENT_LOCAL_8e1';
  return decorate(x);
}

@DwiTask()
String viaTransitive(String x) => transitiveTop(x);

/// Negative control: unannotated and never referenced. Must not survive.
String neverCalled(String x) => '$x SENT_UNUSED_0d4';

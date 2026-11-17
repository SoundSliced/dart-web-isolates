import 'dart:convert';

import 'package:dwi/dwi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobile_probe/app.dart';
import 'package:mobile_probe/dwi_tasks.g.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DWI native probe: tasks, parameters, streams, references', (
    tester,
  ) async {
    final results = <String, Object?>{'platform': 'native'};
    final stopwatch = Stopwatch()..start();
    try {
      // The number of primes up to 3,000,000 is 216,816.
      results['primes'] = await DwiTasks.countPrimes(3000000);
      results['joined'] = await DwiTasks.joinParts(3, 'x');
      results['spread'] = await DwiTasks.spread(1, 3);
      results['streamed'] = await DwiTasks.countBetween(1, 3).toList();
      results['reference'] = await callTwiceByReference(21);
      results['ok'] = true;
    } catch (error, stack) {
      results['ok'] = false;
      results['error'] = '$error';
      results['stack'] = '$stack';
    } finally {
      await Dwi.close();
    }
    results['ms'] = stopwatch.elapsedMilliseconds;
    // ignore: avoid_print
    print('DWI_PROBE ${jsonEncode(results)}');
    expect(results['ok'], isTrue, reason: '${results['error']}');
    expect(results['primes'], 216816);
    expect(results['joined'], 'x3');
    expect(results['spread'], <int>[1, 2, 3]);
    expect(results['streamed'], <int>[1, 2, 3]);
    expect(results['reference'], 42);
  });
}

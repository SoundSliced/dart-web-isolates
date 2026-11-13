import 'dart:convert';

import 'package:dwi/dwi.dart';
import 'package:web/web.dart' as web;

import 'dwi_tasks.g.dart';

Future<void> main() async {
  await Dwi.configure(
    const DwiConfig(
      workerBackend: DwiWorkerBackend.wasm,
      workerScript: DwiConfig.defaultWasmWorkerScript,
    ),
  );
  final count = await DwiTasks.calculatePrimes(100000);
  web.document.body?.textContent = 'primes: $count';
  web.document.title = base64Encode(utf8.encode('$count'));
}

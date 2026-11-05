// Measures dedicated worker handles against the pooled Dwi.run path on the VM.
//
// Run three times and report medians (docs/benchmarks.md):
//
//   cd benchmarks/native_handle
//   dart pub get
//   dart run bin/benchmark.dart
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dwi/dwi.dart';

var _counter = 0;
final Map<int, int> _primeCache = <int, int>{};

int _countPrimes(int limit) {
  final sieve = List<bool>.filled(limit + 1, false);
  var count = 0;
  for (var i = 2; i <= limit; i++) {
    if (sieve[i]) continue;
    count++;
    for (var j = i * i; j <= limit; j += i) {
      sieve[j] = true;
    }
  }
  return count;
}

/// Cached inside the execution context: the first call pays the sieve, later
/// calls return the retained value. `Dwi.run` starts a fresh isolate each time.
int _cachedPrimes(int limit) =>
    _primeCache.putIfAbsent(limit, () => _countPrimes(limit));

int _median(List<int> values) {
  final sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

Map<String, Object?> _summary(String unit, List<int> values) =>
    <String, Object?>{
      'unit': unit,
      'runs': values.length,
      'median': _median(values),
      'min': values.reduce((a, b) => a < b ? a : b),
      'max': values.reduce((a, b) => a > b ? a : b),
    };

Future<void> main() async {
  Dwi.registerTask('echo', (Object? input) => input);
  Dwi.registerTask('count', (Object? input) => ++_counter);
  Dwi.registerTask(
    'cachedPrimes',
    (Object? input) => _cachedPrimes(input! as int),
  );
  Dwi.registerTask('die', (Object? input) => Isolate.exit());
  await Dwi.configure(const DwiConfig());

  final spawnUs = <int>[];
  for (var i = 0; i < 10; i++) {
    final watch = Stopwatch()..start();
    final handle = await DwiWorker.spawn();
    spawnUs.add(watch.elapsedMicroseconds);
    await handle.close();
  }

  final handle = await DwiWorker.spawn();
  for (var i = 0; i < 5; i++) {
    await handle.run<int>('count', null);
  }
  final handleCallUs = <int>[];
  for (var i = 0; i < 100; i++) {
    final watch = Stopwatch()..start();
    await handle.run<int>('count', null);
    handleCallUs.add(watch.elapsedMicroseconds);
  }

  for (var i = 0; i < 5; i++) {
    await Dwi.run<int>('count', null);
  }
  final poolCallUs = <int>[];
  for (var i = 0; i < 100; i++) {
    final watch = Stopwatch()..start();
    await Dwi.run<int>('count', null);
    poolCallUs.add(watch.elapsedMicroseconds);
  }

  const limit = 100000;
  await handle.run<int>('cachedPrimes', limit);
  final handleCachedUs = <int>[];
  for (var i = 0; i < 10; i++) {
    final watch = Stopwatch()..start();
    await handle.run<int>('cachedPrimes', limit);
    handleCachedUs.add(watch.elapsedMicroseconds);
  }

  await Dwi.run<int>('cachedPrimes', limit);
  final poolCachedUs = <int>[];
  for (var i = 0; i < 10; i++) {
    final watch = Stopwatch()..start();
    await Dwi.run<int>('cachedPrimes', limit);
    poolCachedUs.add(watch.elapsedMicroseconds);
  }

  final closeUs = <int>[];
  for (var i = 0; i < 10; i++) {
    final target = await DwiWorker.spawn();
    final watch = Stopwatch()..start();
    await target.close();
    closeUs.add(watch.elapsedMicroseconds);
  }

  final restartUs = <int>[];
  for (var i = 0; i < 5; i++) {
    final target = await DwiWorker.spawn();
    try {
      await target.run<Object?>('die', null);
    } on DwiException {
      // Expected: the handle is now failed.
    }
    final watch = Stopwatch()..start();
    await target.restart();
    restartUs.add(watch.elapsedMicroseconds);
    await target.close();
  }

  await handle.close();

  final rssBefore = ProcessInfo.currentRss;
  final handles = <DwiWorker>[
    for (var i = 0; i < 4; i++) await DwiWorker.spawn(),
  ];
  for (final target in handles) {
    await target.run<int>('count', null);
  }
  final rssWithHandles = ProcessInfo.currentRss;
  for (final target in handles) {
    await target.close();
  }
  final rssAfterClose = ProcessInfo.currentRss;

  await Dwi.close();

  stdout.writeln(
    jsonEncode(<String, Object?>{
      'environment': <String, Object?>{
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dart': Platform.version.split(' ').first,
        'cpus': Platform.numberOfProcessors,
      },
      'spawn': _summary('us', spawnUs),
      'handleCall': _summary('us', handleCallUs),
      'poolCall': _summary('us', poolCallUs),
      'handleCachedPrimes': _summary('us', handleCachedUs),
      'poolCachedPrimes': _summary('us', poolCachedUs),
      'close': _summary('us', closeUs),
      'restart': _summary('us', restartUs),
      'rss': <String, Object?>{
        'before': rssBefore,
        'fourHandles': rssWithHandles,
        'afterClose': rssAfterClose,
        'deltaForFour': rssWithHandles - rssBefore,
        'retainedAfterClose': rssAfterClose - rssBefore,
      },
    }),
  );
}

// Browser test driver. Compiled with dart2js and loaded by index.html.

import 'dart:convert';
import 'dart:js_interop';

import 'package:dwi_core/dwi_core.dart';
import 'package:dwi_web/dwi_web.dart';
import 'package:web/web.dart' as web;

Future<Map<String, Object?>> _runChecks(WebBackend backend) async {
  final results = <String, Object?>{};

  results['echo'] = await backend.run('echo', <String, Object?>{'a': 1});

  try {
    await backend.run('missing', null);
    results['unknownTask'] = 'no error';
  } on DwiUnknownTaskException catch (error) {
    results['unknownTask'] = error.message;
  } catch (error) {
    results['unknownTask'] = 'wrong error: $error';
  }

  try {
    await backend.run('boom', null);
    results['remoteError'] = 'no error';
  } on DwiRemoteException catch (error) {
    results['remoteError'] = <String, Object?>{
      'type': error.remoteType,
      'message': error.message,
      'hasStack': error.remoteStack.isNotEmpty,
    };
  } catch (error) {
    results['remoteError'] = 'wrong error: $error';
  }

  results['capabilities'] = (await backend.capabilities()).toMap();
  return results;
}

Future<void> main() async {
  final results = <String, Object?>{};
  final backend = WebBackend();
  try {
    await backend.configure(const DwiConfig(workerScript: 'worker.js'));
    results.addAll(await _runChecks(backend));
  } catch (error, stack) {
    results['fatal'] = '$error\n$stack';
  } finally {
    await backend.close();
  }

  final body = jsonEncode(results);
  web.document.body!.innerText = body;
  try {
    await web.window
        .fetch(
          '/result'.toJS,
          web.RequestInit(method: 'POST', body: body.toJS),
        )
        .toDart;
  } catch (_) {
    // The page body still carries the result.
  }
}

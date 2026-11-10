// A DEPENDENCY package's web build hook that declares data assets through the
// hooks API. This is the shape the ordering proposal has to preserve: the hook
// runs before compilation, and the assets it declares must still be bundled.
//
// `.hook_runs` counts invocations so a caller can tell "ran again" from
// "skipped" without reading verbose logs.
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    final root = input.packageRoot.toFilePath();
    final counter = File('$root/.hook_runs');
    final raw = counter.existsSync() ? counter.readAsStringSync().trim() : '';
    final runs = raw.isEmpty ? 0 : int.parse(raw);
    counter.writeAsStringSync('${runs + 1}');

    if (!input.config.buildAssetTypes.contains('data_assets/data')) {
      return;
    }

    for (final id in <String>['id1.txt']) {
      output.assets.data.add(
        DataAsset(
          package: input.packageName,
          name: 'data/$id',
          file: input.packageRoot.resolve('data/$id'),
        ),
      );
      // The bundled content follows this file, so it is a build input.
      output.dependencies.add(input.packageRoot.resolve('data/$id'));
    }

    final generated = input.packageRoot.resolve('data/generated.txt');
    final file = File(generated.toFilePath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('generated_content1\n');
    output.assets.data.add(
      DataAsset(
        package: input.packageName,
        name: 'data/generated.txt',
        file: generated,
      ),
    );
  });
}

import 'package:dwi_builder/dwi_builder.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the directory containing your annotated project');
  }
  final builder = DwiBuilder(DwiBuildConfig(projectRoot: args.single));
  final first = await builder.build();
  final second = await builder.build();
  print('First build compiled: ${first.compiled}');
  print('Second build cache hit: ${second.cacheHit}');
}

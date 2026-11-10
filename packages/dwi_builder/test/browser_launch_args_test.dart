import 'package:test/test.dart';

import 'support/browser_engines.dart';

void main() {
  group('chromiumLaunchArguments', () {
    test('Edge automation never uses the real keychain', () {
      final arguments = chromiumLaunchArguments(
        engine: BrowserEngine.edge,
        userDataDir: '/tmp/profile',
        debugPort: 1234,
      );

      expect(arguments, contains('--use-mock-keychain'));
      expect(arguments, contains('--headless=new'));
      expect(arguments, contains('--user-data-dir=/tmp/profile'));
      expect(arguments, contains('--remote-debugging-port=1234'));

      final disabled = arguments.singleWhere(
        (argument) => argument.startsWith('--disable-features='),
      );
      // Edge 157's async keychain provider can bypass --use-mock-keychain.
      expect(disabled, contains('UseKeychainKeyProvider'));
      expect(disabled, contains('msEdgeUpdater'));
      expect(disabled, contains('EdgeUpdater'));
    });

    test('Chrome keeps its headless flags and does not need Edge switches', () {
      final arguments = chromiumLaunchArguments(
        engine: BrowserEngine.chrome,
        userDataDir: '/tmp/profile',
        debugPort: 4321,
      );

      expect(arguments, contains('--headless'));
      expect(arguments, contains('--user-data-dir=/tmp/profile'));
      expect(arguments, contains('--remote-debugging-port=4321'));
      expect(arguments, isNot(contains('--use-mock-keychain')));
      expect(
        arguments.where((argument) => argument.startsWith('--disable-features=')),
        isEmpty,
      );
    });
  });
}

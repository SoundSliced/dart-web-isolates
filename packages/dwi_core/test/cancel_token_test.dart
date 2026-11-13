import 'dart:async';

import 'package:dwi_core/dwi_core.dart';
import 'package:test/test.dart';

void main() {
  group('DwiCancelToken (ADR-027)', () {
    test('outside a task the current token is never cancelled', () {
      final token = DwiCancelToken.current;
      expect(token.isCancelled, isFalse);
      token.cancel();
      expect(DwiCancelToken.current.isCancelled, isFalse);
      expect(DwiCancelToken.current.throwIfCancelled, returnsNormally);
    });

    test('runWith makes the token current, including across awaits', () async {
      final token = DwiCancelToken();
      final seen = await DwiCancelToken.runWith(token, () async {
        expect(identical(DwiCancelToken.current, token), isTrue);
        await Future<void>.delayed(Duration.zero);
        return DwiCancelToken.current;
      });
      expect(identical(seen, token), isTrue);
      expect(identical(DwiCancelToken.current, token), isFalse);
    });

    test(
      'cancel sets the flag, completes whenCancelled and is idempotent',
      () async {
        final token = DwiCancelToken();
        var fired = 0;
        unawaited(token.whenCancelled.then((_) => fired++));
        expect(token.isCancelled, isFalse);

        token
          ..cancel()
          ..cancel();
        await Future<void>.delayed(Duration.zero);

        expect(token.isCancelled, isTrue);
        expect(fired, 1);
        expect(token.throwIfCancelled, throwsA(isA<DwiCancelledException>()));
      },
    );

    test('cancelGracePeriod is off by default and must be positive', () {
      expect(const DwiConfig().cancelGracePeriod, isNull);
      expect(
        const DwiConfig(cancelGracePeriod: Duration(milliseconds: 1))
            .validated()
            .cancelGracePeriod,
        const Duration(milliseconds: 1),
      );
      expect(
        () => const DwiConfig(cancelGracePeriod: Duration.zero).validated(),
        throwsArgumentError,
      );
    });
  });
}

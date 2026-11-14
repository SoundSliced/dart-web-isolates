import 'package:flutter_jank_demo/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the demo page builds with its status line', (tester) async {
    await tester.pumpWidget(const JankApp(autoRun: false));
    expect(find.text('starting'), findsOneWidget);
  });
}

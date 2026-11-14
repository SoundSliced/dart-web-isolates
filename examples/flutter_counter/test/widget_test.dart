import 'package:flutter/material.dart';
import 'package:flutter_counter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the +1 button increments the counter', (tester) async {
    await tester.pumpWidget(const CounterApp(autoRun: false));
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '+1'));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
  });
}

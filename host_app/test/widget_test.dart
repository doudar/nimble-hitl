import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('smoke test harness is available', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('NimBLE HITL'),
        ),
      ),
    );

    expect(find.text('NimBLE HITL'), findsOneWidget);
  });
}

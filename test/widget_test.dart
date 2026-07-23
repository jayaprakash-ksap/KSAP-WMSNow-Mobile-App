import 'package:flutter_test/flutter_test.dart';

import 'package:japra_redwood_v3/main.dart';

void main() {
  testWidgets('Login screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const JapraApp());
    await tester.pump();

    expect(find.text('Japra WMS Mobile'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

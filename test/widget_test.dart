import 'package:flutter_test/flutter_test.dart';

import 'package:wmsnow_redwood_v3/main.dart';

void main() {
  testWidgets('Login screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const WmsNowRedwoodApp());
    await tester.pump();

    expect(find.text('WMSNow Redwood Mobile'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}

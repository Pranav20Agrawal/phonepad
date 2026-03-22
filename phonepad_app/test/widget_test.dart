// widget_test.dart
// Placeholder test file for PhonePad.
// Real tests will be added in Phase 2 once core features are stable.

import 'package:flutter_test/flutter_test.dart';
import 'package:phonepad_app/main.dart';

void main() {
  testWidgets('PhonePad app loads ConnectionScreen', (WidgetTester tester) async {
    await tester.pumpWidget(const PhonePadApp());
    // Verify the connection screen renders with the app title
    expect(find.text('PhonePad'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
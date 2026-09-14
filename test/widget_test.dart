import 'package:flutter_test/flutter_test.dart';

import 'package:scanner_pro/main.dart';

void main() {
  testWidgets('shows the batch photo-to-PDF workspace', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Scanner Pro'), findsOneWidget);
    expect(find.text('Current file window'), findsOneWidget);
    expect(find.text('Convert to PDF'), findsOneWidget);
  });
}

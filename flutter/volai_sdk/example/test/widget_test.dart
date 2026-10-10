import 'package:flutter_test/flutter_test.dart';
import 'package:volai_sdk_example/main.dart';

void main() {
  testWidgets('renders the example page', (tester) async {
    await tester.pumpWidget(const VolaiExampleApp());
    expect(find.text('Start chat'), findsOneWidget);
  });
}

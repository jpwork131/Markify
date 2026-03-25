import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/main.dart';
import 'package:markify/features/upload/presentation/upload_screen.dart';

void main() {
  testWidgets('Upload screen shows correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: WatermarkApp()));

    expect(find.byType(UploadScreen), findsOneWidget);
    expect(find.text('Upload your image'), findsOneWidget);
  });
}

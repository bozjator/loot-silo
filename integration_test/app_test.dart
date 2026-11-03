import 'package:assets_explorer/ui/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'screenshot_helper.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home screen renders', (tester) async {
    await tester.pumpWidget(
      screenshotable(const ProviderScope(child: AssetsExplorerApp())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Asset Explorer'), findsOneWidget);
    await captureScreenshot(tester, 'm1_home');
  });
}

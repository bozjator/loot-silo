import 'package:assets_explorer/ui/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to the empty-library home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AssetsExplorerApp()));
    expect(find.text('Asset Explorer'), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
  });
}

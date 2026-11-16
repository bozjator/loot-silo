import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/platform_semantics.dart';

/// Every widget test also checks that its semantics updates would be taken
/// by the Windows accessibility bridge ([PlatformSemanticsBinding]).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final binding = PlatformSemanticsBinding.ensureInitialized();
  setUp(binding.resetPlatformTree);
  tearDown(() {
    final rejected = List.of(binding.rejected);
    binding.resetPlatformTree();
    // Not `expect`: after a test that failed mid-pump it would report a
    // guarded-function conflict instead of the test's own failure.
    if (rejected.isNotEmpty) {
      throw TestFailure(
        'Windows rejects these semantics updates (see '
        'PlatformSemanticsBinding):\n${rejected.join('\n')}',
      );
    }
  });
  await testMain();
}

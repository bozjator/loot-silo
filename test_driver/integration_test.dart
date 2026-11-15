import 'package:integration_test/integration_test_driver.dart';

/// Driver for `flutter drive --profile` runs of integration tests
/// (performance numbers; see `integration_test/tree_perf_test.dart`).
Future<void> main() => integrationDriver();

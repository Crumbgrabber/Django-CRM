import 'dart:async';

import 'package:bottle_crm/services/api_contract.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fails any test that sends a request outside the API's published schema
/// (`lib/services/api_contract.dart`).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(apiContractViolations.clear);
  tearDown(
    () => expect(
      apiContractViolations,
      isEmpty,
      reason: 'requests the API schema does not publish',
    ),
  );
  await testMain();
}

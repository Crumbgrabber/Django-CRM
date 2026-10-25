import 'dart:convert';

import 'package:bottle_crm/data/models/org_settings.dart';
import 'package:bottle_crm/providers/auth_provider.dart';
import 'package:bottle_crm/providers/settings_provider.dart';
import 'package:bottle_crm/screens/settings/organization_screen.dart';
import 'package:bottle_crm/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Serves `/api/billing/` and answers 404 to everything else, so the module
/// list reads as an older server's (every module on).
class _FakeApi extends http.BaseClient {
  _FakeApi({required this.billingStatus, this.billingBody = '{}'});

  final int billingStatus;
  final String billingBody;
  final List<String> asked = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    asked.add(request.url.path);
    await request.finalize().toBytes();
    final billing = request.url.path == '/api/billing/';
    return http.StreamedResponse(
      Stream.value(utf8.encode(billing ? billingBody : '{}')),
      billing ? billingStatus : 404,
      request: request,
    );
  }
}

class _Org extends OrgSettingsNotifier {
  @override
  Future<OrgSettings> build() async =>
      OrgSettings.fromJson({'id': 'org-1', 'name': 'Acme', 'timezone': 'UTC'});
}

/// Settings › Organization shows the plan's name read-only, nothing where the
/// server has no billing, and never a control to buy or manage a plan.
void main() {
  Future<_FakeApi> pump(
    WidgetTester tester, {
    required int status,
    String body = '{}',
    bool admin = true,
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = _FakeApi(billingStatus: status, billingBody: body);
    ApiService().setClientForTesting(api);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orgSettingsProvider.overrideWith(_Org.new),
          isOrgAdminProvider.overrideWithValue(admin),
        ],
        child: const MaterialApp(home: OrganizationScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  final admin = jsonEncode({
    'plan': {'key': 'a', 'name': 'Plan A'},
    'can_manage': true,
    'state': {'code': 'active', 'sentence': 'Renews soon'},
    'notice': {'sentence': 'The last payment failed.'},
    'plans': [
      {'key': 'a', 'name': 'Plan A', 'current': true, 'action': 'manage'},
      {'key': 'b', 'name': 'Plan B', 'current': false, 'action': 'choose'},
    ],
  });

  void expectNothingToBuy() {
    for (final word in ['Choose', 'Manage', 'Switch', 'Upgrade', 'Buy']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
    expect(find.textContaining('Plan B'), findsNothing);
    expect(find.textContaining('Renews'), findsNothing);
    expect(find.textContaining('payment'), findsNothing);
  }

  testWidgets('a member sees the plan name and nothing else', (tester) async {
    final api = await pump(
      tester,
      status: 200,
      body: '{"plan": {"key": "a", "name": "Plan A"}, "can_manage": false}',
      admin: false,
    );
    expect(api.asked, contains('/api/billing/'));
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Plan A'), findsOneWidget);
    expectNothingToBuy();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an admin sees the name only, never the web buttons or dates', (
    tester,
  ) async {
    await pump(tester, status: 200, body: admin);
    expect(find.text('Plan A'), findsOneWidget);
    expectNothingToBuy();
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server without billing shows no plan row', (tester) async {
    await pump(tester, status: 404, body: '{"detail": "Not found."}');
    expect(find.text('Plan'), findsNothing);
    expect(find.text('Acme'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed read shows no plan row either', (tester) async {
    await pump(tester, status: 500);
    expect(find.text('Plan'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long plan name fits at 390px with large text', (tester) async {
    await pump(
      tester,
      status: 200,
      body: jsonEncode({
        'plan': {'key': 'a', 'name': 'Plan A ${'with a long name ' * 6}'},
        'can_manage': false,
      }),
      textScale: 2.0,
    );
    expect(find.textContaining('with a long name'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

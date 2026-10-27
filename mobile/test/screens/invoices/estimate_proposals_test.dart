import 'package:bottle_crm/data/models/estimate.dart';
import 'package:bottle_crm/providers/invoice_extras_provider.dart';
import 'package:bottle_crm/providers/org_modules_provider.dart';
import 'package:bottle_crm/screens/invoices/estimates_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/modules_fixtures.dart';

/// An accepted proposal on the estimates list: the project it started and the
/// deposit invoice it drafted open from the row, and raising the full invoice
/// asks first while a deposit invoice still bills the client.
const _projectId = '11111111-1111-4111-8111-111111111111';
const _depositId = '22222222-2222-4222-8222-222222222222';

Estimate _estimate({
  String id = 'e1',
  bool project = true,
  String? depositStatus = 'Draft',
}) => Estimate.fromJson({
  'id': id,
  'estimate_number': 'EST-0007',
  'title': 'Website rebuild',
  'status': 'Accepted',
  'account_name': 'Northwind',
  'total_amount': '1000.00',
  'currency': 'EUR',
  'converted_to_invoice': null,
  'project': project ? {'id': _projectId, 'name': 'Website rebuild'} : null,
  'deposit_invoice': depositStatus == null
      ? null
      : {
          'id': _depositId,
          'invoice_number': 'INV-0012',
          'status': depositStatus,
          'total_amount': '330.00',
        },
});

class _FakeEstimates extends EstimatesNotifier {
  _FakeEstimates(this.rows);

  final List<Estimate> rows;
  final List<String> converted = [];

  @override
  Future<List<Estimate>> build() async => rows;

  @override
  Future<({String? invoiceId, String? error})> convert(String id) async {
    converted.add(id);
    return (invoiceId: 'inv-new', error: null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEstimates estimates;

  Future<void> pump(
    WidgetTester tester,
    Estimate estimate, {
    List<String> off = const [],
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    estimates = _FakeEstimates([estimate]);
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(path: '/start', builder: (_, _) => const Text('started')),
        GoRoute(path: '/here', builder: (_, _) => const EstimatesListScreen()),
        GoRoute(
          path: '/projects/:id',
          builder: (_, s) => Text('project ${s.pathParameters['id']}'),
        ),
        GoRoute(
          path: '/invoices/:id',
          builder: (_, s) => Text('invoice ${s.pathParameters['id']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...modulesOverrides(
            FakeOrgModules(() async => modulesAnswer(off: off)),
          ),
          estimatesProvider.overrideWith(() => estimates),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await ProviderScope.containerOf(
      tester.element(find.text('started')),
    ).read(orgModulesProvider.future);
    router.push('/here');
    await tester.pumpAndSettle();
  }

  group('the row of an accepted proposal', () {
    for (final scale in [1.0, 1.5]) {
      testWidgets('fits both links at 390px, text x$scale', (tester) async {
        await pump(tester, _estimate(), textScale: scale);
        expect(find.text('Project: Website rebuild'), findsOneWidget);
        expect(find.text('Deposit invoice INV-0012 · Draft'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('opens the project it started', (tester) async {
      await pump(tester, _estimate());

      await tester.tap(find.text('Project: Website rebuild'));
      await tester.pumpAndSettle();

      expect(find.text('project $_projectId'), findsOneWidget);
    });

    testWidgets('opens the deposit invoice it drafted', (tester) async {
      await pump(tester, _estimate());

      await tester.tap(find.text('Deposit invoice INV-0012 · Draft'));
      await tester.pumpAndSettle();

      expect(find.text('invoice $_depositId'), findsOneWidget);
    });

    testWidgets('with Projects off names the project without opening it', (
      tester,
    ) async {
      await pump(tester, _estimate(), off: ['projects']);

      await tester.tap(find.text('Project: Website rebuild'));
      await tester.pumpAndSettle();

      expect(find.text('project $_projectId'), findsNothing);
      expect(find.byType(EstimatesListScreen), findsOneWidget);
    });

    testWidgets('an estimate with neither shows no link', (tester) async {
      await pump(tester, _estimate(project: false, depositStatus: null));

      expect(find.textContaining('Project'), findsNothing);
      expect(find.textContaining('Deposit invoice'), findsNothing);
    });
  });

  group('raising the full invoice', () {
    const warning =
        'Deposit invoice INV-0012 for €330.00 is not taken off '
        'automatically. Edit the new invoice before you send it.';

    testWidgets('asks first while the deposit invoice is live', (tester) async {
      await pump(tester, _estimate());

      await tester.tap(find.widgetWithText(FilledButton, 'Raise an invoice'));
      await tester.pumpAndSettle();

      expect(find.text('Raise the full invoice?'), findsOneWidget);
      expect(find.text(warning), findsOneWidget);
      expect(estimates.converted, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cancel raises nothing', (tester) async {
      await pump(tester, _estimate());

      await tester.tap(find.widgetWithText(FilledButton, 'Raise an invoice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(estimates.converted, isEmpty);
      expect(find.byType(EstimatesListScreen), findsOneWidget);
    });

    testWidgets('confirming raises it and opens it', (tester) async {
      await pump(tester, _estimate());

      await tester.tap(find.widgetWithText(FilledButton, 'Raise an invoice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Raise invoice'));
      await tester.pumpAndSettle();

      expect(estimates.converted, ['e1']);
      expect(find.text('invoice inv-new'), findsOneWidget);
    });

    for (final (why, estimate) in [
      ('no deposit invoice', _estimate(depositStatus: null)),
      ('a cancelled deposit invoice', _estimate(depositStatus: 'Cancelled')),
    ]) {
      testWidgets('with $why it raises without asking', (tester) async {
        await pump(tester, estimate);

        await tester.tap(find.widgetWithText(FilledButton, 'Raise an invoice'));
        await tester.pumpAndSettle();

        expect(find.text('Raise the full invoice?'), findsNothing);
        expect(estimates.converted, ['e1']);
        expect(find.text('invoice inv-new'), findsOneWidget);
      });
    }
  });
}

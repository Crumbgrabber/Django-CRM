import 'package:bottle_crm/data/models/models.dart';
import 'package:bottle_crm/providers/deal_pipelines_provider.dart';
import 'package:bottle_crm/providers/deals_provider.dart';
import 'package:bottle_crm/providers/invoice_extras_provider.dart';
import 'package:bottle_crm/providers/invoices_provider.dart';
import 'package:bottle_crm/providers/lookup_provider.dart';
import 'package:bottle_crm/providers/org_modules_provider.dart';
import 'package:bottle_crm/routes/app_router.dart';
import 'package:bottle_crm/screens/deals/deal_detail_screen.dart';
import 'package:bottle_crm/screens/invoices/new_estimate_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../support/modules_fixtures.dart';

/// Raising an estimate, blank or from a deal, and an invoice from a won deal.
///
/// The server decides who may bill which account and cite which deal, and it
/// refuses the rest with the same message whether the record is hidden or
/// missing. These tests pin the client half: the form starts from what the
/// deal carries, never submits an id its pickers do not offer, and the deal
/// screen offers "Create invoice" only where the server can say yes.
Deal _deal({
  String stageKind = 'open',
  List<String> contacts = const [],
  int quantity = 3,
  String unitPrice = '100.00',
}) => Deal.fromJson({
  'id': 'd1',
  'name': 'Renewal',
  'stage': stageKind == 'won' ? 'SIGNED' : 'TALKING',
  'stage_label': stageKind == 'won' ? 'Signed' : 'Talking',
  'stage_kind': stageKind,
  'amount': '300',
  'currency': 'EUR',
  'account': {'id': 'acc-1', 'name': 'Northwind'},
  'contacts': [
    for (final id in contacts)
      {'id': id, 'first_name': id, 'last_name': 'Person'},
  ],
  'line_items': [
    {
      'id': 'li1',
      'name': 'Seats',
      'quantity': quantity,
      'unit_price': unitPrice,
    },
  ],
  'created_at': '2026-09-01T00:00:00Z',
});

/// Decimals as the API sends them (strings), with a line discount on each.
Deal _discountedDeal() => Deal.fromJson({
  'id': 'd1',
  'name': 'Renewal',
  'stage': 'TALKING',
  'stage_kind': 'open',
  'currency': 'EUR',
  'account': {'id': 'acc-1', 'name': 'Northwind'},
  'contacts': [
    {'id': 'c1', 'first_name': 'c1', 'last_name': 'Person'},
  ],
  'line_items': [
    {
      'id': 'li1',
      'name': 'Seats',
      'quantity': '2.00',
      'unit_price': '100.00',
      'discount_type': 'PERCENTAGE',
      'discount_value': '10.00',
    },
    {
      'id': 'li2',
      'name': 'Setup',
      'quantity': '1.00',
      'unit_price': '50.00',
      'discount_type': 'FIXED',
      'discount_value': '5.00',
    },
  ],
  'created_at': '2026-09-01T00:00:00Z',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void usePhone(WidgetTester tester, double textScale) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  group('the estimate form', () {
    late _FakeEstimates estimates;

    /// The form's app with the caller an admin or not. Pumped again over a
    /// form already open, it changes the role and keeps the form's state.
    late Widget Function({required bool admin}) app;

    setUp(() => estimates = _FakeEstimates());

    Future<void> pumpForm(
      WidgetTester tester, {
      Deal? fromDeal,
      double textScale = 1.0,
      List<String> off = const [],
      void Function()? onDealsRead,
      bool admin = true,
    }) async {
      usePhone(tester, textScale);
      final router = GoRouter(
        initialLocation: '/start',
        routes: [
          GoRoute(path: '/start', builder: (_, _) => const Text('started')),
          GoRoute(
            path: '/form',
            builder: (_, _) => NewEstimateScreen(fromDeal: fromDeal),
          ),
        ],
      );
      final modules = FakeOrgModules(() async => modulesAnswer(off: off));
      app = ({required bool admin}) => ProviderScope(
        overrides: [
          ...modulesOverrides(modules, admin: admin),
          accountsLookupProvider.overrideWith(_FakeAccounts.new),
          contactsLookupProvider.overrideWith(_FakeContacts.new),
          opportunityEntityOptionsProvider.overrideWith((ref) {
            onDealsRead?.call();
            return const AsyncValue.data([
              EntityLookup(id: 'd1', label: 'Renewal'),
            ]);
          }),
          productsProvider.overrideWith(_FakeProducts.new),
          estimatesProvider.overrideWith(() => estimates),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
      await tester.pumpWidget(app(admin: admin));
      await tester.pumpAndSettle();
      // The app has the module answer before any form opens; a form that
      // starts during the first load reads every module as on.
      await ProviderScope.containerOf(
        tester.element(find.text('started')),
      ).read(orgModulesProvider.future);
      router.push('/form');
      await tester.pumpAndSettle();
    }

    FilledButton submit(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create draft'),
    );

    for (final scale in [1.0, 1.3]) {
      testWidgets('lays out at 390px, text x$scale', (tester) async {
        await pumpForm(
          tester,
          fromDeal: _deal(contacts: ['c1']),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Pipeline off hides the Deal field and never reads deals', (
      tester,
    ) async {
      var reads = 0;
      await pumpForm(tester, off: ['deals'], onDealsRead: () => reads++);
      expect(find.text('Deal (optional)'), findsNothing);
      expect(reads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Pipeline on shows the Deal field and reads deals', (
      tester,
    ) async {
      var reads = 0;
      await pumpForm(tester, onDealsRead: () => reads++);
      expect(find.text('Deal (optional)'), findsOneWidget);
      expect(reads, greaterThan(0));
    });

    testWidgets('a blank form will not submit', (tester) async {
      await pumpForm(tester);

      expect(submit(tester).onPressed, isNull);
      expect(find.text('Pick an account first'), findsOneWidget);
    });

    testWidgets('from a deal it starts with the deal and sends it all', (
      tester,
    ) async {
      // `hidden` is on the deal but not offered by the contact picker, so the
      // first contact the caller can open is used instead.
      await pumpForm(tester, fromDeal: _deal(contacts: ['hidden', 'c1']));

      expect(find.text('Northwind'), findsOneWidget);
      expect(find.text('c1 Person'), findsOneWidget);
      expect(find.text('Renewal'), findsOneWidget);
      expect(find.text('Estimate for Renewal'), findsOneWidget);
      expect(find.text('Seats'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['account_id'], 'acc-1');
      expect(sent['contact_id'], 'c1');
      expect(sent['opportunity_id'], 'd1');
      expect(sent['currency'], 'EUR');
      expect(sent['title'], 'Estimate for Renewal');
      expect(sent['expiry_date'], isNotNull);
      expect(sent['line_items'], [
        {
          'name': 'Seats',
          'description': '',
          'quantity': '3.0',
          'unit_price': '100.00',
          'order': 0,
        },
      ]);
      // Server-derived fields are never sent.
      expect(sent.keys, isNot(contains('status')));
      expect(find.text('started'), findsOneWidget);
    });

    testWidgets(
      'from a deal each line keeps its decimal quantity and discount',
      (tester) async {
        // What the API actually sends: decimals as strings. "2.00" used to parse
        // as a quantity of 1, and the discount was dropped, so the estimate
        // started at the list price of one unit.
        await pumpForm(tester, fromDeal: _discountedDeal());

        // 2 x 100 less 10% = 180, 1 x 50 less 5 = 45.
        expect(find.text('2 x €100.00, less 10%'), findsOneWidget);
        expect(find.text('€180.00'), findsOneWidget);
        expect(find.text('€45.00'), findsOneWidget);
        expect(find.text('€225.00'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
        await tester.pumpAndSettle();

        final lines = estimates.created.single['line_items'] as List;
        expect(lines.first, containsPair('quantity', '2.0'));
        expect(lines.first, containsPair('discount_type', 'PERCENTAGE'));
        expect(lines.first, containsPair('discount_value', '10.00'));
        expect(lines.last, containsPair('discount_type', 'FIXED'));
        expect(lines.last, containsPair('discount_value', '5.00'));
      },
    );

    testWidgets('discounted deal lines lay out at 390px, text x1.3', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _discountedDeal(), textScale: 1.3);
      expect(tester.takeException(), isNull);
    });

    Future<void> reveal(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('sends the introduction, the deposit and the project', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await reveal(tester, field('Introduction (optional)'));
      await tester.enterText(
        field('Introduction (optional)'),
        'Thanks for the call.\nHere is the plan.',
      );
      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '30');
      await tester.pumpAndSettle();
      // 3 x €100 = €300, and 30% of it.
      expect(find.text('€90.00'), findsOneWidget);
      expect(find.text('deposit invoice'), findsOneWidget);

      await reveal(tester, find.text('Start a project when accepted'));
      expect(find.text('Project billing'), findsNothing);
      await tester.tap(find.text('Start a project when accepted'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Fixed fee'));
      await tester.tap(find.text('Fixed fee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Time and materials').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['introduction'], 'Thanks for the call.\nHere is the plan.');
      expect(sent['deposit_percent'], '30.00');
      expect(sent['start_project'], isTrue);
      expect(sent['project_billing_type'], 'time_and_materials');
    });

    testWidgets('the deposit beside the percent carries the tax', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await reveal(tester, field('Tax rate'));
      await tester.enterText(field('Tax rate'), '10');
      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '50');
      await tester.pumpAndSettle();

      // Half of €300 is €150, and 10% tax on that.
      expect(find.text('€165.00'), findsOneWidget);
      expect(find.text('deposit invoice, with tax'), findsOneWidget);
    });

    testWidgets('a project starts as a fixed fee unless changed', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await reveal(tester, find.text('Start a project when accepted'));
      await tester.tap(find.text('Start a project when accepted'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['start_project'], isTrue);
      expect(sent['project_billing_type'], 'fixed_fee');
    });

    testWidgets('left alone, none of the proposal fields is sent', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      for (final key in [
        'introduction',
        'deposit_percent',
        'start_project',
        'project_billing_type',
      ]) {
        expect(sent.keys, isNot(contains(key)), reason: key);
      }
    });

    testWidgets('Projects off offers no project and sends none', (
      tester,
    ) async {
      await pumpForm(
        tester,
        fromDeal: _deal(contacts: ['c1']),
        off: ['projects'],
      );

      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '20');
      await tester.pumpAndSettle();
      expect(find.text('Start a project when accepted'), findsNothing);
      expect(find.text('Project billing'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['deposit_percent'], '20.00');
      expect(sent.keys, isNot(contains('start_project')));
      expect(sent.keys, isNot(contains('project_billing_type')));
    });

    testWidgets('a member is offered no project and sends none', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']), admin: false);

      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '20');
      await tester.pumpAndSettle();
      expect(find.text('Start a project when accepted'), findsNothing);
      expect(find.text('Project billing'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['deposit_percent'], '20.00');
      expect(sent.keys, isNot(contains('start_project')));
      expect(sent.keys, isNot(contains('project_billing_type')));
    });

    testWidgets('a project chosen before admin was lost is not sent', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await reveal(tester, find.text('Start a project when accepted'));
      await tester.tap(find.text('Start a project when accepted'));
      await tester.pumpAndSettle();
      expect(find.text('Project billing'), findsOneWidget);

      await tester.pumpWidget(app(admin: false));
      await tester.pumpAndSettle();
      expect(find.text('Start a project when accepted'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent.keys, isNot(contains('start_project')));
      expect(sent.keys, isNot(contains('project_billing_type')));
    });

    testWidgets('the deposit beside the percent is what the server bills', (
      tester,
    ) async {
      await pumpForm(
        tester,
        fromDeal: _deal(contacts: ['c1'], quantity: 1, unitPrice: '10.01'),
      );

      await reveal(tester, field('Tax rate'));
      await tester.tap(find.text('No discount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Percentage').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('Percent off'), '15');
      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '50');
      await tester.pumpAndSettle();

      // 10.01 less 15% is 8.51 once the discount is to the cent; half is
      // 4.255, which the server bills as 4.26.
      expect(find.text('€4.26'), findsOneWidget);
    });

    testWidgets('a deposit that rounds to nothing says none is drafted', (
      tester,
    ) async {
      await pumpForm(
        tester,
        fromDeal: _deal(contacts: ['c1'], unitPrice: '0.01'),
      );

      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '10');
      await tester.pumpAndSettle();

      // 10% of 0.03 is 0.003.
      expect(
        find.text('Rounds to 0.00, so no deposit invoice is drafted.'),
        findsOneWidget,
      );
      expect(find.text('€0.00'), findsNothing);
      expect(find.text('deposit invoice'), findsNothing);

      // The percent is still the client's to see, so it still goes.
      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();
      expect(estimates.created.single['deposit_percent'], '10.00');
    });

    testWidgets('a deposit of 0 or over 100 holds the form', (tester) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));
      await reveal(tester, field('Deposit on acceptance'));

      for (final (value, error) in [
        ('0', 'A deposit must be more than 0%.'),
        ('.', 'A deposit must be more than 0%.'),
        ('100.01', 'A deposit cannot be more than 100%.'),
        ('150', 'A deposit cannot be more than 100%.'),
      ]) {
        await tester.enterText(field('Deposit on acceptance'), value);
        await tester.pumpAndSettle();
        expect(find.text(error), findsOneWidget, reason: value);
        expect(submit(tester).onPressed, isNull, reason: value);
      }

      await tester.enterText(field('Deposit on acceptance'), '100');
      await tester.pumpAndSettle();
      expect(find.textContaining('A deposit'), findsNothing);
      expect(submit(tester).onPressed, isNotNull);

      await tester.enterText(field('Deposit on acceptance'), '');
      await tester.pumpAndSettle();
      expect(submit(tester).onPressed, isNotNull);
    });

    testWidgets('the acceptance card lays out at 390px, text x1.3', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']), textScale: 1.3);
      await reveal(tester, field('Deposit on acceptance'));
      await tester.enterText(field('Deposit on acceptance'), '33.33');
      await reveal(tester, find.text('Start a project when accepted'));
      await tester.tap(find.text('Start a project when accepted'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Project billing'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('a deal with only hidden contacts leaves the contact unset', (
      tester,
    ) async {
      await pumpForm(tester, fromDeal: _deal(contacts: ['hidden']));

      expect(submit(tester).onPressed, isNull);
    });

    testWidgets('the server refusal is shown and nothing navigates', (
      tester,
    ) async {
      estimates.refusal = 'Account not found, or you do not have access to it.';
      await pumpForm(tester, fromDeal: _deal(contacts: ['c1']));

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      expect(
        find.text('Account not found, or you do not have access to it.'),
        findsOneWidget,
      );
      expect(find.text('started'), findsNothing);
    });
  });

  group('the deal screen', () {
    late _FakeInvoices invoices;

    setUp(() => invoices = _FakeInvoices());

    Future<void> pumpDeal(
      WidgetTester tester,
      Deal deal, {
      double textScale = 1.0,
    }) async {
      usePhone(tester, textScale);
      final router = GoRouter(
        initialLocation: '/deals/d1',
        routes: [
          GoRoute(
            path: '/deals/:id',
            builder: (_, s) =>
                DealDetailScreen(dealId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '${AppRoutes.invoices}/:id',
            builder: (_, s) => Text('invoice ${s.pathParameters['id']}'),
          ),
          GoRoute(
            path: AppRoutes.estimateNew,
            builder: (_, s) => Text('estimate from ${(s.extra as Deal?)?.id}'),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dealsProvider.overrideWith(() => _FakeDeals(deal)),
            dealPipelinesProvider.overrideWith(_FakePipelines.new),
            invoicesProvider.overrideWith(() => invoices),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('a won deal fits its invoice action at 390px, x$scale', (
        tester,
      ) async {
        await pumpDeal(tester, _deal(stageKind: 'won'), textScale: scale);
        expect(find.text('Create invoice'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('an open deal offers no invoice', (tester) async {
      await pumpDeal(tester, _deal());

      expect(find.text('Create invoice'), findsNothing);
    });

    testWidgets('creating the invoice opens it', (tester) async {
      await pumpDeal(tester, _deal(stageKind: 'won'));

      await tester.tap(find.text('Create invoice'));
      await tester.pumpAndSettle();

      expect(invoices.fromDeals, ['d1']);
      expect(find.text('invoice inv-1'), findsOneWidget);
    });

    testWidgets('a refusal is shown as the server wrote it', (tester) async {
      invoices.refusal = 'Opportunity has no products/line items to invoice';
      await pumpDeal(tester, _deal(stageKind: 'won'));

      await tester.tap(find.text('Create invoice'));
      await tester.pump();

      expect(
        find.text('Opportunity has no products/line items to invoice'),
        findsOneWidget,
      );
    });

    testWidgets('any deal can start an estimate from the menu', (tester) async {
      await pumpDeal(tester, _deal());

      await tester.tap(find.byIcon(LucideIcons.moreVertical));
      await tester.pumpAndSettle();
      expect(find.text('Create invoice'), findsNothing);
      await tester.tap(find.text('Create estimate'));
      await tester.pumpAndSettle();

      expect(find.text('estimate from d1'), findsOneWidget);
    });
  });
}

class _FakeAccounts extends AccountsLookupNotifier {
  @override
  Future<List<AccountLookup>> build() async => const [
    AccountLookup(id: 'acc-1', name: 'Northwind'),
  ];
}

class _FakeContacts extends ContactsLookupNotifier {
  @override
  Future<List<ContactLookup>> build() async => const [
    ContactLookup(id: 'c1', firstName: 'c1', lastName: 'Person'),
    ContactLookup(
      id: 'c2',
      firstName: 'Bound',
      lastName: 'Elsewhere',
      accountId: 'acc-2',
    ),
  ];
}

class _FakeProducts extends ProductsNotifier {
  @override
  Future<List<Product>> build() async => const [];
}

class _FakeEstimates extends EstimatesNotifier {
  final List<Map<String, dynamic>> created = [];
  String? refusal;

  @override
  Future<List<Estimate>> build() async => const [];

  @override
  Future<String?> create(Map<String, dynamic> payload) async {
    if (refusal != null) return refusal;
    created.add(payload);
    return null;
  }
}

class _FakeInvoices extends InvoicesNotifier {
  final List<String> fromDeals = [];
  String? refusal;

  @override
  Future<InvoicesListData> build() async => const InvoicesListData();

  @override
  Future<({String? invoiceId, String? error})> createFromDeal(
    String dealId,
  ) async {
    if (refusal != null) return (invoiceId: null, error: refusal);
    fromDeals.add(dealId);
    return (invoiceId: 'inv-1', error: null);
  }
}

class _FakeDeals extends DealsNotifier {
  _FakeDeals(this.deal);

  final Deal deal;

  @override
  Future<DealsListData> build() async => const DealsListData();

  @override
  Future<DealDetail?> getDealDetail(
    String id, {
    void Function()? onNotFound,
  }) async => DealDetail(deal: deal);
}

class _FakePipelines extends DealPipelinesNotifier {
  @override
  Future<List<DealPipeline>> build() async => const [];
}

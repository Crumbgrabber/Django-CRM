import 'package:bottle_crm/data/models/models.dart';
import 'package:bottle_crm/providers/invoice_extras_provider.dart';
import 'package:bottle_crm/providers/invoices_provider.dart';
import 'package:bottle_crm/providers/lookup_provider.dart';
import 'package:bottle_crm/screens/invoices/document_adjustments.dart';
import 'package:bottle_crm/screens/invoices/invoice_detail_screen.dart';
import 'package:bottle_crm/screens/invoices/line_item_sheet.dart';
import 'package:bottle_crm/screens/invoices/new_estimate_screen.dart';
import 'package:bottle_crm/screens/invoices/new_invoice_screen.dart';
import 'package:bottle_crm/screens/invoices/new_recurring_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:go_router/go_router.dart';

import '../../support/modules_fixtures.dart';

/// Document discount, tax and shipping on the invoice, estimate and schedule
/// forms (PARITY B5), the server's discount bounds mirrored on the phone, and
/// the invoice detail's breakdown (PARITY B6).
///
/// The server is the check that counts; these pin that the phone asks it the
/// same question the web does, with the same payload and the same wording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the adjustments ladder and payload', () {
    test('discount off the subtotal, tax on the rest, shipping untaxed', () {
      const flat = DocumentAdjustments(
        discountType: 'FIXED',
        discountValue: 20,
        taxRate: 10,
        shipping: 5,
      );
      // 200 - 20 = 180, + 18 tax, + 5 shipping.
      expect(flat.total(200), closeTo(203, 0.001));

      const percent = DocumentAdjustments(
        discountType: 'PERCENTAGE',
        discountValue: 10,
      );
      expect(percent.total(200), closeTo(180, 0.001));

      // A value with no type chosen takes nothing off and is not sent.
      const untyped = DocumentAdjustments(discountValue: 50);
      expect(untyped.total(200), 200);
      expect(untyped.toPayload(), isEmpty);
    });

    test('sends the web builders keys, and only what is set', () {
      expect(
        const DocumentAdjustments(
          discountType: 'FIXED',
          discountValue: 20,
          taxRate: 7.5,
          shipping: 5,
        ).toPayload(),
        {
          'discount_type': 'FIXED',
          'discount_value': '20.00',
          'tax_rate': '7.50',
          'shipping_amount': '5.00',
        },
      );
      expect(const DocumentAdjustments().toPayload(), isEmpty);
    });

    test('a deposit is its share of the pre-tax amount, with tax on it', () {
      // (1000 - 10%) x 30% = 270, + 10% tax = 297.
      expect(
        const DocumentAdjustments(
          discountType: 'PERCENTAGE',
          discountValue: 10,
          taxRate: 10,
        ).depositAmount(1000, 30),
        closeTo(297, 0.001),
      );
      // (500 - 50) x 25% = 112.50, no tax.
      expect(
        const DocumentAdjustments(
          discountType: 'FIXED',
          discountValue: 50,
        ).depositAmount(500, 25),
        closeTo(112.5, 0.001),
      );
      // 33.35 x 50% = 16.675, half up to 16.68 before the tax.
      expect(
        const DocumentAdjustments().depositAmount(33.35, 50),
        closeTo(16.68, 0.0001),
      );
      expect(
        const DocumentAdjustments().depositAmount(200, 100),
        closeTo(200, 0.001),
      );
    });

    // Each figure is what `estimate_deposit` bills: line gross, line discount,
    // document discount, the deposit part and its tax, each to the cent half up.
    test('a deposit rounds every step as the server bills it', () {
      double subtotal(List<LineItemDraft> lines) =>
          lines.fold(0, (sum, line) => sum + line.netCents) / 100;

      // 10.01 less 15% is 10.01 - 1.50 (not 1.5015) = 8.51; half is 4.255.
      final one = subtotal([
        const LineItemDraft(name: 'Audit', unitPrice: 10.01),
      ]);
      expect(
        const DocumentAdjustments(
          discountType: 'PERCENTAGE',
          discountValue: 15,
        ).depositAmount(one, 50),
        4.26,
      );

      // 1.5 x 1.03 = 1.545, a line gross of 1.55; 30% of it is 0.465.
      const odd = LineItemDraft(name: 'Hours', quantity: 1.5, unitPrice: 1.03);
      expect(odd.netCents, 155);
      expect(
        const DocumentAdjustments().depositAmount(subtotal([odd]), 30),
        0.47,
      );

      // The tax on the part rounds on its own: 0.425 is 0.43, 0.115 is 0.12.
      const tax = DocumentAdjustments(taxRate: 10);
      expect(tax.depositAmount(4.25, 100), 4.68);
      expect(tax.depositAmount(1.15, 100), 1.27);
    });

    test('a line discount rounds to the cent before the subtotal', () {
      // 10.01 less 15% is 8.51, so half of it is 4.26 as above.
      const line = LineItemDraft(
        name: 'Audit',
        unitPrice: 10.01,
        discountType: 'PERCENTAGE',
        discountValue: 15,
      );
      expect(line.netCents, 851);
      expect(
        const DocumentAdjustments().depositAmount(line.netAmount, 50),
        4.26,
      );
    });

    test('a deposit under half a cent comes to nothing', () {
      const none = DocumentAdjustments();
      expect(none.depositAmount(0.04, 10), 0);
      // Half a cent rounds up, so this one is drafted.
      expect(none.depositAmount(0.05, 10), 0.01);
    });

    test('refuses what the API refuses, in its words', () {
      expect(
        const DocumentAdjustments(
          discountType: 'PERCENTAGE',
          discountValue: 100.01,
        ).discountError(500),
        'A percentage discount cannot exceed 100.',
      );
      expect(
        const DocumentAdjustments(
          discountType: 'FIXED',
          discountValue: 100.01,
        ).discountError(100),
        'A discount cannot exceed the subtotal.',
      );
      // The whole subtotal off is allowed, compared in cents.
      expect(
        const DocumentAdjustments(
          discountType: 'FIXED',
          discountValue: 0.3,
        ).discountError(0.1 + 0.2),
        isNull,
      );
      expect(
        const DocumentAdjustments(
          discountType: 'PERCENTAGE',
          discountValue: 100,
        ).discountError(0),
        isNull,
      );
    });

    test('a tax rate over 100 is refused, and blocks the form', () {
      const over = DocumentAdjustments(taxRate: 100.01);
      expect(over.taxError, 'Tax rate cannot exceed 100.');
      expect(over.isValidFor(100), isFalse);
      expect(const DocumentAdjustments(taxRate: 100).taxError, isNull);
      expect(const DocumentAdjustments(taxRate: 100).isValidFor(100), isTrue);
    });

    test('a line discount cannot outgrow its line', () {
      const line = LineItemDraft(
        name: 'Seats',
        quantity: 2,
        unitPrice: 100,
        discountType: 'FIXED',
        discountValue: 150,
      );
      expect(line.discountError, isNull);
      expect(
        const LineItemDraft(
          name: 'Seats',
          quantity: 1,
          unitPrice: 100,
          discountType: 'FIXED',
          discountValue: 150,
        ).discountError,
        "A discount cannot exceed the line's amount.",
      );
      expect(const LineItemDraft(name: 'Plain').discountError, isNull);
    });
  });

  void usePhone(WidgetTester tester, double textScale) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    double textScale = 1.0,
    List overrides = const [],
  }) async {
    usePhone(tester, textScale);
    // A router, as in the app: the forms leave with `context.pop()`.
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(path: '/start', builder: (_, _) => const Text('started')),
        GoRoute(path: '/form', builder: (_, _) => screen),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...modulesOverrides(FakeOrgModules(() async => modulesAnswer())),
          accountsLookupProvider.overrideWith(_FakeAccounts.new),
          contactsLookupProvider.overrideWith(_FakeContacts.new),
          opportunityEntityOptionsProvider.overrideWithValue(
            const AsyncValue.data(<EntityLookup>[]),
          ),
          productsProvider.overrideWith(_FakeProducts.new),
          ...overrides.cast(),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.push('/form');
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('the invoice form lays out at 390px, text x$scale', (
      tester,
    ) async {
      await pump(tester, const NewInvoiceScreen(), textScale: scale);
      await scrollTo(tester, find.text('Shipping'));
      await tester.tap(find.text('No discount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixed amount').last);
      await tester.pumpAndSettle();

      expect(find.text('Amount off'), findsOneWidget);
      expect(find.text('Tax rate'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the schedule form lays out at 390px, text x$scale', (
      tester,
    ) async {
      await pump(tester, const NewRecurringScreen(), textScale: scale);
      await scrollTo(tester, find.text('Tax rate'));

      // The invoice form's own line list and adjustments card, no shipping.
      expect(find.text('Add a line'), findsOneWidget);
      expect(find.text('Shipping'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the invoice detail shows its breakdown at 390px, x$scale', (
      tester,
    ) async {
      await pump(
        tester,
        const InvoiceDetailScreen(invoiceId: 'inv-1'),
        textScale: scale,
        overrides: [invoicesProvider.overrideWith(_FakeInvoices.new)],
      );

      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text(r'$200.00'), findsOneWidget);
      expect(find.text('Discount'), findsOneWidget);
      expect(find.text(r'-$20.00'), findsOneWidget);
      expect(find.text('Tax'), findsOneWidget);
      expect(find.text(r'$18.00'), findsOneWidget);
      expect(find.text('Shipping'), findsOneWidget);
      expect(find.text(r'$5.00'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text(r'$203.00'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'the detail leaves out a discount and shipping it does not have',
    (tester) async {
      await pump(
        tester,
        const InvoiceDetailScreen(invoiceId: 'inv-1'),
        overrides: [
          invoicesProvider.overrideWith(() => _FakeInvoices(plain: true)),
        ],
      );

      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('Tax'), findsOneWidget);
      expect(find.text('Discount'), findsNothing);
      expect(find.text('Shipping'), findsNothing);
    },
  );

  testWidgets('a schedule needs a line only when it emails each invoice', (
    tester,
  ) async {
    await pump(tester, const NewRecurringScreen(), textScale: 1.3);
    FilledButton start() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start schedule'),
    );

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Account'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Northwind').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<String>, 'Bill to'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('c1 Person').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'What it is for'),
      'Hosting',
    );
    await tester.pumpAndSettle();

    // No lines and no auto-send: the API takes it, so the form does too.
    expect(start().onPressed, isNotNull);

    await scrollTo(tester, find.text('Email each invoice automatically'));
    await tester.tap(find.text('Email each invoice automatically'));
    await tester.pumpAndSettle();

    expect(
      find.text('Add at least one line before turning on auto-send.'),
      findsOneWidget,
    );
    expect(start().onPressed, isNull);

    await scrollTo(tester, find.text('Add a line'));
    await tester.tap(find.text('Add a line'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Plan',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Unit price'), '50');
    await tester.tap(find.text('Add line'));
    await tester.pumpAndSettle();

    expect(
      find.text('Add at least one line before turning on auto-send.'),
      findsNothing,
    );
    expect(start().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  group('the estimate form from a deal', () {
    late _FakeEstimates estimates;

    setUp(() => estimates = _FakeEstimates());

    Future<void> pumpEstimate(WidgetTester tester, {Deal? deal}) => pump(
      tester,
      NewEstimateScreen(fromDeal: deal ?? _deal()),
      overrides: [estimatesProvider.overrideWith(() => estimates)],
    );

    FilledButton submit(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create draft'),
    );

    Future<void> chooseFixed(WidgetTester tester, String amount) async {
      await scrollTo(tester, find.text('Tax rate'));
      await tester.tap(find.text('No discount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixed amount').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Amount off'),
        amount,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a discount over the subtotal is refused before sending', (
      tester,
    ) async {
      await pumpEstimate(tester);
      // The deal's line: 3 x 100.
      await chooseFixed(tester, '300.01');

      expect(
        find.text('A discount cannot exceed the subtotal.'),
        findsOneWidget,
      );
      expect(submit(tester).onPressed, isNull);
    });

    testWidgets("a deal line's discount holds the line's price up", (
      tester,
    ) async {
      await pumpEstimate(
        tester,
        deal: _deal(
          lineDiscount: {'discount_type': 'FIXED', 'discount_value': '50.00'},
        ),
      );
      await tester.tap(find.text('Seats'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Unit price'),
        '10',
      );
      await tester.tap(find.text('Save line'));
      await tester.pumpAndSettle();

      // 3 x 10 is less than the 50 the deal took off, which the API refuses.
      expect(
        find.text("A discount cannot exceed the line's amount."),
        findsOneWidget,
      );
      expect(find.text('Edit the line'), findsOneWidget);
    });

    testWidgets('discount and tax travel in the web payload shape', (
      tester,
    ) async {
      await pumpEstimate(tester);
      await chooseFixed(tester, '100');
      await tester.enterText(find.widgetWithText(TextField, 'Tax rate'), '10');
      await tester.pumpAndSettle();

      // (300 - 100) + 10% tax.
      expect(find.text('€220.00'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Create draft'));
      await tester.pumpAndSettle();

      final sent = estimates.created.single;
      expect(sent['discount_type'], 'FIXED');
      expect(sent['discount_value'], '100.00');
      expect(sent['tax_rate'], '10.00');
      // An estimate has no shipping.
      expect(sent.containsKey('shipping_amount'), isFalse);
      expect(find.text('started'), findsOneWidget);
    });
  });
}

Deal _deal({Map<String, dynamic> lineDiscount = const {}}) => Deal.fromJson({
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
      'quantity': 3,
      'unit_price': '100.00',
      ...lineDiscount,
    },
  ],
  'created_at': '2026-09-01T00:00:00Z',
});

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
  ];
}

class _FakeProducts extends ProductsNotifier {
  @override
  Future<List<Product>> build() async => const [];
}

class _FakeEstimates extends EstimatesNotifier {
  final List<Map<String, dynamic>> created = [];

  @override
  Future<List<Estimate>> build() async => const [];

  @override
  Future<String?> create(Map<String, dynamic> payload) async {
    created.add(payload);
    return null;
  }
}

class _FakeInvoices extends InvoicesNotifier {
  _FakeInvoices({this.plain = false});

  /// No discount and no shipping, so those rows have nothing to show.
  final bool plain;

  @override
  Future<InvoicesListData> build() async => const InvoicesListData();

  @override
  Future<Invoice?> getInvoice(String id) async => Invoice.fromJson({
    'id': id,
    'invoice_number': 'INV-1',
    'invoice_title': 'Retainer',
    'status': 'Sent',
    'currency': 'USD',
    'subtotal': '200.00',
    'discount_amount': plain ? '0.00' : '20.00',
    'tax_amount': plain ? '20.00' : '18.00',
    'shipping_amount': plain ? '0.00' : '5.00',
    'total_amount': plain ? '220.00' : '203.00',
    'amount_paid': '0.00',
    'amount_due': plain ? '220.00' : '203.00',
    'line_items': [],
    'payments': [],
  });
}

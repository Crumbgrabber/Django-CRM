import 'package:bottle_crm/data/models/invoice.dart';
import 'package:bottle_crm/data/models/project.dart';
import 'package:bottle_crm/data/models/time_billing.dart';
import 'package:bottle_crm/data/models/time_entry.dart';
import 'package:bottle_crm/providers/projects_provider.dart';
import 'package:bottle_crm/screens/projects/invoice_amount_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// A project detail exactly as the release 1 contract spells it.
Map<String, dynamic> _detail() => {
  'id': 'p1',
  'name': 'Website rebuild',
  'account': {'id': 'a1', 'name': 'Northwind'},
  'deal': {'id': 'd1', 'name': 'Rebuild deal'},
  'status': 'on_hold',
  'billing_type': 'fixed_fee',
  'currency': 'EUR',
  'budget_hours': '40.00',
  'budget_amount': '10000.00',
  'hourly_rate': '120.50',
  'start_date': '2026-10-01',
  'due_date': '2026-12-31',
  'assigned_to': [
    {
      'id': 'pr1',
      'user_details': {'name': 'Ada Lovelace', 'email': 'ada@x.io'},
    },
  ],
  'tags': [
    {'id': 't1', 'name': 'web'},
  ],
  'burn': {
    'logged_hours': '32.50',
    'billable_hours': '30.00',
    'billable_value': '3615.00',
    'unbilled_value': '1200.00',
    'invoiced_amount': '2500.00',
    'hours_percent': 81,
    'amount_percent': 36,
  },
  'created_at': '2026-10-01T09:00:00Z',
  'updated_at': '2026-10-02T09:00:00Z',
  'description': 'New marketing site',
  'custom_fields': {'po': 'PO-7'},
  'rates': [
    {
      'profile': {
        'id': 'pr1',
        'user_details': {'name': 'Ada Lovelace', 'email': 'ada@x.io'},
      },
      'hourly_rate': '150.00',
    },
  ],
  'comments': [
    {
      'id': 'c1',
      'comment': 'Kickoff done',
      'commented_on': '2026-10-02T10:00:00Z',
    },
  ],
  'attachments': [
    {'id': 'f1', 'file_name': 'brief.pdf', 'file_path': 'x/brief.pdf'},
  ],
  'invoices': [
    {
      'id': 'i1',
      'invoice_number': 'INV-0007',
      'status': 'Sent',
      'total_amount': '2500.00',
      'currency': 'EUR',
      'issue_date': '2026-10-20',
    },
  ],
  'can_edit': true,
  'can_delete': false,
  'can_bill': true,
};

TimeEntry _entry(
  String id, {
  String profile = 'pr1',
  String? task,
  String? rate = '100.00',
  int minutes = 60,
  bool billable = true,
  bool running = false,
  String? invoice,
  String currency = 'EUR',
}) => TimeEntry.fromJson({
  'id': id,
  'case': null,
  'project': 'p1',
  'project_name': 'Website rebuild',
  'task': task,
  'profile': profile,
  'started_at': '2026-10-01T09:00:00Z',
  'ended_at': running ? null : '2026-10-01T10:00:00Z',
  'duration_minutes': minutes,
  'billable': billable,
  'hourly_rate': rate,
  'currency': currency,
  'invoice': invoice,
});

void main() {
  group('parsing a project', () {
    test('reads every field of the detail', () {
      final p = Project.fromJson(_detail());

      expect(p.name, 'Website rebuild');
      expect(p.account!.name, 'Northwind');
      expect(p.deal!.id, 'd1');
      expect(p.status, ProjectStatus.onHold);
      expect(p.statusLabel, 'On hold');
      expect(p.billingType, ProjectBillingType.fixedFee);
      expect(p.isFixedFee, isTrue);
      expect(p.currency, 'EUR');
      // Kept as sent for the form, parsed for arithmetic.
      expect(p.budgetHours, '40.00');
      expect(p.budgetAmountValue, 10000);
      expect(p.hourlyRateValue, 120.5);
      expect(p.startDate, DateTime(2026, 10, 1));
      expect(p.dueDate, DateTime(2026, 12, 31));
      expect(p.assignedToIds, ['pr1']);
      expect(p.tagNames, ['web']);
      expect(p.tagIds, ['t1']);
      expect(p.burn.loggedHours, 32.5);
      expect(p.burn.unbilledValue, 1200);
      expect(p.burn.invoicedAmount, 2500);
      expect(p.burn.hoursPercent, 81);
      expect(p.rates.single.profileId, 'pr1');
      expect(p.rates.single.name, 'Ada Lovelace');
      expect(p.rates.single.value, 150);
      expect(p.comments.single.comment, 'Kickoff done');
      expect(p.attachments.single.fileName, 'brief.pdf');
      expect(p.invoices.single.status, InvoiceStatus.sent);
      expect(p.invoices.single.totalAmount, 2500);
      expect(p.invoices.single.issueDate, DateTime(2026, 10, 20));
      expect(p.customFields, {'po': 'PO-7'});
      expect((p.canEdit, p.canDelete, p.canBill), (true, false, true));
    });

    test('nulls are nulls: no deal, no budgets, no dates, no percents', () {
      final p = Project.fromJson({
        ..._detail(),
        'deal': null,
        'budget_hours': null,
        'budget_amount': null,
        'hourly_rate': null,
        'start_date': null,
        'due_date': null,
        'burn': {
          'logged_hours': '0.00',
          'billable_hours': '0.00',
          'billable_value': '0.00',
          'unbilled_value': '0.00',
          'invoiced_amount': '0.00',
          'hours_percent': null,
          'amount_percent': null,
        },
      });

      expect(p.deal, isNull);
      expect(p.budgetHours, isNull);
      expect(p.budgetAmountValue, isNull);
      expect(p.hourlyRateValue, isNull);
      expect(p.startDate, isNull);
      expect(p.dueDate, isNull);
      expect(p.burn.hoursPercent, isNull);
      expect(p.burn.headline, isNull);
    });

    test('a list item, or an older payload, falls back without breaking', () {
      final p = Project.fromJson({
        'id': 'p1',
        'name': 'Bare',
        'account': 'a1',
        'status': 'archived',
        'billing_type': 'retainer',
      });

      expect(p.account!.id, 'a1');
      expect(p.account!.name, '');
      // An unknown status keeps its own words; billing reads the default.
      expect(p.status, isNull);
      expect(p.statusLabel, 'archived');
      expect(p.billingType, ProjectBillingType.timeAndMaterials);
      expect(p.burn.loggedHours, 0);
      expect(p.rates, isEmpty);
      expect(p.invoices, isEmpty);
      expect(p.comments, isEmpty);
      expect((p.canEdit, p.canDelete, p.canBill), (false, false, false));
    });

    test('numbers sent as numbers parse like decimal strings', () {
      final p = Project.fromJson({
        ..._detail(),
        'budget_hours': 12.5,
        'burn': {'logged_hours': 3, 'hours_percent': 24.6},
      });

      expect(p.budgetHoursValue, 12.5);
      expect(p.burn.loggedHours, 3);
      expect(p.burn.hoursPercent, 25);
    });
  });

  group('the burn helpers', () {
    test('turn amber at 80 and red at 100, where notifications fire', () {
      expect(burnLevel(null), BurnLevel.under);
      expect(burnLevel(79), BurnLevel.under);
      expect(burnLevel(80), BurnLevel.warning);
      expect(burnLevel(99), BurnLevel.warning);
      expect(burnLevel(100), BurnLevel.over);
      expect(burnLevel(140), BurnLevel.over);
    });

    test('a bar never fills past full or below empty', () {
      expect(burnFraction(null), 0);
      expect(burnFraction(50), 0.5);
      expect(burnFraction(140), 1);
      expect(burnFraction(-5), 0);
    });

    test('a list row shows the budget closest to running out', () {
      ProjectBurn burn(int? h, int? a) =>
          ProjectBurn(hoursPercent: h, amountPercent: a);
      expect(burn(81, 36).headline, (percent: 81, kind: 'hours'));
      expect(burn(20, 90).headline, (percent: 90, kind: 'amount'));
      expect(burn(null, 40).headline, (percent: 40, kind: 'amount'));
      expect(burn(40, null).headline, (percent: 40, kind: 'hours'));
      expect(burn(50, 50).headline, (percent: 50, kind: 'hours'));
      expect(burn(null, null).headline, isNull);
    });

    test('hours drop their trailing zeros', () {
      expect(hoursLabel(12.5), '12.5');
      expect(hoursLabel(40), '40');
      expect(hoursLabel(0.25), '0.25');
      expect(hoursLabel(0), '0');
    });
  });

  group('the draft from a deal', () {
    test('a deal with an amount drafts a fixed fee', () {
      final d = ProjectDraft.fromJson({
        'name': 'Rebuild deal',
        'account': {'id': 'a1', 'name': 'Northwind'},
        'deal': {'id': 'd1', 'name': 'Rebuild deal'},
        'currency': 'EUR',
        'assigned_to': ['pr1', 'pr2'],
        'billing_type': 'fixed_fee',
        'budget_amount': '10000.00',
      });

      expect(d.name, 'Rebuild deal');
      expect(d.account!.name, 'Northwind');
      expect(d.deal!.id, 'd1');
      expect(d.assignedToIds, ['pr1', 'pr2']);
      expect(d.billingType, ProjectBillingType.fixedFee);
      expect(d.budgetAmount, '10000.00');
    });

    test('bare ids and a deal with no amount read as time and materials', () {
      final d = ProjectDraft.fromJson({
        'name': 'Support',
        'account': 'a1',
        'deal': 'd1',
        'currency': null,
        'assigned_to': [
          {'id': 'pr1'},
        ],
        'billing_type': 'time_and_materials',
        'budget_amount': null,
      });

      expect(d.account!.id, 'a1');
      expect(d.deal!.id, 'd1');
      expect(d.currency, isNull);
      expect(d.assignedToIds, ['pr1']);
      expect(d.billingType, ProjectBillingType.timeAndMaterials);
      expect(d.budgetAmount, isNull);
    });
  });

  test('the unbilled preview parses its decimals and its unrated count', () {
    final u = ProjectUnbilled.fromJson({
      'entry_count': 3,
      'hours': '4.50',
      'value': '540.00',
      'currency': 'EUR',
      'unrated_count': 1,
    });
    expect((u.entryCount, u.hours, u.value, u.currency), (3, 4.5, 540, 'EUR'));
    expect(u.unratedCount, 1);
    // An older API sends no count.
    expect(ProjectUnbilled.fromJson(const {'entry_count': 1}).unratedCount, 0);
  });

  test('an invoiced amount the caller may not see stays null, not 0', () {
    final p = Project.fromJson({
      ..._detail(),
      'burn': {..._detail()['burn'] as Map, 'invoiced_amount': null},
    });
    expect(p.burn.invoicedAmount, isNull);
    expect(Project.fromJson(_detail()).burn.invoicedAmount, 2500);
  });

  group('typed numbers', () {
    test('only digits and a decimal point parse', () {
      expect(parseDecimalText('12'), 12);
      expect(parseDecimalText(' 12.5 '), 12.5);
      expect(parseDecimalText('.5'), 0.5);
      expect(parseDecimalText('12.'), 12);
      for (final odd in [
        '',
        'NaN',
        'Infinity',
        '1e3',
        '1E3',
        '-5',
        '0x10',
        '1,5',
        '1.2.3',
      ]) {
        expect(parseDecimalText(odd), isNull, reason: odd);
      }
    });

    test(
      'an amount is sent with two places, a percent as the web rounds it',
      () {
        expect(amountParam(1200.5), '1200.50');
        expect(amountParam(7), '7.00');
        expect(percentParam(25), '25');
        expect(percentParam(33.333), '33.33');
        expect(percentParam(12.5), '12.5');
        expect(percentParam(99.999), '100');
      },
    );
  });

  test('the list filters become exactly the contract parameters', () {
    expect(const ProjectFilters().query, isEmpty);
    expect(
      const ProjectFilters(
        search: '  site ',
        status: 'active',
        accountId: 'a1',
        accountName: 'Northwind',
      ).query,
      {'search': 'site', 'status': 'active', 'account': 'a1'},
    );
  });

  group('the grouping helpers', () {
    test('Bill time takes stopped, billable, unbilled entries only', () {
      final entries = [
        _entry('ok'),
        _entry('running', running: true),
        _entry('internal', billable: false),
        _entry('billed', invoice: 'i1'),
      ];
      expect(unbilledEntries(entries).map((e) => e.id), ['ok']);
    });

    test('lines split by group, then by rate', () {
      final entries = [
        _entry('e1', profile: 'ada', task: 'design'),
        _entry('e2', profile: 'ada', task: 'build'),
        _entry('e3', profile: 'bob', task: 'build'),
        _entry('e4', profile: 'bob', task: 'build', rate: '80.00'),
        _entry('e5', profile: 'bob'),
      ];
      expect(billLineCount(entries, BillGrouping.entry), 5);
      // ada at 100; bob at 100 and at 80.
      expect(billLineCount(entries, BillGrouping.person), 3);
      // design, build at 100, build at 80, and the no-task line.
      expect(billLineCount(entries, BillGrouping.task), 4);
      // One line per rate.
      expect(billLineCount(entries, BillGrouping.single), 2);
      expect(billLineCount(const [], BillGrouping.single), 0);
    });

    test('the summary adds hours and the value at each saved rate', () {
      final s = UnbilledSummary.of([
        _entry('e1', minutes: 90),
        _entry('e2', minutes: 30, rate: null),
      ]);
      expect(s.entryCount, 2);
      expect(s.hours, 2);
      expect(s.value, 150);
      expect(s.currency, 'EUR');
      expect(s.isMixedCurrency, isFalse);
    });

    test('entries with no rate are counted, since they bill at 0', () {
      final s = UnbilledSummary.of([
        _entry('e1'),
        _entry('e2', rate: null),
        _entry('e3', rate: null),
      ]);
      expect(s.unratedCount, 2);
      expect(UnbilledSummary.of([_entry('e1')]).unratedCount, 0);
    });

    test('two currencies are flagged, since one invoice takes one', () {
      final s = UnbilledSummary.of([
        _entry('e1'),
        _entry('e2', currency: 'USD'),
      ]);
      expect(s.isMixedCurrency, isTrue);
      expect(s.currency, isNull);
      expect(s.currencies, ['EUR', 'USD']);
    });

    test('the groupings send the contract values', () {
      // In the web's order; the sheet starts on one line per entry.
      expect(BillGrouping.values.map((g) => g.value), [
        'single',
        'person',
        'task',
        'entry',
      ]);
    });
  });
}

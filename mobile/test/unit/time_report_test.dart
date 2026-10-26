import 'package:bottle_crm/config/api_config.dart';
import 'package:bottle_crm/data/models/time_report.dart';
import 'package:bottle_crm/providers/time_report_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The time report: what the API sends, and what the screen asks it for.
///
/// The money is the part worth pinning. It arrives as a decimal string,
/// because the API builds it from Decimal columns and a JSON number would
/// round it in transit, so anything that parses it has to say so out loud.

Map<String, dynamic> payload({
  List<Map<String, dynamic>>? rows,
  Map<String, dynamic>? totals,
  List<String> currencies = const ['USD'],
  String groupBy = 'agent',
}) => {
  'start': '2026-08-01',
  'end': '2026-08-31',
  'group_by': groupBy,
  'rows':
      rows ??
      [
        {
          'key': 'p1',
          'name': 'Aswani Kumar',
          'total_minutes': 135,
          'billable_minutes': 105,
          'billable_value': '135.50',
          'entry_count': 3,
        },
      ],
  'totals':
      totals ??
      {
        'total_minutes': 135,
        'billable_minutes': 105,
        'billable_value': '135.50',
        'entry_count': 3,
      },
  'currencies': currencies,
};

void main() {
  group('parsing a report', () {
    test('reads the window, the rows and the totals', () {
      final report = TimeReport.fromJson(payload());

      expect(report.start, DateTime(2026, 8, 1));
      expect(report.end, DateTime(2026, 8, 31));
      expect(report.groupBy, 'agent');
      expect(report.totalMinutes, 135);
      expect(report.billableMinutes, 105);
      expect(report.billableValue, 135.5);
      expect(report.entryCount, 3);
      expect(report.rows.single.name, 'Aswani Kumar');
      expect(report.rows.single.billableValue, 135.5);
    });

    test('parses a date as local midnight, not UTC midnight', () {
      // A UTC midnight read in a zone behind Greenwich lands on the previous
      // day and mislabels the window by one.
      final report = TimeReport.fromJson(payload());

      expect(report.start.hour, 0);
      expect(report.start.day, 1);
      expect(report.start.isUtc, isFalse);
    });

    test('an empty report is empty rather than broken', () {
      final report = TimeReport.fromJson({
        'start': '2026-08-01',
        'end': '2026-08-31',
        'group_by': 'ticket',
        'rows': <Map<String, dynamic>>[],
        'totals': <String, dynamic>{},
        'currencies': <String>[],
      });

      expect(report.isEmpty, isTrue);
      expect(report.totalMinutes, 0);
      expect(report.billableValue, 0);
      expect(report.billableShare, 0);
      expect(report.currency, isNull);
    });

    test('a row with no key is the unattributed bucket, not a broken row', () {
      final report = TimeReport.fromJson(
        payload(
          groupBy: 'account',
          rows: [
            {
              'key': null,
              'name': 'No account',
              'total_minutes': 20,
              'billable_minutes': 0,
              'billable_value': '0.00',
              'entry_count': 1,
            },
          ],
        ),
      );

      expect(report.rows.single.key, isNull);
      expect(report.rows.single.name, 'No account');
    });

    test('two currencies in the window are flagged, not averaged into one', () {
      final report = TimeReport.fromJson(payload(currencies: ['EUR', 'USD']));

      expect(report.isMixedCurrency, isTrue);
      // Null, so nothing can put one symbol in front of a sum of two.
      expect(report.currency, isNull);
    });

    test('the billable share is a percentage of logged time', () {
      final report = TimeReport.fromJson(payload());

      expect(report.billableShare, 78);
    });
  });

  group('the billable share per agent', () {
    test('reads the share as a fraction and shows it as a percent', () {
      final row = TimeReportRow.fromJson({
        'key': 'p1',
        'name': 'Ada',
        'total_minutes': 600,
        'billable_minutes': 375,
        'billable_share': 0.63,
      });
      expect(row.billableShare, 0.63);
      expect(row.billableSharePercent, 63);
      expect(row.billableMinutes, 375);
    });

    test('a row with no time, another grouping or an older API has none', () {
      for (final json in [
        {'name': 'Ada', 'billable_share': null},
        {'name': 'Northwind'},
      ]) {
        final row = TimeReportRow.fromJson(json);
        expect(row.billableShare, isNull);
        expect(row.billableSharePercent, isNull);
      }
    });

    test('a whole share reads as 100 percent', () {
      final row = TimeReportRow.fromJson({
        'name': 'Ada',
        'billable_share': 1.0,
      });
      expect(row.billableSharePercent, 100);
    });
  });

  test('the report can be asked for by project', () {
    final url = ApiConfig.timeReport(
      start: '2026-10-01',
      end: '2026-10-31',
      groupBy: 'project',
    );
    expect(Uri.parse(url).queryParameters['group_by'], 'project');
  });

  group('what the screen asks for', () {
    test('the default window is the last 30 days, inclusive', () {
      final filters = TimeReportFilters.recent();

      expect(filters.end.difference(filters.start).inDays, 29);
      expect(filters.groupBy, 'agent');
      expect(filters.billable, isNull);
    });

    test('the URL carries the window, the grouping and nothing else', () {
      final url = ApiConfig.timeReport(
        start: '2026-08-01',
        end: '2026-08-31',
        groupBy: 'account',
      );

      expect(url, contains('start=2026-08-01'));
      expect(url, contains('end=2026-08-31'));
      expect(url, contains('group_by=account'));
      // The API rejects an unknown `billable`, so it is sent only when picked.
      expect(url, isNot(contains('billable')));
    });

    test('the billable filter is sent when it is picked', () {
      final url = ApiConfig.timeReport(
        start: '2026-08-01',
        end: '2026-08-31',
        groupBy: 'agent',
        billable: 'true',
      );

      expect(url, contains('billable=true'));
    });

    test('clearing the billable filter is not the same as choosing false', () {
      // 'false' asks for non-billable time; null asks for all of it. Folding
      // the two together would quietly hide every billable hour.
      final filters = TimeReportFilters(
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 2, 1),
        billable: 'false',
      );

      expect(filters.copyWith(clearBillable: true).billable, isNull);
      expect(filters.copyWith(groupBy: 'ticket').billable, 'false');
    });
  });
}

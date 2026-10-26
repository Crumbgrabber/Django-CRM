/// Where the time went, as `/api/time-entries/report/` returns it.
///
/// The timesheet answers "what did I do this week". This answers the question
/// asked of that data afterwards, usually by somebody else: how much of the
/// month went to this account, and how much of it can be billed.
///
/// Money arrives as a string, not a double, because the API builds it from
/// Decimal columns and a JSON number would round it on the way. It is parsed
/// once here rather than at every call site.
library;

import '../api/schema.g.dart' as api;

/// One grouped row: an agent, a ticket, an account or a project.
class TimeReportRow {
  const TimeReportRow({
    required this.name,
    this.key,
    this.totalMinutes = 0,
    this.billableMinutes = 0,
    this.billableValue = 0,
    this.entryCount = 0,
    this.billableShare,
  });

  /// The id of the thing this row groups, or null where there is none: time
  /// on tickets with no account lands in a named bucket rather than being
  /// dropped, and unattributed time is exactly what a report is run to find.
  final String? key;
  final String name;
  final int totalMinutes;
  final int billableMinutes;
  final double billableValue;
  final int entryCount;

  /// Billable over logged time, 0 to 1, on rows grouped by agent. Null on
  /// every other grouping, with no time, and from an API older than it.
  final double? billableShare;

  bool get isBillableOnly => billableMinutes == totalMinutes;

  int? get billableSharePercent {
    final share = billableShare;
    return share == null ? null : (share * 100).round();
  }

  /// Reads a `TimeReportRow`.
  factory TimeReportRow.fromJson(Map<String, dynamic> json) {
    final w = api.TimeReportRow.fromJson(json);
    return TimeReportRow(
      key: w.key,
      name: w.name ?? '',
      totalMinutes: w.totalMinutes ?? 0,
      billableMinutes: w.billableMinutes ?? 0,
      billableValue: _money(w.billableValue),
      entryCount: w.entryCount ?? 0,
      billableShare: w.billableShare,
    );
  }
}

/// The whole report: the window the server actually reported on, the rows,
/// and the totals under them.
class TimeReport {
  const TimeReport({
    required this.start,
    required this.end,
    this.groupBy = 'agent',
    this.rows = const [],
    this.totalMinutes = 0,
    this.billableMinutes = 0,
    this.billableValue = 0,
    this.entryCount = 0,
    this.currencies = const [],
  });

  /// Read back from the response rather than kept from the request: asked for
  /// without a window, the API picks the last 30 days, and the header has to
  /// name the days actually reported on.
  final DateTime start;
  final DateTime end;
  final String groupBy;
  final List<TimeReportRow> rows;

  final int totalMinutes;
  final int billableMinutes;
  final double billableValue;
  final int entryCount;

  /// Every currency present in the window. The value totals add across all of
  /// them, so more than one here means no single symbol can label the figure
  /// honestly and the screen says so instead of picking one.
  final List<String> currencies;

  bool get isEmpty => rows.isEmpty;

  bool get isMixedCurrency => currencies.length > 1;

  String? get currency => currencies.length == 1 ? currencies.first : null;

  int get billableShare =>
      totalMinutes == 0 ? 0 : ((billableMinutes / totalMinutes) * 100).round();

  /// Reads a `TimeReport`.
  factory TimeReport.fromJson(Map<String, dynamic> json) {
    final w = api.TimeReport.fromJson(json);
    final totals = w.totals;
    return TimeReport(
      start: _date(w.start),
      end: _date(w.end),
      groupBy: w.groupBy ?? 'agent',
      rows: [
        for (final r in w.rows ?? const <api.TimeReportRow>[])
          TimeReportRow.fromJson(r.json),
      ],
      totalMinutes: totals?.totalMinutes ?? 0,
      billableMinutes: totals?.billableMinutes ?? 0,
      billableValue: _money(totals?.billableValue),
      entryCount: totals?.entryCount ?? 0,
      currencies: w.currencies ?? const [],
    );
  }
}

/// A decimal string from the API as a double. Absent or unparseable is 0,
/// never null: a missing total is nothing logged, and every caller would
/// otherwise write the same `?? 0`.
double _money(String? value) => double.tryParse(value ?? '') ?? 0;

/// A YYYY-MM-DD string as a local calendar date.
///
/// Parsed with an explicit midnight rather than `DateTime.parse` on the bare
/// date, so it is local midnight and not UTC midnight: reading a UTC midnight
/// in a zone behind Greenwich lands on the previous day and mislabels the
/// window by one.
DateTime _date(String? value) =>
    DateTime.tryParse('${value ?? ''}T00:00:00') ?? DateTime.now();

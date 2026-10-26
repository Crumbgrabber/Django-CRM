import '../api/schema.g.dart' as api;

/// The invoice reports, from `/invoices/reports/dashboard/` and
/// `/invoices/reports/aging/`.
///
/// **Both endpoints are admin-only.** `_forbid_non_admin_reports` answers 403
/// to everyone else, so a non-admin opening this screen gets a refusal from
/// the server rather than an empty report, and the screen says so.
///
/// Every invoice carries its own currency and there are no exchange rates, so
/// the server never adds two currencies together: each money figure arrives as
/// a `by_currency` list, and it is kept here as one entry per currency code.
class InvoiceDashboard {
  const InvoiceDashboard({
    this.money = const {},
    this.invoiceCount = 0,
    this.averageDaysToPay = 0,
    this.statusCounts = const {},
    this.estimatesPending = 0,
    this.estimatesAccepted = 0,
    this.estimatesDeclined = 0,
  });

  /// The money figures, keyed by currency code.
  final Map<String, DashboardMoney> money;
  final int invoiceCount;

  /// Issue date to payment date, in whole days, over paid invoices carrying
  /// both dates. Zero when nothing has been paid yet, which is why the screen
  /// hides it rather than printing "0 days to pay" for a new org.
  final int averageDaysToPay;

  final Map<String, int> statusCounts;
  final int estimatesPending;
  final int estimatesAccepted;
  final int estimatesDeclined;

  /// Reads an `InvoiceDashboard`.
  factory InvoiceDashboard.fromJson(Map<String, dynamic> json) {
    final w = api.InvoiceDashboard.fromJson(json);
    final summary = _byCurrency(
      w.summary?.json,
      w.summary?.byCurrency,
      (r) => r.currency,
      api.InvoiceDashboardSummaryCurrency.fromJson,
    );
    final overdue = _byCurrency(
      w.overdue?.json,
      w.overdue?.byCurrency,
      (r) => r.currency,
      api.InvoiceDashboardOverdueCurrency.fromJson,
    );
    final recent = _byCurrency(
      w.recentActivity?.json,
      w.recentActivity?.byCurrency,
      (r) => r.currency,
      api.InvoiceDashboardRecentCurrency.fromJson,
    );
    return InvoiceDashboard(
      money: {
        for (final code in {...summary.keys, ...overdue.keys, ...recent.keys})
          code: DashboardMoney(
            totalInvoiced: _num(summary[code]?.totalInvoiced),
            totalPaid: _num(summary[code]?.totalPaid),
            totalDue: _num(summary[code]?.totalDue),
            overdueCount: overdue[code]?.count ?? 0,
            overdueAmount: _num(overdue[code]?.amount),
            revenue30d: _num(recent[code]?.revenue30d),
            invoiced30d: _num(recent[code]?.invoiced30d),
          ),
      },
      invoiceCount: w.invoiceCount ?? 0,
      averageDaysToPay: w.averageDaysToPay ?? 0,
      statusCounts: w.statusCounts ?? const {},
      estimatesPending: w.estimates?.pending ?? 0,
      estimatesAccepted: w.estimates?.accepted ?? 0,
      estimatesDeclined: w.estimates?.declined ?? 0,
    );
  }
}

/// The dashboard's money in one currency.
class DashboardMoney {
  const DashboardMoney({
    this.totalInvoiced = 0,
    this.totalPaid = 0,
    this.totalDue = 0,
    this.overdueCount = 0,
    this.overdueAmount = 0,
    this.revenue30d = 0,
    this.invoiced30d = 0,
  });

  final double totalInvoiced;
  final double totalPaid;
  final double totalDue;
  final int overdueCount;
  final double overdueAmount;
  final double revenue30d;
  final double invoiced30d;
}

/// One ageing bucket. The server caps `invoices` at ten per bucket while
/// `count` and `amount` cover the whole bucket, so the two disagree on purpose
/// and the screen must not present the listed rows as the total.
class AgingBucket {
  const AgingBucket({required this.label, this.count = 0, this.amount = 0});

  final String label;
  final int count;
  final double amount;

  /// Reads one currency's `AgingBucketCurrency` row of a bucket.
  factory AgingBucket.fromJson(String label, Map<String, dynamic>? json) {
    final w = api.AgingBucketCurrency.fromJson(json ?? const {});
    return AgingBucket(
      label: label,
      count: w.count ?? 0,
      amount: _num(w.amount),
    );
  }
}

/// Accounts receivable ageing in one currency, oldest money first.
class AgingReport {
  const AgingReport({
    this.buckets = const [],
    this.total = 0,
    this.overdue = 0,
  });

  final List<AgingBucket> buckets;

  /// The server's own figure over every unpaid invoice, not a sum of the
  /// buckets above. They should agree, and when they do not the server is
  /// right: it counted the whole queryset while a bucket list can be capped.
  final double total;

  /// Past the due date only, so `total` minus what is merely not yet due.
  final double overdue;

  /// The buckets' labels, in the order [byCurrencyFromJson] reads them.
  static const _labels = [
    'Not yet due',
    '1 to 30 days',
    '31 to 60 days',
    '61 to 90 days',
    'Over 90 days',
  ];

  /// Reads an `AgingReport`: one report per currency code the response has
  /// unpaid money in.
  static Map<String, AgingReport> byCurrencyFromJson(
    Map<String, dynamic> json,
  ) {
    final w = api.AgingReport.fromJson(json);
    final total = _byCurrency(
      w.total?.json,
      w.total?.byCurrency,
      (r) => r.currency,
      api.AgingTallyCurrency.fromJson,
    );
    final overdue = _byCurrency(
      w.overdue?.json,
      w.overdue?.byCurrency,
      (r) => r.currency,
      api.AgingTallyCurrency.fromJson,
    );
    final buckets = [
      for (final b in [
        w.current,
        w.v130Days,
        w.v3160Days,
        w.v6190Days,
        w.over90Days,
      ])
        _byCurrency(
          b?.json,
          b?.byCurrency,
          (r) => r.currency,
          api.AgingBucketCurrency.fromJson,
        ),
    ];
    return {
      for (final code in total.keys)
        code: AgingReport(
          buckets: [
            for (final (i, label) in _labels.indexed)
              AgingBucket.fromJson(label, buckets[i][code]?.json),
          ],
          total: _num(total[code]?.amount),
          overdue: _num(overdue[code]?.amount),
        ),
    };
  }

  /// Every bucket at zero, for a currency with nothing unpaid.
  static final empty = AgingReport(
    buckets: [for (final label in _labels) AgingBucket(label: label)],
  );
}

double _num(String? value) => double.tryParse(value ?? '') ?? 0;

/// A report block's `by_currency` rows, keyed by currency code.
///
/// A server older than the per-currency reports sends only the plain figures;
/// the block itself is then read as one row under an empty code, which the
/// screen labels with the org's own currency, as it always did.
Map<String, R> _byCurrency<R>(
  Map<String, dynamic>? block,
  List<R>? rows,
  String? Function(R row) currency,
  R Function(Map<String, dynamic> json) row,
) {
  if (rows == null) {
    return block == null || block.isEmpty ? const {} : {'': row(block)};
  }
  return {for (final r in rows) ?currency(r): r};
}

import '../api/schema.g.dart' as api;

/// An account's statement (#810), from `GET /api/invoices/statements/<id>/`.
///
/// Per currency the server sends an opening balance, the period's invoices,
/// payments and cancellations in date order with a running balance, and a
/// closing balance. It does all the arithmetic, and the web page and the PDF
/// show the same figures; nothing here adds money up.
///
/// **Admin-only on the server**, like the invoice reports: a statement sums
/// every invoice on the account, including ones a member may not open.
class AccountStatement {
  const AccountStatement({
    required this.accountId,
    required this.accountName,
    required this.startDate,
    required this.endDate,
    required this.sections,
  });

  final String accountId;
  final String accountName;

  /// The period, `YYYY-MM-DD`, both days included.
  final String startDate;
  final String endDate;

  /// One per currency, ordered by code. Empty when nothing was billed or paid
  /// in the period and nothing is owed.
  final List<StatementSection> sections;

  /// Reads an `AccountStatement`.
  factory AccountStatement.fromJson(Map<String, dynamic> json) {
    final w = api.AccountStatement.fromJson(json);
    return AccountStatement(
      accountId: w.account?.id ?? '',
      accountName: w.account?.name ?? '',
      startDate: w.startDate ?? '',
      endDate: w.endDate ?? '',
      sections: [
        for (final section in w.currencies ?? const <api.StatementCurrency>[])
          StatementSection.fromJson(section.json),
      ],
    );
  }
}

/// The statement in one currency. Never added to another: there are no
/// exchange rates.
class StatementSection {
  const StatementSection({
    required this.currency,
    required this.openingBalance,
    required this.invoiced,
    required this.paid,
    required this.cancelled,
    required this.closingBalance,
    required this.entries,
  });

  final String currency;
  final double openingBalance;
  final double invoiced;
  final double paid;
  final double cancelled;

  /// Negative when the account is in credit.
  final double closingBalance;
  final List<StatementEntry> entries;

  /// Reads a `StatementCurrency`.
  factory StatementSection.fromJson(Map<String, dynamic> json) {
    final w = api.StatementCurrency.fromJson(json);
    return StatementSection(
      currency: w.currency ?? '',
      openingBalance: _num(w.openingBalance),
      invoiced: _num(w.invoiced),
      paid: _num(w.paid),
      cancelled: _num(w.cancelled),
      closingBalance: _num(w.closingBalance),
      entries: [
        for (final entry in w.entries ?? const <api.StatementEntry>[])
          StatementEntry.fromJson(entry.json),
      ],
    );
  }
}

/// One line: an invoice billed, a payment, or a cancellation.
class StatementEntry {
  const StatementEntry({
    required this.date,
    required this.kind,
    required this.invoiceId,
    required this.invoiceNumber,
    required this.description,
    required this.amount,
    required this.balance,
  });

  /// `YYYY-MM-DD`.
  final String date;

  /// `invoice`, `payment` or `cancellation`.
  final String kind;
  final String invoiceId;
  final String invoiceNumber;
  final String description;

  /// Signed: positive adds to what the account owes, negative takes from it.
  final double amount;

  /// What the account owes after this line.
  final double balance;

  /// Reads a `StatementEntry`.
  factory StatementEntry.fromJson(Map<String, dynamic> json) {
    final w = api.StatementEntry.fromJson(json);
    return StatementEntry(
      date: w.date ?? '',
      kind: w.kind ?? '',
      invoiceId: w.invoiceId ?? '',
      invoiceNumber: w.invoiceNumber ?? '',
      description: w.description ?? '',
      amount: _num(w.amount),
      balance: _num(w.balance),
    );
  }
}

/// The whole calendar month before the one [iso] (`YYYY-MM-DD`) falls in.
/// Statements are read a month at a time, and stepping back by a tap beats
/// two date pickers.
({String start, String end}) previousMonth(String iso) {
  final day = DateTime.parse(iso);
  final first = DateTime(day.year, day.month - 1, 1);
  // Day 0 of the following month is this month's last day.
  final last = DateTime(first.year, first.month + 1, 0);
  String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return (start: ymd(first), end: ymd(last));
}

double _num(String? value) => double.tryParse(value ?? '') ?? 0;

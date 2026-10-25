import 'time_entry.dart';

/// How `POST /api/invoices/from-time-entries/` groups entries into lines.
/// A grouped line's quantity is the summed hours at the shared rate; entries
/// of one group with different rates split into one line per rate.
enum BillGrouping {
  single('single', 'One line for everything'),
  person('person', 'One line per person'),
  task('task', 'One line per task'),
  entry('entry', 'One line per entry');

  const BillGrouping(this.value, this.label);

  final String value;
  final String label;
}

/// The entries Bill time takes from a list: stopped, billable, not billed.
List<TimeEntry> unbilledEntries(Iterable<TimeEntry> entries) => [
  for (final e in entries)
    if (!e.isRunning && e.billable && !e.isBilled) e,
];

/// The invoice lines [entries] would make under [grouping], counted the way
/// the server groups them: by the group's key, then by rate. Entries without
/// a task share one task line.
int billLineCount(Iterable<TimeEntry> entries, BillGrouping grouping) {
  final keys = <String>{};
  for (final e in entries) {
    final group = switch (grouping) {
      BillGrouping.entry => e.id,
      BillGrouping.person => e.profileId,
      BillGrouping.task => e.taskId ?? '',
      BillGrouping.single => '',
    };
    keys.add('$group|${e.hourlyRate}');
  }
  return keys.length;
}

/// A preview of what Bill time would draft from [entries]: how many, how
/// long, and what they are worth at their saved rates. An entry with no rate
/// adds its hours and nothing to the value, as the invoice line does.
class UnbilledSummary {
  const UnbilledSummary({
    this.entryCount = 0,
    this.minutes = 0,
    this.value = 0,
    this.currencies = const [],
    this.unratedCount = 0,
  });

  final int entryCount;
  final int minutes;
  final double value;
  final List<String> currencies;

  /// Entries with no rate, which bill at 0.
  final int unratedCount;

  double get hours => minutes / 60;

  /// The API refuses to bill two currencies onto one invoice.
  bool get isMixedCurrency => currencies.length > 1;

  String? get currency => currencies.length == 1 ? currencies.first : null;

  factory UnbilledSummary.of(Iterable<TimeEntry> entries) {
    var count = 0, minutes = 0, unrated = 0;
    var value = 0.0;
    final currencies = <String>{};
    for (final e in entries) {
      final m = e.durationMinutes ?? 0;
      count++;
      minutes += m;
      final rate = e.hourlyRate;
      if (rate != null) {
        value += m / 60 * rate;
      } else {
        unrated++;
      }
      final c = e.currency;
      if (c != null && c.isNotEmpty) currencies.add(c);
    }
    return UnbilledSummary(
      entryCount: count,
      minutes: minutes,
      value: value,
      currencies: currencies.toList()..sort(),
      unratedCount: unrated,
    );
  }
}

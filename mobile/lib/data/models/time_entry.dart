import '../api/schema.g.dart' as api;

/// Time-tracking entry on a ticket or a project. Ended-null = currently
/// running.
///
/// Mirrors `cases.serializer.TimeEntrySerializer`, which two endpoints emit in
/// two shapes. On a ticket's own list `case` and `invoice` are bare ids; on
/// `/time-entries/timesheet/` the view expands both to objects, because that
/// page shows a week across many tickets and an id is not a name. `fromJson`
/// reads either, so `caseId` is an id in both and never the string
/// `"{id: ..., name: ...}"`, which is what `.toString()` on the object form
/// used to produce.
///
/// At most one of `case` and `project` is set. Both are null on an entry
/// whose project was deleted: it keeps existing with no parent, and every
/// screen shows it without a link.
class TimeEntry {
  final String id;

  /// Empty when the entry is not on a ticket.
  final String caseId;

  /// Present only where the server expands the ticket (the timesheet).
  final String? caseName;

  final String? projectId;
  final String? projectName;

  /// A task on the entry's project, or null.
  final String? taskId;
  final String profileId;
  final String? profileName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? durationMinutes;
  final bool billable;
  final String? description;

  /// Set once the entry has been billed. A billed entry is shown as billed and
  /// never offered for editing: double-billing an hour is a refund.
  final String? invoiceId;
  final String? invoiceNumber;

  /// True once billed, even while Invoices is off and `invoice` is null.
  final bool invoiced;

  /// The rate as it stood when this entry was logged, and the currency it was
  /// logged in. Both are snapshotted per entry precisely so a rate change next
  /// month does not rewrite what last month was worth. Sent as a decimal
  /// string, so parsed rather than cast.
  final double? hourlyRate;
  final String? currency;

  /// The server's own count of minutes elapsed on a running timer, taken at
  /// response time. The phone's clock is a rendering detail, not the truth
  /// about how long somebody has been working, so the screen counts up from
  /// this rather than from `DateTime.now()` against `startedAt`.
  final int? liveDurationMinutes;

  const TimeEntry({
    required this.id,
    required this.caseId,
    this.caseName,
    this.projectId,
    this.projectName,
    this.taskId,
    required this.profileId,
    this.profileName,
    required this.startedAt,
    this.endedAt,
    this.durationMinutes,
    this.billable = false,
    this.description,
    this.invoiceId,
    this.invoiceNumber,
    this.invoiced = false,
    this.hourlyRate,
    this.currency,
    this.liveDurationMinutes,
  });

  bool get isRunning => endedAt == null;

  bool get isBilled => invoiced || invoiceId != null;

  bool get isOnTicket => caseId.isNotEmpty;

  bool get isOnProject => (projectId ?? '').isNotEmpty;

  /// What the entry was logged against, or null for an entry with neither.
  String? get sourceName {
    if (isOnProject) return projectName ?? 'a project';
    if (isOnTicket) return caseName ?? 'a ticket';
    return null;
  }

  /// Where the entry's parent opens, or null for an entry with neither.
  String? get sourcePath {
    if (isOnProject) return '/projects/$projectId';
    if (isOnTicket) return '/tickets/$caseId';
    return null;
  }

  /// Live duration, including currently-running timers.
  Duration get liveDuration {
    final end = endedAt ?? DateTime.now();
    return end.difference(startedAt);
  }

  /// Minutes this entry contributes to a total, `elapsed` minutes after the
  /// response was received. A stopped entry ignores `elapsed`: its duration is
  /// settled and must not drift upwards while the screen is open.
  int minutesAt(int elapsed) {
    if (!isRunning) return durationMinutes ?? 0;
    final base = liveDurationMinutes ?? liveDuration.inMinutes;
    return base + elapsed;
  }

  /// Reads a `TimesheetEntry` (the timesheet) or a `TimeEntry` (a ticket's or
  /// a project's list), the two shapes described above.
  factory TimeEntry.fromJson(Map<String, dynamic> json) {
    final w = api.TimesheetEntry.fromJson(json);
    final flat = api.TimeEntry.fromJson(json);
    String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
    return TimeEntry(
      id: w.id ?? '',
      caseId: w.case_?.id ?? flat.case_ ?? '',
      caseName: w.case_?.name,
      projectId: nonEmpty(w.project),
      projectName: w.projectName,
      taskId: nonEmpty(w.task),
      profileId: w.profile?.id ?? '',
      profileName: w.profile?.userDetails?.email,
      startedAt: DateTime.tryParse(w.startedAt ?? '') ?? DateTime.now(),
      endedAt: DateTime.tryParse(w.endedAt ?? ''),
      durationMinutes: w.durationMinutes,
      billable: w.billable ?? false,
      description: w.description,
      invoiceId: w.invoice?.id ?? flat.invoice,
      invoiceNumber: w.invoice?.invoiceNumber,
      invoiced: w.invoiced ?? false,
      hourlyRate: double.tryParse(w.hourlyRate ?? ''),
      currency: w.currency,
      liveDurationMinutes: w.liveDurationMinutes,
    );
  }
}

/// Aggregate totals for a ticket. Mirrors `CaseSerializer.time_summary`.
class TimeSummary {
  final int totalMinutes;
  final int billableMinutes;
  final DateTime? lastEntryAt;
  final List<TimeSummaryByProfile> byProfile;

  const TimeSummary({
    this.totalMinutes = 0,
    this.billableMinutes = 0,
    this.lastEntryAt,
    this.byProfile = const [],
  });

  /// Reads a ticket's `CaseTimeSummary`.
  factory TimeSummary.fromJson(Map<String, dynamic> json) {
    final w = api.CaseTimeSummary.fromJson(json);
    return TimeSummary(
      totalMinutes: w.totalMinutes ?? 0,
      billableMinutes: w.billableMinutes ?? 0,
      lastEntryAt: DateTime.tryParse(w.lastEntryAt ?? ''),
      byProfile: [
        for (final p in w.byProfile ?? const <api.CaseTimeByProfile>[])
          TimeSummaryByProfile.fromJson(p.json),
      ],
    );
  }
}

class TimeSummaryByProfile {
  final String profileId;
  final String name;
  final int minutes;
  const TimeSummaryByProfile({
    required this.profileId,
    required this.name,
    required this.minutes,
  });

  /// Reads a `CaseTimeByProfile` row.
  factory TimeSummaryByProfile.fromJson(Map<String, dynamic> json) {
    final w = api.CaseTimeByProfile.fromJson(json);
    return TimeSummaryByProfile(
      profileId: w.profileId ?? '',
      name: w.name ?? '',
      minutes: w.minutes ?? 0,
    );
  }
}

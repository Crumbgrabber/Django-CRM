import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;
import 'comment.dart';

/// Ticket status enumeration matching backend STATUS_CHOICE
enum TicketStatus {
  newStatus('New', 'New', AppColors.primary500),
  assigned('Assigned', 'Assigned', AppColors.primary400),
  pending('Pending', 'Pending', AppColors.warning500),
  closed('Closed', 'Closed', AppColors.success600),
  rejected('Rejected', 'Rejected', AppColors.danger500),
  duplicate('Duplicate', 'Duplicate', AppColors.gray500);

  final String value;
  final String label;
  final Color color;

  const TicketStatus(this.value, this.label, this.color);

  String get displayName => label;

  /// The statuses a person may pick. Duplicate is reached only by merging a
  /// ticket into another; the backend refuses it from an edit, a bulk update
  /// or a board move (`cases.workflow.duplicate_refusal`).
  static List<TicketStatus> get settable =>
      values.where((s) => s != TicketStatus.duplicate).toList();

  static TicketStatus fromString(String? value) {
    if (value == null) return TicketStatus.newStatus;
    return TicketStatus.values.firstWhere(
      (s) => s.value == value,
      orElse: () => TicketStatus.newStatus,
    );
  }
}

/// Ticket priority enumeration matching backend PRIORITY_CHOICE
enum TicketPriority {
  low('Low', 'Low', AppColors.success500),
  normal('Normal', 'Normal', AppColors.primary400),
  high('High', 'High', AppColors.warning500),
  urgent('Urgent', 'Urgent', AppColors.danger500);

  final String value;
  final String label;
  final Color color;

  const TicketPriority(this.value, this.label, this.color);

  String get displayName => label;

  static TicketPriority fromString(String? value) {
    if (value == null) return TicketPriority.normal;
    return TicketPriority.values.firstWhere(
      (p) => p.value == value,
      orElse: () => TicketPriority.normal,
    );
  }
}

/// Ticket type enumeration matching backend CASE_TYPE
enum TicketType {
  question('Question', 'Question', LucideIcons.circleHelp),
  incident('Incident', 'Incident', LucideIcons.circleAlert),
  problem('Problem', 'Problem', LucideIcons.triangleAlert);

  final String value;
  final String label;
  final IconData icon;

  const TicketType(this.value, this.label, this.icon);

  String get displayName => label;

  static TicketType fromString(String? value) {
    if (value == null) return TicketType.question;
    return TicketType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => TicketType.question,
    );
  }
}

/// Ticket model for BottleCRM
/// Statuses where somebody still owes the customer something.
///
/// Mirrors `cases.views.OPEN_STATUSES` and the web's `OPEN_STATUSES` in
/// `lib/server/v2/tickets.ts`. Three lists, one definition, so a rail that
/// says "also open" means the same thing everywhere.
const List<TicketStatus> openTicketStatuses = [
  TicketStatus.newStatus,
  TicketStatus.assigned,
  TicketStatus.pending,
];

class Ticket {
  final String id;
  final String name;
  final TicketStatus status;
  final TicketPriority priority;
  final TicketType ticketType;
  final String? description;
  final String? accountId;
  final String? accountName;
  final List<Map<String, dynamic>> assignedTo;
  final List<String> assignedToIds;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime? closedOn;
  final int? slaFirstResponseHours;
  final int? slaResolutionHours;
  final DateTime? firstResponseAt;
  final DateTime? resolvedAt;
  final bool isFirstResponseSlaBreachedFromApi;
  final bool isResolutionSlaBreachedFromApi;

  /// The amber band between on-track and breached, taken from the server.
  ///
  /// Unlike the breach getters above there is no local fallback, deliberately.
  /// The band is a fraction of this ticket's configured target measured against
  /// the org's business calendar, and the wall-clock approximation those
  /// getters fall back to would put the warning in the wrong place. No flag
  /// from the API means no warning, which is the fail-quiet answer.
  final bool isFirstResponseSlaAtRisk;
  final bool isResolutionSlaAtRisk;
  final List<Comment> comments;
  final List<String> tagIds;

  /// The people on this ticket, from the `contacts` M2M.
  ///
  /// Read AND sent. `CaseDetailView.put` clears `contacts` unconditionally and
  /// re-adds whatever the body carries, so a client that edits with PUT and
  /// omits this field unlinks every contact on the ticket. This app now edits
  /// with PATCH, which only touches the key when it is present, and sends the
  /// list either way.
  final List<String> contactIds;

  /// Display names for the same rows, so the detail screen can name them
  /// without a second request.
  final List<String> contactNames;
  final Map<String, dynamic> customFields;
  final DateTime? firstResponseSlaDeadline;
  final DateTime? resolutionSlaDeadline;
  final DateTime? slaPausedAt;
  final int escalationCount;
  final DateTime? lastEscalationFiredAt;
  final TicketParentSummary? parentSummary;
  final int childCount;
  final bool isProblem;

  const Ticket({
    required this.id,
    required this.name,
    required this.status,
    required this.priority,
    required this.ticketType,
    this.description,
    this.accountId,
    this.accountName,
    this.assignedTo = const [],
    this.assignedToIds = const [],
    this.tags = const [],
    this.tagIds = const [],
    this.contactIds = const [],
    this.contactNames = const [],
    this.customFields = const {},
    this.firstResponseSlaDeadline,
    this.resolutionSlaDeadline,
    this.slaPausedAt,
    this.escalationCount = 0,
    this.lastEscalationFiredAt,
    this.parentSummary,
    this.childCount = 0,
    this.isProblem = false,
    required this.createdAt,
    this.closedOn,
    this.slaFirstResponseHours,
    this.slaResolutionHours,
    this.firstResponseAt,
    this.resolvedAt,
    this.isFirstResponseSlaBreachedFromApi = false,
    this.isResolutionSlaBreachedFromApi = false,
    this.isFirstResponseSlaAtRisk = false,
    this.isResolutionSlaAtRisk = false,
    this.comments = const [],
  });

  /// First-response SLA breach.
  ///
  /// Mirrors `Case.is_sla_first_response_breached` on the backend:
  /// breached when no `first_response_at` AND `now > created_at + sla_first_response_hours`.
  /// Both web and mobile compute from the same `created_at + sla_first_response_hours`
  /// so the badge stays consistent across clients.
  bool get isFirstResponseSlaBreached {
    if (isFirstResponseSlaBreachedFromApi) return true;
    if (firstResponseAt != null) return false;
    if (slaFirstResponseHours == null) return false;
    final deadline = createdAt.add(Duration(hours: slaFirstResponseHours!));
    return DateTime.now().isAfter(deadline);
  }

  /// Resolution SLA breach, same wall-clock approximation as
  /// [isFirstResponseSlaBreached] (no business-hours adjustment) so the chip
  /// matches what the user reads on the card.
  bool get isResolutionSlaBreached {
    if (isResolutionSlaBreachedFromApi) return true;
    if (resolvedAt != null) return false;
    if (slaResolutionHours == null) return false;
    final deadline = createdAt.add(Duration(hours: slaResolutionHours!));
    return DateTime.now().isAfter(deadline);
  }

  /// Either target inside the warning band, and neither already missed.
  ///
  /// Breached wins the tie. The two are exclusive server-side, so a ticket
  /// reporting both would be a bug worth seeing as red rather than amber.
  bool get isSlaAtRisk {
    if (isFirstResponseSlaBreached || isResolutionSlaBreached) return false;
    return isFirstResponseSlaAtRisk || isResolutionSlaAtRisk;
  }

  /// Assigned-to display name (first assignee or "Unassigned").
  String get assignedToName {
    if (assignedTo.isEmpty) return 'Unassigned';
    final email = api.Profile.fromJson(assignedTo.first).userDetails?.email;
    if (email == null || email.isEmpty) return 'Unassigned';
    return email.split('@').first;
  }

  /// Reads a `Case`, the row the list, the watching list and the detail's
  /// `cases_obj` share. Comments travel beside it in the detail answer, and
  /// the provider adds them.
  factory Ticket.fromJson(Map<String, dynamic> json) {
    final w = api.Case.fromJson(json);
    final tags = w.tags ?? const <api.Tags>[];
    final assigned = w.assignedTo ?? const <api.Profile>[];
    final contacts = w.contacts ?? const <api.ContactLink>[];
    final customFields = w.customFields;
    final parent = w.parentSummary;
    return Ticket(
      id: w.id ?? '',
      name: w.name ?? '',
      status: TicketStatus.fromString(w.status),
      priority: TicketPriority.fromString(w.priority),
      ticketType: TicketType.fromString(w.caseType),
      description: w.description,
      accountId: w.account?.id,
      accountName: w.account?.name,
      assignedTo: [for (final p in assigned) p.json],
      assignedToIds: [
        for (final p in assigned)
          if (p.id case final id? when id.isNotEmpty) id,
      ],
      tags: [
        for (final t in tags)
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      tagIds: [
        for (final t in tags)
          if (t.id case final id? when id.isNotEmpty) id,
      ],
      contactIds: [
        for (final c in contacts)
          if (c.id case final id? when id.isNotEmpty) id,
      ],
      contactNames: [for (final c in contacts) _contactName(c)],
      customFields: {
        if (customFields is Map)
          for (final MapEntry(:key, :value) in customFields.entries)
            if (key is String) key: value,
      },
      createdAt: DateTime.tryParse(w.createdAt ?? '') ?? DateTime.now(),
      closedOn: DateTime.tryParse(w.closedOn ?? ''),
      slaFirstResponseHours: w.slaFirstResponseHours,
      slaResolutionHours: w.slaResolutionHours,
      firstResponseAt: DateTime.tryParse(w.firstResponseAt ?? ''),
      resolvedAt: DateTime.tryParse(w.resolvedAt ?? ''),
      isFirstResponseSlaBreachedFromApi: w.isSlaFirstResponseBreached ?? false,
      isResolutionSlaBreachedFromApi: w.isSlaResolutionBreached ?? false,
      isFirstResponseSlaAtRisk: w.isSlaFirstResponseAtRisk ?? false,
      isResolutionSlaAtRisk: w.isSlaResolutionAtRisk ?? false,
      firstResponseSlaDeadline: DateTime.tryParse(
        w.firstResponseSlaDeadline ?? '',
      ),
      resolutionSlaDeadline: DateTime.tryParse(w.resolutionSlaDeadline ?? ''),
      slaPausedAt: DateTime.tryParse(w.slaPausedAt ?? ''),
      escalationCount: w.escalationCount ?? 0,
      lastEscalationFiredAt: DateTime.tryParse(w.lastEscalationFiredAt ?? ''),
      parentSummary: parent == null
          ? null
          : TicketParentSummary.fromJson(parent.json),
      childCount: w.childCount ?? 0,
      isProblem: w.isProblem ?? false,
    );
  }

  static String _contactName(api.ContactLink c) {
    final name = [
      c.firstName,
      c.lastName,
    ].whereType<String>().where((part) => part.trim().isNotEmpty).join(' ');
    return name.trim().isNotEmpty ? name.trim() : (c.email ?? 'Contact');
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'status': status.value,
      'priority': priority.value,
      'case_type': ticketType.value,
      'description': description,
      'account': accountId,
      'assigned_to': assignedToIds,
      'tags': tagIds,
      'contacts': contactIds,
      'custom_fields': customFields,
      if (closedOn != null)
        'closed_on':
            '${closedOn!.year.toString().padLeft(4, '0')}-'
            '${closedOn!.month.toString().padLeft(2, '0')}-'
            '${closedOn!.day.toString().padLeft(2, '0')}',
    };
  }

  Ticket copyWith({
    String? id,
    String? name,
    TicketStatus? status,
    TicketPriority? priority,
    TicketType? ticketType,
    String? description,
    String? accountId,
    String? accountName,
    List<Map<String, dynamic>>? assignedTo,
    List<String>? assignedToIds,
    List<String>? tags,
    List<String>? tagIds,
    List<String>? contactIds,
    List<String>? contactNames,
    Map<String, dynamic>? customFields,
    DateTime? firstResponseSlaDeadline,
    DateTime? resolutionSlaDeadline,
    DateTime? slaPausedAt,
    int? escalationCount,
    DateTime? lastEscalationFiredAt,
    TicketParentSummary? parentSummary,
    int? childCount,
    bool? isProblem,
    DateTime? createdAt,
    DateTime? closedOn,
    int? slaFirstResponseHours,
    int? slaResolutionHours,
    DateTime? firstResponseAt,
    DateTime? resolvedAt,
    bool? isFirstResponseSlaBreachedFromApi,
    bool? isResolutionSlaBreachedFromApi,
    List<Comment>? comments,
  }) {
    return Ticket(
      id: id ?? this.id,
      name: name ?? this.name,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      ticketType: ticketType ?? this.ticketType,
      description: description ?? this.description,
      accountId: accountId ?? this.accountId,
      accountName: accountName ?? this.accountName,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToIds: assignedToIds ?? this.assignedToIds,
      tags: tags ?? this.tags,
      tagIds: tagIds ?? this.tagIds,
      contactIds: contactIds ?? this.contactIds,
      contactNames: contactNames ?? this.contactNames,
      customFields: customFields ?? this.customFields,
      firstResponseSlaDeadline:
          firstResponseSlaDeadline ?? this.firstResponseSlaDeadline,
      resolutionSlaDeadline:
          resolutionSlaDeadline ?? this.resolutionSlaDeadline,
      slaPausedAt: slaPausedAt ?? this.slaPausedAt,
      escalationCount: escalationCount ?? this.escalationCount,
      lastEscalationFiredAt:
          lastEscalationFiredAt ?? this.lastEscalationFiredAt,
      parentSummary: parentSummary ?? this.parentSummary,
      childCount: childCount ?? this.childCount,
      isProblem: isProblem ?? this.isProblem,
      createdAt: createdAt ?? this.createdAt,
      closedOn: closedOn ?? this.closedOn,
      slaFirstResponseHours:
          slaFirstResponseHours ?? this.slaFirstResponseHours,
      slaResolutionHours: slaResolutionHours ?? this.slaResolutionHours,
      firstResponseAt: firstResponseAt ?? this.firstResponseAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      isFirstResponseSlaBreachedFromApi:
          isFirstResponseSlaBreachedFromApi ??
          this.isFirstResponseSlaBreachedFromApi,
      isResolutionSlaBreachedFromApi:
          isResolutionSlaBreachedFromApi ?? this.isResolutionSlaBreachedFromApi,
      comments: comments ?? this.comments,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Ticket && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Lightweight ref to a parent ticket, used to render the "linked to" tile.
///
/// A parent the viewer may not open arrives as `restricted: true` with no name
/// or status, the redaction `/tree/` applies to a hidden node. [name] then
/// reads as [restrictedName] and the screen does not offer to open it. The id
/// stays, since detaching from it needs write on the child alone.
class TicketParentSummary {
  static const restrictedName = 'A ticket you cannot open';

  final String id;
  final String name;
  final String? status;
  final bool restricted;

  const TicketParentSummary({
    required this.id,
    required this.name,
    this.status,
    this.restricted = false,
  });

  /// Reads a `CaseParentSummary`.
  factory TicketParentSummary.fromJson(Map<String, dynamic> json) {
    final w = api.CaseParentSummary.fromJson(json);
    final restricted = w.restricted ?? false;
    return TicketParentSummary(
      id: w.id ?? '',
      name: restricted ? restrictedName : w.name ?? '',
      status: restricted ? null : w.status,
      restricted: restricted,
    );
  }
}

/// What to say BEFORE closing a parent ticket: the line above the checkbox.
///
/// [count] is the open descendants the close would really touch, never the
/// ticket's `child_count`. See [cascadeCloseMessage] for why those differ.
///
/// [truncated] means the tree endpoint stopped at its depth cap, so the list
/// shown alongside is a floor. The close itself has no cap, so more can close
/// than the prompt is able to name, and saying so beats implying a complete
/// list.
///
/// `frontend/src/routes/(app)/tickets/[id]/close.js` carries the same rules.
String cascadeSummary({required int count, bool truncated = false}) {
  if (count == 0) {
    return 'Nothing linked to this ticket is still open, so closing it '
        'changes nothing else.';
  }
  final noun = count == 1 ? 'ticket' : 'tickets';
  final verb = count == 1 ? 'is' : 'are';
  final tail = truncated
      ? ' There may be more further down than are listed here, and those '
            'close too.'
      : '';
  return '$count linked $noun $verb still open and will be closed with it.'
      '$tail';
}

/// What to say after closing a parent ticket.
///
/// **Counted from the response, not from `child_count`.** The server closes the
/// open *descendants*, the whole subtree, and returns their ids in
/// `cascaded_case_ids`. `child_count` is neither of those: it counts direct
/// children whether they were already closed or not. Reporting it claimed
/// "and 3 linked" when three children were already closed and nothing happened,
/// and understated a deep tree where more than the direct children closed.
String cascadeCloseMessage({required bool cascade, required int cascaded}) {
  if (!cascade) return 'Ticket closed';
  if (cascaded == 0) {
    return 'Ticket closed. Nothing linked was open, so nothing else changed.';
  }
  return 'Ticket closed, and $cascaded linked '
      '${cascaded == 1 ? 'ticket' : 'tickets'} with it';
}

/// The ids the close endpoint reports as cascaded, counted defensively: a body
/// without the key means nothing was cascaded, not an unknown number.
int cascadedCount(Map<String, dynamic>? body) =>
    api.CaseCloseWithChildrenResponse.fromJson(
      body ?? const {},
    ).cascadedCaseIds?.length ??
    0;

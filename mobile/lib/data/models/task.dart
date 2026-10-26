import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;
import 'lead.dart';

/// Related entity type for polymorphic relations
enum RelatedEntityType {
  lead('lead', 'Lead', LucideIcons.user),
  account('account', 'Account', LucideIcons.building2),
  opportunity('opportunity', 'Opportunity', LucideIcons.trendingUp),
  ticket_('case', 'Ticket', LucideIcons.headset),
  contact('contact', 'Contact', LucideIcons.contact);

  final String value;
  final String label;
  final IconData icon;

  const RelatedEntityType(this.value, this.label, this.icon);

  static RelatedEntityType fromString(String? value) {
    if (value == null) return RelatedEntityType.lead;
    return RelatedEntityType.values.firstWhere(
      (t) => t.value == value.toLowerCase(),
      orElse: () => RelatedEntityType.lead,
    );
  }
}

/// Related entity reference
class RelatedEntity {
  final String id;
  final RelatedEntityType type;
  final String title;

  const RelatedEntity({
    required this.id,
    required this.type,
    required this.title,
  });

  String get displayLabel => '${type.label}: $title';

  /// Reads a task's parent link, a `RelatedEntity` (`{id, name}`).
  factory RelatedEntity.fromJson(
    Map<String, dynamic> json,
    RelatedEntityType type,
  ) {
    final w = api.RelatedEntity.fromJson(json);
    return RelatedEntity(
      id: w.id ?? '',
      type: type,
      title: w.name ?? 'Unknown',
    );
  }
}

/// Task status enumeration matching backend STATUS_CHOICES
enum TaskStatus {
  newTask('New', 'New', AppColors.primary500),
  inProgress('In Progress', 'In Progress', AppColors.warning500),
  completed('Completed', 'Completed', AppColors.success500);

  final String value;
  final String label;
  final Color color;

  const TaskStatus(this.value, this.label, this.color);

  static TaskStatus fromString(String? value) {
    if (value == null) return TaskStatus.newTask;
    return TaskStatus.values.firstWhere(
      (s) => s.value.toLowerCase() == value.toLowerCase(),
      orElse: () => TaskStatus.newTask,
    );
  }
}

/// Task model for BottleCRM
class Task {
  final String id;
  final String title;
  final String? description;
  final DateTime? dueDate;
  final TaskStatus status;
  final Priority priority;
  final List<Map<String, dynamic>>? assignedTo;
  // Profile UUIDs of assignees, extracted from `assigned_to[].id`. Forms need
  // the IDs to round-trip through the API; the detail view uses `assignedTo`.
  final List<String> assignedToIds;
  final RelatedEntity? relatedTo;
  // Raw parent FK IDs from the API, exposed separately because the backend
  // serializes FKs as plain UUID strings (not nested objects), which the
  // `relatedTo` parser misses. Exactly one of these can be non-null per the
  // backend's `Task.clean()` invariant.
  final String? accountId;
  final String? opportunityId;
  final String? caseId;
  final String? leadId;
  final String? projectId;
  final List<String> tags;
  // Resolved team names attached to the task (TaskSerializer returns nested
  // Team objects, but only the display name is used in the UI today).
  final List<String> teamNames;
  final Map<String, dynamic> customFields;
  // Task creator, backend serializes via UserSerializer, exposing at least
  // an email. We surface both first/last name (joined) and email so the UI
  // can pick whichever is non-empty.
  final String? createdByName;
  final String? createdByEmail;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const Task({
    required this.id,
    required this.title,
    this.description,
    this.dueDate,
    required this.status,
    required this.priority,
    this.assignedTo,
    this.assignedToIds = const [],
    this.relatedTo,
    this.accountId,
    this.opportunityId,
    this.caseId,
    this.leadId,
    this.projectId,
    this.tags = const [],
    this.teamNames = const [],
    this.customFields = const {},
    this.createdByName,
    this.createdByEmail,
    required this.createdAt,
    this.updatedAt,
  });

  /// Check if task is completed
  bool get completed => status == TaskStatus.completed;

  /// Check if task is overdue
  bool get isOverdue {
    if (completed || dueDate == null) return false;
    return dueDate!.isBefore(DateTime.now());
  }

  /// Check if task is due today
  bool get isDueToday {
    if (dueDate == null) return false;
    final now = DateTime.now();
    return dueDate!.year == now.year &&
        dueDate!.month == now.month &&
        dueDate!.day == now.day;
  }

  /// Check if task is due within 2 hours
  bool get isDueSoon {
    if (completed || dueDate == null) return false;
    final now = DateTime.now();
    final diff = dueDate!.difference(now);
    return diff.inHours >= 0 && diff.inHours <= 2;
  }

  /// Check if task is upcoming (future, not today)
  bool get isUpcoming {
    if (completed || dueDate == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return taskDate.isAfter(today);
  }

  /// Get task due status category
  TaskDueStatus get dueStatus {
    if (completed) return TaskDueStatus.completed;
    if (isOverdue) return TaskDueStatus.overdue;
    if (isDueToday) return TaskDueStatus.today;
    if (dueDate == null) return TaskDueStatus.noDueDate;
    return TaskDueStatus.upcoming;
  }

  /// Days until due (negative if overdue)
  int? get daysUntilDue {
    if (dueDate == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final taskDate = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return taskDate.difference(today).inDays;
  }

  /// The first assignee's name, else their email's local part.
  String get assignedToName {
    if (assignedTo == null || assignedTo!.isEmpty) return 'Unassigned';
    final details = api.Profile.fromJson(assignedTo!.first).userDetails;
    final name = details?.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return (details?.email ?? '').split('@').first;
  }

  /// Reads a `Task`, the detail's `task_obj`; the list's `TaskList` rows are
  /// the same shape with fewer fields.
  factory Task.fromJson(Map<String, dynamic> json) {
    final w = api.Task.fromJson(json);
    final assigned = w.assignedTo;
    final customFields = w.customFields;
    final createdByName = w.createdBy?.name?.trim() ?? '';

    // Through django-crm 1.0.0 the parent links were bare ids; since 2026-05
    // they are `{id, name}`, which is also what fills [relatedTo].
    String? linkId(api.RelatedEntity? link, String key) {
      if (link != null) return link.id;
      final raw = json[key];
      return raw is String && raw.isNotEmpty ? raw : null;
    }

    RelatedEntity? relatedEntity;
    if (w.account case final link?) {
      relatedEntity = RelatedEntity.fromJson(
        link.json,
        RelatedEntityType.account,
      );
    } else if (w.lead case final link?) {
      relatedEntity = RelatedEntity.fromJson(link.json, RelatedEntityType.lead);
    } else if (w.opportunity case final link?) {
      relatedEntity = RelatedEntity.fromJson(
        link.json,
        RelatedEntityType.opportunity,
      );
    } else if (w.case_ case final link?) {
      relatedEntity = RelatedEntity.fromJson(
        link.json,
        RelatedEntityType.ticket_,
      );
    }

    return Task(
      id: w.id ?? '',
      title: w.title ?? '',
      description: w.description,
      dueDate: DateTime.tryParse(w.dueDate ?? ''),
      status: TaskStatus.fromString(w.status),
      priority: Priority.fromString(w.priority),
      assignedTo: assigned?.map((p) => p.json).toList(),
      assignedToIds: [
        for (final p in assigned ?? const <api.Profile>[])
          if (p.id case final id? when id.isNotEmpty) id,
      ],
      relatedTo: relatedEntity,
      accountId: linkId(w.account, 'account'),
      opportunityId: linkId(w.opportunity, 'opportunity'),
      caseId: linkId(w.case_, 'case'),
      leadId: linkId(w.lead, 'lead'),
      projectId: w.project?.isNotEmpty == true ? w.project : null,
      tags: [
        for (final t in w.tags ?? const <api.Tags>[])
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      teamNames: [
        for (final t in w.teams ?? const <api.Teams>[])
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      customFields: customFields is Map<String, dynamic>
          ? Map<String, dynamic>.from(customFields)
          : const {},
      createdByName: createdByName.isEmpty ? null : createdByName,
      createdByEmail: w.createdBy?.email,
      createdAt: DateTime.tryParse(w.createdAt ?? '') ?? DateTime.now(),
    );
  }

  /// Convert Task to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'due_date': dueDate?.toIso8601String().split('T').first,
      'status': status.value,
      'priority': priority.label,
    };
  }

  Task copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? dueDate,
    TaskStatus? status,
    Priority? priority,
    List<Map<String, dynamic>>? assignedTo,
    List<String>? assignedToIds,
    RelatedEntity? relatedTo,
    String? accountId,
    String? opportunityId,
    String? caseId,
    String? leadId,
    String? projectId,
    List<String>? tags,
    List<String>? teamNames,
    Map<String, dynamic>? customFields,
    String? createdByName,
    String? createdByEmail,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      dueDate: dueDate ?? this.dueDate,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToIds: assignedToIds ?? this.assignedToIds,
      relatedTo: relatedTo ?? this.relatedTo,
      accountId: accountId ?? this.accountId,
      opportunityId: opportunityId ?? this.opportunityId,
      caseId: caseId ?? this.caseId,
      leadId: leadId ?? this.leadId,
      projectId: projectId ?? this.projectId,
      tags: tags ?? this.tags,
      teamNames: teamNames ?? this.teamNames,
      customFields: customFields ?? this.customFields,
      createdByName: createdByName ?? this.createdByName,
      createdByEmail: createdByEmail ?? this.createdByEmail,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Task && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Task due status for grouping
enum TaskDueStatus {
  overdue,
  today,
  upcoming,
  noDueDate,
  completed;

  String get label {
    switch (this) {
      case TaskDueStatus.overdue:
        return 'Overdue';
      case TaskDueStatus.today:
        return 'Today';
      case TaskDueStatus.upcoming:
        return 'Upcoming';
      case TaskDueStatus.noDueDate:
        return 'No Due Date';
      case TaskDueStatus.completed:
        return 'Completed';
    }
  }
}

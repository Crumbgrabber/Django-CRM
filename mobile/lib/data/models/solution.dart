import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;

/// Knowledge Base solution: a reusable answer that can be linked to tickets.
/// Mirrors `cases.models.Solution`.
class Solution {
  final String id;
  final String title;
  final String description;
  final SolutionStatus status;
  final bool isPublished;
  final int caseCount;

  /// Ids of the tags this article is filed under. Agent-side only: the portal
  /// serializers carry no tags at all, because the vocabulary is shared with
  /// deals and reads like "At Risk". The portal uses them to pick related
  /// articles and never prints the names.
  final List<String> tagIds;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The server's `write` and `delete` rules for the signed-in user (admins and
  /// the author), sent by the detail route only. False anywhere else, so a
  /// list row never offers an edit or delete on a guess.
  final bool canEdit;
  final bool canDelete;

  const Solution({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    this.isPublished = false,
    this.caseCount = 0,
    this.tagIds = const [],
    this.createdAt,
    this.updatedAt,
    this.canEdit = false,
    this.canDelete = false,
  });

  /// Reads a `SolutionDetail`, the detail route's answer. A list row
  /// (`Solution`) is the same without `can_edit` and `can_delete`; of a
  /// `SolutionSuggestion`, only `id`, `title` and `updated_at` match.
  factory Solution.fromJson(Map<String, dynamic> json) {
    final w = api.SolutionDetail.fromJson(json);
    return Solution(
      id: w.id ?? '',
      title: w.title ?? '',
      description: w.description ?? '',
      status: SolutionStatus.fromString(w.status),
      isPublished: w.isPublished ?? false,
      caseCount: w.caseCount ?? 0,
      tagIds: [
        for (final t in w.tags ?? const <api.Tags>[])
          if (t.id case final id? when id.isNotEmpty) id,
      ],
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      updatedAt: DateTime.tryParse(w.updatedAt ?? ''),
      canEdit: w.canEdit ?? false,
      canDelete: w.canDelete ?? false,
    );
  }

  Map<String, dynamic> toCreatePayload() => {
    'title': title,
    'description': description,
    'status': status.value,
    'is_published': isPublished,
    // Always sent. The form shows every active tag, so an unticked one is a
    // deliberate "not this", and the API reads an explicit empty list as
    // "clear" while an absent key means "leave alone".
    'tags': tagIds,
  };

  Solution copyWith({
    String? id,
    String? title,
    String? description,
    SolutionStatus? status,
    bool? isPublished,
    int? caseCount,
    List<String>? tagIds,
  }) {
    return Solution(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      isPublished: isPublished ?? this.isPublished,
      caseCount: caseCount ?? this.caseCount,
      tagIds: tagIds ?? this.tagIds,
      createdAt: createdAt,
      updatedAt: updatedAt,
      canEdit: canEdit,
      canDelete: canDelete,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Solution && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum SolutionStatus {
  draft('draft', 'Draft', AppColors.gray500),
  reviewed('reviewed', 'Reviewed', AppColors.warning500),
  approved('approved', 'Approved', AppColors.success600);

  final String value;
  final String label;
  final Color color;
  const SolutionStatus(this.value, this.label, this.color);

  static SolutionStatus fromString(String? value) {
    return SolutionStatus.values.firstWhere(
      (s) => s.value == value,
      orElse: () => SolutionStatus.draft,
    );
  }
}

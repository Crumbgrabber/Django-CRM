import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;

/// Approval request for a ticket close (Tier 3).
class Approval {
  final String id;
  final ApprovalState state;
  final String? note;
  final String? reason;
  final DateTime? decidedAt;
  final DateTime? createdAt;
  final ApprovalCaseSummary? caseSummary;
  final ApprovalRuleSummary? ruleSummary;
  final ApprovalProfileRef? requestedBy;
  final ApprovalProfileRef? approver;

  /// The viewer may approve or reject this row right now, as the server
  /// decides it (`ApprovalSerializer.get_can_act`): pending, in the rule's
  /// approver pool, and not the requester.
  final bool canAct;

  /// The viewer may withdraw this request right now (`can_cancel`): it is
  /// pending and they filed it or are an org admin, the cancel endpoint's
  /// rule. This, not [isOwnRequest], gates Withdraw.
  final bool canCancel;

  /// The viewer filed this request.
  final bool isOwnRequest;

  const Approval({
    required this.id,
    required this.state,
    this.note,
    this.reason,
    this.decidedAt,
    this.createdAt,
    this.caseSummary,
    this.ruleSummary,
    this.requestedBy,
    this.approver,
    this.canAct = false,
    this.canCancel = false,
    this.isOwnRequest = false,
  });

  bool get isPending => state == ApprovalState.pending;

  /// Reads an `Approval`, as the inbox lists them.
  factory Approval.fromJson(Map<String, dynamic> json) {
    final w = api.Approval.fromJson(json);
    final caseSummary = w.caseSummary;
    final ruleSummary = w.ruleSummary;
    final requestedBy = w.requestedBy;
    final approver = w.approver;
    return Approval(
      id: w.id ?? '',
      state: ApprovalState.fromString(w.state),
      note: w.note,
      reason: w.reason,
      decidedAt: DateTime.tryParse(w.decidedAt ?? ''),
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      caseSummary: caseSummary == null
          ? null
          : ApprovalCaseSummary.fromJson(caseSummary.json),
      ruleSummary: ruleSummary == null
          ? null
          : ApprovalRuleSummary.fromJson(ruleSummary.json),
      requestedBy: requestedBy == null
          ? null
          : ApprovalProfileRef.fromJson(requestedBy.json),
      approver: approver == null
          ? null
          : ApprovalProfileRef.fromJson(approver.json),
      canAct: w.canAct ?? false,
      canCancel: w.canCancel ?? false,
      isOwnRequest: w.isOwnRequest ?? false,
    );
  }
}

enum ApprovalState {
  pending('pending', 'Pending', AppColors.warning500),
  approved('approved', 'Approved', AppColors.success600),
  rejected('rejected', 'Rejected', AppColors.danger600),
  cancelled('cancelled', 'Cancelled', AppColors.gray500);

  final String value;
  final String label;
  final Color color;
  const ApprovalState(this.value, this.label, this.color);

  static ApprovalState fromString(String? value) {
    return ApprovalState.values.firstWhere(
      (s) => s.value == value,
      orElse: () => ApprovalState.pending,
    );
  }
}

class ApprovalCaseSummary {
  final String id;
  final String name;
  final String? status;
  final String? priority;
  const ApprovalCaseSummary({
    required this.id,
    required this.name,
    this.status,
    this.priority,
  });

  /// Reads an `ApprovalCaseSummary`.
  factory ApprovalCaseSummary.fromJson(Map<String, dynamic> json) {
    final w = api.ApprovalCaseSummary.fromJson(json);
    return ApprovalCaseSummary(
      id: w.id ?? '',
      name: w.name ?? '',
      status: w.status,
      priority: w.priority,
    );
  }
}

class ApprovalRuleSummary {
  final String id;
  final String name;
  final String? approverRole;
  const ApprovalRuleSummary({
    required this.id,
    required this.name,
    this.approverRole,
  });

  /// Reads an `ApprovalRuleSummary`. The ticket detail's `approval_rule` is a
  /// `CaseApprovalRuleRef`, the same without `approver_role`.
  factory ApprovalRuleSummary.fromJson(Map<String, dynamic> json) {
    final w = api.ApprovalRuleSummary.fromJson(json);
    return ApprovalRuleSummary(
      id: w.id ?? '',
      name: w.name ?? '',
      approverRole: w.approverRole,
    );
  }
}

class ApprovalProfileRef {
  final String id;
  final String email;
  const ApprovalProfileRef({required this.id, required this.email});

  /// Reads an `ApprovalProfileLabel`.
  factory ApprovalProfileRef.fromJson(Map<String, dynamic> json) {
    final w = api.ApprovalProfileLabel.fromJson(json);
    return ApprovalProfileRef(id: w.id ?? '', email: w.email ?? '');
  }
}

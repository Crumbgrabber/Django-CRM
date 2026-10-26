import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../api/enterprise_schema.g.dart' as enterprise;

enum SupportCategory {
  technical('technical', 'Technical issue'),
  billing('billing', 'Billing'),
  account('account', 'Account access'),
  featureRequest('feature_request', 'Feature request'),
  other('other', 'Other');

  const SupportCategory(this.value, this.label);
  final String value;
  final String label;

  static SupportCategory fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => SupportCategory.other,
  );
}

enum SupportStatus {
  open('open', 'Open', AppColors.danger600),
  inProgress('in_progress', 'In progress', AppColors.warning600),
  waitingOnCustomer(
    'waiting_on_customer',
    'Waiting on you',
    AppColors.primary600,
  ),
  resolved('resolved', 'Resolved', AppColors.success600),
  closed('closed', 'Closed', AppColors.gray500);

  const SupportStatus(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static SupportStatus fromValue(String? value) => values.firstWhere(
    (item) => item.value == value,
    orElse: () => SupportStatus.open,
  );
}

class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.authorLabel,
    required this.isStaff,
    required this.body,
    this.attachmentName,
    required this.createdAt,
  });

  final String id;
  final String authorLabel;
  final bool isStaff;
  final String body;
  final String? attachmentName;
  final DateTime createdAt;

  bool get hasAttachment => (attachmentName ?? '').isNotEmpty;

  /// Reads a `SupportMessage`.
  factory SupportMessage.fromJson(Map<String, dynamic> json) {
    final w = enterprise.SupportMessage.fromJson(json);
    final attachmentName = w.attachmentName ?? '';
    return SupportMessage(
      id: w.id ?? '',
      authorLabel: w.authorLabel ?? 'Unknown',
      isStaff: w.authorType == 'staff',
      body: w.body ?? '',
      attachmentName: attachmentName.isEmpty ? null : attachmentName,
      createdAt:
          DateTime.tryParse(w.createdAt ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class SupportTicket {
  const SupportTicket({
    required this.id,
    required this.reference,
    required this.subject,
    required this.category,
    required this.status,
    required this.priorityLabel,
    required this.messageCount,
    required this.assigned,
    this.firstResponseAt,
    required this.lastActivityAt,
    required this.createdAt,
    this.messages = const [],
  });

  final String id;
  final String reference;
  final String subject;
  final SupportCategory category;
  final SupportStatus status;
  final String priorityLabel;
  final int messageCount;
  final bool assigned;
  final DateTime? firstResponseAt;
  final DateTime lastActivityAt;
  final DateTime createdAt;
  final List<SupportMessage> messages;

  bool get canReply => status != SupportStatus.closed;

  /// Reads a `SupportTicketDetail`. A list row is a `SupportTicketList`, the
  /// same without `assigned`, `first_response_at` and the messages.
  factory SupportTicket.fromJson(Map<String, dynamic> json) {
    final w = enterprise.SupportTicketDetail.fromJson(json);
    final messages = [
      for (final m in w.messages ?? const <enterprise.SupportMessage>[])
        SupportMessage.fromJson(m.json),
    ];
    return SupportTicket(
      id: w.id ?? '',
      reference: w.reference ?? '',
      subject: w.subject ?? '',
      category: SupportCategory.fromValue(w.category),
      status: SupportStatus.fromValue(w.status),
      priorityLabel: w.priorityLabel ?? 'Normal',
      messageCount: w.messageCount ?? messages.length,
      assigned: w.assigned ?? false,
      firstResponseAt: DateTime.tryParse(w.firstResponseAt ?? ''),
      lastActivityAt:
          DateTime.tryParse(w.lastActivityAt ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      createdAt:
          DateTime.tryParse(w.createdAt ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      messages: messages,
    );
  }
}

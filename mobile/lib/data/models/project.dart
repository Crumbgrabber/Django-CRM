import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'attachment.dart';
import 'comment.dart';
import 'invoice.dart' show InvoiceStatus;

/// A project, as `/api/projects/` returns it: the work between a won deal and
/// its invoices. The list sends the list item; the detail adds description,
/// rates, comments, attachments, invoices and the three permission flags.
///
/// Decimals arrive as strings ("12.50"). The budget and rate fields keep the
/// text as sent, so an edit form shows exactly what is stored, and expose a
/// parsed value beside it for arithmetic.
enum ProjectStatus {
  active('active', 'Active', AppColors.success600),
  onHold('on_hold', 'On hold', AppColors.warning600),
  completed('completed', 'Completed', AppColors.primary600),
  cancelled('cancelled', 'Cancelled', AppColors.gray500);

  const ProjectStatus(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;

  static ProjectStatus? fromValue(String? raw) {
    for (final s in values) {
      if (s.value == raw) return s;
    }
    return null;
  }
}

enum ProjectBillingType {
  timeAndMaterials('time_and_materials', 'Time and materials'),
  fixedFee('fixed_fee', 'Fixed fee'),
  nonBillable('non_billable', 'Non-billable');

  const ProjectBillingType(this.value, this.label);

  final String value;
  final String label;

  /// Unknown or absent reads as time and materials, the server's default.
  static ProjectBillingType fromValue(String? raw) {
    for (final t in values) {
      if (t.value == raw) return t;
    }
    return timeAndMaterials;
  }
}

/// `{"id", "name"}`, or a bare id from a leaner payload.
class ProjectRef {
  const ProjectRef({required this.id, this.name = ''});

  final String id;
  final String name;

  static ProjectRef? fromJson(Object? json) {
    if (json is Map) {
      final id = json['id']?.toString() ?? '';
      if (id.isEmpty) return null;
      final name = json['name'];
      return ProjectRef(id: id, name: name is String ? name : '');
    }
    if (json is String && json.isNotEmpty) return ProjectRef(id: json);
    return null;
  }
}

/// A typed decimal: digits with an optional fraction, nothing else. Stricter
/// than `double.tryParse`, which takes "NaN", "Infinity" and "1e3", none of
/// which a money or hours field should send.
double? parseDecimalText(String text) {
  final t = text.trim();
  if (!RegExp(r'^(\d+(\.\d*)?|\.\d+)$').hasMatch(t)) return null;
  return double.tryParse(t);
}

/// A decimal from the API as a double, or null when absent or unparseable.
double? decimalOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

double _decimal(Object? value) => decimalOrNull(value) ?? 0;

/// The decimal's text as sent, or null when absent or blank.
String? _decimalText(Object? value) {
  if (value is num) return value.toString();
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

int? _percent(Object? value) {
  if (value is num) return value.round();
  if (value is String) return double.tryParse(value)?.round();
  return null;
}

/// A `YYYY-MM-DD` date as local midnight, so a zone behind Greenwich does not
/// read it as the day before.
DateTime? _day(Object? value) {
  if (value is! String || value.isEmpty) return null;
  if (value.length == 10) return DateTime.tryParse('${value}T00:00:00');
  final parsed = DateTime.tryParse(value);
  return parsed == null
      ? null
      : DateTime(parsed.year, parsed.month, parsed.day);
}

/// Hours with the trailing zeros dropped: 12.50 reads "12.5", 40.00 "40".
String hoursLabel(double hours) {
  final fixed = hours.toStringAsFixed(2);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// A profile map's display name: the name, else the email's local part.
String profileName(Map<String, dynamic> profile) {
  final details = profile['user_details'];
  if (details is Map) {
    final name = (details['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final email = (details['email'] as String?)?.trim() ?? '';
    if (email.isNotEmpty) return email.split('@').first;
  }
  final email = (profile['email'] as String?)?.trim() ?? '';
  if (email.isNotEmpty) return email.split('@').first;
  return 'Someone';
}

/// How far a budget has gone. Notifications go out at 80 and 100, so the
/// bar changes colour at the same two points.
enum BurnLevel { under, warning, over }

BurnLevel burnLevel(int? percent) {
  if (percent == null || percent < 80) return BurnLevel.under;
  if (percent < 100) return BurnLevel.warning;
  return BurnLevel.over;
}

/// A percent as the share of a bar, clamped: a project at 140% fills it.
double burnFraction(int? percent) =>
    ((percent ?? 0) / 100).clamp(0.0, 1.0).toDouble();

Color burnColor(int? percent) => switch (burnLevel(percent)) {
  BurnLevel.under => AppColors.primary600,
  BurnLevel.warning => AppColors.warning600,
  BurnLevel.over => AppColors.danger600,
};

/// The live burn block. Counted by the server over every stopped entry on the
/// project, whoever logged it.
class ProjectBurn {
  const ProjectBurn({
    this.loggedHours = 0,
    this.billableHours = 0,
    this.billableValue = 0,
    this.unbilledValue = 0,
    this.invoicedAmount,
    this.hoursPercent,
    this.amountPercent,
  });

  final double loggedHours;
  final double billableHours;
  final double billableValue;
  final double unbilledValue;

  /// Null for a non-admin, and while Invoices is off.
  final double? invoicedAmount;

  /// Null without that budget.
  final int? hoursPercent;
  final int? amountPercent;

  factory ProjectBurn.fromJson(Object? json) {
    if (json is! Map) return const ProjectBurn();
    return ProjectBurn(
      loggedHours: _decimal(json['logged_hours']),
      billableHours: _decimal(json['billable_hours']),
      billableValue: _decimal(json['billable_value']),
      unbilledValue: _decimal(json['unbilled_value']),
      invoicedAmount: decimalOrNull(json['invoiced_amount']),
      hoursPercent: _percent(json['hours_percent']),
      amountPercent: _percent(json['amount_percent']),
    );
  }

  /// The budget closest to running out, for a list row with room for one bar:
  /// `(percent, 'hours' | 'amount')`, or null with neither budget.
  ({int percent, String kind})? get headline {
    final h = hoursPercent, a = amountPercent;
    if (h == null && a == null) return null;
    if (a == null || (h != null && h >= a)) return (percent: h!, kind: 'hours');
    return (percent: a, kind: 'amount');
  }
}

/// One person's own rate on a project.
class ProjectRate {
  const ProjectRate({required this.profileId, this.name = '', this.hourlyRate});

  final String profileId;
  final String name;

  /// The rate's text as sent.
  final String? hourlyRate;

  double? get value => decimalOrNull(hourlyRate);

  factory ProjectRate.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'];
    return ProjectRate(
      profileId: profile is Map
          ? profile['id']?.toString() ?? ''
          : profile?.toString() ?? '',
      name: profile is Map<String, dynamic> ? profileName(profile) : '',
      hourlyRate: _decimalText(json['hourly_rate']),
    );
  }
}

/// An invoice raised for the project, as the detail lists it.
class ProjectInvoice {
  const ProjectInvoice({
    required this.id,
    this.invoiceNumber = '',
    this.rawStatus = '',
    this.totalAmount = 0,
    this.currency,
    this.issueDate,
  });

  final String id;
  final String invoiceNumber;
  final String rawStatus;
  final double totalAmount;
  final String? currency;
  final DateTime? issueDate;

  InvoiceStatus? get status => InvoiceStatus.fromString(rawStatus);

  String get statusLabel => status?.label ?? rawStatus.replaceAll('_', ' ');

  factory ProjectInvoice.fromJson(Map<String, dynamic> json) => ProjectInvoice(
    id: json['id']?.toString() ?? '',
    invoiceNumber: json['invoice_number']?.toString() ?? '',
    rawStatus: json['status']?.toString() ?? '',
    totalAmount: _decimal(json['total_amount']),
    currency: json['currency'] as String?,
    issueDate: _day(json['issue_date']),
  );
}

class Project {
  const Project({
    required this.id,
    required this.name,
    this.account,
    this.deal,
    this.rawStatus = 'active',
    this.billingType = ProjectBillingType.timeAndMaterials,
    this.currency = '',
    this.budgetHours,
    this.budgetAmount,
    this.hourlyRate,
    this.startDate,
    this.dueDate,
    this.assignedTo = const [],
    this.tagIds = const [],
    this.tagNames = const [],
    this.burn = const ProjectBurn(),
    this.createdAt,
    this.updatedAt,
    this.description = '',
    this.customFields = const {},
    this.rates = const [],
    this.comments = const [],
    this.attachments = const [],
    this.invoices = const [],
    this.canEdit = false,
    this.canDelete = false,
    this.canBill = false,
  });

  final String id;
  final String name;
  final ProjectRef? account;
  final ProjectRef? deal;

  /// As the server spelled it, so an unknown status still shows.
  final String rawStatus;
  final ProjectBillingType billingType;
  final String currency;

  /// Decimal text as sent, or null.
  final String? budgetHours;
  final String? budgetAmount;
  final String? hourlyRate;
  final DateTime? startDate;
  final DateTime? dueDate;

  /// The profile maps as sent, the shape the deal screens render.
  final List<Map<String, dynamic>> assignedTo;
  final List<String> tagIds;
  final List<String> tagNames;
  final ProjectBurn burn;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // Detail only.
  final String description;
  final Map<String, dynamic> customFields;
  final List<ProjectRate> rates;
  final List<Comment> comments;
  final List<Attachment> attachments;
  final List<ProjectInvoice> invoices;
  final bool canEdit;
  final bool canDelete;

  /// True for org admins. The billing actions show only with it; the API
  /// refuses anyone else.
  final bool canBill;

  ProjectStatus? get status => ProjectStatus.fromValue(rawStatus);

  String get statusLabel => status?.label ?? rawStatus.replaceAll('_', ' ');

  Color get statusColor => status?.color ?? AppColors.gray500;

  bool get isFixedFee => billingType == ProjectBillingType.fixedFee;

  double? get budgetHoursValue => decimalOrNull(budgetHours);
  double? get budgetAmountValue => decimalOrNull(budgetAmount);
  double? get hourlyRateValue => decimalOrNull(hourlyRate);

  List<String> get assignedToIds => [
    for (final p in assignedTo)
      if ((p['id']?.toString() ?? '').isNotEmpty) p['id'].toString(),
  ];

  factory Project.fromJson(Map<String, dynamic> json) {
    final tagIds = <String>[];
    final tagNames = <String>[];
    for (final t in (json['tags'] as List?) ?? const []) {
      if (t is Map) {
        final id = t['id']?.toString() ?? '';
        final name = t['name']?.toString() ?? '';
        if (id.isNotEmpty) tagIds.add(id);
        if (name.isNotEmpty) tagNames.add(name);
      } else if (t is String && t.isNotEmpty) {
        tagNames.add(t);
      }
    }
    List<T> rows<T>(String key, T Function(Map<String, dynamic>) parse) => [
      for (final r in (json[key] as List?) ?? const [])
        if (r is Map<String, dynamic>) parse(r),
    ];
    return Project(
      id: json['id']?.toString() ?? '',
      name: json['name'] as String? ?? '',
      account: ProjectRef.fromJson(json['account']),
      deal: ProjectRef.fromJson(json['deal']),
      rawStatus: json['status'] as String? ?? 'active',
      billingType: ProjectBillingType.fromValue(
        json['billing_type'] as String?,
      ),
      currency: json['currency'] as String? ?? '',
      budgetHours: _decimalText(json['budget_hours']),
      budgetAmount: _decimalText(json['budget_amount']),
      hourlyRate: _decimalText(json['hourly_rate']),
      startDate: _day(json['start_date']),
      dueDate: _day(json['due_date']),
      assignedTo: rows('assigned_to', (p) => p),
      tagIds: tagIds,
      tagNames: tagNames,
      burn: ProjectBurn.fromJson(json['burn']),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      description: json['description'] as String? ?? '',
      customFields: json['custom_fields'] is Map
          ? Map<String, dynamic>.from(json['custom_fields'] as Map)
          : const {},
      rates: rows('rates', ProjectRate.fromJson),
      comments: rows('comments', Comment.fromJson),
      attachments: rows('attachments', Attachment.fromJson),
      invoices: rows('invoices', ProjectInvoice.fromJson),
      canEdit: json['can_edit'] == true,
      canDelete: json['can_delete'] == true,
      canBill: json['can_bill'] == true,
    );
  }

  Project copyWith({List<Comment>? comments, List<Attachment>? attachments}) =>
      Project(
        id: id,
        name: name,
        account: account,
        deal: deal,
        rawStatus: rawStatus,
        billingType: billingType,
        currency: currency,
        budgetHours: budgetHours,
        budgetAmount: budgetAmount,
        hourlyRate: hourlyRate,
        startDate: startDate,
        dueDate: dueDate,
        assignedTo: assignedTo,
        tagIds: tagIds,
        tagNames: tagNames,
        burn: burn,
        createdAt: createdAt,
        updatedAt: updatedAt,
        description: description,
        customFields: customFields,
        rates: rates,
        comments: comments ?? this.comments,
        attachments: attachments ?? this.attachments,
        invoices: invoices,
        canEdit: canEdit,
        canDelete: canDelete,
        canBill: canBill,
      );
}

/// What `GET /api/projects/from-deal/<id>/` drafts for the new-project form.
/// Nothing is saved until the form is.
class ProjectDraft {
  const ProjectDraft({
    this.name = '',
    this.account,
    this.deal,
    this.currency,
    this.assignedToIds = const [],
    this.billingType = ProjectBillingType.timeAndMaterials,
    this.budgetAmount,
  });

  final String name;
  final ProjectRef? account;
  final ProjectRef? deal;
  final String? currency;
  final List<String> assignedToIds;
  final ProjectBillingType billingType;
  final String? budgetAmount;

  factory ProjectDraft.fromJson(Map<String, dynamic> json) => ProjectDraft(
    name: json['name'] as String? ?? '',
    account: ProjectRef.fromJson(json['account']),
    deal: ProjectRef.fromJson(json['deal']),
    currency: json['currency'] as String?,
    assignedToIds: [
      for (final p in (json['assigned_to'] as List?) ?? const [])
        if (p is Map && p['id'] != null)
          p['id'].toString()
        else if (p is String && p.isNotEmpty)
          p,
    ],
    billingType: ProjectBillingType.fromValue(json['billing_type'] as String?),
    budgetAmount: _decimalText(json['budget_amount']),
  );
}

/// `GET /api/projects/<id>/unbilled/`: what Bill time would take.
class ProjectUnbilled {
  const ProjectUnbilled({
    this.entryCount = 0,
    this.hours = 0,
    this.value = 0,
    this.currency,
    this.unratedCount = 0,
  });

  final int entryCount;
  final double hours;
  final double value;
  final String? currency;

  /// Entries with no rate, which bill at 0. Absent from an older API.
  final int unratedCount;

  factory ProjectUnbilled.fromJson(Map<String, dynamic> json) =>
      ProjectUnbilled(
        entryCount: (json['entry_count'] as num?)?.toInt() ?? 0,
        hours: _decimal(json['hours']),
        value: _decimal(json['value']),
        currency: json['currency'] as String?,
        unratedCount: (json['unrated_count'] as num?)?.toInt() ?? 0,
      );
}

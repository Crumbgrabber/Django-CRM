import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;
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

/// A project's account or deal: `{"id", "name"}`.
class ProjectRef {
  const ProjectRef({required this.id, this.name = ''});

  final String id;
  final String name;

  /// Reads a `ProjectRef`, or null without one.
  static ProjectRef? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final w = api.ProjectRef.fromJson(json);
    final id = w.id ?? '';
    if (id.isEmpty) return null;
    return ProjectRef(id: id, name: w.name ?? '');
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
String? _decimalText(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? null : text;
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

/// A `Profile` map's display name: the name, else the email's local part.
String profileName(Map<String, dynamic> profile) {
  final details = api.Profile.fromJson(profile).userDetails;
  final name = details?.name?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final email = details?.email?.trim() ?? '';
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

  /// Reads a `ProjectBurn`, or all zeros without one.
  factory ProjectBurn.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const ProjectBurn();
    final w = api.ProjectBurn.fromJson(json);
    return ProjectBurn(
      loggedHours: _decimal(w.loggedHours),
      billableHours: _decimal(w.billableHours),
      billableValue: _decimal(w.billableValue),
      unbilledValue: _decimal(w.unbilledValue),
      invoicedAmount: decimalOrNull(w.invoicedAmount),
      hoursPercent: w.hoursPercent,
      amountPercent: w.amountPercent,
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

  /// Reads a `ProjectRateRow`.
  factory ProjectRate.fromJson(Map<String, dynamic> json) {
    final w = api.ProjectRateRow.fromJson(json);
    final profile = w.profile;
    return ProjectRate(
      profileId: profile?.id ?? '',
      name: profile == null ? '' : profileName(profile.json),
      hourlyRate: _decimalText(w.hourlyRate),
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

  /// Reads a `ProjectInvoiceRow`.
  factory ProjectInvoice.fromJson(Map<String, dynamic> json) {
    final w = api.ProjectInvoiceRow.fromJson(json);
    return ProjectInvoice(
      id: w.id ?? '',
      invoiceNumber: w.invoiceNumber ?? '',
      rawStatus: w.status ?? '',
      totalAmount: _decimal(w.totalAmount),
      currency: w.currency,
      issueDate: _day(w.issueDate),
    );
  }
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
    this.estimateNumber,
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

  /// The number of the accepted estimate that started the project, or null.
  final String? estimateNumber;

  ProjectStatus? get status => ProjectStatus.fromValue(rawStatus);

  String get statusLabel => status?.label ?? rawStatus.replaceAll('_', ' ');

  Color get statusColor => status?.color ?? AppColors.gray500;

  bool get isFixedFee => billingType == ProjectBillingType.fixedFee;

  double? get budgetHoursValue => decimalOrNull(budgetHours);
  double? get budgetAmountValue => decimalOrNull(budgetAmount);
  double? get hourlyRateValue => decimalOrNull(hourlyRate);

  List<String> get assignedToIds => [
    for (final p in assignedTo)
      if (api.Profile.fromJson(p).id case final id? when id.isNotEmpty) id,
  ];

  /// Reads a `ProjectDetail`. A `ProjectList` row is the same object without
  /// the detail's fields, which then read as empty.
  factory Project.fromJson(Map<String, dynamic> json) {
    final w = api.ProjectDetail.fromJson(json);
    final tags = w.tags ?? const <api.Tags>[];
    final customFields = w.customFields;
    return Project(
      id: w.id ?? '',
      name: w.name ?? '',
      account: ProjectRef.fromJson(w.account?.json),
      deal: ProjectRef.fromJson(w.deal?.json),
      rawStatus: w.status ?? 'active',
      billingType: ProjectBillingType.fromValue(w.billingType),
      currency: w.currency ?? '',
      budgetHours: _decimalText(w.budgetHours),
      budgetAmount: _decimalText(w.budgetAmount),
      hourlyRate: _decimalText(w.hourlyRate),
      startDate: _day(w.startDate),
      dueDate: _day(w.dueDate),
      assignedTo: [
        for (final p in w.assignedTo ?? const <api.Profile>[]) p.json,
      ],
      tagIds: [
        for (final t in tags)
          if (t.id case final id? when id.isNotEmpty) id,
      ],
      tagNames: [
        for (final t in tags)
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      burn: ProjectBurn.fromJson(w.burn?.json),
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      updatedAt: DateTime.tryParse(w.updatedAt ?? ''),
      description: w.description ?? '',
      customFields: customFields is Map
          ? Map<String, dynamic>.from(customFields)
          : const {},
      rates: [
        for (final r in w.rates ?? const <api.ProjectRateRow>[])
          ProjectRate.fromJson(r.json),
      ],
      comments: [
        for (final c in w.comments ?? const <api.Comment>[])
          Comment.fromJson(c.json),
      ],
      attachments: [
        for (final a in w.attachments ?? const <api.Attachments>[])
          Attachment.fromJson(a.json),
      ],
      invoices: [
        for (final i in w.invoices ?? const <api.ProjectInvoiceRow>[])
          ProjectInvoice.fromJson(i.json),
      ],
      canEdit: w.canEdit ?? false,
      canDelete: w.canDelete ?? false,
      canBill: w.canBill ?? false,
      estimateNumber: switch (w.estimate?.estimateNumber?.trim()) {
        final number? when number.isNotEmpty => number,
        _ => null,
      },
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
        estimateNumber: estimateNumber,
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

  /// Reads a `ProjectDraft`.
  factory ProjectDraft.fromJson(Map<String, dynamic> json) {
    final w = api.ProjectDraft.fromJson(json);
    return ProjectDraft(
      name: w.name ?? '',
      account: ProjectRef.fromJson(w.account?.json),
      deal: ProjectRef.fromJson(w.deal?.json),
      currency: w.currency,
      assignedToIds: [
        for (final id in w.assignedTo ?? const <String>[])
          if (id.isNotEmpty) id,
      ],
      billingType: ProjectBillingType.fromValue(w.billingType),
      budgetAmount: _decimalText(w.budgetAmount),
    );
  }
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

  /// Reads a `ProjectUnbilled`.
  factory ProjectUnbilled.fromJson(Map<String, dynamic> json) {
    final w = api.ProjectUnbilled.fromJson(json);
    return ProjectUnbilled(
      entryCount: w.entryCount ?? 0,
      hours: _decimal(w.hours),
      value: _decimal(w.value),
      currency: w.currency,
      unratedCount: w.unratedCount ?? 0,
    );
  }
}

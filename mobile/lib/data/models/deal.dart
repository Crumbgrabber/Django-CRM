import '../../services/org_date.dart';
import '../api/schema.g.dart' as api;
import 'attachment.dart';
import 'comment.dart';
import 'deal_pipeline.dart';
import 'lead.dart';
import 'lookup_models.dart';

/// Opportunity type enumeration
enum OpportunityType {
  // Sentinel, backend stores this as null (the column is blank=True,null=True).
  // The picker shows this as "Not Specified"; toJson translates it to null so
  // we don't auto-stamp NEW_BUSINESS on deals the user never categorized.
  unspecified('', 'Not Specified'),
  newBusiness('NEW_BUSINESS', 'New Business'),
  existingBusiness('EXISTING_BUSINESS', 'Existing Business'),
  renewal('RENEWAL', 'Renewal'),
  upsell('UPSELL', 'Upsell'),
  crossSell('CROSS_SELL', 'Cross Sell');

  final String value;
  final String label;

  const OpportunityType(this.value, this.label);

  static OpportunityType fromString(String? value) {
    if (value == null || value.isEmpty) return OpportunityType.unspecified;
    return OpportunityType.values.firstWhere(
      (e) => e.value.toLowerCase() == value.toLowerCase().replaceAll(' ', '_'),
      orElse: () => OpportunityType.unspecified,
    );
  }
}

/// Currency enumeration
enum Currency {
  usd('USD', 'USD', '\$'),
  eur('EUR', 'EUR', '€'),
  gbp('GBP', 'GBP', '£'),
  inr('INR', 'INR', '₹'),
  cad('CAD', 'CAD', 'C\$'),
  aud('AUD', 'AUD', 'A\$'),
  jpy('JPY', 'JPY', '¥'),
  cny('CNY', 'CNY', '¥'),
  chf('CHF', 'CHF', 'CHF'),
  sgd('SGD', 'SGD', 'S\$'),
  aed('AED', 'AED', 'د.إ'),
  brl('BRL', 'BRL', 'R\$'),
  mxn('MXN', 'MXN', '\$'),
  zar('ZAR', 'ZAR', 'R');

  final String value;
  final String label;
  final String symbol;

  const Currency(this.value, this.label, this.symbol);

  static Currency fromString(String? value) {
    if (value == null) return Currency.usd;
    return Currency.values.firstWhere(
      (e) => e.value.toLowerCase() == value.toLowerCase(),
      orElse: () => Currency.usd,
    );
  }

  /// The symbol for [code], or the code itself when this enum does not list
  /// it. Unlike [fromString] it never falls back to the dollar sign, so a
  /// figure in an unlisted currency cannot pass for one in dollars.
  static String symbolFor(String code) {
    for (final c in Currency.values) {
      if (c.value == code.toUpperCase()) return c.symbol;
    }
    return '$code ';
  }
}

/// A deal's earliest open task, as the deal list sends it (`next_activity`).
///
/// The server counts only tasks the caller can open, so a task hidden from
/// this user never reaches the phone. Undated tasks sort after dated ones.
class DealNextActivity {
  final String id;
  final String title;
  final DateTime? dueDate;

  const DealNextActivity({required this.id, required this.title, this.dueDate});

  /// Reads a `NextActivity`.
  static DealNextActivity? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final w = api.NextActivity.fromJson(json);
    return DealNextActivity(
      id: w.id ?? '',
      title: w.title ?? '',
      dueDate: DateTime.tryParse(w.dueDate ?? ''),
    );
  }
}

/// Product in a deal
class DealProduct {
  final String id;
  final String name;

  /// A decimal on the server ("2.50"), so a double here.
  final double quantity;
  final double unitPrice;

  /// The line's own discount: `PERCENTAGE` takes that share, anything else a
  /// flat amount, as `OpportunityLineItem.save` reads it.
  final String discountType;
  final double discountValue;

  const DealProduct({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.discountType = '',
    this.discountValue = 0,
  });

  /// Trailing zeroes dropped, so 2 units reads "2" and 1.5 reads "1.5".
  String get quantityLabel {
    final whole = quantity.truncateToDouble() == quantity;
    return whole ? quantity.toStringAsFixed(0) : quantity.toString();
  }

  /// Quantity x unit price less the line's discount: the server's line `total`.
  double get netTotal {
    final gross = quantity * unitPrice;
    return gross -
        (discountType == 'PERCENTAGE'
            ? gross * discountValue / 100
            : discountValue);
  }
}

/// Deal model for BottleCRM
class Deal {
  final String id;
  final String title;
  final double value;

  /// The stage `code`, one of [pipelineId]'s stages. Read [stageLabel] to show
  /// it and [stageKind] (or [isClosed], [isWon], [isLost]) to decide anything.
  final String stage;
  final String stageLabel;

  /// `open`, `won` or `lost`. See `deal_pipeline.dart`.
  final String stageKind;

  /// Null from a server that predates configurable pipelines.
  final String? pipelineId;
  final int probability;
  final DateTime? closeDate;
  final String? leadId;
  final String companyName;
  final String? accountId;
  final List<DealProduct> products;
  final String assignedTo;
  final List<String> assignedToIds;
  // Raw assigned_to profile maps from the detail endpoint (each entry has
  // `id`, `user_details: { name, email, profile_pic }`). Used to render
  // every assignee in the detail screen, not just the first.
  final List<Map<String, dynamic>> assignedToRaw;
  final Priority priority;
  final List<String> labels;
  final List<String> tagIds;
  final List<String> contactIds;
  final String? notes;
  final OpportunityType opportunityType;

  /// A key from the org's lead sources, as the server sent it; empty for
  /// none. An older API's uppercase values (`CALL`, `WEBSITE`) arrive as they
  /// are, except `NONE`, which meant none.
  final String leadSource;
  final Currency currency;
  final DateTime createdAt;
  final DateTime updatedAt;
  // When the deal last changed stage. Drives the rotten / aging indicator and
  // the "oldest first" sort. Null for legacy deals that pre-date the field.
  final DateTime? stageChangedAt;
  // Per-org JSONField on Opportunity. Empty map when the org defines no
  // custom fields or when the server hasn't returned them yet.
  final Map<String, dynamic> customFieldValues;
  // Detail-only payload. Empty/null on list responses; populated by
  // getDealDetail.
  final List<Comment> comments;
  final List<Attachment> attachments;
  final List<ContactLookup> contactsList;
  final List<String> teamIds;
  final List<String> teamNames;
  final String? createdByName;
  final String? createdByEmail;
  final String? closedByName;
  final String? closedByEmail;
  // Backend-computed aging: whole days in the current stage, and `green`,
  // `yellow` (past the stage's expected or warning days) or `red` (rotting).
  // The thresholds are per stage and live only on the server.
  final int? daysInStageServer;
  final String? agingStatus;
  final double? lineItemsTotal;

  /// The earliest open task on the deal that this user can open, or null
  /// when there is none (the "no next step" flag). Only meaningful when
  /// [nextActivityKnown]: the deal list computes it, the detail does not, and
  /// a deal read from the detail must not be shown as having nothing planned.
  final DealNextActivity? nextActivity;
  final bool nextActivityKnown;

  const Deal({
    required this.id,
    required this.title,
    required this.value,
    required this.stage,
    this.stageLabel = '',
    this.stageKind = dealStageOpen,
    this.pipelineId,
    required this.probability,
    this.closeDate,
    this.leadId,
    required this.companyName,
    this.accountId,
    this.products = const [],
    required this.assignedTo,
    this.assignedToIds = const [],
    this.assignedToRaw = const [],
    required this.priority,
    this.labels = const [],
    this.tagIds = const [],
    this.contactIds = const [],
    this.notes,
    this.opportunityType = OpportunityType.newBusiness,
    this.leadSource = '',
    this.currency = Currency.usd,
    required this.createdAt,
    required this.updatedAt,
    this.stageChangedAt,
    this.customFieldValues = const {},
    this.comments = const [],
    this.attachments = const [],
    this.contactsList = const [],
    this.teamIds = const [],
    this.teamNames = const [],
    this.createdByName,
    this.createdByEmail,
    this.closedByName,
    this.closedByEmail,
    this.daysInStageServer,
    this.agingStatus,
    this.lineItemsTotal,
    this.nextActivity,
    this.nextActivityKnown = false,
  });

  /// Reads an `OpportunityList` row, the widest of the three shapes this is
  /// fed: the detail's `opportunity_obj` is an `Opportunity` (the same row
  /// without `next_activity`), and a board card an `OpportunityKanbanCard`
  /// (fewer fields, plus `updated_at`).
  factory Deal.fromJson(Map<String, dynamic> json) {
    final w = api.OpportunityList.fromJson(json);
    final tags = w.tags ?? const <api.Tags>[];
    final assigned = w.assignedTo ?? const <api.Profile>[];
    final contacts = w.contacts ?? const <api.ContactLink>[];
    final teams = w.teams ?? const <api.Teams>[];

    // One display name for the first assignee that has one, for the list
    // card, where there is no room for more.
    String assignedToName = 'Unassigned';
    for (final p in assigned) {
      if (assignedToName != 'Unassigned') break;
      final name = (p.userDetails?.name ?? '').trim();
      final email = (p.userDetails?.email ?? '').trim();
      if (name.isNotEmpty) {
        assignedToName = name;
      } else if (email.isNotEmpty) {
        assignedToName = email.split('@').first;
      }
      if (assignedToName.isEmpty) assignedToName = 'Assigned';
    }

    final closedBy = w.closedBy?.userDetails;
    final closedByName = (closedBy?.name ?? '').trim();

    // DRF sends decimals as strings ("2.00"). An int parse of "2.00" fails,
    // which used to read every line as a quantity of 1.
    double decimal(String? raw, double fallback) =>
        double.tryParse(raw ?? '') ?? fallback;

    // The kind decides closed/won/lost. A row with none (a server older than
    // configurable pipelines, or a code its pipeline no longer has) falls
    // back to what the seeded codes have always meant.
    final stageCode = w.stage ?? '';
    final label = w.stageLabel;
    final pipeline = w.pipeline;
    final customFields = w.customFields;

    return Deal(
      id: w.id ?? '',
      title: w.name ?? '',
      value: double.tryParse(w.amount ?? '') ?? 0.0,
      stage: stageCode,
      stageLabel: (label == null || label.isEmpty)
          ? legacyDealStageLabel(stageCode)
          : label,
      stageKind: w.stageKind ?? legacyDealStageKind(stageCode),
      pipelineId: (pipeline == null || pipeline.isEmpty) ? null : pipeline,
      probability: w.probability ?? 0,
      closeDate: DateTime.tryParse(w.closedOn ?? ''),
      leadId: null, // API doesn't have lead reference directly
      companyName: w.account?.name ?? 'No Account',
      accountId: w.account?.id,
      products: [
        for (final item in w.lineItems ?? const <api.OpportunityLineItem>[])
          if (item.id case final id? when id.isNotEmpty)
            DealProduct(
              id: id,
              name: item.name ?? '',
              quantity: decimal(item.quantity, 1),
              unitPrice: decimal(item.unitPrice, 0),
              discountType: item.discountType ?? '',
              discountValue: decimal(item.discountValue, 0),
            ),
      ],
      assignedTo: assignedToName,
      assignedToIds: [
        for (final p in assigned)
          if (p.id case final id? when id.isNotEmpty) id,
      ],
      assignedToRaw: [for (final p in assigned) p.json],
      priority: Priority.medium, // API doesn't have priority, default to medium
      labels: [
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
      notes: w.description,
      opportunityType: OpportunityType.fromString(w.opportunityType),
      leadSource: switch (w.leadSource) {
        null || 'NONE' => '',
        final key => key,
      },
      currency: Currency.fromString(w.currency),
      createdAt: DateTime.tryParse(w.createdAt ?? '') ?? DateTime.now(),
      // Only a board card carries it.
      updatedAt:
          DateTime.tryParse(
            api.OpportunityKanbanCard.fromJson(json).updatedAt ?? '',
          ) ??
          DateTime.now(),
      stageChangedAt: DateTime.tryParse(w.stageChangedAt ?? ''),
      customFieldValues: customFields is Map
          ? Map<String, dynamic>.from(customFields)
          : const {},
      contactsList: [for (final c in contacts) ContactLookup.fromJson(c.json)],
      teamIds: [
        for (final t in teams)
          if (t.id case final id? when id.isNotEmpty) id,
      ],
      teamNames: [
        for (final t in teams)
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      createdByName: (w.createdBy?.name ?? '').trim().isEmpty
          ? null
          : w.createdBy!.name!.trim(),
      createdByEmail: w.createdBy?.email,
      closedByName: closedByName.isEmpty ? null : closedByName,
      closedByEmail: closedBy?.email,
      daysInStageServer: w.daysInStage,
      agingStatus: w.agingStatus,
      lineItemsTotal: w.lineItemsTotal,
      nextActivity: DealNextActivity.fromJson(w.nextActivity?.json),
      // Presence, not the value: the list sends null for "nothing planned",
      // and the detail sends no key at all.
      nextActivityKnown: json.containsKey('next_activity'),
    );
  }

  /// Convert Deal to JSON for API requests (create/update).
  ///
  /// IMPORTANT: nullable fields (amount, account, closed_on, description,
  /// opportunity_type) are emitted as explicit `null` when empty so edit-mode
  /// clears actually persist. The backend's PUT uses a non-partial serializer,
  /// so omitting a key leaves the old value in place, which would silently
  /// drop the user's edit. m2m collections (contacts/tags/teams/assigned_to)
  /// are always sent as arrays (possibly empty) because the view unconditionally
  /// calls `.clear()` then re-adds.
  ///
  /// `pipeline` goes only when known, and `stage` only when chosen: with
  /// neither, the server keeps the deal's pipeline (or the org default for a
  /// new deal) and starts a new deal in its first open stage.
  ///
  /// `lead_source` goes only when [withLeadSource], which the form sets when
  /// the user picked one, so a source this build does not know survives.
  Map<String, dynamic> toJson({bool withLeadSource = false}) {
    return {
      'name': title,
      if (pipelineId != null && pipelineId!.isNotEmpty) 'pipeline': pipelineId,
      if (stage.isNotEmpty) 'stage': stage,
      'probability': probability,
      'amount': value > 0 ? value.toStringAsFixed(2) : null,
      'account': (accountId != null && accountId!.isNotEmpty)
          ? accountId
          : null,
      'closed_on': closeDate != null
          ? '${closeDate!.year}-${closeDate!.month.toString().padLeft(2, '0')}-${closeDate!.day.toString().padLeft(2, '0')}'
          : null,
      'description': (notes != null && notes!.isNotEmpty) ? notes : null,
      'assigned_to': assignedToIds,
      'contacts': contactIds,
      'tags': tagIds,
      'teams': teamIds,
      'opportunity_type': opportunityType == OpportunityType.unspecified
          ? null
          : opportunityType.value,
      if (withLeadSource) 'lead_source': leadSource,
      'currency': currency.value,
      'custom_fields': customFieldValues,
    };
  }

  bool get isWon => stageKind == dealStageWon;
  bool get isLost => stageKind == dealStageLost;
  bool get isClosed => isWon || isLost;

  /// Get weighted value based on probability
  double get weightedValue => value * (probability / 100);

  /// Check if deal is closing soon (within 7 days)
  bool get isClosingSoon {
    final days = daysUntilClose;
    return days != null && days >= 0 && days <= 7;
  }

  /// Check if deal is overdue: its close date is before the org's today.
  bool get isOverdue {
    if (closeDate == null || isClosed) return false;
    return daysUntilClose! < 0;
  }

  /// Calendar days from the org's today to the close date, negative once it
  /// has passed. Whole days, not `difference(now)`, which read a deal closing
  /// tomorrow as due today for most of the day.
  int? get daysUntilClose {
    if (closeDate == null) return null;
    return orgDaysUntil(closeDate!);
  }

  Deal copyWith({
    String? id,
    String? title,
    double? value,
    String? stage,
    String? stageLabel,
    String? stageKind,
    String? pipelineId,
    int? probability,
    DateTime? closeDate,
    String? leadId,
    String? companyName,
    String? accountId,
    List<DealProduct>? products,
    String? assignedTo,
    List<String>? assignedToIds,
    List<Map<String, dynamic>>? assignedToRaw,
    Priority? priority,
    List<String>? labels,
    List<String>? tagIds,
    List<String>? contactIds,
    String? notes,
    OpportunityType? opportunityType,
    String? leadSource,
    Currency? currency,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? stageChangedAt,
    Map<String, dynamic>? customFieldValues,
    List<Comment>? comments,
    List<Attachment>? attachments,
    List<ContactLookup>? contactsList,
    List<String>? teamIds,
    List<String>? teamNames,
    String? createdByName,
    String? createdByEmail,
    String? closedByName,
    String? closedByEmail,
    int? daysInStageServer,
    String? agingStatus,
    double? lineItemsTotal,
  }) {
    // The next activity is carried as it is: no edit made on the phone
    // changes which tasks are open, and a reload replaces it.
    return Deal(
      id: id ?? this.id,
      title: title ?? this.title,
      value: value ?? this.value,
      stage: stage ?? this.stage,
      stageLabel: stageLabel ?? this.stageLabel,
      stageKind: stageKind ?? this.stageKind,
      pipelineId: pipelineId ?? this.pipelineId,
      probability: probability ?? this.probability,
      closeDate: closeDate ?? this.closeDate,
      leadId: leadId ?? this.leadId,
      companyName: companyName ?? this.companyName,
      accountId: accountId ?? this.accountId,
      products: products ?? this.products,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToIds: assignedToIds ?? this.assignedToIds,
      assignedToRaw: assignedToRaw ?? this.assignedToRaw,
      priority: priority ?? this.priority,
      labels: labels ?? this.labels,
      tagIds: tagIds ?? this.tagIds,
      contactIds: contactIds ?? this.contactIds,
      notes: notes ?? this.notes,
      opportunityType: opportunityType ?? this.opportunityType,
      leadSource: leadSource ?? this.leadSource,
      currency: currency ?? this.currency,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      stageChangedAt: stageChangedAt ?? this.stageChangedAt,
      customFieldValues: customFieldValues ?? this.customFieldValues,
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
      contactsList: contactsList ?? this.contactsList,
      teamIds: teamIds ?? this.teamIds,
      teamNames: teamNames ?? this.teamNames,
      createdByName: createdByName ?? this.createdByName,
      createdByEmail: createdByEmail ?? this.createdByEmail,
      closedByName: closedByName ?? this.closedByName,
      closedByEmail: closedByEmail ?? this.closedByEmail,
      daysInStageServer: daysInStageServer ?? this.daysInStageServer,
      agingStatus: agingStatus ?? this.agingStatus,
      lineItemsTotal: lineItemsTotal ?? this.lineItemsTotal,
      nextActivity: nextActivity,
      nextActivityKnown: nextActivityKnown,
    );
  }

  /// Days since the deal last changed stage, counted on the phone. Only a
  /// fallback for [daysInStageServer]; null when the field is missing.
  int? get daysInCurrentStage {
    final ref = stageChangedAt;
    if (ref == null) return null;
    return DateTime.now().difference(ref).inDays;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Deal && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

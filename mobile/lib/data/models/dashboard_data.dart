// Dashboard data models for BottleCRM
import '../api/schema.g.dart' as api;
import 'deal_pipeline.dart';

/// Urgent counts from dashboard API
class UrgentCounts {
  final int overdueTasks;
  final int tasksDueToday;
  final int followupsToday;
  final int hotLeads;

  const UrgentCounts({
    this.overdueTasks = 0,
    this.tasksDueToday = 0,
    this.followupsToday = 0,
    this.hotLeads = 0,
  });

  /// Reads an `ApiHomeUrgentCounts`.
  factory UrgentCounts.fromJson(Map<String, dynamic> json) {
    final w = api.ApiHomeUrgentCounts.fromJson(json);
    return UrgentCounts(
      overdueTasks: w.overdueTasks ?? 0,
      tasksDueToday: w.tasksDueToday ?? 0,
      followupsToday: w.followupsToday ?? 0,
      hotLeads: w.hotLeads ?? 0,
    );
  }
}

/// One stage of the org's default deal pipeline, with its deal count and
/// value, from `pipeline_by_stage`.
class PipelineStage {
  final String code;
  final String label;

  /// `open`, `won` or `lost`. See `deal_pipeline.dart`.
  final String kind;

  /// Board order within the pipeline.
  final int order;
  final int count;
  final double value;

  const PipelineStage({
    required this.code,
    required this.label,
    this.kind = dealStageOpen,
    this.order = 0,
    this.count = 0,
    this.value = 0,
  });

  bool get isOpen => kind == dealStageOpen;

  /// Reads an `ApiHomeStageFigures`, keyed by [code] in the map.
  ///
  /// A server older than configurable pipelines sends neither `kind` nor
  /// `order`; the seeded codes' own meaning and order stand in.
  factory PipelineStage.fromJson(String code, Map<String, dynamic> json) {
    final w = api.ApiHomeStageFigures.fromJson(json);
    return PipelineStage(
      code: code,
      label: w.label ?? legacyDealStageLabel(code),
      kind: w.kind ?? legacyDealStageKind(code),
      order:
          w.order ??
          DealPipeline.legacy.stageByCode(code)?.order ??
          DealPipeline.legacy.stages.length,
      count: w.count ?? 0,
      value: w.value ?? 0,
    );
  }
}

/// Revenue metrics from dashboard API
class RevenueMetrics {
  final double pipelineValue;

  /// Deals making up [pipelineValue], open stages only. The dashboard's
  /// top-level `opportunities_count` counts every stage including closed, so
  /// it is not the number to show under an "Open Deals" label.
  final int openOpportunitiesCount;
  final double weightedPipeline;
  final double wonThisMonth;
  final double conversionRate;
  final String currency;
  final int otherCurrencyCount;

  const RevenueMetrics({
    this.pipelineValue = 0,
    this.openOpportunitiesCount = 0,
    this.weightedPipeline = 0,
    this.wonThisMonth = 0,
    this.conversionRate = 0,
    this.currency = 'USD',
    this.otherCurrencyCount = 0,
  });

  /// Reads an `ApiHomeRevenueMetrics`.
  factory RevenueMetrics.fromJson(Map<String, dynamic> json) {
    final w = api.ApiHomeRevenueMetrics.fromJson(json);
    return RevenueMetrics(
      pipelineValue: w.pipelineValue ?? 0,
      openOpportunitiesCount: w.openOpportunitiesCount ?? 0,
      weightedPipeline: w.weightedPipeline ?? 0,
      wonThisMonth: w.wonThisMonth ?? 0,
      conversionRate: w.conversionRate ?? 0,
      currency: w.currency ?? 'USD',
      otherCurrencyCount: w.otherCurrencyCount ?? 0,
    );
  }
}

/// Hot lead from dashboard API
class HotLead {
  final String id;
  final String firstName;
  final String lastName;
  final String? company;
  final String? rating;
  final DateTime? nextFollowUp;
  final DateTime? lastContacted;

  const HotLead({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.company,
    this.rating,
    this.nextFollowUp,
    this.lastContacted,
  });

  String get fullName => '$firstName $lastName'.trim();

  /// Reads an `ApiHomeHotLead`.
  factory HotLead.fromJson(Map<String, dynamic> json) {
    final w = api.ApiHomeHotLead.fromJson(json);
    return HotLead(
      id: w.id ?? '',
      firstName: w.firstName ?? '',
      lastName: w.lastName ?? '',
      company: w.company,
      rating: w.rating,
      nextFollowUp: DateTime.tryParse(w.nextFollowUp ?? ''),
      lastContacted: DateTime.tryParse(w.lastContacted ?? ''),
    );
  }
}

/// Dashboard task from API
class DashboardTask {
  final String id;
  final String title;
  final String? description;
  final String status;
  final String priority;
  final DateTime? dueDate;
  final String? accountName;
  final String? leadName;

  const DashboardTask({
    required this.id,
    required this.title,
    this.description,
    this.status = 'New',
    this.priority = 'Medium',
    this.dueDate,
    this.accountName,
    this.leadName,
  });

  bool get isCompleted => status.toLowerCase() == 'completed';

  String? get relatedTo => accountName ?? leadName;

  /// Reads a `Task`, whose `account` is an `{id, name}` link.
  factory DashboardTask.fromJson(Map<String, dynamic> json) {
    final w = api.Task.fromJson(json);
    return DashboardTask(
      id: w.id ?? '',
      title: w.title ?? 'Untitled',
      description: w.description,
      status: w.status ?? 'New',
      priority: w.priority ?? 'Medium',
      dueDate: DateTime.tryParse(w.dueDate ?? ''),
      accountName: w.account?.name,
      leadName: w.lead?.name,
    );
  }
}

/// Dashboard activity from API
class DashboardActivity {
  final String id;
  final String activityType;
  final String description;
  final DateTime createdAt;
  final String? userName;
  final String? entityType;
  final String? entityName;

  const DashboardActivity({
    required this.id,
    required this.activityType,
    required this.description,
    required this.createdAt,
    this.userName,
    this.entityType,
    this.entityName,
  });

  String get relativeTime {
    final now = DateTime.now();
    final diff = now.difference(createdAt);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  /// Reads a `DashboardActivity`. It carries no `activity_type`,
  /// `created_at` or `created_by` (its own names are `action`, `timestamp`
  /// and `user`), so those three keep their defaults.
  factory DashboardActivity.fromJson(Map<String, dynamic> json) {
    final w = api.DashboardActivity.fromJson(json);
    return DashboardActivity(
      id: w.id ?? '',
      activityType: 'update',
      description: w.description ?? '',
      createdAt: DateTime.now(),
      entityType: w.entityType,
      entityName: w.entityName,
    );
  }
}

/// Complete dashboard data response
class DashboardData {
  final int accountsCount;
  final int contactsCount;
  final int leadsCount;
  final int opportunitiesCount;
  final UrgentCounts urgentCounts;
  final List<PipelineStage> pipelineByStage;
  final RevenueMetrics revenueMetrics;
  final List<HotLead> hotLeads;
  final List<DashboardTask> tasks;
  final List<DashboardActivity> activities;

  /// The current goals the signed-in person may see, at most three. Served by
  /// `/api/dashboard/` as `goal_summary` and narrowed there to their own goals,
  /// their teams', and (for an admin) the org-wide ones.
  final List<DashboardGoal> goalSummary;

  /// The caller can see no real contact and no real lead (sample data does
  /// not count). From `import_prompt_facts` on `/api/dashboard/`.
  final bool emptyWorkspace;

  /// The import views would let the caller in (`can_mass_import`).
  final bool canImport;

  /// Visible leads waiting for a first reply, from `unanswered_leads`. Null
  /// from an API that predates response times.
  final int? unansweredLeads;

  const DashboardData({
    this.accountsCount = 0,
    this.contactsCount = 0,
    this.leadsCount = 0,
    this.opportunitiesCount = 0,
    this.urgentCounts = const UrgentCounts(),
    this.pipelineByStage = const [],
    this.revenueMetrics = const RevenueMetrics(),
    this.hotLeads = const [],
    this.tasks = const [],
    this.activities = const [],
    this.goalSummary = const [],
    this.emptyWorkspace = false,
    this.canImport = false,
    this.unansweredLeads,
  });

  /// Whether the home screen offers an import, as the web home page's "Bring
  /// in your contacts" card does. Absent keys, from an older server, offer
  /// nothing.
  bool get offersImport => emptyWorkspace && canImport;

  /// Reads an `ApiHomeResponse`, the whole `/api/dashboard/` answer.
  factory DashboardData.fromJson(Map<String, dynamic> json) {
    final w = api.ApiHomeResponse.fromJson(json);
    final pipelineStages = [
      for (final MapEntry(:key, :value)
          in (w.pipelineByStage ?? const <String, api.ApiHomeStageFigures>{})
              .entries)
        PipelineStage.fromJson(key, value.json),
    ];
    // The map carries no order of its own, so the board's is restored.
    pipelineStages.sort((a, b) => a.order.compareTo(b.order));

    final urgentCounts = w.urgentCounts;
    final revenueMetrics = w.revenueMetrics;
    return DashboardData(
      accountsCount: w.accountsCount ?? 0,
      contactsCount: w.contactsCount ?? 0,
      leadsCount: w.leadsCount ?? 0,
      opportunitiesCount: w.opportunitiesCount ?? 0,
      urgentCounts: urgentCounts == null
          ? const UrgentCounts()
          : UrgentCounts.fromJson(urgentCounts.json),
      pipelineByStage: pipelineStages,
      revenueMetrics: revenueMetrics == null
          ? const RevenueMetrics()
          : RevenueMetrics.fromJson(revenueMetrics.json),
      hotLeads: [
        for (final l in w.hotLeads ?? const <api.ApiHomeHotLead>[])
          HotLead.fromJson(l.json),
      ],
      tasks: [
        for (final t in w.tasks ?? const <api.Task>[])
          DashboardTask.fromJson(t.json),
      ],
      activities: [
        for (final a in w.activities ?? const <api.DashboardActivity>[])
          DashboardActivity.fromJson(a.json),
      ],
      goalSummary: [
        for (final g in w.goalSummary ?? const <api.ApiHomeGoal>[])
          DashboardGoal.fromJson(g.json),
      ],
      emptyWorkspace: w.emptyWorkspace ?? false,
      canImport: w.canImport ?? false,
      unansweredLeads: w.unansweredLeads?.count,
    );
  }
}

/// One current goal on the dashboard, from `/api/dashboard/` `goal_summary`.
///
/// A slimmer shape than [SalesGoal]: the endpoint sends only what a progress
/// strip needs, and parsing it as a full goal would invent nulls for the seven
/// fields it does not carry.
///
/// The backend has served this field all along and neither client rendered it,
/// so the numbers behind this were already being computed and thrown away.
class DashboardGoal {
  const DashboardGoal({
    required this.id,
    required this.name,
    required this.goalType,
    required this.targetValue,
    required this.progressValue,
    required this.progressPercent,
    required this.status,
    this.currency,
  });

  final String id;
  final String name;
  final String goalType;

  /// The currency a REVENUE goal is counted in. Null from a server that
  /// predates the field, where the strip falls back to the org's currency.
  final String? currency;
  final double targetValue;
  final double progressValue;
  final int progressPercent;

  /// The server's pace judgement (`on_track` / `at_risk` / `behind` /
  /// `completed`), which compares attainment against elapsed time. Read, never
  /// recomputed: this app cannot see the opportunities another person's goal
  /// counts.
  final String status;

  /// Reads an `ApiHomeGoal`.
  factory DashboardGoal.fromJson(Map<String, dynamic> json) {
    final w = api.ApiHomeGoal.fromJson(json);
    final currency = w.currency ?? '';
    return DashboardGoal(
      id: w.id ?? '',
      name: w.name ?? '',
      goalType: w.goalType ?? 'REVENUE',
      targetValue: w.targetValue ?? 0,
      progressValue: w.progressValue ?? 0,
      progressPercent: w.progressPercent ?? 0,
      status: w.status ?? 'on_track',
      currency: currency.isEmpty ? null : currency,
    );
  }
}

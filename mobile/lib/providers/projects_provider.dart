import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../data/api/schema.g.dart' as api;
import '../data/models/project.dart';
import '../data/models/task.dart';
import '../data/models/time_entry.dart';
import '../services/api_service.dart';

/// The list's filters, each a query parameter of `GET /api/projects/`.
class ProjectFilters {
  const ProjectFilters({
    this.search = '',
    this.status,
    this.accountId,
    this.accountName,
  });

  final String search;

  /// A [ProjectStatus] value, or null for every status.
  final String? status;
  final String? accountId;

  /// Shown on the filter button; not sent.
  final String? accountName;

  bool get isEmpty => search.isEmpty && status == null && accountId == null;

  ProjectFilters copyWith({
    String? search,
    Object? status = _keep,
    Object? accountId = _keep,
    Object? accountName = _keep,
  }) => ProjectFilters(
    search: search ?? this.search,
    status: identical(status, _keep) ? this.status : status as String?,
    accountId: identical(accountId, _keep)
        ? this.accountId
        : accountId as String?,
    accountName: identical(accountName, _keep)
        ? this.accountName
        : accountName as String?,
  );

  Map<String, String> get query => {
    if (search.trim().isNotEmpty) 'search': search.trim(),
    'status': ?status,
    'account': ?accountId,
  };

  static const _keep = Object();
}

class ProjectsListData {
  const ProjectsListData({
    this.projects = const [],
    this.count = 0,
    this.filters = const ProjectFilters(),
  });

  final List<Project> projects;
  final int count;
  final ProjectFilters filters;

  bool get hasMore => projects.length < count;
}

/// The result of a write: an id where one was made, else the server's words.
typedef ProjectWrite = ({String? id, String? error});

/// The projects list and every project call. The list screen watches it; the
/// detail and form screens use the notifier for one-shot reads and writes, as
/// the deal screens do.
class ProjectsNotifier extends AsyncNotifier<ProjectsListData> {
  final ApiService _api = ApiService();
  static const int pageSize = 50;

  ProjectFilters _filters = const ProjectFilters();
  ProjectFilters get filters => _filters;

  @override
  Future<ProjectsListData> build() => _fetch(_filters, offset: 0);

  Future<ProjectsListData> _fetch(
    ProjectFilters filters, {
    required int offset,
  }) async {
    final url = Uri.parse(ApiConfig.projects)
        .replace(
          queryParameters: {
            ...filters.query,
            'limit': '$pageSize',
            'offset': '$offset',
          },
        )
        .toString();
    final response = await _api.get(url);
    final data = response.data;
    if (!response.success || data == null) {
      throw Exception(response.message ?? 'Could not load projects.');
    }
    final body = api.ProjectListResponse.fromJson(data);
    final projects = [
      for (final row in body.projects ?? const <api.ProjectList>[])
        Project.fromJson(row.json),
    ];
    return ProjectsListData(
      projects: projects,
      count: body.count ?? projects.length,
      filters: filters,
    );
  }

  Future<void> setFilters(ProjectFilters filters) async {
    _filters = filters;
    await refresh();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _fetch(_filters, offset: 0));
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || state.isLoading) return;
    state = await AsyncValue.guard(() async {
      final next = await _fetch(
        current.filters,
        offset: current.projects.length,
      );
      return ProjectsListData(
        projects: [...current.projects, ...next.projects],
        count: next.count,
        filters: current.filters,
      );
    });
  }

  /// One project with everything its page shows. [onNotFound] runs on a 404,
  /// which the server answers alike for a project that does not exist and
  /// one this user may not see; any other failure returns null without it.
  Future<Project?> getProject(String id, {void Function()? onNotFound}) async {
    final String url;
    try {
      url = ApiConfig.project(id);
    } on ArgumentError {
      onNotFound?.call();
      return null;
    }
    final response = await _api.get(url);
    final data = response.data;
    if (!response.success || data == null) {
      if (response.statusCode == 404) onNotFound?.call();
      return null;
    }
    return Project.fromJson(data);
  }

  Future<ProjectWrite> create(Map<String, dynamic> payload) async {
    final response = await _api.post(ApiConfig.projects, payload);
    if (!response.success) {
      return (id: null, error: response.message ?? 'Could not save.');
    }
    final saved = api.ProjectSaved.fromJson(response.data ?? {});
    final id = saved.id ?? saved.project?.id;
    await refresh();
    return (id: id, error: null);
  }

  Future<ProjectWrite> saveChanges(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final response = await _api.patch(ApiConfig.project(id), payload);
    if (!response.success) {
      return (id: null, error: response.message ?? 'Could not save.');
    }
    await refresh();
    return (id: id, error: null);
  }

  Future<String?> delete(String id) async {
    final response = await _api.delete(ApiConfig.project(id));
    if (!response.success) {
      return response.message ?? 'Could not delete this project.';
    }
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        ProjectsListData(
          projects: current.projects.where((p) => p.id != id).toList(),
          count: current.count - 1,
          filters: current.filters,
        ),
      );
    }
    return null;
  }

  /// Adds a comment. The answer carries the refreshed comments and
  /// attachments, as a deal's does.
  Future<({Map<String, dynamic>? data, String? error})> addComment(
    String id,
    String comment,
  ) async {
    final response = await _api.post(ApiConfig.project(id), {
      'comment': comment,
    });
    if (!response.success) {
      return (data: null, error: response.message ?? 'Could not add that.');
    }
    return (data: response.data, error: null);
  }

  /// The new-project form's draft from a deal. Null with the server's words
  /// when the deal cannot be seen.
  Future<({ProjectDraft? draft, String? error})> draftFromDeal(
    String dealId,
  ) async {
    final String url;
    try {
      url = ApiConfig.projectFromDeal(dealId);
    } on ArgumentError {
      return (draft: null, error: 'That deal could not be found.');
    }
    final response = await _api.get(url);
    final data = response.data;
    if (!response.success || data == null) {
      return (
        draft: null,
        error: response.statusCode == 404
            ? 'That deal could not be found.'
            : response.message ?? 'Could not read that deal.',
      );
    }
    return (draft: ProjectDraft.fromJson(data), error: null);
  }

  /// The tasks on a project, open ones first as the API orders them.
  Future<List<Task>?> fetchTasks(String id) async {
    final url = Uri.parse(
      ApiConfig.tasks,
    ).replace(queryParameters: {'project': id, 'limit': '200'}).toString();
    final response = await _api.get(url);
    final data = response.data;
    if (!response.success || data == null) return null;
    final body = api.TaskListResponse.fromJson(data);
    return [
      for (final row in body.tasks ?? const <api.TaskList>[])
        Task.fromJson(row.json),
    ];
  }

  /// Every entry on the project, newest first. A bare array, as on a ticket.
  Future<List<TimeEntry>?> fetchTimeEntries(String id) async {
    final response = await _api.getList(ApiConfig.projectTimeEntries(id));
    final data = response.data;
    if (!response.success || data == null) return null;
    return data
        .whereType<Map<String, dynamic>>()
        .map(TimeEntry.fromJson)
        .toList();
  }

  /// [billable] is the project's: false on a non-billable project, where the
  /// server keeps every entry non-billable anyway.
  Future<ApiResponse<Map<String, dynamic>>> startTimer(
    String id, {
    required bool billable,
    String? taskId,
  }) => _api.post(ApiConfig.projectTimerStart(id), {
    'billable': billable,
    'description': '',
    'task': ?taskId,
  });

  Future<ApiResponse<Map<String, dynamic>>> stopTimer(String entryId) =>
      _api.post(ApiConfig.timeEntryStop(entryId), const {});

  Future<ApiResponse<Map<String, dynamic>>> logTime(
    String id, {
    required DateTime startedAt,
    required DateTime endedAt,
    required bool billable,
    required String description,
    String? taskId,
  }) => _api.post(ApiConfig.projectTimeEntries(id), {
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'billable': billable,
    'description': description,
    'task': ?taskId,
  });

  Future<({ProjectUnbilled? unbilled, String? error})> unbilled(
    String id,
    String upTo,
  ) async {
    final response = await _api.get(ApiConfig.projectUnbilled(id, upTo));
    final data = response.data;
    if (!response.success || data == null) {
      return (
        unbilled: null,
        error: response.message ?? 'Could not read the unbilled time.',
      );
    }
    return (unbilled: ProjectUnbilled.fromJson(data), error: null);
  }

  /// A one-line Draft invoice for exactly one of [amount] or [percent].
  Future<ProjectWrite> invoiceAmount(
    String id, {
    String? amount,
    String? percent,
    String? description,
  }) async {
    final response = await _api.post(ApiConfig.projectInvoiceAmount(id), {
      'amount': ?amount,
      'percent': ?percent,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });
    if (!response.success) {
      return (id: null, error: response.message ?? 'Could not invoice.');
    }
    final drafted = api.ProjectInvoiceAmount.fromJson(response.data ?? {});
    return (id: drafted.invoiceId, error: null);
  }

  /// Bills the open retainer month. Answers the Draft invoice's id.
  ///
  /// [month] is the `YYYY-MM` the person was shown; the API refuses the bill
  /// when a different month is the one billing next.
  Future<ProjectWrite> billRetainer(String id, {String? month}) async {
    final response = await _api.post(ApiConfig.projectRetainerBill(id), {
      'month': ?month,
    });
    if (!response.success) {
      return (id: null, error: response.message ?? 'Could not bill the month.');
    }
    final billed = api.ProjectRetainerBill.fromJson(response.data ?? {});
    return (id: billed.invoiceId, error: null);
  }
}

final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, ProjectsListData>(
      ProjectsNotifier.new,
    );

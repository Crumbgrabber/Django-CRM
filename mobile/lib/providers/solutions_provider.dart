import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../data/api/schema.g.dart' as api;
import '../data/models/solution.dart';
import '../services/api_service.dart';

/// Solutions (Knowledge Base) state, independent of tickets.
class SolutionsListData {
  final List<Solution> solutions;
  final bool isLoading;
  final String? error;

  const SolutionsListData({
    this.solutions = const [],
    this.isLoading = false,
    this.error,
  });

  SolutionsListData copyWith({
    List<Solution>? solutions,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return SolutionsListData(
      solutions: solutions ?? this.solutions,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SolutionsNotifier extends Notifier<SolutionsListData> {
  final ApiService _api = ApiService();

  @override
  SolutionsListData build() {
    Future.microtask(() => refresh());
    return const SolutionsListData(isLoading: true);
  }

  Future<void> refresh({
    String? search,
    SolutionStatus? status,
    bool? publishedOnly,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    final params = <String, String>{};
    if (search != null && search.isNotEmpty) params['search'] = search;
    if (status != null) params['status'] = status.value;
    if (publishedOnly == true) params['is_published'] = 'true';

    final url = params.isEmpty
        ? ApiConfig.solutions
        : Uri.parse(
            ApiConfig.solutions,
          ).replace(queryParameters: params).toString();

    final response = await _api.get(url);
    if (!response.success || response.data == null) {
      state = state.copyWith(
        isLoading: false,
        error: response.message ?? 'Failed to load solutions',
      );
      return;
    }
    final rows = api.SolutionListResponse.fromJson(response.data!).results;
    state = state.copyWith(
      solutions: [
        for (final row in rows ?? const <api.Solution>[])
          Solution.fromJson(row.json),
      ],
      isLoading: false,
    );
  }

  /// Always the detail route, never the cached list row: only the detail
  /// carries `can_edit` and `can_delete`, and a list row standing in for it
  /// would hide Edit and Delete from the author.
  Future<Solution?> getById(String id) async {
    final response = await _api.get(ApiConfig.solutionDetail(id));
    if (!response.success || response.data == null) return null;
    return Solution.fromJson(response.data!);
  }

  Future<ApiResponse<Map<String, dynamic>>> create(Solution s) async {
    final response = await _api.post(ApiConfig.solutions, s.toCreatePayload());
    if (response.success) await refresh();
    return response;
  }

  Future<ApiResponse<Map<String, dynamic>>> update(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final response = await _api.put(ApiConfig.solutionDetail(id), payload);
    if (response.success) await refresh();
    return response;
  }

  Future<ApiResponse<Map<String, dynamic>>> delete(String id) async {
    final response = await _api.delete(ApiConfig.solutionDetail(id));
    if (response.success) {
      state = state.copyWith(
        solutions: state.solutions.where((s) => s.id != id).toList(),
      );
    }
    return response;
  }

  Future<ApiResponse<Map<String, dynamic>>> publish(String id) async {
    final response = await _api.post(ApiConfig.solutionPublish(id), const {});
    if (response.success) await refresh();
    return response;
  }

  Future<ApiResponse<Map<String, dynamic>>> unpublish(String id) async {
    final response = await _api.post(ApiConfig.solutionUnpublish(id), const {});
    if (response.success) await refresh();
    return response;
  }

  /// Link a solution to a ticket.
  Future<bool> linkToTicket(String ticketId, String solutionId) async {
    final response = await _api.post(ApiConfig.ticketSolutionLink(ticketId), {
      'solution_id': solutionId,
    });
    return response.success;
  }

  /// Unlink a solution from a ticket.
  Future<bool> unlinkFromTicket(String ticketId, String solutionId) async {
    final response = await _api.delete(
      ApiConfig.ticketSolutionUnlink(ticketId, solutionId),
    );
    return response.success;
  }

  /// Solution suggestions for a ticket (KB typeahead).
  Future<List<Solution>> suggestionsFor(String ticketId) async {
    final response = await _api.get(
      ApiConfig.ticketSolutionSuggestions(ticketId),
    );
    if (!response.success || response.data == null) return const [];
    final rows = api.SolutionSuggestionsResponse.fromJson(
      response.data!,
    ).results;
    return [
      for (final row in rows ?? const <api.SolutionSuggestion>[])
        Solution.fromJson(row.json),
    ];
  }
}

final solutionsProvider =
    NotifierProvider<SolutionsNotifier, SolutionsListData>(
      SolutionsNotifier.new,
    );

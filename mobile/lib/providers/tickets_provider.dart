import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/api_config.dart';
import '../data/api/schema.g.dart' as api;
import '../data/models/approval.dart';
import '../data/models/attachment.dart';
import '../data/models/ticket.dart';
import '../data/models/comment.dart';
import '../data/models/custom_field_definition.dart';
import '../data/models/email_message.dart';
import '../data/models/solution.dart';
import '../data/models/time_entry.dart';
import '../services/api_service.dart';

/// Paginated tickets snapshot, wrapped by AsyncValue.
class TicketsListData {
  final List<Ticket> tickets;
  final int totalCount;
  final bool hasMore;
  final int currentOffset;

  const TicketsListData({
    this.tickets = const [],
    this.totalCount = 0,
    this.hasMore = true,
    this.currentOffset = 0,
  });

  TicketsListData copyWith({
    List<Ticket>? tickets,
    int? totalCount,
    bool? hasMore,
    int? currentOffset,
  }) {
    return TicketsListData(
      tickets: tickets ?? this.tickets,
      totalCount: totalCount ?? this.totalCount,
      hasMore: hasMore ?? this.hasMore,
      currentOffset: currentOffset ?? this.currentOffset,
    );
  }
}

/// The query the "also open" rail asks: open tickets on one account.
///
/// `limit=6` and not 5, because this ticket is usually among them and is
/// dropped afterwards. Repeated `status=` params, the spelling the list view
/// reads (`choice_list_param`), and the same three statuses the web rail uses.
String alsoOpenQueryUrl(String accountId) {
  final statuses = openTicketStatuses
      .map((s) => 'status=${Uri.encodeQueryComponent(s.value)}')
      .join('&');
  return '${ApiConfig.tickets}?limit=6&slim=true'
      '&account=${Uri.encodeQueryComponent(accountId)}&$statuses';
}

/// Drop the ticket being read, keep five. Same as the web rail.
List<Ticket> pickAlsoOpen(
  Iterable<Ticket> rows, {
  required String excludeTicketId,
}) => rows.where((t) => t.id != excludeTicketId).take(5).toList();

/// The queue's filters as the API reads them, without paging. The list asks
/// with these and so does its CSV export, so the file holds what the screen
/// shows. A `List` value is a repeated parameter.
Map<String, Object> ticketListQuery(TicketListFilters filters) => {
  if (filters.search.isNotEmpty) 'search': filters.search,
  if (filters.statusList.isNotEmpty)
    'status': filters.statusList
  else if (filters.status != null)
    'status': filters.status!,
  if (filters.priority != null) 'priority': filters.priority!,
  if (filters.accountId != null) 'account': filters.accountId!,
  if (filters.caseType != null) 'case_type': filters.caseType!,
  if (filters.slaBreached) 'sla_breached': 'true',
  if (filters.createdAfter != null)
    'created_at__gte': filters.createdAfter!.toUtc().toIso8601String(),
  if (filters.createdBefore != null)
    'created_at__lte': filters.createdBefore!.toUtc().toIso8601String(),
  if (filters.assigneeIds.isNotEmpty) 'assigned_to': filters.assigneeIds,
  if (filters.tagIds.isNotEmpty) 'tags': filters.tagIds,
};

class TicketsNotifier extends AsyncNotifier<TicketsListData> {
  final ApiService _apiService = ApiService();
  static const int _pageSize = 20;

  @override
  Future<TicketsListData> build() =>
      _fetchPage(offset: 0, filters: const TicketListFilters());

  Future<void> refresh({
    TicketListFilters filters = const TicketListFilters(),
  }) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _fetchPage(offset: 0, filters: filters),
    );
  }

  Future<void> loadMore({
    TicketListFilters filters = const TicketListFilters(),
  }) async {
    final current = state.value;
    if (current == null || !current.hasMore) return;
    if (state.isLoading) return;

    state = await AsyncValue.guard(() async {
      final next = await _fetchPage(
        offset: current.currentOffset,
        filters: filters,
      );
      return current.copyWith(
        tickets: [...current.tickets, ...next.tickets],
        totalCount: next.totalCount,
        hasMore: next.hasMore,
        currentOffset: next.currentOffset,
      );
    });
  }

  Future<TicketsListData> _fetchPage({
    required int offset,
    required TicketListFilters filters,
  }) async {
    // Watching-only flips us to a different endpoint scoped to the current
    // profile's watched cases. Same filter params apply to both.
    final endpoint = filters.watchingOnly
        ? ApiConfig.ticketsWatching
        : ApiConfig.tickets;

    // `dynamic` so a value can be a List: `Uri.replace` turns one into a
    // repeated parameter, which is how the API takes several statuses.
    final params = <String, dynamic>{
      'limit': _pageSize.toString(),
      'offset': offset.toString(),
      ...ticketListQuery(filters),
    };
    final url = Uri.parse(endpoint).replace(queryParameters: params).toString();

    final response = await _apiService.get(url);
    if (!response.success || response.data == null) {
      throw Exception(response.message ?? 'Failed to load tickets');
    }

    // CaseListView returns `cases_count` (total matching) and `offset` (next
    // page offset, or null when this was the final page). The watching view
    // returns `count` and no offset. Treat its response as a single page.
    final List<api.Case> rows;
    final int? total;
    int? nextOffset;
    if (filters.watchingOnly) {
      final data = api.CaseWatchingResponse.fromJson(response.data!);
      rows = data.cases ?? const [];
      total = data.count;
    } else {
      final data = api.CaseListResponse.fromJson(response.data!);
      rows = data.cases ?? const [];
      total = data.casesCount;
      nextOffset = data.offset;
    }
    final newTickets = [for (final row in rows) Ticket.fromJson(row.json)];

    return TicketsListData(
      tickets: newTickets,
      totalCount: total ?? newTickets.length,
      hasMore: !filters.watchingOnly && nextOffset != null,
      currentOffset: nextOffset ?? (offset + rows.length),
    );
  }

  /// Fetch a single ticket (just the Ticket object).
  ///
  /// Never follows a merge: the edit form saves back to [id], so handing it
  /// the ticket a merged one redirects to would write that ticket's fields
  /// onto the merged one. A merged ticket is null here, as it always was.
  ///
  /// Null on any failure: the edit form has one error state, and it only
  /// needs to know there is nothing to edit.
  Future<Ticket?> getTicketById(String id) async {
    try {
      final detail = await _fetchTicketDetail(id, followMerge: false);
      return detail?.ticketObj;
    } on TicketLoadFailure {
      return null;
    }
  }

  /// Fetch the full ticket detail (incl. comments + activities + permissions).
  ///
  /// Null only for a 404, which is also what a ticket the caller may not open
  /// answers, so the two cannot be told apart. Any other failure (offline, a
  /// 500, a body that will not parse) throws [TicketLoadFailure], so a screen
  /// can offer a retry instead of saying the ticket does not exist.
  ///
  /// A merged ticket answers with `redirect_to`, the ticket it was merged
  /// into, instead of itself. That one is fetched and returned in its place,
  /// as the web redirects, so the result's `ticketObj.id` differs from [id]
  /// and no screen ever offers a status change on the merged ticket (the API
  /// refuses one until it is unmerged).
  Future<TicketDetailResult?> getTicketDetail(String id) =>
      _fetchTicketDetail(id, followMerge: true);

  Future<TicketDetailResult?> _fetchTicketDetail(
    String id, {
    required bool followMerge,
  }) async {
    final response = await _apiService.get(ApiConfig.ticketDetail(id));
    if (response.statusCode == 404) return null;
    if (!response.success || response.data == null) {
      throw TicketLoadFailure(
        response.statusCode == 0
            ? (response.message ?? TicketLoadFailure.fallback)
            : TicketLoadFailure.fallback,
      );
    }

    // Followed once: a merge never targets a ticket that is itself merged,
    // and a second hop would mean something is wrong, not a longer chain.
    final redirectTo = api.CaseMergedRedirectResponse.fromJson(
      response.data!,
    ).redirectTo;
    if (redirectTo != null && redirectTo.isNotEmpty) {
      if (followMerge) {
        return _fetchTicketDetail(redirectTo, followMerge: false);
      }
      throw const TicketLoadFailure(TicketLoadFailure.fallback);
    }

    try {
      final data = api.CaseDetailResponse.fromJson(response.data!);
      final ticketData = data.casesObj;
      if (ticketData == null) {
        throw const TicketLoadFailure(TicketLoadFailure.fallback);
      }
      var ticketObj = Ticket.fromJson(ticketData.json);

      // Public + internal comments are sent in two separate arrays. We tag
      // each so the UI can render an "Internal" badge without an extra
      // round-trip; `Comment` itself doesn't carry that flag yet.
      final List<_TaggedComment> tagged = [
        for (final c in data.comments ?? const <api.Comment>[])
          _TaggedComment(comment: Comment.fromJson(c.json), isInternal: false),
        for (final c in data.internalNotes ?? const <api.Comment>[])
          _TaggedComment(comment: Comment.fromJson(c.json), isInternal: true),
      ];
      tagged.sort(
        (a, b) => b.comment.commentedOn.compareTo(a.comment.commentedOn),
      );
      if (tagged.isNotEmpty) {
        ticketObj = ticketObj.copyWith(
          comments: tagged.map((t) => t.comment).toList(),
        );
      }
      final approvalRule = data.approvalRule;

      return TicketDetailResult(
        ticketObj: ticketObj,
        activities: [
          for (final a in data.activities ?? const <api.Activity>[]) a.json,
        ],
        // `CaseDetailView` has returned these all along. Nothing on the phone
        // read them, so a screenshot attached to a ticket was invisible here.
        attachments: [
          for (final a in data.attachments ?? const <api.Attachments>[])
            Attachment.fromJson(a.json),
        ],
        emails: [
          for (final e in data.emailMessages ?? const <api.EmailMessage>[])
            EmailMessage.fromJson(e.json),
        ],
        mergedFromCases: [
          for (final m
              in data.mergedFromCases ?? const <api.CaseMergedSource>[])
            MergedFromSummary.fromJson(m.json),
        ],
        linkedSolutions: [
          for (final s in data.solutions ?? const <api.Solution>[])
            Solution.fromJson(s.json),
        ],
        commentPermission: data.commentPermission ?? false,
        canMerge: data.canMerge ?? false,
        approvalRule: approvalRule == null
            ? null
            : ApprovalRuleSummary.fromJson(approvalRule.json),
        internalCommentIds: tagged
            .where((t) => t.isInternal)
            .map((t) => t.comment.id)
            .toSet(),
        customFieldDefinitions: customFieldDefinitionsIn(response.data),
      );
    } on TicketLoadFailure {
      rethrow;
    } catch (_) {
      // A body that does not parse is a failed load, not a missing ticket.
      throw const TicketLoadFailure(TicketLoadFailure.fallback);
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> createTicket(
    Map<String, dynamic> ticketData,
  ) async {
    try {
      final response = await _apiService.post(ApiConfig.tickets, ticketData);
      if (response.success) await refresh();
      return response;
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// `PATCH /api/cases/<id>/`, not PUT.
  ///
  /// PUT is a full replace: `CaseDetailView.put` clears `contacts`, `teams`,
  /// `assigned_to` and `tags` unconditionally and re-adds only what the body
  /// carries. This form sent no `contacts` and no `teams`, so every edit made
  /// from the phone silently unlinked every contact and every team on the
  /// ticket, whatever the edit was actually about. PATCH touches an M2M only
  /// when the key is present, which is what a partial form means.
  ///
  /// The web app has always used PATCH. Assignment notification is on both
  /// verbs now (`cases.views.notify_newly_assigned`), so switching loses
  /// nothing.
  Future<ApiResponse<Map<String, dynamic>>> updateTicket(
    String id,
    Map<String, dynamic> ticketData,
  ) async {
    try {
      final response = await _apiService.patch(
        ApiConfig.ticketDetail(id),
        ticketData,
      );
      if (response.success) await refresh();
      return response;
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> addComment(
    String ticketId,
    String comment, {
    bool isInternal = false,
  }) async {
    try {
      final response = await _apiService.post(
        ApiConfig.ticketDetail(ticketId),
        {'comment': comment, 'is_internal': isInternal},
      );
      return response;
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Fetch watcher list for a ticket.
  /// Returns ({watcherCount, isCurrentUserWatching, watchers}) or null on error.
  /// The other open tickets on the same account, most recent first.
  ///
  /// A second request because the detail endpoint has no idea what else is
  /// happening on that account. The web rail asks the same question the same
  /// way, so both clients rank the same rows: open statuses only, this ticket
  /// dropped, five kept.
  ///
  /// Degrades to an empty list rather than failing the screen. It is context
  /// beside the ticket, not the ticket.
  Future<List<Ticket>> getAlsoOpenOnAccount({
    required String accountId,
    required String excludeTicketId,
  }) async {
    if (accountId.isEmpty) return const [];
    try {
      final response = await _apiService.get(alsoOpenQueryUrl(accountId));
      if (!response.success || response.data == null) return const [];
      final rows = api.CaseListResponse.fromJson(response.data!).cases;
      return pickAlsoOpen([
        for (final row in rows ?? const <api.Case>[]) Ticket.fromJson(row.json),
      ], excludeTicketId: excludeTicketId);
    } catch (_) {
      return const [];
    }
  }

  Future<TicketWatchers?> getWatchers(String id) async {
    try {
      final response = await _apiService.get(ApiConfig.ticketWatchers(id));
      if (!response.success || response.data == null) return null;
      final data = api.CaseWatchersResponse.fromJson(response.data!);
      final list = [
        for (final w in data.watchers ?? const <api.CaseWatcherRow>[]) w.json,
      ];
      return TicketWatchers(
        watchers: list,
        count: list.length,
        isCurrentUserWatching: data.isCurrentUserWatching ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetch all time entries for a ticket (most recent first).
  Future<List<TimeEntry>> fetchTimeEntries(String id) async {
    try {
      // Backend returns a bare array, not an envelope.
      final response = await _apiService.getList(
        ApiConfig.ticketTimeEntries(id),
      );
      if (!response.success || response.data == null) return const [];
      return response.data!
          .whereType<Map<String, dynamic>>()
          .map(TimeEntry.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Fetch ticket time summary (totals + per-profile).
  Future<TimeSummary?> fetchTimeSummary(String id) async {
    try {
      final response = await _apiService.get(ApiConfig.ticketTimeSummary(id));
      if (!response.success || response.data == null) return null;
      return TimeSummary.fromJson(response.data!);
    } catch (_) {
      return null;
    }
  }

  /// Start a running timer on a ticket.
  Future<ApiResponse<Map<String, dynamic>>> startTimer(
    String id, {
    bool billable = false,
    String description = '',
  }) async {
    try {
      return await _apiService.post(ApiConfig.ticketTimerStart(id), {
        'billable': billable,
        'description': description,
      });
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Stop a running timer by entry id.
  Future<ApiResponse<Map<String, dynamic>>> stopTimer(String entryId) async {
    try {
      return await _apiService.post(ApiConfig.timeEntryStop(entryId), const {});
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Add a manual completed time entry.
  Future<ApiResponse<Map<String, dynamic>>> addManualTimeEntry(
    String id, {
    required DateTime startedAt,
    required DateTime endedAt,
    bool billable = false,
    String description = '',
  }) async {
    try {
      return await _apiService.post(ApiConfig.ticketTimeEntries(id), {
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt.toUtc().toIso8601String(),
        'billable': billable,
        'description': description,
      });
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Fetch parent/child tree (rooted at the closest visible ancestor).
  Future<TicketTreeNode?> fetchTree(String id) async {
    try {
      final response = await _apiService.get(ApiConfig.ticketTree(id));
      if (!response.success || response.data == null) return null;
      final data = api.CaseTreeResponse.fromJson(response.data!);
      final root = data.root;
      if (root == null) return null;
      return TicketTreeNode.fromJson(root.json, focusId: data.focusId);
    } catch (_) {
      return null;
    }
  }

  /// Link to a parent (pass null to detach).
  Future<ApiResponse<Map<String, dynamic>>> linkParent(
    String id,
    String? parentId,
  ) async {
    try {
      return await _apiService.post(ApiConfig.ticketLinkParent(id), {
        'parent_id': parentId,
      });
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Close this ticket; optionally cascade-close its open descendants.
  ///
  /// `cascade` is always sent. The endpoint falls back to the org's
  /// `auto_close_children_on_parent_close` only when the key is ABSENT, so
  /// omitting it would hand the decision to a setting the person confirming
  /// never saw. The prompt seeds its checkbox from that setting instead.
  ///
  /// `resolutionComment` lands in the `PARENT_CLOSED_CASCADE` activity row on
  /// every cascaded child, so it is the only explanation anyone opening one of
  /// those tickets will find. This used to send nothing at all, which left that
  /// field empty on every ticket the phone ever cascade-closed.
  Future<ApiResponse<Map<String, dynamic>>> closeWithChildren(
    String id, {
    bool cascade = true,
    String resolutionComment = '',
  }) async {
    try {
      return await _apiService.post(ApiConfig.ticketCloseWithChildren(id), {
        'cascade': cascade,
        'resolution_comment': resolutionComment.trim(),
      });
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Merge `sourceId` as a duplicate INTO `intoId`. Source becomes inactive
  /// and its comments/attachments/emails move to the target.
  Future<ApiResponse<Map<String, dynamic>>> mergeInto(
    String sourceId,
    String intoId,
  ) async {
    try {
      return await _apiService.post(
        ApiConfig.ticketMerge(sourceId, intoId),
        const {},
      );
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// The tickets [sourceId] may be merged into, as the server computes them
  /// (at most 20, newest first, narrowed by name with [search]). The picker
  /// lists only these: never the loaded list, which holds tickets the merge
  /// would refuse. A failure carries the server's sentence, e.g. the 403 for
  /// a caller who may not merge this ticket.
  Future<ApiResponse<List<Ticket>>> mergeTargets(
    String sourceId, {
    String search = '',
  }) async {
    final query = search.trim();
    final response = await _apiService.get(
      ApiConfig.ticketMergeTargets(sourceId),
      queryParams: query.isEmpty ? null : {'search': query},
    );
    if (!response.success || response.data == null) {
      return ApiResponse(
        success: false,
        message: response.message ?? 'Could not load tickets to merge into.',
        statusCode: response.statusCode,
      );
    }
    final rows = api.CaseMergeTargetsResponse.fromJson(response.data!).results;
    final tickets = [
      for (final row in rows ?? const <api.CaseMergeTarget>[])
        Ticket.fromJson({
          ...row.json,
          'account': row.accountName == null ? null : {'name': row.accountName},
        }),
    ];
    return ApiResponse(
      success: true,
      data: tickets,
      statusCode: response.statusCode,
    );
  }

  /// Reverse a prior merge; called on the source ticket id.
  Future<ApiResponse<Map<String, dynamic>>> unmerge(String sourceId) async {
    try {
      return await _apiService.post(
        ApiConfig.ticketUnmerge(sourceId),
        const {},
      );
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Toggle the current user's watch state on a ticket.
  Future<bool> setWatching(String id, bool watch) async {
    try {
      final response = watch
          ? await _apiService.post(ApiConfig.ticketWatch(id), const {})
          : await _apiService.delete(ApiConfig.ticketWatch(id));
      return response.success;
    } catch (_) {
      return false;
    }
  }

  /// Bulk-update the given tickets in one call. `fields` is applied
  /// server-side: `tags` appends to each ticket's existing tags, `assigned_to`
  /// replaces them, and every other field is a plain overwrite.
  ///
  /// Returns the raw `{error, updated, results}` envelope untouched. This
  /// layer does not summarize it or refresh local state; the caller (the
  /// bulk-actions UI) does both, since it also owns the current selection.
  Future<ApiResponse<Map<String, dynamic>>> bulkUpdate(
    List<String> ids,
    Map<String, dynamic> fields,
  ) async {
    try {
      return await _apiService.post(ApiConfig.casesBulkUpdate, {
        'ids': ids,
        'fields': fields,
      });
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  /// Bulk-delete the given tickets in one call. Per-record authorization
  /// (admin or creator) is enforced server-side, so a caller with no rights
  /// on some of the ids gets those reported as failures in `results` rather
  /// than the whole request being refused.
  ///
  /// Returns the raw `{error, deleted, results}` envelope untouched, same as
  /// [bulkUpdate].
  Future<ApiResponse<Map<String, dynamic>>> bulkDelete(List<String> ids) async {
    try {
      return await _apiService.post(ApiConfig.casesBulkDelete, {'ids': ids});
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteTicket(String id) async {
    try {
      final response = await _apiService.delete(ApiConfig.ticketDetail(id));
      if (response.success) {
        final current = state.value;
        if (current != null) {
          state = AsyncValue.data(
            current.copyWith(
              tickets: current.tickets.where((t) => t.id != id).toList(),
              totalCount: current.totalCount > 0 ? current.totalCount - 1 : 0,
            ),
          );
        }
      }
      return response;
    } catch (e) {
      return ApiResponse(success: false, message: e.toString(), statusCode: 0);
    }
  }
}

final ticketsProvider = AsyncNotifierProvider<TicketsNotifier, TicketsListData>(
  TicketsNotifier.new,
);

/// Convenience providers. Read from the AsyncValue.
final ticketsListProvider = Provider<List<Ticket>>((ref) {
  return ref.watch(ticketsProvider).value?.tickets ?? const [];
});

final ticketsLoadingProvider = Provider<bool>((ref) {
  return ref.watch(ticketsProvider).isLoading;
});

final ticketsErrorProvider = Provider<String?>((ref) {
  return ref.watch(ticketsProvider).error?.toString();
});

/// A ticket detail that could not be loaded for a reason other than a 404:
/// offline, a server error, a body that would not parse. [message] is what to
/// show beside a retry. A 404 is not this: it is a null result.
class TicketLoadFailure implements Exception {
  final String message;
  const TicketLoadFailure(this.message);

  static const fallback =
      'The server could not load this ticket. Try again in a moment.';

  @override
  String toString() => 'TicketLoadFailure: $message';
}

/// Bundled detail-fetch result. The mobile detail screen needs more than
/// just the Ticket object, also activities and the per-user permission to
/// add comments.
class TicketDetailResult {
  final Ticket ticketObj;
  final List<Map<String, dynamic>> activities;
  final List<EmailMessage> emails;
  final List<MergedFromSummary> mergedFromCases;
  final List<Solution> linkedSolutions;
  final List<Attachment> attachments;
  final bool commentPermission;

  /// Whether the caller may merge this ticket into another (admin or its
  /// creator), as the server decides. Gates the "Merge into" action.
  final bool canMerge;

  /// The approval rule that gates closing this ticket (`approval_rule`), or
  /// null when none does. "Request approval" is offered only when it is set.
  final ApprovalRuleSummary? approvalRule;
  final Set<String> internalCommentIds;

  /// The org's active ticket fields, from the same response.
  final List<CustomFieldDefinition> customFieldDefinitions;

  const TicketDetailResult({
    required this.ticketObj,
    required this.activities,
    this.emails = const [],
    this.mergedFromCases = const [],
    this.linkedSolutions = const [],
    this.attachments = const [],
    required this.commentPermission,
    this.canMerge = false,
    this.approvalRule,
    required this.internalCommentIds,
    this.customFieldDefinitions = const [],
  });

  TicketDetailResult copyWith({List<Attachment>? attachments}) {
    return TicketDetailResult(
      ticketObj: ticketObj,
      activities: activities,
      emails: emails,
      mergedFromCases: mergedFromCases,
      linkedSolutions: linkedSolutions,
      attachments: attachments ?? this.attachments,
      commentPermission: commentPermission,
      canMerge: canMerge,
      approvalRule: approvalRule,
      internalCommentIds: internalCommentIds,
      customFieldDefinitions: customFieldDefinitions,
    );
  }
}

/// Recursive tree node returned by `/api/cases/{id}/tree/`.
///
/// A ticket the viewer may not open comes back redacted: `restricted: true`,
/// `name: null`, and only its id, status and active flag. It stays in the tree
/// so the shape and the cascade count are true; [name] reads as
/// [restrictedName] for it, and the screen does not offer to open it.
class TicketTreeNode {
  static const restrictedName = TicketParentSummary.restrictedName;

  final String id;
  final String name;
  final String? status;
  final String? priority;
  final bool isProblem;
  final bool isActive;
  final bool truncated;
  final bool restricted;
  final List<TicketTreeNode> children;
  final String? focusId;

  const TicketTreeNode({
    required this.id,
    required this.name,
    this.status,
    this.priority,
    this.isProblem = false,
    this.isActive = true,
    this.truncated = false,
    this.restricted = false,
    this.children = const [],
    this.focusId,
  });

  bool get isFocused => focusId != null && focusId == id;

  /// Reads a `CaseTreeNodeResponse`.
  factory TicketTreeNode.fromJson(
    Map<String, dynamic> json, {
    String? focusId,
  }) {
    final w = api.CaseTreeNodeResponse.fromJson(json);
    final restricted = w.restricted ?? false;
    return TicketTreeNode(
      id: w.id ?? '',
      name: restricted ? restrictedName : w.name ?? '',
      status: w.status,
      priority: w.priority,
      isProblem: w.isProblem ?? false,
      isActive: w.isActive ?? true,
      truncated: w.truncated ?? false,
      restricted: restricted,
      children: [
        for (final c in w.children ?? const <api.CaseTreeNodeResponse>[])
          TicketTreeNode.fromJson(c.json, focusId: focusId),
      ],
      focusId: focusId,
    );
  }

  /// The node for [id] anywhere in this tree, or null.
  TicketTreeNode? find(String id) {
    if (id.isEmpty) return null;
    if (this.id == id) return this;
    for (final child in children) {
      final hit = child.find(id);
      if (hit != null) return hit;
    }
    return null;
  }

  /// The tickets a cascading close of [id] would actually close.
  ///
  /// **This tree's root is not the ticket being closed.** `CaseTreeView` walks
  /// UP to the highest ancestor in the org, so the subtree that closes has to
  /// be found inside the response first. Walking from the root instead would
  /// list the ticket's parent, siblings and cousins as about to close, none of
  /// which `_open_descendants` touches.
  ///
  /// Mirrors `_open_descendants` in `cases/parent_views.py`, including the two
  /// easy mistakes: a node counts only when it is open (neither Closed nor
  /// Duplicate, since a merged ticket's status is not the cascade's to change)
  /// AND active, and recursion goes through closed nodes anyway, so an open
  /// grandchild under a closed child still cascades.
  ///
  /// `frontend/src/routes/(app)/tickets/[id]/close.js` carries the same rules.
  List<TicketTreeNode> openDescendantsOf(String id) {
    final focus = find(id);
    if (focus == null) return const [];
    final out = <TicketTreeNode>[];
    void walk(TicketTreeNode node) {
      for (final child in node.children) {
        final open = child.status != 'Closed' && child.status != 'Duplicate';
        if (open && child.isActive) out.add(child);
        walk(child);
      }
    }

    walk(focus);
    return out;
  }

  /// True when the API stopped at its depth cap inside [id]'s subtree, so the
  /// list above is a floor. The close itself has no such cap.
  bool subtreeTruncatedFor(String id) {
    final focus = find(id);
    if (focus == null) return false;
    bool walk(TicketTreeNode node) => node.truncated || node.children.any(walk);
    return walk(focus);
  }
}

/// Lightweight reference to a ticket that was merged into the current one.
///
/// A source the viewer may not open arrives as `restricted: true` with no
/// name, the `parent_summary` redaction (D51). [name] then reads as
/// [restrictedName] and the screen does not offer to open it.
///
/// [canUnmerge] is the server's answer to whether the caller may unmerge this
/// source (admin, or creator of both tickets); the screen offers Unmerge only
/// when it is true.
class MergedFromSummary {
  static const restrictedName = TicketParentSummary.restrictedName;

  final String id;
  final String name;
  final DateTime? mergedAt;
  final bool restricted;
  final bool canUnmerge;
  const MergedFromSummary({
    required this.id,
    required this.name,
    this.mergedAt,
    this.restricted = false,
    this.canUnmerge = false,
  });

  /// Reads a `CaseMergedSource`.
  factory MergedFromSummary.fromJson(Map<String, dynamic> json) {
    final w = api.CaseMergedSource.fromJson(json);
    final restricted = w.restricted ?? false;
    return MergedFromSummary(
      id: w.id ?? '',
      name: restricted ? restrictedName : w.name ?? '',
      mergedAt: DateTime.tryParse(w.mergedAt ?? ''),
      restricted: restricted,
      canUnmerge: w.canUnmerge ?? false,
    );
  }
}

/// Bundle of filters applied to the tickets list.
///
/// All filters are server-side now (backend accepts the same params on
/// `/cases/` and `/cases/watching/`). `statusList` is the multi-status form
/// used by the Open/Closed quick chips; if it's empty we fall back to the
/// single-value `status` field.
class TicketListFilters {
  final String search;
  final String? status;
  final List<String> statusList;
  final String? priority;
  final String? accountId;
  final String? caseType;
  final List<String> assigneeIds;
  final List<String> tagIds;
  final bool watchingOnly;
  final bool slaBreached;
  final DateTime? createdAfter;
  final DateTime? createdBefore;

  const TicketListFilters({
    this.search = '',
    this.status,
    this.statusList = const [],
    this.priority,
    this.accountId,
    this.caseType,
    this.assigneeIds = const [],
    this.tagIds = const [],
    this.watchingOnly = false,
    this.slaBreached = false,
    this.createdAfter,
    this.createdBefore,
  });

  /// A saved view's filters (`{param: [value, ...]}`) as the queue's state:
  /// what [ticketListQuery] sends, read back. One status is the single
  /// `status`, several the `statusList` the quick chips use. Watching is an
  /// endpoint rather than a filter, so a view never turns it on.
  factory TicketListFilters.fromQuery(Map<String, List<String>> query) {
    String? one(String key) {
      final values = query[key];
      return values == null || values.isEmpty ? null : values.first;
    }

    final statuses = query['status'] ?? const <String>[];
    return TicketListFilters(
      search: one('search') ?? '',
      status: statuses.length == 1 ? statuses.first : null,
      statusList: statuses.length > 1 ? statuses : const [],
      priority: one('priority'),
      accountId: one('account'),
      caseType: one('case_type'),
      assigneeIds: query['assigned_to'] ?? const [],
      tagIds: query['tags'] ?? const [],
      slaBreached: one('sla_breached') == 'true',
      createdAfter: DateTime.tryParse(one('created_at__gte') ?? ''),
      createdBefore: DateTime.tryParse(one('created_at__lte') ?? ''),
    );
  }

  bool get hasAny =>
      search.isNotEmpty ||
      status != null ||
      statusList.isNotEmpty ||
      priority != null ||
      accountId != null ||
      caseType != null ||
      assigneeIds.isNotEmpty ||
      tagIds.isNotEmpty ||
      watchingOnly ||
      slaBreached ||
      createdAfter != null ||
      createdBefore != null;

  TicketListFilters copyWith({
    String? search,
    String? status,
    List<String>? statusList,
    String? priority,
    String? accountId,
    String? caseType,
    List<String>? assigneeIds,
    List<String>? tagIds,
    bool? watchingOnly,
    bool? slaBreached,
    DateTime? createdAfter,
    DateTime? createdBefore,
    bool clearStatus = false,
    bool clearStatusList = false,
    bool clearPriority = false,
    bool clearAccountId = false,
    bool clearCaseType = false,
    bool clearCreatedAfter = false,
    bool clearCreatedBefore = false,
  }) {
    return TicketListFilters(
      search: search ?? this.search,
      status: clearStatus ? null : (status ?? this.status),
      statusList: clearStatusList ? const [] : (statusList ?? this.statusList),
      priority: clearPriority ? null : (priority ?? this.priority),
      accountId: clearAccountId ? null : (accountId ?? this.accountId),
      caseType: clearCaseType ? null : (caseType ?? this.caseType),
      assigneeIds: assigneeIds ?? this.assigneeIds,
      tagIds: tagIds ?? this.tagIds,
      watchingOnly: watchingOnly ?? this.watchingOnly,
      slaBreached: slaBreached ?? this.slaBreached,
      createdAfter: clearCreatedAfter
          ? null
          : (createdAfter ?? this.createdAfter),
      createdBefore: clearCreatedBefore
          ? null
          : (createdBefore ?? this.createdBefore),
    );
  }

  /// JSON-encode for SharedPreferences. ISO-8601 for dates; default field
  /// values are not omitted so we get a stable round-trip on decode.
  Map<String, dynamic> toJson() => {
    'search': search,
    if (status != null) 'status': status,
    'statusList': statusList,
    if (priority != null) 'priority': priority,
    if (accountId != null) 'accountId': accountId,
    if (caseType != null) 'caseType': caseType,
    'assigneeIds': assigneeIds,
    'tagIds': tagIds,
    'watchingOnly': watchingOnly,
    'slaBreached': slaBreached,
    if (createdAfter != null) 'createdAfter': createdAfter!.toIso8601String(),
    if (createdBefore != null)
      'createdBefore': createdBefore!.toIso8601String(),
  };

  factory TicketListFilters.fromJson(Map<String, dynamic> json) {
    return TicketListFilters(
      search: json['search'] as String? ?? '',
      status: json['status'] as String?,
      statusList: ((json['statusList'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(),
      priority: json['priority'] as String?,
      accountId: json['accountId'] as String?,
      caseType: json['caseType'] as String?,
      assigneeIds: ((json['assigneeIds'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(),
      tagIds: ((json['tagIds'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(),
      watchingOnly: json['watchingOnly'] as bool? ?? false,
      slaBreached: json['slaBreached'] as bool? ?? false,
      createdAfter: json['createdAfter'] != null
          ? DateTime.tryParse(json['createdAfter'] as String)
          : null,
      createdBefore: json['createdBefore'] != null
          ? DateTime.tryParse(json['createdBefore'] as String)
          : null,
    );
  }
}

/// Watcher list response, used by the detail screen's sidebar.
class TicketWatchers {
  final List<Map<String, dynamic>> watchers;
  final int count;
  final bool isCurrentUserWatching;
  const TicketWatchers({
    required this.watchers,
    required this.count,
    required this.isCurrentUserWatching,
  });
}

class _TaggedComment {
  final Comment comment;
  final bool isInternal;
  const _TaggedComment({required this.comment, required this.isInternal});
}

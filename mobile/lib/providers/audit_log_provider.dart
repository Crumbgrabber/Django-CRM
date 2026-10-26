import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../data/api/schema.g.dart' as api;
import '../data/models/audit_entry.dart';
import '../services/api_service.dart';

/// The security audit log, mirroring `/settings/audit-log` on the web.
///
/// Admin-only server-side (`common/views/audit_log_views.py`). The screen
/// gates on `isOrgAdminProvider` so a member never asks; that is a courtesy,
/// not the boundary. The server validates every filter and answers 400 on a
/// malformed one, whose sentence the screen shows.
///
/// Token refreshes (a signed-in app quietly renewing its session) are most of
/// the log, so the server leaves them out unless `include_token_refresh=true`
/// is sent or the Token Refresh event is picked.

/// Entries per page, the same as the web.
const int auditLogPageSize = 25;

/// What the screen is asking for. A record, so two equal queries share one
/// cached page.
typedef AuditLogQuery = ({
  String? eventType,
  String? actor,
  DateTime? from,
  DateTime? to,
  bool includeTokenRefresh,
  int offset,
});

const AuditLogQuery auditLogFirstPage = (
  eventType: null,
  actor: null,
  from: null,
  to: null,
  includeTokenRefresh: false,
  offset: 0,
);

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The query parameters for [q]. Only set filters are sent.
Map<String, String> auditLogParams(AuditLogQuery q) => {
  'limit': '$auditLogPageSize',
  'offset': '${q.offset}',
  if (q.eventType != null && q.eventType!.isNotEmpty)
    'event_type': q.eventType!,
  if (q.actor != null && q.actor!.isNotEmpty) 'actor': q.actor!,
  if (q.from != null) 'from': _day(q.from!),
  if (q.to != null) 'to': _day(q.to!),
  if (q.includeTokenRefresh) 'include_token_refresh': 'true',
};

class AuditLogPage {
  const AuditLogPage({
    this.entries = const [],
    this.count = 0,
    this.eventTypes = const [],
  });

  final List<AuditEntry> entries;
  final int count;
  final List<AuditEventType> eventTypes;
}

final auditLogProvider = FutureProvider.autoDispose
    .family<AuditLogPage, AuditLogQuery>((ref, q) async {
      final response = await ApiService().get(
        ApiConfig.auditLog,
        queryParams: auditLogParams(q),
      );
      if (!response.success || response.data == null) {
        throw Exception(response.message ?? 'Could not load the audit log');
      }
      final body = api.AuditLogListResponse.fromJson(response.data!);
      final entries = [
        for (final row in body.results ?? const <api.AuditLogEntry>[])
          AuditEntry.fromJson(row.json),
      ];
      return AuditLogPage(
        entries: entries,
        count: body.count ?? entries.length,
        eventTypes: [
          for (final row in body.eventTypes ?? const <api.AuditLogEventType>[])
            AuditEventType.fromJson(row.json),
        ],
      );
    });

/// The state of your task calendar feed, from `GET /api/profile/calendar-feed/`.
///
/// Never the URL: the API keeps only a hash of it, so the URL exists on the
/// phone only in the response to the request that created it.
library;

import '../api/schema.g.dart' as api;

class CalendarFeed {
  const CalendarFeed({this.enabled = false, this.createdAt, this.lastUsedAt});

  final bool enabled;

  /// When the current URL was issued. Regenerating resets it.
  final DateTime? createdAt;

  /// When a calendar app last read the feed. Moved at most once an hour.
  final DateTime? lastUsedAt;

  /// Reads a `CalendarFeedStateResponse`.
  factory CalendarFeed.fromJson(Map<String, dynamic> json) {
    final w = api.CalendarFeedStateResponse.fromJson(json);
    DateTime? when(String? value) =>
        value == null ? null : DateTime.tryParse(value)?.toLocal();
    return CalendarFeed(
      enabled: w.enabled == true,
      createdAt: when(w.createdAt),
      lastUsedAt: when(w.lastUsedAt),
    );
  }
}

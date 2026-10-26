import 'package:bottle_crm/core/theme/theme.dart';
import 'package:bottle_crm/data/models/ticket.dart';
import 'package:bottle_crm/data/models/time_entry.dart';
import 'package:bottle_crm/providers/lookup_provider.dart';
import 'package:bottle_crm/providers/tickets_provider.dart';
import 'package:bottle_crm/screens/tickets/ticket_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The ticket timeline names who acted. Since 1.2 the actor's email is under
/// `user.user_details`, as the web reads it; before that the activity came
/// with a flat `user.email`, which a server that old still sends.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app(List<Map<String, dynamic>> activities) => ProviderScope(
    overrides: [
      ticketsProvider.overrideWith(() => _FakeTicketsNotifier(activities)),
      usersProvider.overrideWithValue(const []),
      tagsProvider.overrideWithValue(const []),
      accountOptionsProvider.overrideWithValue(const []),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light,
      routerConfig: GoRouter(
        initialLocation: '/here',
        routes: [
          GoRoute(
            path: '/here',
            builder: (_, _) => const TicketDetailScreen(ticketId: 'c1'),
          ),
        ],
      ),
    ),
  );

  Future<void> openActivity(
    WidgetTester tester,
    Map<String, dynamic> activity,
  ) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app([activity]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
  }

  testWidgets('names the actor from user_details', (tester) async {
    await openActivity(tester, {
      'id': 'a1',
      'action': 'UPDATE',
      'action_display': 'Updated',
      'user': {
        'id': 'p1',
        'user_details': {'email': 'asha@example.com'},
      },
      'created_at': '2026-09-01T09:00:00Z',
    });

    expect(find.textContaining('asha@example.com'), findsOneWidget);
  });

  testWidgets('still names it from an older server\'s flat user', (
    tester,
  ) async {
    await openActivity(tester, {
      'id': 'a1',
      'action': 'UPDATE',
      'action_display': 'Updated',
      'user': {'email': 'raj@example.com'},
      'timestamp': '2026-09-01T09:00:00Z',
    });

    expect(find.textContaining('raj@example.com'), findsOneWidget);
  });
}

class _FakeTicketsNotifier extends TicketsNotifier {
  _FakeTicketsNotifier(this.activities);

  final List<Map<String, dynamic>> activities;

  @override
  Future<TicketsListData> build() async =>
      TicketsListData(tickets: const [], totalCount: 0, hasMore: false);

  @override
  Future<TicketDetailResult?> getTicketDetail(String id) async =>
      TicketDetailResult(
        ticketObj: Ticket.fromJson({
          'id': id,
          'name': 'Printer on fire',
          'status': 'New',
          'priority': 'Normal',
          'created_at': '2026-09-01T09:00:00Z',
        }),
        activities: activities,
        commentPermission: true,
        internalCommentIds: const {},
      );

  @override
  Future<TicketWatchers?> getWatchers(String id) async => const TicketWatchers(
    watchers: [],
    count: 0,
    isCurrentUserWatching: false,
  );

  @override
  Future<TicketTreeNode?> fetchTree(String id) async => null;

  @override
  Future<List<TimeEntry>> fetchTimeEntries(String id) async => const [];

  @override
  Future<TimeSummary?> fetchTimeSummary(String id) async => null;
}

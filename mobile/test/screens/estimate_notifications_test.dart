import 'package:bottle_crm/data/models/app_notification.dart';
import 'package:bottle_crm/providers/notifications_provider.dart';
import 'package:bottle_crm/screens/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A client's answer to an estimate in the feed: the sentence, its icon, no
/// person beside it, and the record it opens.
const _projectId = '11111111-1111-4111-8111-111111111111';
const _depositId = '22222222-2222-4222-8222-222222222222';

const _started =
    'Ada Lovelace accepted estimate EST-0007, project started, deposit '
    'invoice drafted';
const _drafted =
    'Grace Hopper accepted estimate EST-0008, deposit invoice drafted';
const _declined = 'Northwind declined estimate EST-0009';
const _accepted = 'A client accepted an estimate.';

Map<String, dynamic> _row(String id, String verb, Object? data, String link) =>
    {
      'id': id,
      'verb': verb,
      'actor': null,
      'data': data,
      'link': link,
      'read_at': null,
      'created_at': DateTime.now()
          .subtract(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
    };

class _FakeFeed extends NotificationsNotifier {
  @override
  Future<NotificationFeed> build() async {
    final items = [
      for (final json in [
        _row('n1', 'estimate.accepted', {
          'estimate_number': 'EST-0007',
          'client_name': 'Ada Lovelace',
          'project_id': _projectId,
          'deposit_invoice_id': _depositId,
        }, '/projects/$_projectId'),
        _row('n2', 'estimate.accepted', {
          'estimate_number': 'EST-0008',
          'client_name': 'Grace Hopper',
          'project_id': null,
          'deposit_invoice_id': _depositId,
        }, '/invoices/$_depositId'),
        _row('n3', 'estimate.declined', {
          'estimate_number': 'EST-0009',
          'client_name': 'Northwind',
        }, '/invoices/estimates'),
        _row('n4', 'estimate.accepted', 'not a map', '/invoices/estimates'),
      ])
        AppNotification.fromJson(json),
    ];
    return NotificationFeed(
      items: items,
      unreadCount: items.length,
      total: items.length,
    );
  }

  @override
  Future<ApiResponse<Map<String, dynamic>>> markRead(String id) async =>
      const ApiResponse(success: true, statusCode: 200);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, {double textScale = 1.0}) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [notificationsProvider.overrideWith(_FakeFeed.new)],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/here',
            routes: [
              GoRoute(
                path: '/here',
                builder: (_, _) => const NotificationsScreen(),
              ),
              GoRoute(
                path: '/projects/:id',
                builder: (_, s) => Text('project ${s.pathParameters['id']}'),
              ),
              GoRoute(
                path: '/invoices/estimates',
                builder: (_, _) => const Text('the estimates'),
              ),
              GoRoute(
                path: '/invoices/:id',
                builder: (_, s) => Text('invoice ${s.pathParameters['id']}'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rowOf(Finder text) =>
      find.ancestor(of: text, matching: find.byType(InkWell)).first;

  for (final scale in [1.0, 1.5]) {
    testWidgets('each answer fits at 390px, text x$scale', (tester) async {
      await pump(tester, textScale: scale);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('each row is the sentence, with no person beside it', (
    tester,
  ) async {
    await pump(tester);

    for (final text in [_started, _drafted, _declined, _accepted]) {
      expect(find.text(text), findsOneWidget, reason: text);
      expect(
        find.descendant(
          of: rowOf(find.text(text)),
          matching: find.text('The system'),
        ),
        findsNothing,
        reason: text,
      );
    }
    expect(find.textContaining('has no producer'), findsNothing);
  });

  testWidgets('an acceptance and a decline carry their own icons', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.descendant(
        of: rowOf(find.text(_started)),
        matching: find.byIcon(LucideIcons.fileCheck),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: rowOf(find.text(_declined)),
        matching: find.byIcon(LucideIcons.fileX),
      ),
      findsOneWidget,
    );
  });

  for (final (text, opened) in [
    (_started, 'project $_projectId'),
    (_drafted, 'invoice $_depositId'),
    (_declined, 'the estimates'),
  ]) {
    testWidgets('"$text" opens $opened', (tester) async {
      await pump(tester);

      await tester.tap(find.text(text));
      await tester.pumpAndSettle();

      expect(find.text(opened), findsOneWidget);
    });
  }
}

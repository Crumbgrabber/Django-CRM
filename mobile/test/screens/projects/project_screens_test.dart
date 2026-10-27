import 'dart:convert';

import 'package:bottle_crm/config/api_config.dart';
import 'package:bottle_crm/core/theme/theme.dart';
import 'package:bottle_crm/data/models/models.dart';
import 'package:bottle_crm/data/models/time_report.dart';
import 'package:bottle_crm/providers/deal_pipelines_provider.dart';
import 'package:bottle_crm/providers/deals_provider.dart';
import 'package:bottle_crm/providers/org_modules_provider.dart';
import 'package:bottle_crm/providers/tickets_provider.dart';
import 'package:bottle_crm/providers/time_report_provider.dart';
import 'package:bottle_crm/providers/timesheet_provider.dart';
import 'package:bottle_crm/screens/deals/deal_detail_screen.dart';
import 'package:bottle_crm/screens/projects/project_detail_screen.dart';
import 'package:bottle_crm/screens/projects/project_form_screen.dart';
import 'package:bottle_crm/screens/projects/projects_list_screen.dart';
import 'package:bottle_crm/screens/timesheet/time_report_screen.dart';
import 'package:bottle_crm/screens/timesheet/timesheet_screen.dart';
import 'package:bottle_crm/services/api_service.dart';
import 'package:bottle_crm/widgets/tickets/ticket_time_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/modules_fixtures.dart';

const _pid = '11111111-1111-4111-8111-111111111111';
const _dealId = '22222222-2222-4222-8222-222222222222';

String _path(String url) => Uri.parse(url).path;

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _project({
  bool canBill = false,
  bool canEdit = true,
  bool canDelete = false,
  String billingType = 'time_and_materials',
  String name = 'Website rebuild',
  String? budgetHours = '40.00',
  String? budgetAmount = '10000.00',
  String? startDate,
  String? dueDate,
  String? invoicedAmount = '2500.00',
}) => {
  'id': _pid,
  'name': name,
  'account': {'id': 'a1', 'name': 'Northwind'},
  'deal': null,
  'status': 'active',
  'billing_type': billingType,
  'currency': 'EUR',
  'budget_hours': budgetHours,
  'budget_amount': budgetAmount,
  'hourly_rate': '100.00',
  'start_date': startDate,
  'due_date': dueDate,
  'assigned_to': [
    {
      'id': 'pr1',
      'user_details': {'name': 'Ada Lovelace', 'email': 'ada@x.io'},
    },
  ],
  'tags': [],
  'burn': {
    'logged_hours': '34.00',
    'billable_hours': '30.00',
    'billable_value': '3000.00',
    'unbilled_value': '1200.00',
    'invoiced_amount': invoicedAmount,
    // Null without that budget, as the server sends it.
    'hours_percent': budgetHours == null ? null : 85,
    'amount_percent': budgetAmount == null ? null : 30,
  },
  'created_at': '2026-10-01T09:00:00Z',
  'updated_at': '2026-10-01T09:00:00Z',
  'description': '',
  'custom_fields': {},
  'rates': [],
  'comments': [],
  'attachments': [],
  'invoices': [
    {
      'id': 'inv-9',
      'invoice_number': 'INV-0009',
      'status': 'Draft',
      'total_amount': '2500.00',
      'currency': 'EUR',
      'issue_date': '2026-10-20',
    },
  ],
  'can_edit': canEdit,
  'can_delete': canDelete,
  'can_bill': canBill,
};

/// Answers by `METHOD /path` and keeps every request it saw.
class _Server {
  final requests = <http.Request>[];
  final routes = <String, http.Response Function(http.Request)>{};

  void install() => ApiService().setClientForTesting(
    MockClient((r) async {
      requests.add(r);
      return routes['${r.method} ${r.url.path}']?.call(r) ??
          http.Response('{}', 404);
    }),
  );

  List<http.Request> sent(String method, String url) => [
    for (final r in requests)
      if (r.method == method && r.url.path == _path(url)) r,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;

  setUp(() {
    server = _Server()..install();
    server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
        _json(_project());
    server.routes['GET ${_path(ApiConfig.projectTimeEntries(_pid))}'] = (_) =>
        _json([]);
    server.routes['GET ${_path(ApiConfig.tasks)}'] = (_) =>
        _json({'tasks': [], 'tasks_count': 0});
  });

  tearDown(() => ApiService().setClientForTesting(http.Client()));

  void usePhone(WidgetTester tester, {double textScale = 1.0}) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// [screen] pushed over a start page once the module answer is in, as the
  /// app has it before any screen opens.
  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    List<String> off = const [],
    bool admin = true,
    List<Override> overrides = const [],
  }) async {
    usePhone(tester);
    final router = GoRouter(
      initialLocation: '/start',
      routes: [
        GoRoute(path: '/start', builder: (_, _) => const Text('started')),
        GoRoute(path: '/here', builder: (_, _) => screen),
        GoRoute(
          path: '/invoices/:id',
          builder: (_, s) => Text('invoice ${s.pathParameters['id']}'),
        ),
        GoRoute(
          path: '/projects/new',
          builder: (_, s) =>
              Text('new project from ${s.uri.queryParameters['deal']}'),
        ),
        GoRoute(
          path: '/projects/:id',
          builder: (_, s) => Text('project ${s.pathParameters['id']}'),
        ),
        GoRoute(
          path: '/tasks/create',
          builder: (_, s) =>
              Text('new task on ${s.uri.queryParameters['project']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...modulesOverrides(
            FakeOrgModules(() async => modulesAnswer(off: off)),
            admin: admin,
          ),
          ...overrides,
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await ProviderScope.containerOf(
      tester.element(find.text('started')),
    ).read(orgModulesProvider.future);
    router.push('/here');
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    // The bar scrolls, so a later tab may start past the edge.
    await tester.ensureVisible(find.widgetWithText(Tab, label));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, label));
    await tester.pumpAndSettle();
  }

  group('the projects list', () {
    setUp(() {
      server.routes['GET ${_path(ApiConfig.projects)}'] = (_) => _json({
        'projects': [_project(), _project(name: 'Audit', budgetHours: null)],
        'count': 2,
      });
    });

    testWidgets('shows each project with its client, status and burn', (
      tester,
    ) async {
      await pump(tester, const ProjectsListScreen());

      expect(find.text('Website rebuild'), findsOneWidget);
      expect(find.text('Northwind'), findsNWidgets(2));
      expect(find.text('Active'), findsWidgets);
      // The hours budget is the one closest to running out.
      expect(find.text('34h of 40h'), findsOneWidget);
      expect(find.text('85%'), findsOneWidget);
      // Without an hours budget the row shows the amount one.
      expect(find.textContaining('of €10,000.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a status chip asks the API for that status', (tester) async {
      await pump(tester, const ProjectsListScreen());

      await tester.tap(find.text('On hold'));
      await tester.pumpAndSettle();

      final last = server.sent('GET', ApiConfig.projects).last;
      expect(last.url.queryParameters['status'], 'on_hold');
      expect(last.url.queryParameters['limit'], '50');
    });

    testWidgets('a row opens its project', (tester) async {
      await pump(tester, const ProjectsListScreen());

      await tester.tap(find.text('Website rebuild'));
      await tester.pumpAndSettle();

      expect(find.text('project $_pid'), findsOneWidget);
    });
  });

  group('the project page', () {
    void serve(Map<String, dynamic> project) =>
        server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
            _json(project);

    testWidgets('shows the sections the web does, for the modules that are '
        'on', (tester) async {
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      for (final tab in ['Overview', 'Tasks', 'Time', 'Invoices']) {
        expect(find.widgetWithText(Tab, tab), findsOneWidget, reason: tab);
      }
      expect(find.text('Northwind'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Not yet billed: €1,200.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('names the estimate that started it, as text', (tester) async {
      serve({
        ..._project(),
        'estimate': {'id': 'e7', 'estimate_number': 'EST-0007'},
      });
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('FROM ESTIMATE'), findsOneWidget);
      expect(find.text('EST-0007'), findsOneWidget);
      await tester.tap(find.text('EST-0007'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectDetailScreen), findsOneWidget);
    });

    testWidgets('a project no estimate started says nothing of one', (
      tester,
    ) async {
      serve({..._project(), 'estimate': null});
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('FROM ESTIMATE'), findsNothing);
    });

    testWidgets('a module that is off takes its section with it', (
      tester,
    ) async {
      await pump(
        tester,
        const ProjectDetailScreen(projectId: _pid),
        off: ['tasks', 'timesheet', 'invoices'],
      );

      expect(find.widgetWithText(Tab, 'Overview'), findsOneWidget);
      for (final tab in ['Tasks', 'Time', 'Invoices']) {
        expect(find.widgetWithText(Tab, tab), findsNothing, reason: tab);
      }
    });

    testWidgets('without can_bill there is no billing action anywhere', (
      tester,
    ) async {
      serve(_project(billingType: 'fixed_fee'));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('Bill time'), findsNothing);
      expect(find.text('Invoice an amount'), findsNothing);
      await openTab(tester, 'Invoices');
      expect(find.text('Bill time'), findsNothing);
      expect(find.text('INV-0009'), findsOneWidget);
    });

    testWidgets('can_bill on time and materials offers Bill time only', (
      tester,
    ) async {
      serve(_project(canBill: true));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('Bill time'), findsOneWidget);
      expect(find.text('Invoice an amount'), findsNothing);
    });

    testWidgets('can_bill on a fixed fee offers both', (tester) async {
      serve(_project(canBill: true, billingType: 'fixed_fee'));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('Bill time'), findsOneWidget);
      expect(find.text('Invoice an amount'), findsOneWidget);
      expect(
        find.text('Invoiced €2,500.00 of the €10,000.00 fee'),
        findsOneWidget,
      );
    });

    testWidgets('with Invoices off, can_bill offers nothing', (tester) async {
      serve(_project(canBill: true, billingType: 'fixed_fee'));
      await pump(
        tester,
        const ProjectDetailScreen(projectId: _pid),
        off: ['invoices'],
      );

      expect(find.text('Bill time'), findsNothing);
      expect(find.text('Invoice an amount'), findsNothing);
    });

    testWidgets(
      'Bill time previews to the date, groups, then opens the draft',
      (tester) async {
        serve(_project(canBill: true));
        server.routes['GET ${_path(ApiConfig.projectUnbilled(_pid, 'x'))}'] =
            (_) => _json({
              'entry_count': 3,
              'hours': '4.50',
              'value': '450.00',
              'currency': 'EUR',
            });
        server.routes['POST ${_path(ApiConfig.invoiceFromTimeEntries)}'] =
            (_) => _json({
              'error': false,
              'invoice_id': 'inv-new',
              'invoice_number': 'INV-0010',
              'project_id': _pid,
            }, 201);
        await pump(tester, const ProjectDetailScreen(projectId: _pid));

        await tester.tap(find.text('Bill time'));
        await tester.pumpAndSettle();
        expect(find.text('3 entries, 4.5h, worth €450.00'), findsOneWidget);
        expect(
          server
              .sent('GET', ApiConfig.projectUnbilled(_pid, 'x'))
              .single
              .url
              .queryParameters['up_to'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
        );

        await tester.tap(find.text('One line per person'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create draft invoice'));
        await tester.pumpAndSettle();

        final body =
            jsonDecode(
                  server
                      .sent('POST', ApiConfig.invoiceFromTimeEntries)
                      .single
                      .body,
                )
                as Map<String, dynamic>;
        expect(body['project_id'], _pid);
        expect(body['group_by'], 'person');
        expect(body['up_to'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(body.containsKey('account_id'), isFalse);
        expect(body.containsKey('entry_ids'), isFalse);
        expect(find.text('invoice inv-new'), findsOneWidget);
      },
    );

    testWidgets('nothing unbilled leaves nothing to bill', (tester) async {
      serve(_project(canBill: true));
      server.routes['GET ${_path(ApiConfig.projectUnbilled(_pid, 'x'))}'] =
          (_) => _json({
            'entry_count': 0,
            'hours': '0.00',
            'value': '0.00',
            'currency': 'EUR',
          });
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Bill time'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing unbilled up to this date.'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create draft invoice'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('Invoice an amount checks the percent, then sends one value', (
      tester,
    ) async {
      serve(_project(canBill: true, billingType: 'fixed_fee'));
      server.routes['POST ${_path(ApiConfig.projectInvoiceAmount(_pid))}'] =
          (_) => _json({
            'invoice_id': 'inv-fee',
            'invoice_number': 'INV-0011',
          }, 201);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Invoice an amount'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Percent of fee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '120');
      await tester.pumpAndSettle();
      expect(find.text('A percent is at most 100.'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '25');
      await tester.pumpAndSettle();
      expect(find.text('€2,500.00 of the €10,000.00 fee'), findsOneWidget);
      await tester.tap(find.text('Create draft invoice'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(
                server
                    .sent('POST', ApiConfig.projectInvoiceAmount(_pid))
                    .single
                    .body,
              )
              as Map<String, dynamic>;
      expect(body, {'percent': '25'});
      expect(find.text('invoice inv-fee'), findsOneWidget);
    });

    testWidgets('a member who may not edit gets no Edit and no time logging', (
      tester,
    ) async {
      serve(_project(canEdit: false));
      await pump(
        tester,
        const ProjectDetailScreen(projectId: _pid),
        admin: false,
      );

      expect(find.byTooltip('Edit project'), findsNothing);
      expect(find.byTooltip('Delete project'), findsNothing);
      await openTab(tester, 'Time');
      expect(find.text('Start timer'), findsNothing);
      expect(find.text('Log time'), findsNothing);
    });

    testWidgets('the time tab lists entries with their task, and a project '
        'entry starts its timer here', (tester) async {
      server.routes['GET ${_path(ApiConfig.tasks)}'] = (_) => _json({
        'tasks': [
          {
            'id': 't1',
            'title': 'Design the homepage',
            'status': 'In Progress',
            'priority': 'Medium',
            'project': _pid,
          },
        ],
      });
      server.routes['GET ${_path(ApiConfig.projectTimeEntries(_pid))}'] = (_) =>
          _json([
            {
              'id': 'e1',
              'case': null,
              'project': _pid,
              'project_name': 'Website rebuild',
              'task': 't1',
              'profile': {
                'id': 'pr1',
                'user_details': {'email': 'ada@x.io'},
              },
              'started_at': '2026-10-20T09:00:00Z',
              'ended_at': '2026-10-20T11:00:00Z',
              'duration_minutes': 120,
              'billable': true,
              'description': 'Wireframes',
            },
          ]);
      server.routes['POST ${_path(ApiConfig.projectTimerStart(_pid))}'] = (_) =>
          _json({'id': 'e2'}, 201);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await openTab(tester, 'Time');
      expect(find.text('Wireframes'), findsOneWidget);
      expect(find.text('ada@x.io · Design the homepage'), findsOneWidget);

      await tester.tap(find.text('Start timer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Design the homepage').last);
      await tester.pumpAndSettle();
      final body =
          jsonDecode(
                server
                    .sent('POST', ApiConfig.projectTimerStart(_pid))
                    .single
                    .body,
              )
              as Map<String, dynamic>;
      expect(body['task'], 't1');
    });

    testWidgets('New task opens the task form on this project', (tester) async {
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await openTab(tester, 'Tasks');
      expect(find.text('No tasks on this project yet.'), findsOneWidget);
      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();

      expect(find.text('new task on $_pid'), findsOneWidget);
    });

    testWidgets(
      'a non-billable project offers no Bill time, even to an admin',
      (tester) async {
        serve({..._project(canBill: true), 'billing_type': 'non_billable'});
        await pump(tester, const ProjectDetailScreen(projectId: _pid));

        expect(find.text('Bill time'), findsNothing);
        await openTab(tester, 'Time');
        expect(find.text('Bill time'), findsNothing);
        await openTab(tester, 'Invoices');
        expect(find.text('Bill time'), findsNothing);
      },
    );

    testWidgets('a failed preview still lets the time be billed, and says so', (
      tester,
    ) async {
      serve(_project(canBill: true));
      server.routes['GET ${_path(ApiConfig.projectUnbilled(_pid, 'x'))}'] =
          (_) => _json({'error': true}, 500);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Bill time'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The preview could not be loaded. The invoice still takes every '
          'billable entry not yet billed up to this date.',
        ),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create draft invoice'),
      );
      expect(button.onPressed, isNotNull);
    });

    for (final (count, sentence) in [
      (1, '1 entry has no rate and will be billed at 0.'),
      (2, '2 of these entries have no rate and will be billed at 0.'),
    ]) {
      testWidgets('$count unrated entries are called out before billing', (
        tester,
      ) async {
        serve(_project(canBill: true));
        server.routes['GET ${_path(ApiConfig.projectUnbilled(_pid, 'x'))}'] =
            (_) => _json({
              'entry_count': 3,
              'hours': '4.50',
              'value': '300.00',
              'currency': 'EUR',
              'unrated_count': count,
            });
        await pump(tester, const ProjectDetailScreen(projectId: _pid));

        await tester.tap(find.text('Bill time'));
        await tester.pumpAndSettle();

        expect(find.text(sentence), findsOneWidget);
      });
    }

    testWidgets('with no invoiced amount there is no invoiced line', (
      tester,
    ) async {
      serve(_project(billingType: 'fixed_fee', invoicedAmount: null));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.textContaining('Invoiced'), findsNothing);
      await openTab(tester, 'Invoices');
      expect(find.textContaining('Invoiced'), findsNothing);
      expect(find.text('INV-0009'), findsOneWidget);
    });

    for (final (type, billable) in [
      ('time_and_materials', true),
      ('non_billable', false),
    ]) {
      testWidgets('the timer starts billable only on a billable project '
          '($type)', (tester) async {
        serve({..._project(), 'billing_type': type});
        server.routes['POST ${_path(ApiConfig.projectTimerStart(_pid))}'] =
            (_) => _json({'id': 'e2'}, 201);
        await pump(tester, const ProjectDetailScreen(projectId: _pid));

        await openTab(tester, 'Time');
        await tester.tap(find.text('Start timer'));
        await tester.pumpAndSettle();

        final body =
            jsonDecode(
                  server
                      .sent('POST', ApiConfig.projectTimerStart(_pid))
                      .single
                      .body,
                )
                as Map<String, dynamic>;
        expect(body['billable'], billable);
      });
    }

    testWidgets('Invoice an amount sends two places and refuses odd numbers', (
      tester,
    ) async {
      serve(_project(canBill: true, billingType: 'fixed_fee'));
      server.routes['POST ${_path(ApiConfig.projectInvoiceAmount(_pid))}'] =
          (_) => _json({'invoice_id': 'inv-fee'}, 201);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Invoice an amount'));
      await tester.pumpAndSettle();
      for (final odd in ['1e3', 'NaN', 'Infinity', '-5']) {
        await tester.enterText(find.byType(TextField).first, odd);
        await tester.pumpAndSettle();
        expect(find.text('Enter a number.'), findsOneWidget, reason: odd);
      }
      await tester.enterText(find.byType(TextField).first, '1200.5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create draft invoice'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(
                server
                    .sent('POST', ApiConfig.projectInvoiceAmount(_pid))
                    .single
                    .body,
              )
              as Map<String, dynamic>;
      expect(body, {'amount': '1200.50'});
    });

    testWidgets('a project that answers 404 says not found', (tester) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json({'error': true}, 404);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('Project not found'), findsOneWidget);
    });
  });

  group('the project form', () {
    setUp(() {
      server.routes['GET ${_path(ApiConfig.accounts)}'] = (_) => _json({
        'active_accounts': {
          'open_accounts': [
            {'id': 'a1', 'name': 'Northwind'},
          ],
        },
      });
      server.routes['GET ${_path(ApiConfig.teamsAndUsers)}'] = (_) => _json({
        'profiles': [
          {
            'id': 'pr1',
            'user_details': {'name': 'Ada Lovelace', 'email': 'ada@x.io'},
          },
        ],
      });
    });

    testWidgets('refuses a save with no name and no account, beside them', (
      tester,
    ) async {
      await pump(tester, const ProjectFormScreen());

      await tester.tap(find.text('Create project'));
      await tester.pumpAndSettle();

      expect(find.text('A project needs a name.'), findsOneWidget);
      expect(find.text('Pick the client account.'), findsOneWidget);
      expect(server.sent('POST', ApiConfig.projects), isEmpty);
    });

    testWidgets('a due date before the start is refused before sending', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(_project(startDate: '2026-10-10', dueDate: '2026-10-01'));
      await pump(tester, const ProjectFormScreen(projectId: _pid));

      expect(
        find.text('The due date cannot be before the start date.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();
      expect(server.sent('PATCH', ApiConfig.project(_pid)), isEmpty);
    });

    testWidgets('a negative budget is called out on its field', (tester) async {
      await pump(tester, const ProjectFormScreen());

      await tester.enterText(
        find.widgetWithText(TextField, 'Budget hours'),
        '-4',
      );
      await tester.pumpAndSettle();

      expect(find.text('Enter 0 or more.'), findsOneWidget);
    });

    testWidgets('editing sends the whole form as a PATCH and comes back', (
      tester,
    ) async {
      server.routes['PATCH ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(_project());
      server.routes['GET ${_path(ApiConfig.projects)}'] = (_) =>
          _json({'projects': [], 'count': 0});
      await pump(tester, const ProjectFormScreen(projectId: _pid));

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Website rebuild, phase 2',
      );
      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body['name'], 'Website rebuild, phase 2');
      expect(body['account'], 'a1');
      expect(body['budget_hours'], '40.00');
      expect(body['currency'], 'EUR');
      expect(body['rates'], isEmpty);
      expect(find.text('started'), findsOneWidget);
    });

    testWidgets('Start a project fills the form from the deal\'s draft', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.projectFromDeal(_dealId))}'] = (_) =>
          _json({
            'name': 'Harbour Road rebuild',
            // The shapes the backend sends.
            'account': {'id': 'a1', 'name': 'Northwind'},
            'deal': {'id': _dealId, 'name': 'Harbour Road rebuild'},
            'currency': 'EUR',
            'assigned_to': ['pr1'],
            'billing_type': 'fixed_fee',
            'budget_amount': '12000.00',
          });
      await pump(tester, const ProjectFormScreen(fromDealId: _dealId));

      // The name field and the deal it came from, by the draft's names.
      expect(
        find.widgetWithText(TextField, 'Harbour Road rebuild'),
        findsOneWidget,
      );
      expect(find.text('Harbour Road rebuild'), findsNWidgets(2));
      expect(find.text('Northwind'), findsOneWidget);
      expect(find.text('Fixed fee'), findsOneWidget);
      expect(find.text('12000.00'), findsOneWidget);
      for (
        var i = 0;
        i < 6 && find.text('Ada Lovelace').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(find.text('Ada Lovelace'), findsOneWidget);
      // Nothing is created until the form is saved.
      expect(server.sent('POST', ApiConfig.projects), isEmpty);
    });

    testWidgets('with Deals off an edit leaves the deal link alone', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) => _json({
        ..._project(),
        'deal': {'id': _dealId, 'name': 'Harbour Road rebuild'},
      });
      server.routes['PATCH ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(_project());
      await pump(
        tester,
        const ProjectFormScreen(projectId: _pid),
        off: ['deals'],
      );

      expect(find.text('Deal (optional)'), findsNothing);
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body.containsKey('deal'), isFalse);
      expect(body['name'], 'Website rebuild');
    });

    testWidgets('a member edits without the money fields or the account', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) => _json({
        ..._project(),
        'rates': [
          {
            'profile': {
              'id': 'pr1',
              'user_details': {'name': 'Ada Lovelace'},
            },
            'hourly_rate': '150.00',
          },
        ],
      });
      server.routes['PATCH ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(_project());
      await pump(
        tester,
        const ProjectFormScreen(projectId: _pid),
        admin: false,
      );

      // Shown, and not offered for change.
      expect(find.text('Northwind'), findsOneWidget);
      expect(
        find.widgetWithText(DropdownButtonFormField<String>, 'Account'),
        findsNothing,
      );
      expect(find.text('Only an admin can change these.'), findsOneWidget);
      expect(find.text('Budget hours'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Budget hours'), findsNothing);
      for (
        var i = 0;
        i < 6 && find.text('Add a rate').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(find.text('Add a rate'), findsNothing);

      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();
      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      for (final key in [
        'account',
        'billing_type',
        'currency',
        'budget_hours',
        'budget_amount',
        'hourly_rate',
        'rates',
      ]) {
        expect(body.containsKey(key), isFalse, reason: key);
      }
      expect(body['name'], 'Website rebuild');
    });

    testWidgets('a member\'s new project picks an account and no money', (
      tester,
    ) async {
      await pump(tester, const ProjectFormScreen(), admin: false);

      expect(
        find.widgetWithText(DropdownButtonFormField<String>, 'Account'),
        findsOneWidget,
      );
      expect(find.text('Billing type'), findsNothing);
      expect(find.text('Budget hours'), findsNothing);
      expect(find.text('Only an admin can change these.'), findsNothing);
    });

    testWidgets('a refused currency change shows the server\'s words', (
      tester,
    ) async {
      server.routes['PATCH ${_path(ApiConfig.project(_pid))}'] = (_) => _json({
        'error': true,
        'errors': {
          'currency': [
            'The currency cannot change once the project has time or invoices.',
          ],
        },
      }, 400);
      await pump(tester, const ProjectFormScreen(projectId: _pid));

      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'The currency cannot change once the project has time or invoices.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a deal the caller cannot see says so', (tester) async {
      server.routes['GET ${_path(ApiConfig.projectFromDeal(_dealId))}'] = (_) =>
          _json({'error': true}, 404);
      await pump(tester, const ProjectFormScreen(fromDealId: _dealId));

      expect(find.text('That deal could not be found.'), findsOneWidget);
    });
  });

  group('a retainer project', () {
    Map<String, dynamic> retainer({
      bool canBill = true,
      bool billableNow = true,
      String? available = '10.00',
      String over = '0.00',
      String? lastMonth,
      String carried = '0.00',
    }) => {
      ..._project(canBill: canBill, billingType: 'retainer'),
      'retainer_fee': '2000.00',
      'retainer_hours': available,
      'retainer_rollover': true,
      'retainer_overage_rate': '150.00',
      'retainer_carried_hours': carried,
      'retainer_next_month': '2026-10-01',
      'retainer_last_month': lastMonth,
      'retainer_usage': {
        'month': '2026-10',
        'used_hours': '12.50',
        'available_hours': available,
        'overage_hours': over,
        'billable_now': billableNow,
      },
    };

    void serve(Map<String, dynamic> project) =>
        server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
            _json(project);

    testWidgets('shows the fee, the month so far, the overage and carry', (
      tester,
    ) async {
      serve(retainer(over: '2.50', carried: '1.50'));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('RETAINER'), findsOneWidget);
      expect(find.text('\u20ac2,000.00 a month'), findsOneWidget);
      expect(
        find.text('12.5 of 10 hours used in October 2026'),
        findsOneWidget,
      );
      expect(
        find.text('2.5 hours over the allowance so far, \u20ac375.00'),
        findsOneWidget,
      );
      expect(
        find.text('1.5 hours carried in from earlier months'),
        findsOneWidget,
      );
      expect(find.textContaining('Ended after'), findsNothing);
    });

    testWidgets('says 1 hour in the singular, and a missing fee', (
      tester,
    ) async {
      serve({
        ...retainer(available: null, over: '1.00', carried: '1.00'),
        'retainer_fee': null,
        'retainer_usage': {
          'month': '2026-10',
          'used_hours': '1.00',
          'available_hours': null,
          'overage_hours': '1.00',
          'billable_now': false,
        },
      });
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('No monthly fee set'), findsOneWidget);
      expect(find.text('1 hour in October 2026'), findsOneWidget);
      expect(
        find.text('1 hour over the allowance so far, \u20ac150.00'),
        findsOneWidget,
      );
      expect(
        find.text('1 hour carried in from earlier months'),
        findsOneWidget,
      );
    });

    testWidgets('leaves the amount off an overage with no rate', (
      tester,
    ) async {
      serve({...retainer(over: '2.00'), 'retainer_overage_rate': null});
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('2 hours over the allowance so far'), findsOneWidget);
    });

    testWidgets('without an allowance it says hours in the month', (
      tester,
    ) async {
      serve(retainer(available: null));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('12.5 hours in October 2026'), findsOneWidget);
    });

    testWidgets('an ended retainer says so', (tester) async {
      serve(retainer(lastMonth: '2026-09-01'));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      expect(find.text('Ended after September 2026'), findsOneWidget);
    });

    testWidgets(
      'an admin bills the month after a confirm and opens the draft',
      (tester) async {
        serve(retainer());
        server.routes['POST ${_path(ApiConfig.projectRetainerBill(_pid))}'] =
            (_) => _json({
              'invoice_id': 'inv-ret',
              'invoice_number': 'INV-0012',
              'month': '2026-10',
            }, 201);
        await pump(tester, const ProjectDetailScreen(projectId: _pid));

        expect(find.text('Bill time'), findsNothing);
        await tester.tap(find.text('Bill October 2026'));
        await tester.pumpAndSettle();
        expect(find.text('Bill October 2026?'), findsOneWidget);
        expect(
          server.sent('POST', ApiConfig.projectRetainerBill(_pid)),
          isEmpty,
        );

        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Bill October 2026'),
          ),
        );
        await tester.pumpAndSettle();

        final sent = server.sent('POST', ApiConfig.projectRetainerBill(_pid));
        expect(sent, hasLength(1));
        expect(jsonDecode(sent.single.body), {'month': '2026-10'});
        expect(find.text('invoice inv-ret'), findsOneWidget);
      },
    );

    testWidgets('Cancel bills nothing', (tester) async {
      serve(retainer());
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Bill October 2026'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(server.sent('POST', ApiConfig.projectRetainerBill(_pid)), isEmpty);
    });

    testWidgets('a refusal shows its message and opens nothing', (
      tester,
    ) async {
      serve(retainer());
      server.routes['POST ${_path(ApiConfig.projectRetainerBill(_pid))}'] =
          (_) => _json({
            'error': true,
            'message': 'This month is already billed.',
          }, 400);
      await pump(tester, const ProjectDetailScreen(projectId: _pid));

      await tester.tap(find.text('Bill October 2026'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Bill October 2026'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('This month is already billed.'), findsOneWidget);
      expect(find.textContaining('invoice inv'), findsNothing);
    });

    testWidgets('no button when nothing is billable', (tester) async {
      serve(retainer(billableNow: false));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));
      expect(find.textContaining('Bill October'), findsNothing);
      expect(find.text('RETAINER'), findsOneWidget);
    });

    testWidgets('no button for a member', (tester) async {
      serve(retainer(canBill: false));
      await pump(tester, const ProjectDetailScreen(projectId: _pid));
      expect(find.textContaining('Bill October'), findsNothing);
    });

    testWidgets('no button with Invoices off', (tester) async {
      serve(retainer());
      await pump(
        tester,
        const ProjectDetailScreen(projectId: _pid),
        off: ['invoices'],
      );
      expect(find.textContaining('Bill October'), findsNothing);
    });

    testWidgets('the Time tab offers no Bill time on a retainer', (
      tester,
    ) async {
      serve(retainer());
      await pump(tester, const ProjectDetailScreen(projectId: _pid));
      await openTab(tester, 'Time');

      expect(find.text('Bill time'), findsNothing);
    });
  });

  group('the retainer fields on the form', () {
    setUp(() {
      server.routes['GET ${_path(ApiConfig.accounts)}'] = (_) => _json({
        'active_accounts': {
          'open_accounts': [
            {'id': 'a1', 'name': 'Northwind'},
          ],
        },
      });
      server.routes['GET ${_path(ApiConfig.teamsAndUsers)}'] = (_) =>
          _json({'profiles': []});
      server.routes['PATCH ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(_project());
      server.routes['GET ${_path(ApiConfig.projects)}'] = (_) =>
          _json({'projects': [], 'count': 0});
    });

    Map<String, dynamic> existing({String billingType = 'retainer'}) => {
      ..._project(billingType: billingType),
      'retainer_fee': '2000.00',
      'retainer_hours': '10.00',
      'retainer_rollover': true,
      'retainer_overage_rate': '150.00',
      'retainer_carried_hours': '1.50',
      'retainer_next_month': '2026-10-01',
      'retainer_last_month': null,
    };

    testWidgets('an admin sees them only while Retainer is chosen', (
      tester,
    ) async {
      await pump(tester, const ProjectFormScreen());
      expect(find.text('Monthly fee'), findsNothing);

      await tester.ensureVisible(find.text('Billing type'));
      await tester.tap(find.text('Time and materials'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retainer').last);
      await tester.pumpAndSettle();

      expect(find.text('Monthly fee'), findsOneWidget);
      expect(find.text('Hours included each month'), findsOneWidget);
      expect(find.text('Roll unused hours over'), findsOneWidget);
      expect(find.text('Rate for hours over the allowance'), findsOneWidget);
      expect(find.text('Carried hours'), findsNothing);
    });

    testWidgets('the fee and, with hours, the rate are required', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) => _json({
        ...existing(),
        'retainer_fee': null,
        'retainer_overage_rate': null,
      });
      await pump(tester, const ProjectFormScreen(projectId: _pid));

      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      expect(find.text('Set the monthly fee.'), findsOneWidget);
      expect(
        find.text('Set the rate for hours over the allowance.'),
        findsOneWidget,
      );
      expect(server.sent('PATCH', ApiConfig.project(_pid)), isEmpty);
    });

    testWidgets('an edit sends every retainer value, rollover explicit', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(existing());
      await pump(tester, const ProjectFormScreen(projectId: _pid));
      expect(find.text('Carried hours'), findsOneWidget);

      await tester.ensureVisible(find.byType(Switch).first);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body['billing_type'], 'retainer');
      expect(body['retainer_fee'], '2000.00');
      expect(body['retainer_hours'], '10.00');
      expect(body['retainer_rollover'], false);
      expect(body['retainer_overage_rate'], '150.00');
      expect(body.containsKey('retainer_carried_hours'), isFalse);
    });

    testWidgets('a carried figure the admin changed is sent', (tester) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(existing());
      await pump(tester, const ProjectFormScreen(projectId: _pid));

      await tester.enterText(
        find.widgetWithText(TextField, 'Carried hours'),
        '0',
      );
      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body['retainer_carried_hours'], '0.00');
    });

    testWidgets('another billing type sends no retainer value', (tester) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(existing(billingType: 'fixed_fee'));
      await pump(tester, const ProjectFormScreen(projectId: _pid));
      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body.keys.where((k) => k.startsWith('retainer_')), isEmpty);
    });

    testWidgets('a member sees the values and cannot change them or status', (
      tester,
    ) async {
      server.routes['GET ${_path(ApiConfig.project(_pid))}'] = (_) =>
          _json(existing());
      await pump(
        tester,
        const ProjectFormScreen(projectId: _pid),
        admin: false,
      );

      expect(find.text('Monthly fee'), findsOneWidget);
      expect(
        find.byType(TextField).evaluate().any((e) {
          final f = e.widget as TextField;
          return f.decoration?.labelText == 'Monthly fee';
        }),
        isFalse,
      );
      await tester.ensureVisible(find.text('Save project'));
      await tester.tap(find.text('Save project'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(server.sent('PATCH', ApiConfig.project(_pid)).single.body)
              as Map<String, dynamic>;
      expect(body.keys.where((k) => k.startsWith('retainer_')), isEmpty);
      expect(body.containsKey('status'), isFalse);
      expect(body.containsKey('billing_type'), isFalse);
    });
  });

  group('a won deal', () {
    Deal deal(String kind) => Deal.fromJson({
      'id': _dealId,
      'name': 'Harbour Road rebuild',
      'stage': kind == 'won' ? 'WON' : 'TALKING',
      'stage_label': kind == 'won' ? 'Won' : 'Talking',
      'stage_kind': kind,
      'amount': '12000',
      'currency': 'EUR',
      'account': {'id': 'a1', 'name': 'Northwind'},
      'created_at': '2026-09-01T00:00:00Z',
    });

    List<Override> dealOverrides(Deal d) => [
      dealsProvider.overrideWith(() => _FakeDeals(d)),
      dealPipelinesProvider.overrideWith(_FakePipelines.new),
    ];

    testWidgets('offers Start a project, which opens the form from it', (
      tester,
    ) async {
      await pump(
        tester,
        const DealDetailScreen(dealId: _dealId),
        overrides: dealOverrides(deal('won')),
      );

      await tester.tap(find.text('Start a project'));
      await tester.pumpAndSettle();

      expect(find.text('new project from $_dealId'), findsOneWidget);
    });

    testWidgets('does not offer it with Projects off, nor on an open deal', (
      tester,
    ) async {
      await pump(
        tester,
        const DealDetailScreen(dealId: _dealId),
        off: ['projects'],
        overrides: dealOverrides(deal('won')),
      );
      expect(find.text('Start a project'), findsNothing);

      await pump(
        tester,
        const DealDetailScreen(dealId: _dealId),
        overrides: dealOverrides(deal('open')),
      );
      expect(find.text('Start a project'), findsNothing);
    });
  });

  group('the ticket time panel', () {
    TimeEntry entry(String id, {String? invoice, bool billable = true}) =>
        TimeEntry.fromJson({
          'id': id,
          'case': 'k1',
          'profile': 'pr1',
          'started_at': '2026-10-20T09:00:00Z',
          'ended_at': '2026-10-20T10:00:00Z',
          'duration_minutes': 60,
          'billable': billable,
          'hourly_rate': '100.00',
          'currency': 'EUR',
          'invoice': invoice,
          'description': 'Fixed the printer $id',
        });

    Widget panel({String? accountId = 'a1'}) => Scaffold(
      body: SingleChildScrollView(
        child: TicketTimePanel(
          ticketId: 'k1',
          canLogTime: true,
          accountId: accountId,
        ),
      ),
    );

    List<Override> tickets() => [
      ticketsProvider.overrideWith(
        () => _FakeTickets([
          entry('e1'),
          entry('e2'),
          entry('e3', invoice: 'i1'),
          entry('e4', billable: false),
        ]),
      ),
    ];

    testWidgets('an admin bills the unbilled entries for the account', (
      tester,
    ) async {
      server.routes['POST ${_path(ApiConfig.invoiceFromTimeEntries)}'] = (_) =>
          _json({'error': false, 'invoice_id': 'inv-t'}, 201);
      await pump(tester, panel(), overrides: tickets());

      await tester.tap(find.text('Bill time (2 entries)'));
      await tester.pumpAndSettle();
      expect(find.text('2 entries, 2h, worth about €200.00'), findsOneWidget);
      // A ticket's entries have no task, so that grouping is not offered.
      expect(find.text('One line per task'), findsNothing);
      await tester.tap(find.text('One line for everything'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create draft invoice'));
      await tester.pumpAndSettle();

      final body =
          jsonDecode(
                server
                    .sent('POST', ApiConfig.invoiceFromTimeEntries)
                    .single
                    .body,
              )
              as Map<String, dynamic>;
      expect(body, {
        'account_id': 'a1',
        'entry_ids': ['e1', 'e2'],
        'group_by': 'single',
      });
      expect(find.text('invoice inv-t'), findsOneWidget);
    });

    testWidgets('a member is not offered Bill time', (tester) async {
      await pump(tester, panel(), admin: false, overrides: tickets());

      expect(find.textContaining('Bill time'), findsNothing);
    });

    testWidgets('a ticket with no account says why it cannot be billed', (
      tester,
    ) async {
      await pump(tester, panel(accountId: null), overrides: tickets());

      expect(find.textContaining('Bill time'), findsNothing);
      expect(
        find.text('Link this ticket to an account to bill its time.'),
        findsOneWidget,
      );
    });
  });

  group('the time report', () {
    testWidgets('groups by project, and shows each agent\'s billable share', (
      tester,
    ) async {
      final report = _FakeReport();
      await pump(
        tester,
        const TimeReportScreen(),
        overrides: [timeReportProvider.overrideWith(() => report)],
      );

      expect(find.text('63% billable share'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Project'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Project'));
      await tester.pumpAndSettle();
      expect(report.groupedBy, 'project');
    });

    testWidgets('offers no project grouping with Projects off', (tester) async {
      await pump(
        tester,
        const TimeReportScreen(),
        off: ['projects'],
        overrides: [timeReportProvider.overrideWith(_FakeReport.new)],
      );

      expect(find.widgetWithText(ChoiceChip, 'Project'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Account'), findsOneWidget);
    });
  });

  testWidgets('the timesheet names a project entry and shows one with no '
      'parent without a link', (tester) async {
    await pump(
      tester,
      const TimesheetScreen(),
      overrides: [timesheetProvider.overrideWith(_FakeTimesheet.new)],
    );

    expect(find.text('Website rebuild'), findsOneWidget);
    expect(find.text('No ticket or project'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('No ticket or project'));
    await tester.pumpAndSettle();
    expect(find.text('No ticket or project'), findsOneWidget);

    await tester.tap(find.text('Website rebuild'));
    await tester.pumpAndSettle();
    expect(find.text('project $_pid'), findsOneWidget);
  });
}

class _FakeDeals extends DealsNotifier {
  _FakeDeals(this.deal);

  final Deal deal;

  @override
  Future<DealsListData> build() async => const DealsListData();

  @override
  Future<DealDetail?> getDealDetail(
    String id, {
    void Function()? onNotFound,
  }) async => DealDetail(deal: deal);
}

class _FakePipelines extends DealPipelinesNotifier {
  @override
  Future<List<DealPipeline>> build() async => const [];
}

class _FakeTickets extends TicketsNotifier {
  _FakeTickets(this.entries);

  final List<TimeEntry> entries;

  @override
  Future<TicketsListData> build() async =>
      TicketsListData(tickets: const [], totalCount: 0, hasMore: false);

  @override
  Future<List<TimeEntry>> fetchTimeEntries(String id) async => entries;

  @override
  Future<TimeSummary?> fetchTimeSummary(String id) async =>
      const TimeSummary(totalMinutes: 240, billableMinutes: 180);
}

class _FakeReport extends TimeReportNotifier {
  String? groupedBy;

  @override
  Future<TimeReport> build() async {
    final filters = ref.watch(timeReportFiltersProvider);
    groupedBy = filters.groupBy;
    return TimeReport(
      start: DateTime(2026, 10, 1),
      end: DateTime(2026, 10, 30),
      groupBy: filters.groupBy,
      rows: const [
        TimeReportRow(
          key: 'pr1',
          name: 'Ada Lovelace',
          totalMinutes: 600,
          billableMinutes: 378,
          entryCount: 12,
          billableShare: 0.63,
        ),
      ],
      totalMinutes: 600,
      billableMinutes: 378,
      entryCount: 12,
    );
  }
}

class _FakeTimesheet extends TimesheetNotifier {
  @override
  Future<TimesheetWeek> build() async => TimesheetWeek(
    start: DateTime(2026, 10, 19),
    end: DateTime(2026, 10, 25),
    profileName: 'Ada',
    days: [
      TimesheetDay(
        date: DateTime(2026, 10, 19),
        entries: [
          TimeEntry.fromJson({
            'id': 'e1',
            'case': null,
            'project': _pid,
            'project_name': 'Website rebuild',
            'profile': 'pr1',
            'started_at': '2026-10-19T09:00:00Z',
            'ended_at': '2026-10-19T10:00:00Z',
            'duration_minutes': 60,
            'billable': true,
          }),
          TimeEntry.fromJson({
            'id': 'e2',
            'case': null,
            'project': null,
            'project_name': null,
            'profile': 'pr1',
            'started_at': '2026-10-19T11:00:00Z',
            'ended_at': '2026-10-19T11:30:00Z',
            'duration_minutes': 30,
            'billable': false,
          }),
        ],
      ),
    ],
  );
}

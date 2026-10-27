import 'package:bottle_crm/data/models/custom_field_definition.dart';
import 'package:bottle_crm/data/models/auth_response.dart';
import 'package:bottle_crm/data/models/custom_object.dart';
import 'package:bottle_crm/data/models/lookup_models.dart';
import 'package:bottle_crm/data/models/object_record_filters.dart';
import 'package:bottle_crm/data/models/profile.dart';
import 'package:bottle_crm/providers/auth_provider.dart';
import 'package:bottle_crm/providers/profile_provider.dart';
import 'package:bottle_crm/providers/custom_objects_provider.dart';
import 'package:bottle_crm/providers/lookup_provider.dart';
import 'package:bottle_crm/screens/objects/object_records_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeObjects extends CustomObjectsNotifier {
  _FakeObjects(this.answer);

  final CustomObjectsAnswer answer;

  @override
  Future<CustomObjectsAnswer?> build() async => answer;
}

class _FakeRecords extends ObjectRecordsNotifier {
  _FakeRecords(
    super.key,
    this.data,
    this.applied, [
    this._current = const ObjectRecordFilters(),
  ]);

  final ObjectRecordsData data;
  final List<ObjectRecordFilters> applied;
  ObjectRecordFilters _current;

  @override
  ObjectRecordFilters get filters => _current;

  @override
  Future<ObjectRecordsData> build() async => ObjectRecordsData(
    records: data.records,
    count: data.count,
    filters: _current,
  );

  @override
  Future<void> setFilters(ObjectRecordFilters filters) async {
    _current = filters;
    applied.add(filters);
    state = AsyncData(
      ObjectRecordsData(
        records: data.records,
        count: data.count,
        filters: filters,
      ),
    );
  }
}

const _definition = ObjectDefinition(
  summary: ObjectSummary(
    key: 'property',
    label: 'Property',
    labelPlural: 'Properties',
  ),
  fields: [
    ObjectField(
      key: 'stage',
      label: 'Stage',
      fieldType: 'dropdown',
      options: [
        CustomFieldOption(value: 'hot', label: 'Hot lead'),
        CustomFieldOption(value: 'cold', label: 'Cold lead'),
      ],
    ),
    ObjectField(
      key: 'pets',
      label: 'Pets',
      fieldType: 'checkbox',
      displayOrder: 1,
    ),
    ObjectField(
      key: 'empty',
      label: 'Nothing here',
      fieldType: 'dropdown',
      displayOrder: 3,
    ),
    ObjectField(
      key: 'beds',
      label: 'Beds',
      fieldType: 'number',
      displayOrder: 2,
    ),
  ],
);

final _records = ObjectRecordsData(
  records: [
    ObjectRecord.fromJson({
      'id': '11111111-1111-1111-1111-111111111111',
      'name': 'Harbour View',
      'tags': [
        {'id': 't1', 'name': 'Prime'},
        {'id': 't2', 'name': 'Waterfront'},
      ],
    }),
  ],
  count: 1,
);

class _FakeProfile extends ProfileNotifier {
  _FakeProfile(this.sales);

  final bool sales;

  @override
  Future<Profile> build() async => Profile(
    id: 'me-id',
    user: const AuthUser(id: 'u1', email: 'Me@Example.com', name: 'Me'),
    hasSalesAccess: sales,
  );
}

Widget _app(
  List<ObjectRecordFilters> applied, {
  double textScale = 1.0,
  bool admin = true,
  bool sales = false,
  bool writes = true,
  ObjectRecordFilters current = const ObjectRecordFilters(),
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const ObjectRecordsScreen(objectKey: 'property'),
      ),
    ],
  );
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      customObjectsProvider.overrideWith(
        () => _FakeObjects(CustomObjectsAnswer(hasCustomObjects: writes)),
      ),
      isOrgAdminProvider.overrideWithValue(admin),
      profileProvider.overrideWith(() => _FakeProfile(sales)),
      myEmailProvider.overrideWithValue('me@example.com'),
      objectDefinitionProvider.overrideWith((ref, key) async => _definition),
      objectRecordsProvider('property').overrideWith(
        () => _FakeRecords('property', _records, applied, current),
      ),
      usersProvider.overrideWithValue(const [
        UserLookup(
          id: 'me-id',
          email: 'me@example.com',
          name: 'Me',
          role: 'USER',
          isActive: true,
        ),
      ]),
      tagsProvider.overrideWithValue(const [
        TagLookup(id: 't1', name: 'Prime', slug: 'prime', color: 'blue'),
      ]),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
  );
}

void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('each row shows its tags', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(_app([]));
    await tester.pumpAndSettle();
    expect(find.text('Prime'), findsOneWidget);
    expect(find.text('Waterfront'), findsOneWidget);
  });

  testWidgets('the bar offers filters, saved views, import and export', (
    tester,
  ) async {
    usePhone(tester);
    await tester.pumpWidget(_app([]));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Filters'), findsOneWidget);
    expect(find.byTooltip('Saved views'), findsOneWidget);
    expect(find.byTooltip('Export CSV'), findsOneWidget);
    expect(find.byTooltip('Import from a spreadsheet'), findsOneWidget);
  });

  testWidgets('Import is for an admin or a member with sales access', (
    tester,
  ) async {
    usePhone(tester);
    const tip = 'Import from a spreadsheet';
    await tester.pumpWidget(_app([], admin: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip(tip), findsNothing);

    await tester.pumpWidget(_app([], admin: false, sales: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip(tip), findsOneWidget);

    await tester.pumpWidget(_app([], writes: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip(tip), findsNothing);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'the filter sheet applies a checkbox and a dropdown at $scale',
      (tester) async {
        usePhone(tester);
        final applied = <ObjectRecordFilters>[];
        await tester.pumpWidget(_app(applied, textScale: scale));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Filters'));
        await tester.pumpAndSettle();
        expect(find.text('Assigned to'), findsOneWidget);
        expect(find.text('Stage'), findsOneWidget);
        expect(find.text('Pets'), findsOneWidget);
        expect(find.text('Beds'), findsNothing);
        expect(find.text('Nothing here'), findsNothing);

        await tester.tap(find.text('Me'));
        await tester.tap(find.text('Hot lead'));
        await tester.tap(find.text('No'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();

        expect(applied.single.assignedTo, ['me-id']);
        expect(applied.single.fields, {'stage': 'hot', 'pets': 'false'});
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Filters (3 on)'), findsOneWidget);
      },
    );
  }

  testWidgets('a chosen option is cleared by choosing it again', (
    tester,
  ) async {
    usePhone(tester);
    final applied = <ObjectRecordFilters>[];
    await tester.pumpWidget(_app(applied));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hot lead'));
    await tester.tap(find.text('Hot lead'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(applied.single.fields, isEmpty);
  });

  testWidgets('Clear all empties the draft but keeps the search text', (
    tester,
  ) async {
    usePhone(tester);
    final applied = <ObjectRecordFilters>[];
    await tester.pumpWidget(_app(applied));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hot lead'));
    await tester.tap(find.text('Clear all'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(applied.single.isEmpty, isTrue);
  });

  testWidgets('a saved dropdown value that is no longer an option still '
      'shows, counts and is sent', (tester) async {
    usePhone(tester);
    final applied = <ObjectRecordFilters>[];
    await tester.pumpWidget(
      _app(
        applied,
        current: const ObjectRecordFilters(fields: {'stage': 'warm'}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Filters (1 on)'), findsOneWidget);

    await tester.tap(find.byTooltip('Filters (1 on)'));
    await tester.pumpAndSettle();
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'warm'),
    );
    expect(chip.selected, isTrue);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(applied.single.fields, {'stage': 'warm'});
    expect(applied.single.toQuery()['cf_stage'], 'warm');
  });
}

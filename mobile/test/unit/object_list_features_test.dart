import 'dart:convert';

import 'package:bottle_crm/config/api_config.dart';
import 'package:bottle_crm/data/api/schema.g.dart' as api;
import 'package:bottle_crm/data/models/custom_field_definition.dart';
import 'package:bottle_crm/data/models/custom_object.dart';
import 'package:bottle_crm/data/models/object_record_filters.dart';
import 'package:bottle_crm/data/models/tag.dart';
import 'package:bottle_crm/providers/csv_import_provider.dart';
import 'package:bottle_crm/providers/custom_objects_provider.dart';
import 'package:bottle_crm/providers/saved_views_provider.dart';
import 'package:bottle_crm/providers/settings_provider.dart';
import 'package:bottle_crm/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  final List<(int, String)> replies = [];
  final List<http.BaseRequest> sent = [];
  final List<String> bodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    bodies.add(utf8.decode(await request.finalize().toBytes()));
    final (status, body) = replies.removeAt(0);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
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
      options: [CustomFieldOption(value: 'hot', label: 'Hot lead')],
    ),
    ObjectField(
      key: 'pets',
      label: 'Pets',
      fieldType: 'checkbox',
      displayOrder: 1,
    ),
    ObjectField(
      key: 'beds',
      label: 'Beds',
      fieldType: 'number',
      displayOrder: 2,
    ),
    ObjectField(
      key: 'old',
      label: 'Old',
      fieldType: 'dropdown',
      displayOrder: 3,
      isActive: false,
    ),
  ],
);

void main() {
  group('list filters', () {
    test('send the contract parameters, lists repeated', () async {
      final client = _Client();
      ApiService().setClientForTesting(client);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      client.replies
        ..add((200, jsonEncode({'count': 0, 'results': []})))
        ..add((200, jsonEncode({'count': 0, 'results': []})));
      container.listen(objectRecordsProvider('property'), (_, _) {});
      await container.read(objectRecordsProvider('property').future);

      await container
          .read(objectRecordsProvider('property').notifier)
          .setFilters(
            const ObjectRecordFilters(
              query: 'oslo',
              assignedTo: ['p1', 'p2'],
              tagIds: ['t1', 't2'],
              fields: {'pets': 'true', 'stage': ''},
            ),
          );

      final url = client.sent.last.url;
      expect(url.path, endsWith('/api/objects/property/records/'));
      expect(url.queryParametersAll['q'], ['oslo']);
      expect(url.queryParametersAll['assigned_to'], ['p1', 'p2']);
      expect(url.queryParametersAll['tags'], ['t1', 't2']);
      expect(url.queryParametersAll['cf_pets'], ['true']);
      expect(url.queryParametersAll.containsKey('cf_stage'), isFalse);
      expect(url.queryParametersAll['limit'], ['20']);
    });

    test('a search keeps the other filters, and the export sends them', () {
      const filters = ObjectRecordFilters(
        tagIds: ['t1'],
        fields: {'stage': 'hot'},
      );
      final next = filters.copyWith(query: 'harbour');
      expect(next.toQuery(), {
        'q': 'harbour',
        'tags': ['t1'],
        'cf_stage': 'hot',
      });
      expect(next.count, 2);
      expect(const ObjectRecordFilters().isEmpty, isTrue);
      expect(next == filters.copyWith(query: 'harbour'), isTrue);
    });

    test('a refresh keeps the filters the list was narrowed by', () async {
      final client = _Client();
      ApiService().setClientForTesting(client);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (var i = 0; i < 3; i++) {
        client.replies.add((200, jsonEncode({'count': 0, 'results': []})));
      }
      container.listen(objectRecordsProvider('property'), (_, _) {});
      await container.read(objectRecordsProvider('property').future);
      final notifier = container.read(
        objectRecordsProvider('property').notifier,
      );
      await notifier.setFilters(
        const ObjectRecordFilters(query: 'oslo', fields: {'pets': 'true'}),
      );
      await notifier.refresh();
      final url = client.sent.last.url;
      expect(url.queryParametersAll['q'], ['oslo']);
      expect(url.queryParametersAll['cf_pets'], ['true']);
    });

    test('a saved view holding a value that is no longer an option', () {
      final filters = ObjectRecordFilters.fromSavedView(
        {
          'cf_stage': ['gone'],
        },
        {'stage'},
      );
      // Kept and sent: the server still matches records holding it.
      expect(filters.fields, {'stage': 'gone'});
      expect(filters.count, 1);
    });

    test('the filterable fields are the active dropdowns and checkboxes', () {
      expect(
        [for (final f in filterableFields(_definition)) f.key],
        ['stage', 'pets'],
      );
      expect(objectSavedViewKeys(_definition), {
        'q',
        'assigned_to',
        'tags',
        'cf_stage',
        'cf_pets',
      });
    });
  });

  group('saved views on a custom object', () {
    test('the list is named by its registry key, and compares by it', () {
      expect(SavedViewList.object('property').module, 'obj:property');
      expect(
        SavedViewList.object('property'),
        SavedViewList.object('property'),
      );
      expect(SavedViewList.leads.module, 'leads');
      expect(SavedViewList.deals.module, 'opportunities');
      expect(SavedViewList.tickets.module, 'cases');
    });

    test('a round trip saves the filters and puts them back', () async {
      final client = _Client();
      ApiService().setClientForTesting(client);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final list = SavedViewList.object('property');
      final view = {
        'id': '99999999-8888-7777-6666-555555555555',
        'module': 'obj:property',
        'name': 'Pets',
        'filters': {
          'assigned_to': ['p1'],
          'tags': ['t1', 't2'],
          'cf_pets': ['true'],
          'cf_beds': ['3'],
        },
      };
      client.replies
        ..add((200, jsonEncode({'saved_views': [], 'limit': 25})))
        ..add((201, jsonEncode(view)))
        ..add((
          200,
          jsonEncode({
            'saved_views': [view],
            'limit': 25,
          }),
        ));
      container.listen(savedViewsProvider(list), (_, _) {});
      await container.read(savedViewsProvider(list).future);
      expect(client.sent[0].url.queryParameters['module'], 'obj:property');

      const filters = ObjectRecordFilters(
        assignedTo: ['p1'],
        tagIds: ['t1', 't2'],
        fields: {'pets': 'true'},
      );
      final keys = objectSavedViewKeys(_definition);
      final saved = savedViewFilters(
        filters.toQuery(),
        keys,
        multi: const {'assigned_to', 'tags'},
      );
      final error = await container
          .read(savedViewsProvider(list).notifier)
          .save('Pets', saved);

      expect(error, isNull);
      expect(jsonDecode(client.bodies[1]), {
        'module': 'obj:property',
        'name': 'Pets',
        'filters': {
          'assigned_to': ['p1'],
          'tags': ['t1', 't2'],
          'cf_pets': ['true'],
        },
      });
      final stored = container
          .read(savedViewsProvider(list))
          .value!
          .views
          .single;
      expect(
        ObjectRecordFilters.fromSavedView(stored.filters, {'stage', 'pets'}),
        filters,
      );
      expect(stored.dropped(keys, const {'assigned_to', 'tags'}), 1);
    });
  });

  group('records carry tags', () {
    test('a row with tags reads them, a row without reads none', () {
      final tagged = ObjectRecord.fromJson({
        'id': 'r1',
        'name': 'Harbour View',
        'tags': [
          {'id': 't1', 'name': 'Prime', 'color': 'blue'},
          {'name': 'no id'},
        ],
      });
      expect([for (final t in tagged.tags) t.name], ['Prime']);
      expect(tagged.tags.single.color, 'blue');
      expect(ObjectRecord.fromJson({'id': 'r2', 'name': 'x'}).tags, isEmpty);
      expect(
        ObjectRecord.fromJson({'id': 'r2', 'name': 'x', 'tags': 'oops'}).tags,
        isEmpty,
      );
    });

    test('a write sends tags only when they changed', () {
      Map<String, dynamic> body(List<String> tags, ObjectRecord? original) =>
          recordWriteBody(
            definition: _definition,
            name: 'x',
            customFields: const {},
            links: const {},
            assignees: const [],
            tags: tags,
            original: original,
          );
      final original = ObjectRecord.fromJson({
        'id': 'r1',
        'name': 'x',
        'tags': [
          {'id': 't1', 'name': 'Prime'},
        ],
      });

      expect(body(const [], null).containsKey('tags'), isFalse);
      expect(body(['t1', 't2'], null)['tags'], ['t1', 't2']);
      expect(body(['t1'], original).containsKey('tags'), isFalse);
      expect(body(const [], original)['tags'], isEmpty);
      expect(body(['t2'], original)['tags'], ['t2']);
    });
  });

  group('export and import', () {
    test('the export URL is the list URL plus export/', () {
      expect(
        ApiConfig.objectRecordsExport('property'),
        endsWith('/api/objects/property/records/export/'),
      );
      expect(
        () => ApiConfig.objectRecordsExport('Bad Key'),
        throwsArgumentError,
      );
    });

    test('an object target builds its template from the fields', () {
      final target = CsvImportTarget.forObject(
        key: 'property',
        label: 'Property',
        labelPlural: 'Properties',
        nameLabel: 'Address',
        fields: _definition.fields,
      );
      expect(
        target.previewUrl,
        endsWith('/api/objects/property/records/import/preview/'),
      );
      expect(
        target.commitUrl,
        endsWith('/api/objects/property/records/import/commit/'),
      );
      expect(target.usesMapping, isTrue);
      expect(target.plural, 'properties');
      expect(target.noun(1), 'property');
      expect(target.templateCsv.split('\n'), [
        'Address,Stage,Pets,Beds,Assigned to,Tags',
        'Example property,Hot lead,Yes,3,agent@yourco.com,"vip,featured"',
      ]);
      expect(target.templateFileName, 'property-import-template.csv');
    });

    test('a long-text field gets the same example as the web', () {
      final target = CsvImportTarget.forObject(
        key: 'property',
        label: 'Property',
        labelPlural: 'Properties',
        fields: const [
          ObjectField(key: 'notes', label: 'Notes', fieldType: 'textarea'),
        ],
      );
      expect(target.templateHeaders, ['Name', 'Notes', 'Assigned to', 'Tags']);
      expect(target.templateExample[1], 'A longer note');
    });

    test('the sample line names the record and its first values', () {
      final target = CsvImportTarget.forObject(
        key: 'property',
        label: 'Property',
        labelPlural: 'Properties',
        fields: _definition.fields,
      );
      final line = target.sampleLine({
        'row': 4,
        'name': 'Harbour View',
        'custom_fields': {'stage': 'hot', 'pets': true, 'beds': null},
      });
      expect(line.title, 'Harbour View');
      expect(line.details, 'Hot lead · Yes');
      expect(target.sampleRow({'row': 4}), 4);
      expect(target.sampleLine(const {}).title, 'Unnamed');
    });

    test('targets are equal by where they import', () {
      CsvImportTarget forKey(String key) =>
          CsvImportTarget.forObject(key: key, label: 'A', labelPlural: 'As');
      expect(forKey('a'), forKey('a'));
      expect(forKey('a') == forKey('b'), isFalse);
      expect(forKey('a') == CsvImportTarget.leads, isFalse);
      expect(CsvImportTarget.values, hasLength(3));
    });

    test(
      'a custom field keyed like a built-in column is not a template column',
      () {
        final target = CsvImportTarget.forObject(
          key: 'property',
          label: 'Property',
          labelPlural: 'Properties',
          fields: const [
            ObjectField(key: 'tags', label: 'Tags', fieldType: 'text'),
            ObjectField(key: 'name', label: 'Name', fieldType: 'text'),
            ObjectField(key: 'assigned_to', label: 'Owner', fieldType: 'text'),
            ObjectField(key: 'full_name', label: 'Full', fieldType: 'text'),
            ObjectField(key: 'beds', label: 'Beds', fieldType: 'number'),
          ],
        );
        expect(target.templateHeaders, ['Name', 'Beds', 'Assigned to', 'Tags']);
        expect(target.templateExample, hasLength(4));
      },
    );

    for (final body in [
      {'detail': "Your organization's plan does not include custom objects."},
      {'detail': 'Importing needs an admin, or a member with sales access.'},
    ]) {
      test('a 403 shows the server detail: ${body['detail']}', () async {
        final client = _Client();
        ApiService().setClientForTesting(client);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final target = CsvImportTarget.forObject(
          key: 'property',
          label: 'Property',
          labelPlural: 'Properties',
        );
        container.listen(csvImportProvider(target), (_, _) {});
        client.replies.add((403, jsonEncode(body)));
        await container
            .read(csvImportProvider(target).notifier)
            .useFile(
              CsvImportFile(name: 'a.csv', bytes: utf8.encode('Name\nx')),
            );
        expect(container.read(csvImportProvider(target)).error, body['detail']);
      });
    }

    test('a 403 without a detail keeps the permission sentence', () async {
      final client = _Client();
      ApiService().setClientForTesting(client);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final target = CsvImportTarget.forObject(
        key: 'property',
        label: 'Property',
        labelPlural: 'Properties',
      );
      container.listen(csvImportProvider(target), (_, _) {});
      client.replies.add((403, jsonEncode(<String, dynamic>{})));
      await container
          .read(csvImportProvider(target).notifier)
          .useFile(CsvImportFile(name: 'a.csv', bytes: utf8.encode('Name\nx')));
      expect(
        container.read(csvImportProvider(target)).error,
        csvImportForbiddenMessage,
      );
    });
  });

  group('Settings tags read their labels from the server', () {
    test('usage_labels name each key, and a missing key shows itself', () {
      final tag = Tag.fromJson(
        {
          'id': 't1',
          'name': 'Prime',
          'usage': {'leads': 2, 'obj:property': 1, 'macros': 3, 'mystery': 1},
        },
        usageLabels: const {
          'leads': 'Leads',
          'obj:property': 'Properties',
          'macros': 'Macros',
        },
      );
      expect(tagUsageSummary(tag), '3 macros, 2 leads, 1 mystery, 1 property');
      expect(tag.labelFor('obj:property'), 'Properties');
      expect(tag.labelFor('mystery'), 'mystery');
    });

    test('an older server sends no labels and the phone words stand in', () {
      final tag = Tag.fromJson({
        'id': 't1',
        'name': 'Prime',
        'usage': {'opportunities': 2},
      });
      expect(tag.usageLabels, isNull);
      expect(tagUsageSummary(tag), '2 deals');
      expect(api.TagsListResponse.fromJson(const {}).usageLabels, isNull);
      expect(
        api.TagsListResponse.fromJson({
          'usage_labels': {'leads': 'Leads'},
        }).usageLabels,
        {'leads': 'Leads'},
      );
    });

    test('the tags list passes the labels to every row', () async {
      final client = _Client();
      ApiService().setClientForTesting(client);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      client.replies.add((
        200,
        jsonEncode({
          'tags_count': 1,
          'tags': [
            {
              'id': 't1',
              'name': 'Prime',
              'slug': 'prime',
              'color': 'blue',
              'is_active': true,
              'usage': {'obj:property': 4},
            },
          ],
          'totals': {'count': 1, 'active': 1, 'unused': 0},
          'usage_labels': {'obj:property': 'Properties'},
        }),
      ));
      container.listen(tagSettingsProvider, (_, _) {});
      final state = await container.read(tagSettingsProvider.future);

      expect(tagUsageSummary(state.tags.single), '4 properties');
    });
  });
}

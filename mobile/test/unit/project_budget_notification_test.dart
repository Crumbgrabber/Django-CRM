import 'package:bottle_crm/data/models/app_notification.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '3f2b8c1e-5a4d-4e8b-9c3a-1d2e3f4a5b6c';

AppNotification _budget(Object? data, {String link = '/projects/$_id'}) =>
    AppNotification.fromJson({
      'id': 'n1',
      'verb': 'project.budget',
      'actor': null,
      'data': data,
      'link': link,
      'read_at': null,
      'created_at': '2026-10-26T09:00:00Z',
    });

void main() {
  group('the project budget sentence', () {
    test('80% of the hours budget', () {
      final n = _budget({
        'kind': 'hours',
        'percent': 80,
        'project': 'Website rebuild',
      });
      expect(n.budgetText, 'Website rebuild has used 80% of its hours budget');
      expect(n.isKnownVerb, isTrue);
    });

    test('80% of the amount budget', () {
      final n = _budget({'kind': 'amount', 'percent': 80, 'project': 'Audit'});
      expect(n.budgetText, 'Audit has used 80% of its amount budget');
    });

    test('at 100% the whole budget is used', () {
      expect(
        _budget({
          'kind': 'hours',
          'percent': 100,
          'project': 'Audit',
        }).budgetText,
        'Audit has used all of its hours budget',
      );
      expect(
        _budget({
          'kind': 'amount',
          'percent': 100,
          'project': 'Audit',
        }).budgetText,
        'Audit has used all of its amount budget',
      );
    });

    test(
      'data of the wrong shape gives no sentence rather than a wrong one',
      () {
        for (final data in [
          null,
          'Audit',
          {'kind': 'days', 'percent': 80, 'project': 'Audit'},
          {'kind': 'hours', 'percent': '80', 'project': 'Audit'},
          {'kind': 'hours', 'percent': 80},
          {'kind': 'hours', 'percent': 80, 'project': '  '},
          {'kind': 'hours', 'percent': 0, 'project': 'Audit'},
        ]) {
          expect(_budget(data).budgetText, isNull, reason: '$data');
        }
      },
    );

    test('another verb has no budget sentence', () {
      final n = AppNotification.fromJson({
        'id': 'n2',
        'verb': 'case.commented',
        'data': {'kind': 'hours', 'percent': 80, 'project': 'Audit'},
        'created_at': '2026-10-26T09:00:00Z',
      });
      expect(n.budgetText, isNull);
    });
  });

  group('where a budget notification opens', () {
    test('its project, by the stored link', () {
      expect(_budget(const {}).destinationPath, '/projects/$_id');
    });

    test('nowhere for an id that is not one, or a path that is not ours', () {
      expect(
        _budget(const {}, link: '/projects/not-an-id').destinationPath,
        isNull,
      );
      expect(
        _budget(
          const {},
          link: 'https://evil.example/projects/$_id',
        ).destinationPath,
        isNull,
      );
    });
  });
}

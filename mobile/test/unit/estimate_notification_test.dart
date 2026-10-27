import 'package:bottle_crm/data/models/app_notification.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '3f2b8c1e-5a4d-4e8b-9c3a-1d2e3f4a5b6c';
const _other = '7a1c2b3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';

AppNotification _answer(
  String verb,
  Object? data, {
  String link = '/invoices/estimates',
}) => AppNotification.fromJson({
  'id': 'n1',
  'verb': verb,
  'actor': null,
  'data': data,
  'link': link,
  'read_at': null,
  'created_at': '2026-10-27T09:00:00Z',
});

void main() {
  group('a client accepting an estimate', () {
    test('says who and which, and nothing else when nothing was made', () {
      final n = _answer('estimate.accepted', {
        'estimate_number': 'EST-0007',
        'client_name': 'Ada Lovelace',
        'project_id': null,
        'deposit_invoice_id': null,
      });
      expect(n.estimateText, 'Ada Lovelace accepted estimate EST-0007');
      expect(n.isKnownVerb, isTrue);
    });

    test('adds the project and the deposit as they apply', () {
      Map<String, Object?> data({String? project, String? deposit}) => {
        'estimate_number': 'EST-0007',
        'client_name': 'Ada Lovelace',
        'project_id': project,
        'deposit_invoice_id': deposit,
      };
      expect(
        _answer('estimate.accepted', data(project: _id)).estimateText,
        'Ada Lovelace accepted estimate EST-0007, project started',
      );
      expect(
        _answer('estimate.accepted', data(deposit: _other)).estimateText,
        'Ada Lovelace accepted estimate EST-0007, deposit invoice drafted',
      );
      expect(
        _answer(
          'estimate.accepted',
          data(project: _id, deposit: _other),
        ).estimateText,
        'Ada Lovelace accepted estimate EST-0007, project started, '
        'deposit invoice drafted',
      );
    });
  });

  group('a client declining an estimate', () {
    test('says who and which', () {
      final n = _answer('estimate.declined', {
        'estimate_number': 'EST-0008',
        'client_name': 'Northwind',
      });
      expect(n.estimateText, 'Northwind declined estimate EST-0008');
      expect(n.isKnownVerb, isTrue);
    });

    test('ignores project and deposit keys it should never carry', () {
      final n = _answer('estimate.declined', {
        'estimate_number': 'EST-0008',
        'client_name': 'Northwind',
        'project_id': _id,
      });
      expect(n.estimateText, 'Northwind declined estimate EST-0008');
    });
  });

  group('the sentence', () {
    test('names the client generically when the name is blank', () {
      for (final name in [null, '', '   ']) {
        expect(
          _answer('estimate.declined', {
            'estimate_number': 'EST-0008',
            'client_name': name,
          }).estimateText,
          'The client declined estimate EST-0008',
          reason: '$name',
        );
      }
    });

    test('shows markup in a typed name as text', () {
      expect(
        _answer('estimate.accepted', {
          'estimate_number': 'EST-0007',
          'client_name': '<b>Ada</b>',
        }).estimateText,
        '<b>Ada</b> accepted estimate EST-0007',
      );
    });

    test('is null without a number, or for data of the wrong shape', () {
      for (final data in [
        null,
        'EST-0007',
        <String, Object?>{'client_name': 'Ada'},
        {'estimate_number': 7, 'client_name': 'Ada'},
        {'estimate_number': '  ', 'client_name': 'Ada'},
      ]) {
        expect(
          _answer('estimate.accepted', data).estimateText,
          isNull,
          reason: '$data',
        );
      }
    });

    test('belongs to the two estimate verbs only', () {
      final n = _answer('project.budget', {
        'estimate_number': 'EST-0007',
        'client_name': 'Ada',
      });
      expect(n.estimateText, isNull);
    });
  });

  group('where an estimate answer opens', () {
    test('the project it started, the deposit invoice, or the estimates', () {
      expect(
        _answer(
          'estimate.accepted',
          {},
          link: '/projects/$_id',
        ).destinationPath,
        '/projects/$_id',
      );
      expect(
        _answer(
          'estimate.accepted',
          {},
          link: '/invoices/$_id',
        ).destinationPath,
        '/invoices/$_id',
      );
      expect(
        _answer('estimate.declined', {}).destinationPath,
        '/invoices/estimates',
      );
    });

    test('nowhere for an id that is not one, or a path that is not ours', () {
      for (final link in [
        '/invoices/not-an-id',
        '/invoices/estimates/',
        '/invoices/estimates/new',
        '/invoices/$_id/',
        '/invoices/$_id/edit',
        '/invoices/$_id?next=//evil.example',
        '/invoices/$_id\n',
        ' /invoices/estimates',
        '/Invoices/$_id',
        'https://evil.example/invoices/$_id',
        '//evil.example/invoices/estimates',
      ]) {
        expect(
          _answer('estimate.accepted', {}, link: link).destinationPath,
          isNull,
          reason: link,
        );
      }
    });
  });

  group('a retainer invoice drafted', () {
    AppNotification retainer(Object? data) =>
        _answer('project.retainer_invoice', data, link: '/invoices/$_id');

    test('names the invoice, the month and the project', () {
      final n = retainer({
        'project': 'Website care',
        'month': '2026-10',
        'invoice_number': 'INV-0012',
      });
      expect(
        n.retainerText,
        'Retainer invoice INV-0012 for October 2026 drafted for Website care',
      );
      expect(n.isKnownVerb, isTrue);
      expect(n.destinationPath, '/invoices/$_id');
    });

    test('is null without a number, a month or a project', () {
      for (final data in [
        null,
        'x',
        {'project': 'P', 'month': '2026-10'},
        {'project': 'P', 'invoice_number': 'INV-1'},
        {'project': 'P', 'month': '2026-13', 'invoice_number': 'INV-1'},
        {'month': '2026-10', 'invoice_number': 'INV-1'},
      ]) {
        expect(retainer(data).retainerText, isNull, reason: '$data');
      }
    });

    test('does not borrow the entity name when the project is missing', () {
      final n = AppNotification.fromJson({
        'id': 'n1',
        'verb': 'project.retainer_invoice',
        'actor': null,
        'entity_name': 'Website care',
        'data': {'month': '2026-10', 'invoice_number': 'INV-1'},
        'link': '/invoices/$_id',
        'read_at': null,
        'created_at': '2026-10-27T09:00:00Z',
      });
      expect(n.retainerText, isNull);
    });

    test('belongs to its verb only', () {
      expect(
        _answer('project.budget', {
          'project': 'P',
          'month': '2026-10',
          'invoice_number': 'INV-1',
        }).retainerText,
        isNull,
      );
    });
  });
}

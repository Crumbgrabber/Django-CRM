import 'package:bottle_crm/data/models/time_entry.dart';
import 'package:bottle_crm/widgets/time/time_entry_parts.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(Map<String, dynamic> extra) => {
  'id': 'e1',
  'case': 'c1',
  'profile': 'p1',
  'started_at': '2026-09-01T09:00:00Z',
  'ended_at': '2026-09-01T10:00:00Z',
  'duration_minutes': 60,
  'billable': true,
  ...extra,
};

void main() {
  test('an entry billed while Invoices is off reads as billed', () {
    final entry = TimeEntry.fromJson(
      _json({'invoiced': true, 'invoice': null}),
    );
    expect(entry.invoiceId, isNull);
    expect(entry.isBilled, isTrue);
  });

  test(
    'an entry with an invoice reads as billed, and one without does not',
    () {
      expect(TimeEntry.fromJson(_json({'invoice': 'i1'})).isBilled, isTrue);
      final open = TimeEntry.fromJson(_json({}));
      expect(open.invoiced, isFalse);
      expect(open.isBilled, isFalse);
    },
  );
  group('the parent an entry hangs off', () {
    test('an entry on a project names it and opens it', () {
      final entry = TimeEntry.fromJson(
        _json({
          'case': null,
          'project': 'p1',
          'project_name': 'Website rebuild',
          'task': 't1',
        }),
      );
      expect(entry.isOnTicket, isFalse);
      expect(entry.isOnProject, isTrue);
      expect(entry.caseId, '');
      expect(entry.taskId, 't1');
      expect(entry.sourceName, 'Website rebuild');
      expect(entry.sourcePath, '/projects/p1');
    });

    test('an expanded project and task read as their ids', () {
      final entry = TimeEntry.fromJson(
        _json({
          'case': null,
          'project': {'id': 'p1', 'name': 'Website rebuild'},
          'task': {'id': 't1', 'title': 'Design'},
        }),
      );
      expect(entry.projectId, 'p1');
      expect(entry.projectName, 'Website rebuild');
      expect(entry.taskId, 't1');
    });

    test('an entry whose project was deleted has no parent and no link', () {
      final entry = TimeEntry.fromJson(
        _json({
          'case': null,
          'project': null,
          'project_name': null,
          'task': null,
        }),
      );
      expect(entry.isOnTicket, isFalse);
      expect(entry.isOnProject, isFalse);
      expect(entry.sourceName, isNull);
      expect(entry.sourcePath, isNull);
      expect(entry.durationMinutes, 60);
    });

    test('an older API with no project fields reads as a ticket entry', () {
      final entry = TimeEntry.fromJson(_json({}));
      expect(entry.projectId, isNull);
      expect(entry.projectName, isNull);
      expect(entry.taskId, isNull);
      expect(entry.sourceName, 'a ticket');
      expect(entry.sourcePath, '/tickets/c1');
    });
  });

  test('a 409 opens whichever timer is running, a ticket or a project', () {
    expect(runningTimerPath({'running_case_id': 'k1'}), '/tickets/k1');
    expect(
      runningTimerPath({'running_case_id': null, 'running_project_id': 'p1'}),
      '/projects/p1',
    );
    expect(runningTimerPath({'detail': 'Timer already running'}), isNull);
    expect(runningTimerPath(null), isNull);
  });
}

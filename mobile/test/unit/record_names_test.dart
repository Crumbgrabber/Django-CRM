import 'package:bottle_crm/data/models/auth_response.dart';
import 'package:bottle_crm/data/models/dashboard_data.dart';
import 'package:bottle_crm/data/models/deal.dart';
import 'package:bottle_crm/data/models/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// Names the app showed as "Unknown", "?" or nothing, because it read keys
/// the API never sent. Each fixture is the shape the schema publishes.
void main() {
  const profile = {
    'id': 'p1',
    'user_details': {'email': 'asha@example.com', 'name': 'Asha Rao'},
  };

  group('a task', () {
    test('names its lead from the link the API sends', () {
      final task = Task.fromJson({
        'id': 't1',
        'title': 'Call back',
        'lead': {'id': 'l1', 'name': 'Jill Shaffer'},
      });

      expect(task.relatedTo?.id, 'l1');
      expect(task.relatedTo?.title, 'Jill Shaffer');
    });

    test('names its first assignee', () {
      final task = Task.fromJson({
        'id': 't1',
        'title': 'Call back',
        'assigned_to': [profile],
      });

      expect(task.assignedToName, 'Asha Rao');
    });

    test('falls back to the assignee email local part, then Unassigned', () {
      final unnamed = Task.fromJson({
        'id': 't1',
        'assigned_to': [
          {
            'id': 'p2',
            'user_details': {'email': 'raj@example.com', 'name': ''},
          },
        ],
      });

      expect(unnamed.assignedToName, 'raj');
      expect(Task.fromJson({'id': 't2'}).assignedToName, 'Unassigned');
    });
  });

  test('a dashboard task linked only to a lead names the lead', () {
    final task = DashboardTask.fromJson({
      'id': 't1',
      'title': 'Call back',
      'lead': {'id': 'l1', 'name': 'Jill Shaffer'},
    });

    expect(task.relatedTo, 'Jill Shaffer');
  });

  test('a deal names who created it', () {
    final deal = Deal.fromJson({
      'id': 'o1',
      'name': 'Renewal',
      'created_by': {
        'id': 'u1',
        'email': 'asha@example.com',
        'name': 'Asha Rao',
      },
    });

    expect(deal.createdByName, 'Asha Rao');
    expect(deal.createdByEmail, 'asha@example.com');
  });

  test('an org with no name still parses', () {
    final org = Organization.fromJson({'id': 'org1', 'name': null});

    expect(org.id, 'org1');
    expect(org.name, '');
  });
}

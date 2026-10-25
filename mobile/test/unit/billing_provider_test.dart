import 'dart:convert';

import 'package:bottle_crm/providers/billing_provider.dart';
import 'package:bottle_crm/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _FakeClient extends http.BaseClient {
  int status = 200;
  String body = '{}';
  bool offline = false;
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    await request.finalize().toBytes();
    if (offline) throw http.ClientException('no route');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

/// The phone reads only the plan's name from `GET /api/billing/`, and shows
/// nothing where the server has no billing or the read fails.
void main() {
  late ProviderContainer container;
  late _FakeClient client;

  setUp(() {
    client = _FakeClient();
    ApiService().setClientForTesting(client);
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  Future<String?> read() {
    container.listen(orgPlanNameProvider, (_, _) {});
    return container.read(orgPlanNameProvider.future);
  }

  group('orgPlanNameProvider', () {
    test('reads the plan name a member is sent', () async {
      client.body =
          '{"plan": {"key": "a", "name": "Plan A"}, '
          '"can_manage": false}';
      expect(await read(), 'Plan A');
      expect(client.sent.single.method, 'GET');
      expect(client.sent.single.url.path, '/api/billing/');
    });

    test('reads only the name from an admin answer', () async {
      client.body = jsonEncode({
        'plan': {'key': 'b', 'name': ' Plan B '},
        'can_manage': true,
        'state': {'code': 'active', 'sentence': 'Renews soon'},
        'notice': null,
        'plans': [
          {'key': 'b', 'name': 'Plan B', 'action': 'manage'},
        ],
      });
      expect(await read(), 'Plan B');
    });

    test('a server without billing answers null', () async {
      client.status = 404;
      client.body = '{"detail": "Not found."}';
      expect(await read(), isNull);
    });

    test('a failure is null too, never a stale or invented name', () async {
      client.status = 500;
      expect(await read(), isNull);
      container.invalidate(orgPlanNameProvider);
      client.status = 200;
      client.offline = true;
      expect(await read(), isNull);
    });
  });

  group('planNameFrom', () {
    test('needs a plan with a name', () {
      expect(planNameFrom(null), isNull);
      expect(planNameFrom({}), isNull);
      expect(planNameFrom({'plan': 'Plan A'}), isNull);
      expect(
        planNameFrom({
          'plan': {'key': 'a'},
        }),
        isNull,
      );
      expect(
        planNameFrom({
          'plan': {'name': '  '},
        }),
        isNull,
      );
      expect(
        planNameFrom({
          'plan': {'name': 3},
        }),
        isNull,
      );
    });
  });
}

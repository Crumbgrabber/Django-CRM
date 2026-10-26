import 'package:bottle_crm/config/api_config.dart';
import 'package:bottle_crm/core/app_info.dart';
import 'package:bottle_crm/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Every request carries `X-BottleCRM-App`. The server reads a phone request
/// without it as an older build and guards its lead and deal writes, so a
/// verb that forgot the header would have this build's edits second-guessed.
void main() {
  final seen = <String, String?>{};

  setUp(() {
    seen.clear();
    ApiService().setClientForTesting(
      MockClient((request) async {
        seen[request.method] = request.headers['X-BottleCRM-App'];
        return http.Response('{}', 200);
      }),
    );
  });

  tearDown(() => ApiService().setClientForTesting(http.Client()));

  test('every verb sends the app version', () async {
    final api = ApiService();
    final lead = '${ApiConfig.leads}1/';
    await api.get(lead);
    await api.post(lead, const {});
    await api.put(lead, const {});
    await api.patch(lead, const {});
    await api.delete(lead);

    expect(seen.keys, containsAll(['GET', 'POST', 'PUT', 'PATCH', 'DELETE']));
    expect(seen.values.toSet(), {appVersion});
  });

  test('a request that needs no sign-in sends it too', () async {
    await ApiService().post(
      ApiConfig.magicLinkRequest,
      const {},
      requiresAuth: false,
    );
    expect(seen['POST'], appVersion);
  });

  test('a multipart upload sends it', () async {
    await ApiService().postMultipart(
      '${ApiConfig.leads}1/',
      fileField: 'lead_attachment',
      fileBytes: const [1, 2, 3],
      fileName: 'a.txt',
    );
    expect(seen['POST'], appVersion);
  });
}

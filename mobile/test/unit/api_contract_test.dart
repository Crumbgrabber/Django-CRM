import 'package:bottle_crm/config/api_config.dart';
import 'package:bottle_crm/services/api_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final api = ApiConfig.apiBaseUrl;

  test('a published operation with accepted fields passes', () {
    expect(apiContractProblem('POST', '$api/tags/', ['name']), isNull);
    expect(apiContractProblem('GET', '$api/leads/abc/'), isNull);
  });

  test('a field the operation does not take is named', () {
    expect(
      apiContractProblem('POST', '$api/tags/', ['name', 'colour']),
      'POST /api/tags/ takes no colour',
    );
  });

  test('a method the path does not answer is named', () {
    expect(
      apiContractProblem('PUT', ApiConfig.leads),
      'PUT /api/leads/ is not published; it takes GET, POST',
    );
  });

  test('a path outside the schema is named', () {
    expect(
      apiContractProblem('GET', '$api/tickets/'),
      'GET /api/tickets/ is not in the API schema',
    );
  });

  test('a literal segment wins over a parameter', () {
    expect(
      apiContractProblem('PUT', ApiConfig.leadSourcesOrder),
      isNot(contains('is not in the API schema')),
    );
    expect(apiContractProblem('GET', '$api/leads/sources/'), isNull);
  });

  test('enterprise operations are known', () {
    expect(apiContractProblem('GET', ApiConfig.objects), isNull);
    expect(apiContractProblem('GET', ApiConfig.supportTickets), isNull);
    expect(apiContractProblem('GET', ApiConfig.billing), isNull);
  });

  test('another host is not checked', () {
    expect(
      apiContractProblem('GET', 'https://files.example.com/a.pdf'),
      isNull,
    );
  });

  test('a violation is recorded for the test hook', () {
    debugCheckApiRequest('GET', '$api/nowhere/');
    expect(apiContractViolations, [
      'GET /api/nowhere/ is not in the API schema',
    ]);
    apiContractViolations.clear();
  });
}

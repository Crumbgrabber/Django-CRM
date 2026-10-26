/// Holding every request to the API's published schema, in debug builds and
/// tests.
///
/// DRF ignores a body field it does not know and answers 200, so a misspelt or
/// retired key loses the user's edit with nothing to show for it. The schema
/// lists each operation's accepted fields (`lib/data/api/schema.g.dart`), and
/// a request that names a path, method or field outside it is recorded here
/// and printed. `test/flutter_test_config.dart` fails any test that records
/// one. Release builds skip the check entirely.
library;

import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../data/api/enterprise_schema.g.dart' as enterprise;
import '../data/api/schema.g.dart' as community;

/// What the checks found since the list was last cleared.
@visibleForTesting
final List<String> apiContractViolations = [];

/// Records a request that does not fit the schema. A no-op in release builds.
void debugCheckApiRequest(
  String method,
  String url, [
  Iterable<String> fields = const [],
]) {
  assert(() {
    final problem = apiContractProblem(method, url, fields);
    if (problem != null) {
      apiContractViolations.add(problem);
      debugPrint('API contract: $problem');
    }
    return true;
  }());
}

/// Why [method] [url] with body [fields] is not an operation the API
/// publishes, or null when it is. A URL on another host is not checked.
@visibleForTesting
String? apiContractProblem(
  String method,
  String url, [
  Iterable<String> fields = const [],
]) {
  final uri = Uri.parse(url);
  final base = Uri.parse(ApiConfig.baseUrl);
  if (uri.host != base.host || !uri.path.startsWith(base.path)) return null;
  final path = uri.path.substring(base.path.length);
  final operations = _operationsFor(path);
  if (operations == null) return '$method $path is not in the API schema';
  if (!operations.containsKey(method)) {
    return '$method $path is not published; it takes '
        '${operations.keys.join(', ')}';
  }
  final accepted = operations[method];
  if (accepted == null) return null;
  final unknown = [
    for (final field in fields)
      if (!accepted.contains(field)) field,
  ];
  if (unknown.isEmpty) return null;
  return '$method $path takes no ${unknown.join(', ')}';
}

/// The operations of the schema path [path] falls under. A literal segment
/// beats a `{parameter}`, as Django's URL order does: `/api/leads/sources/`
/// is not `/api/leads/{id}/`.
Map<String, Set<String>?>? _operationsFor(String path) {
  for (final (pattern, operations) in _templates) {
    if (pattern.hasMatch(path)) return operations;
  }
  return null;
}

final List<(RegExp, Map<String, Set<String>?>)> _templates = () {
  final templates = [
    for (final MapEntry(:key, :value) in {
      ...community.apiOperations,
      ...enterprise.apiOperations,
    }.entries)
      (key, value),
  ]..sort((a, b) => '{'.allMatches(a.$1).length - '{'.allMatches(b.$1).length);
  return [
    for (final (template, operations) in templates)
      (
        RegExp(
          '^${template.split('/').map((s) => s.startsWith('{') ? '[^/]+' : RegExp.escape(s)).join('/')}\$',
        ),
        operations,
      ),
  ];
}();

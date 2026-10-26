import '../api/schema.g.dart' as api;

const defaultModuleLabels = {
  'deals': 'Pipeline',
  'leads': 'Leads',
  'goals': 'Goals',
  'tasks': 'Tasks',
  'tickets': 'Tickets',
  'knowledge_base': 'Knowledge base',
  'documents': 'Documents',
  'projects': 'Projects',
  'invoices': 'Invoices',
  'timesheet': 'Timesheet',
};

const moduleGroups = ['sell', 'serve', 'bill'];

/// One row of `GET /api/org/modules/`.
class OrgModule {
  final String key;
  final String label;
  final String group;
  final String covers;
  final String stops;
  final bool enabled;
  final bool available;
  final String? needs;

  const OrgModule({
    required this.key,
    required this.label,
    required this.group,
    this.covers = '',
    this.stops = '',
    this.enabled = true,
    this.available = true,
    this.needs,
  });

  /// Reads an `OrgModuleRow`.
  factory OrgModule.fromJson(Map<String, dynamic> json) {
    final w = api.OrgModuleRow.fromJson(json);
    final key = w.key ?? '';
    final enabled = w.enabled ?? true;
    final need = w.needs ?? '';
    return OrgModule(
      key: key,
      label: w.label ?? defaultModuleLabels[key] ?? key,
      group: w.group ?? '',
      covers: w.covers ?? '',
      stops: w.stops ?? '',
      enabled: enabled,
      available: w.available ?? enabled,
      needs: need.isEmpty ? null : need,
    );
  }
}

/// The answer of `GET /api/org/modules/`, tagged with the org it was asked for.
class OrgModulesAnswer {
  final String? orgId;
  final List<OrgModule> modules;
  final bool canEdit;

  const OrgModulesAnswer({
    this.orgId,
    this.modules = const [],
    this.canEdit = false,
  });

  /// Reads an `OrgModulesResponse`, the answer to both GET and PUT.
  factory OrgModulesAnswer.fromJson(
    Map<String, dynamic> json, {
    String? orgId,
  }) {
    final w = api.OrgModulesResponse.fromJson(json);
    return OrgModulesAnswer(
      orgId: orgId,
      modules: [
        for (final r in w.modules ?? const <api.OrgModuleRow>[])
          if (r.key?.isNotEmpty ?? false) OrgModule.fromJson(r.json),
      ],
      canEdit: w.canEdit ?? false,
    );
  }

  OrgModule? _row(String key) {
    for (final m in modules) {
      if (m.key == key) return m;
    }
    return null;
  }

  /// A module with no row reads as on.
  bool isOn(String key) => _row(key)?.available ?? true;

  bool get productsOn => isOn('deals') || isOn('invoices');

  String labelOf(String key) =>
      _row(key)?.label ?? defaultModuleLabels[key] ?? key;

  /// The `PUT` body that flips one module's own switch and keeps the order
  /// as served. Null for a key with no row.
  ({List<String> off, List<String> order})? switchBody(String key, bool on) {
    if (_row(key) == null) return null;
    return (
      off: [
        for (final m in modules)
          if (m.key == key ? !on : !m.enabled) m.key,
      ],
      order: [for (final m in modules) m.key],
    );
  }

  /// The `PUT` body after moving one module a place `up` or `down` within its
  /// group. Null at the ends, for an unknown key or for any other direction.
  ({List<String> off, List<String> order})? moveBody(
    String key,
    String direction,
  ) {
    if (direction != 'up' && direction != 'down') return null;
    final at = modules.indexWhere((m) => m.key == key);
    if (at < 0) return null;
    final group = modules[at].group;
    final step = direction == 'up' ? -1 : 1;
    var to = at + step;
    while (to >= 0 && to < modules.length && modules[to].group != group) {
      to += step;
    }
    if (to < 0 || to >= modules.length) return null;
    final order = [for (final m in modules) m.key];
    order[at] = modules[to].key;
    order[to] = key;
    return (
      off: [
        for (final m in modules)
          if (!m.enabled) m.key,
      ],
      order: order,
    );
  }
}

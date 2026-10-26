import '../api/schema.g.dart' as api;

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(dynamic v) => v is List
    ? [
        for (final e in v)
          if (e is Map) _map(e),
      ]
    : const [];

String _str(dynamic v, [String fallback = '']) => v?.toString() ?? fallback;

String _label(String? v, String fallback) =>
    v == null || v.isEmpty ? fallback : v;

/// A deep copy of decoded JSON, so a draft never shares a list or map.
dynamic _clone(dynamic v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key.toString(): _clone(e.value),
    };
  }
  if (v is List) return [for (final e in v) _clone(e)];
  return v;
}

class RulePerson {
  final String id;
  final String name;

  const RulePerson({required this.id, this.name = ''});

  /// Reads a `RuleOwner`; the catalogue's `AutomationCataloguePerson` is the
  /// same shape.
  factory RulePerson.fromJson(Map<String, dynamic> json) {
    final w = api.RuleOwner.fromJson(json);
    return RulePerson(id: w.id ?? '', name: w.name ?? '');
  }
}

class RuleEndpoint {
  final String id;
  final String description;

  const RuleEndpoint({required this.id, this.description = ''});

  /// Reads an `AutomationCatalogueEndpoint`.
  factory RuleEndpoint.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueEndpoint.fromJson(json);
    return RuleEndpoint(id: w.id ?? '', description: w.description ?? '');
  }
}

class RuleChoice {
  final String value;
  final String label;
  final String group;
  final bool settable;

  const RuleChoice({
    required this.value,
    required this.label,
    this.group = '',
    this.settable = true,
  });

  /// Reads an `AutomationCatalogueChoice`.
  factory RuleChoice.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueChoice.fromJson(json);
    final value = w.value ?? '';
    return RuleChoice(
      value: value,
      label: _label(w.label, value),
      group: w.group ?? '',
      settable: w.settable ?? true,
    );
  }
}

class RuleField {
  final String key;
  final String label;
  final String type;
  final List<RuleChoice> choices;
  final bool settable;

  const RuleField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.choices = const [],
    this.settable = true,
  });

  /// Reads an `AutomationCatalogueField`.
  factory RuleField.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueField.fromJson(json);
    final key = w.key ?? '';
    return RuleField(
      key: key,
      label: _label(w.label, key),
      type: w.type ?? 'text',
      choices: [
        for (final c in w.choices ?? const <api.AutomationCatalogueChoice>[])
          RuleChoice.fromJson(c.json),
      ],
      settable: w.settable ?? true,
    );
  }
}

class RuleLinkSpec {
  final String id;
  final String label;
  final String objectKey;

  const RuleLinkSpec({required this.id, this.label = '', this.objectKey = ''});

  /// Reads an `AutomationCatalogueLink`.
  factory RuleLinkSpec.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueLink.fromJson(json);
    return RuleLinkSpec(
      id: w.id ?? '',
      label: w.label ?? '',
      objectKey: w.objectKey ?? '',
    );
  }
}

class RuleParent {
  final String key;
  final String label;

  const RuleParent({required this.key, this.label = ''});

  /// Reads an `AutomationCatalogueParent`.
  factory RuleParent.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueParent.fromJson(json);
    return RuleParent(key: w.key ?? '', label: w.label ?? '');
  }
}

class AutomationObject {
  final String key;
  final String label;
  final String labelPlural;
  final List<RuleField> fields;
  final RuleParent? parent;
  final List<RuleLinkSpec> links;

  const AutomationObject({
    required this.key,
    required this.label,
    required this.labelPlural,
    this.fields = const [],
    this.parent,
    this.links = const [],
  });

  /// Reads an `AutomationCatalogueObject`.
  factory AutomationObject.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueObject.fromJson(json);
    final key = w.key ?? '';
    final label = _label(w.label, key);
    final parent = w.parent;
    return AutomationObject(
      key: key,
      label: label,
      labelPlural: _label(w.labelPlural, label),
      fields: [
        for (final f in w.fields ?? const <api.AutomationCatalogueField>[])
          RuleField.fromJson(f.json),
      ],
      parent: parent == null ? null : RuleParent.fromJson(parent.json),
      links: [
        for (final l in w.links ?? const <api.AutomationCatalogueLink>[])
          RuleLinkSpec.fromJson(l.json),
      ],
    );
  }
}

/// The answer of `GET /api/automation/catalogue/`.
class AutomationCatalogue {
  final List<AutomationObject> objects;
  final Map<String, List<String>> operators;
  final List<String> updateOnlyOperators;
  final List<String> actions;
  final List<RulePerson> people;
  final List<RuleEndpoint> endpoints;
  final int maxConditions;
  final int maxActions;

  const AutomationCatalogue({
    this.objects = const [],
    this.operators = const {},
    this.updateOnlyOperators = const [],
    this.actions = const [],
    this.people = const [],
    this.endpoints = const [],
    this.maxConditions = 20,
    this.maxActions = 10,
  });

  /// Reads an `AutomationCatalogueResponse`.
  factory AutomationCatalogue.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationCatalogueResponse.fromJson(json);
    return AutomationCatalogue(
      objects: [
        for (final o in w.objects ?? const <api.AutomationCatalogueObject>[])
          AutomationObject.fromJson(o.json),
      ],
      operators: w.operators ?? const {},
      updateOnlyOperators: w.updateOnlyOperators ?? const [],
      actions: w.actions ?? const [],
      people: [
        for (final p in w.people ?? const <api.AutomationCataloguePerson>[])
          RulePerson.fromJson(p.json),
      ],
      endpoints: [
        for (final e
            in w.endpoints ?? const <api.AutomationCatalogueEndpoint>[])
          RuleEndpoint.fromJson(e.json),
      ],
      maxConditions: w.limits?.conditions ?? 20,
      maxActions: w.limits?.actions ?? 10,
    );
  }
}

class TriggerDraft {
  String event;
  String? field;
  dynamic to;

  TriggerDraft({this.event = 'created', this.field, this.to});

  factory TriggerDraft.fromJson(dynamic json) {
    final m = _map(json);
    final field = m['field'];
    return TriggerDraft(
      event: _str(m['event'], 'created'),
      field: field is String ? field : null,
      to: _clone(m['to']),
    );
  }

  TriggerDraft copy() =>
      TriggerDraft(event: event, field: field, to: _clone(to));
}

class ConditionDraft {
  String field;
  String op;
  dynamic value;

  ConditionDraft({this.field = '', this.op = '', this.value});

  factory ConditionDraft.fromJson(Map<String, dynamic> json) => ConditionDraft(
    field: _str(json['field']),
    op: _str(json['op']),
    value: _clone(json['value']),
  );

  ConditionDraft copy() =>
      ConditionDraft(field: field, op: op, value: _clone(value));
}

class ActionDraft {
  String type;
  Map<String, dynamic> values;

  ActionDraft({this.type = '', Map<String, dynamic>? values})
    : values = values ?? <String, dynamic>{};

  factory ActionDraft.fromJson(Map<String, dynamic> json) => ActionDraft(
    type: _str(json['type']),
    values: {
      for (final e in json.entries)
        if (e.key != 'type') e.key: _clone(e.value),
    },
  );

  ActionDraft copy() =>
      ActionDraft(type: type, values: _clone(values) as Map<String, dynamic>);
}

class AutomationRule {
  final String id;
  final String name;
  final String objectKey;
  final TriggerDraft trigger;
  final String match;
  final List<ConditionDraft> conditions;
  final List<ActionDraft> actions;
  final bool isActive;
  final RulePerson? owner;
  final DateTime? switchedOnAt;
  final String pausedReason;

  const AutomationRule({
    required this.id,
    this.name = '',
    this.objectKey = '',
    required this.trigger,
    this.match = 'all',
    this.conditions = const [],
    this.actions = const [],
    this.isActive = false,
    this.owner,
    this.switchedOnAt,
    this.pausedReason = '',
  });

  /// Reads a `Rule`. Its trigger, conditions and actions are free-form JSON
  /// in the schema, so the drafts read those themselves.
  factory AutomationRule.fromJson(Map<String, dynamic> json) {
    final w = api.Rule.fromJson(json);
    final owner = w.owner;
    return AutomationRule(
      id: w.id ?? '',
      name: w.name ?? '',
      objectKey: w.objectKey ?? '',
      trigger: TriggerDraft.fromJson(w.trigger),
      match: w.match ?? 'all',
      conditions: _maps(w.conditions).map(ConditionDraft.fromJson).toList(),
      actions: _maps(w.actions).map(ActionDraft.fromJson).toList(),
      isActive: w.isActive ?? false,
      owner: owner == null ? null : RulePerson.fromJson(owner.json),
      switchedOnAt: DateTime.tryParse(w.switchedOnAt ?? ''),
      pausedReason: w.pausedReason ?? '',
    );
  }
}

/// A rule as `GET rules/` lists it: the detail route carries no status.
class AutomationRuleRow extends AutomationRule {
  final String status;
  final String statusText;
  final int runs7d;
  final int failures7d;

  const AutomationRuleRow({
    required super.id,
    super.name,
    super.objectKey,
    required super.trigger,
    super.match,
    super.conditions,
    super.actions,
    super.isActive,
    super.owner,
    super.switchedOnAt,
    super.pausedReason,
    this.status = 'off',
    this.statusText = '',
    this.runs7d = 0,
    this.failures7d = 0,
  });

  /// Reads a `RuleRow`: a `Rule` with its status and last week's counts.
  factory AutomationRuleRow.fromJson(Map<String, dynamic> json) {
    final rule = AutomationRule.fromJson(json);
    final w = api.RuleRow.fromJson(json);
    return AutomationRuleRow(
      id: rule.id,
      name: rule.name,
      objectKey: rule.objectKey,
      trigger: rule.trigger,
      match: rule.match,
      conditions: rule.conditions,
      actions: rule.actions,
      isActive: rule.isActive,
      owner: rule.owner,
      switchedOnAt: rule.switchedOnAt,
      pausedReason: rule.pausedReason,
      status: w.status ?? 'off',
      statusText: w.statusText ?? '',
      runs7d: w.runs7d ?? 0,
      failures7d: w.failures7d ?? 0,
    );
  }
}

class AutomationRulesAnswer {
  final String? summary;
  final List<AutomationRuleRow> rules;

  const AutomationRulesAnswer({this.summary, this.rules = const []});

  /// Reads an `AutomationRuleListResponse`.
  factory AutomationRulesAnswer.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationRuleListResponse.fromJson(json);
    return AutomationRulesAnswer(
      summary: w.summary,
      rules: [
        for (final r in w.results ?? const <api.RuleRow>[])
          AutomationRuleRow.fromJson(r.json),
      ],
    );
  }
}

class RunStep {
  final int action;
  final String type;
  final String status;
  final String text;

  const RunStep({
    this.action = 0,
    this.type = '',
    this.status = '',
    this.text = '',
  });

  /// Reads an `AutomationStep`.
  factory RunStep.fromJson(Map<String, dynamic> json) {
    final w = api.AutomationStep.fromJson(json);
    return RunStep(
      action: w.action ?? 0,
      type: w.type ?? '',
      status: w.status ?? '',
      text: w.text ?? '',
    );
  }
}

class AutomationRun {
  final String id;
  final DateTime? createdAt;
  final String recordId;
  final String recordName;
  final String objectKey;
  final String status;
  final String reason;
  final List<RunStep> steps;
  final int skippedCount;
  final String? triggeredByRuleName;

  const AutomationRun({
    required this.id,
    this.createdAt,
    this.recordId = '',
    this.recordName = '',
    this.objectKey = '',
    this.status = '',
    this.reason = '',
    this.steps = const [],
    this.skippedCount = 0,
    this.triggeredByRuleName,
  });

  /// Reads a `Run`.
  factory AutomationRun.fromJson(Map<String, dynamic> json) {
    final w = api.Run.fromJson(json);
    final byName = w.triggeredBy?.ruleName ?? '';
    return AutomationRun(
      id: w.id ?? '',
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      recordId: w.recordId ?? '',
      recordName: w.recordName ?? '',
      objectKey: w.objectKey ?? '',
      status: w.status ?? '',
      reason: w.reason ?? '',
      steps: [
        for (final s in w.steps ?? const <api.AutomationStep>[])
          RunStep.fromJson(s.json),
      ],
      skippedCount: w.skippedCount ?? 0,
      triggeredByRuleName: byName.isEmpty ? null : byName,
    );
  }
}

class RunPage {
  final List<AutomationRun> runs;
  final int count;
  final int offset;

  const RunPage({this.runs = const [], this.count = 0, this.offset = 0});

  /// Reads an `AutomationRunListResponse`.
  factory RunPage.fromJson(Map<String, dynamic> json, {int offset = 0}) {
    final w = api.AutomationRunListResponse.fromJson(json);
    final runs = [
      for (final r in w.results ?? const <api.Run>[])
        AutomationRun.fromJson(r.json),
    ];
    return RunPage(runs: runs, count: w.count ?? runs.length, offset: offset);
  }
}

/// The editable form of a rule. Task 2's body builder turns it into JSON.
class RuleDraft {
  String name;
  String objectKey;
  TriggerDraft trigger;
  String match;
  List<ConditionDraft> conditions;
  List<ActionDraft> actions;

  RuleDraft({
    this.name = '',
    required this.objectKey,
    TriggerDraft? trigger,
    this.match = 'all',
    List<ConditionDraft>? conditions,
    List<ActionDraft>? actions,
  }) : trigger = trigger ?? TriggerDraft(),
       conditions = conditions ?? [],
       actions = actions ?? [];

  factory RuleDraft.blank(String objectKey) => RuleDraft(objectKey: objectKey);

  factory RuleDraft.from(AutomationRule rule) => RuleDraft(
    name: rule.name,
    objectKey: rule.objectKey,
    trigger: rule.trigger,
    match: rule.match,
    conditions: rule.conditions,
    actions: rule.actions,
  ).copy();

  RuleDraft copy() => RuleDraft(
    name: name,
    objectKey: objectKey,
    trigger: trigger.copy(),
    match: match,
    conditions: [for (final c in conditions) c.copy()],
    actions: [for (final a in actions) a.copy()],
  );
}

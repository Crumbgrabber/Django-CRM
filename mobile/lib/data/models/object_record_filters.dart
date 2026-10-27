import 'custom_object.dart';

/// What narrows a custom object's record list: the contract of
/// `GET /api/objects/<key>/records/` and of a saved view on `obj:<key>`.
///
/// [fields] holds the raw text of each `cf_<key>` filter. The server types it
/// by the field (a number, `true` or `false`, an option value) and answers 400
/// naming the parameter when it does not fit.
class ObjectRecordFilters {
  const ObjectRecordFilters({
    this.query = '',
    this.assignedTo = const [],
    this.tagIds = const [],
    this.fields = const {},
  });

  final String query;

  /// Member profile ids. "Me" is the viewer's own id, as on every list.
  final List<String> assignedTo;
  final List<String> tagIds;

  /// Field key to the value asked for.
  final Map<String, String> fields;

  /// How many filters besides the search text are on.
  int get count =>
      (assignedTo.isEmpty ? 0 : 1) +
      (tagIds.isEmpty ? 0 : 1) +
      fields.values.where((v) => v.isNotEmpty).length;

  bool get isEmpty => query.isEmpty && count == 0;

  ObjectRecordFilters copyWith({
    String? query,
    List<String>? assignedTo,
    List<String>? tagIds,
    Map<String, String>? fields,
  }) => ObjectRecordFilters(
    query: query ?? this.query,
    assignedTo: assignedTo ?? this.assignedTo,
    tagIds: tagIds ?? this.tagIds,
    fields: fields ?? this.fields,
  );

  /// The list's query parameters, which the export takes unchanged. A `List`
  /// is a repeated parameter.
  Map<String, Object?> toQuery() => {
    if (query.isNotEmpty) 'q': query,
    if (assignedTo.isNotEmpty) 'assigned_to': assignedTo,
    if (tagIds.isNotEmpty) 'tags': tagIds,
    for (final e in fields.entries)
      if (e.value.isNotEmpty) 'cf_${e.key}': e.value,
  };

  /// A saved view's `{param: [value, ...]}` read back. Only the `cf_` keys in
  /// [fieldKeys] are taken, so a view carrying a filter this screen has no
  /// control for opens without it.
  factory ObjectRecordFilters.fromSavedView(
    Map<String, List<String>> view,
    Set<String> fieldKeys,
  ) => ObjectRecordFilters(
    query: view['q']?.firstOrNull ?? '',
    assignedTo: [...?view['assigned_to']],
    tagIds: [...?view['tags']],
    fields: {
      for (final key in fieldKeys)
        if (view['cf_$key']?.firstOrNull case final value?
            when value.isNotEmpty)
          key: value,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is ObjectRecordFilters &&
      other.query == query &&
      _same(other.assignedTo, assignedTo) &&
      _same(other.tagIds, tagIds) &&
      _same(
        [for (final e in other.fields.entries) '${e.key}=${e.value}'],
        [for (final e in fields.entries) '${e.key}=${e.value}'],
      );

  @override
  int get hashCode => Object.hash(
    query,
    Object.hashAll(assignedTo),
    Object.hashAll(tagIds),
    Object.hashAll(fields.entries.map((e) => '${e.key}=${e.value}')),
  );

  static bool _same(List<String> a, List<String> b) {
    final left = [...a]..sort();
    final right = [...b]..sort();
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }
}

/// The `cf_` filters a phone can set on a list: active dropdown (with options)
/// and checkbox fields, the two kinds with a fixed set of answers.
List<ObjectField> filterableFields(ObjectDefinition def) => [
  for (final f in def.customFields)
    if (f.fieldType == 'checkbox' ||
        (f.fieldType == 'dropdown' && f.options.isNotEmpty))
      f,
];

/// Every parameter a saved view on this object's list can use here.
Set<String> objectSavedViewKeys(ObjectDefinition def) => {
  'q',
  'assigned_to',
  'tags',
  for (final f in filterableFields(def)) 'cf_${f.key}',
};

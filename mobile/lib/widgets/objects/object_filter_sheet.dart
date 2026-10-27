import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/theme.dart';
import '../../data/models/custom_object.dart';
import '../../data/models/lookup_models.dart';
import '../../data/models/object_record_filters.dart';
import '../../providers/auth_provider.dart';
import '../../providers/lookup_provider.dart';
import '../forms/multi_select_sheet.dart';

/// Opens the filter sheet over a custom object's list. Answers the filters to
/// show, or null when the sheet was dismissed.
Future<ObjectRecordFilters?> showObjectFilterSheet(
  BuildContext context, {
  required ObjectDefinition definition,
  required ObjectRecordFilters current,
}) => showModalBottomSheet<ObjectRecordFilters>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ObjectFilterSheet(definition: definition, current: current),
);

/// Assignee, tags and the object's dropdown and checkbox fields. The search
/// text stays on the list's own search bar and is carried through unchanged.
class ObjectFilterSheet extends ConsumerStatefulWidget {
  const ObjectFilterSheet({
    super.key,
    required this.definition,
    required this.current,
  });

  final ObjectDefinition definition;
  final ObjectRecordFilters current;

  @override
  ConsumerState<ObjectFilterSheet> createState() => _ObjectFilterSheetState();
}

class _ObjectFilterSheetState extends ConsumerState<ObjectFilterSheet> {
  late ObjectRecordFilters _draft = widget.current;

  /// The viewer's profile id: the users list matched by the signed-in email,
  /// as the web's `resolveMe` does, so a saved view holds the same id on both
  /// apps. Null until the list loads or when nobody matches.
  String? get _meId {
    final email = ref.read(myEmailProvider)?.trim().toLowerCase();
    if (email == null || email.isEmpty) return null;
    for (final u in ref.read(usersProvider)) {
      if (u.email.trim().toLowerCase() == email) return u.id;
    }
    return null;
  }

  bool get _mine {
    final me = _meId;
    return me != null && _draft.assignedTo.contains(me);
  }

  List<String> get _others => [
    for (final id in _draft.assignedTo)
      if (id != _meId) id,
  ];

  void _setField(String key, String value) {
    final next = {..._draft.fields};
    if (value.isEmpty || next[key] == value) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    setState(() => _draft = _draft.copyWith(fields: next));
  }

  Future<void> _pickPeople(List<UserLookup> people) async {
    final picked = await MultiSelectSheet.show<UserLookup>(
      context: context,
      title: 'Assigned to',
      items: people,
      initialSelection: [
        for (final u in people)
          if (_others.contains(u.id)) u,
      ],
      labelOf: (u) => u.displayName,
      searchText: (u) => '${u.displayName} ${u.email}',
      emptyMessage: 'No members',
    );
    if (picked == null) return;
    setState(
      () => _draft = _draft.copyWith(
        assignedTo: [if (_mine) _meId!, for (final u in picked) u.id],
      ),
    );
  }

  Future<void> _pickTags(List<TagLookup> tags) async {
    final picked = await MultiSelectSheet.show<TagLookup>(
      context: context,
      title: 'Tags',
      items: tags,
      initialSelection: [
        for (final t in tags)
          if (_draft.tagIds.contains(t.id)) t,
      ],
      labelOf: (t) => t.name,
      searchText: (t) => t.name,
      emptyMessage: 'No tags',
    );
    if (picked == null) return;
    setState(
      () => _draft = _draft.copyWith(tagIds: [for (final t in picked) t.id]),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(
      text,
      style: AppTypography.label.copyWith(color: AppColors.textSecondary),
    ),
  );

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );

  Widget _pickerTile(IconData icon, String text, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.gray300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppTypography.body)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(usersProvider);
    final tags = ref.watch(tagsProvider);
    final byId = {for (final u in people) u.id: u.displayName};
    final tagById = {for (final t in tags) t.id: t.name};
    final others = _others.map((id) => byId[id] ?? 'Member').join(', ');
    final tagNames = _draft.tagIds.map((id) => tagById[id] ?? 'Tag').join(', ');

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Filters',
                    style: AppTypography.h3.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(LucideIcons.x, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('Assigned to'),
                  if (_meId case final me?) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _chip(
                          'Me',
                          _mine,
                          () => setState(
                            () => _draft = _draft.copyWith(
                              assignedTo: [if (!_mine) me, ..._others],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  _pickerTile(
                    LucideIcons.users,
                    others.isEmpty ? 'Other members' : others,
                    () => _pickPeople(people),
                  ),
                  _label('Tags'),
                  _pickerTile(
                    LucideIcons.tag,
                    tagNames.isEmpty ? 'Any tag' : tagNames,
                    () => _pickTags(tags),
                  ),
                  for (final f in filterableFields(widget.definition)) ...[
                    _label(f.label),
                    if (f.fieldType == 'checkbox')
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _chip(
                            'Yes',
                            _draft.fields[f.key] == 'true',
                            () => _setField(f.key, 'true'),
                          ),
                          _chip(
                            'No',
                            _draft.fields[f.key] == 'false',
                            () => _setField(f.key, 'false'),
                          ),
                        ],
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final o in f.options)
                            _chip(
                              o.label,
                              _draft.fields[f.key] == o.value,
                              () => _setField(f.key, o.value),
                            ),
                          // A saved value that is no longer an option still
                          // narrows the list (the web keeps it too), so it
                          // shows, raw, and a tap clears it.
                          if (_draft.fields[f.key] case final saved?
                              when saved.isNotEmpty &&
                                  !f.options.any((o) => o.value == saved))
                            _chip(saved, true, () => _setField(f.key, saved)),
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(
                        AppLayout.buttonHeightLarge,
                      ),
                    ),
                    onPressed: () => setState(
                      () => _draft = ObjectRecordFilters(query: _draft.query),
                    ),
                    child: const Text('Clear all'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(
                        AppLayout.buttonHeightLarge,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

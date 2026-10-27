import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../data/api/enterprise_schema.g.dart' as enterprise;
import '../data/api/schema.g.dart' as api;
import '../data/models/custom_object.dart';
import '../services/api_service.dart';

enum _CsvKind { contacts, tickets, leads, object }

/// Spreadsheet import for contacts, tickets and leads: preview, then commit.
///
/// The same two-step contract the web speaks (`ImportFlow` for contacts and
/// leads, `TicketImportDrawer` for tickets): one multipart `file` posted to
/// `import/preview/`, which checks every row and writes nothing, then the same
/// bytes posted to `import/commit/`, which checks again and creates the rows in
/// one transaction.
///
/// Contacts and leads also send `mapping` ([CsvImportTarget.usesMapping]):
/// `auto` for the first preview, so the server guesses which column is which,
/// then the person's own choice as JSON. That switches the server to column
/// matching: `.xlsx` as well as `.csv`, any column names, and rows that cannot
/// be imported are skipped and counted rather than refusing the file. Tickets
/// send no `mapping` and keep the template-only import.
///
/// Every rule checked here is a courtesy. The import views decide who may
/// import (`can_mass_import`: admins, superusers and sales access), check the
/// mapping against each module's own fields, cap the size at 5 MB and the rows
/// at 5000, throttle, and scope every write to the caller's org. The checks
/// below only save somebody an upload the server would refuse.
///
/// A target is one of the three built-in lists, or the records of one custom
/// object ([CsvImportTarget.forObject]). Two targets are equal when they import
/// into the same place, so a target is a provider key.
class CsvImportTarget {
  static const contacts = CsvImportTarget._(
    kind: _CsvKind.contacts,
    singular: 'contact',
    plural: 'contacts',
    description:
        "Bring in a spreadsheet of contacts. You'll check how its columns "
        'match, and nothing is written until you choose Import.',
    requiredHeaders: ['first_name', 'last_name'],
    templateHeaders: [
      'first_name',
      'last_name',
      'email',
      'phone',
      'organization',
      'title',
      'department',
      'do_not_call',
      'linkedin_url',
      'address_line',
      'city',
      'state',
      'postcode',
      'country',
      'description',
      'account_name',
      'assigned_emails',
      'team_names',
      'tags',
    ],
    templateExample: [
      'Alice',
      'Smith',
      'alice@acme.test',
      '+1 (555) 123-4567',
      'Acme Corp',
      'VP of Sales',
      'Sales',
      'no',
      'https://linkedin.com/in/alice',
      '500 Main St',
      'Austin',
      'TX',
      '78701',
      'US',
      'Met at SaaStr 2024',
      'Acme Corp',
      'agent@yourco.com',
      'Sales',
      'vip;newsletter',
    ],
  );

  static const tickets = CsvImportTarget._(
    kind: _CsvKind.tickets,
    singular: 'ticket',
    plural: 'tickets',
    description:
        "Upload a CSV of tickets. We'll validate every row before writing "
        'anything. References (account, contacts, assignees) must already '
        'exist in your org.',
    requiredHeaders: ['name', 'status', 'priority'],
    optionalHelp:
        'description, case_type, account_name, contact_emails, '
        'assigned_emails, team_names, tags (semicolon-separated), closed_on '
        '(YYYY-MM-DD).',
    templateHeaders: [
      'name',
      'status',
      'priority',
      'description',
      'case_type',
      'account_name',
      'contact_emails',
      'assigned_emails',
      'team_names',
      'tags',
      'closed_on',
    ],
    templateExample: [
      'Login button broken',
      'New',
      'High',
      'Returns 500 on submit',
      'Incident',
      'Acme Corp',
      'pat@acme.test',
      'agent@yourco.com',
      'Support',
      'auth;urgent',
      '',
    ],
  );

  static const leads = CsvImportTarget._(
    kind: _CsvKind.leads,
    singular: 'lead',
    plural: 'leads',
    description:
        "Bring in a spreadsheet of leads. You'll check how its columns match, "
        'and nothing is written until you choose Import.',
    requiredHeaders: ['first_name', 'last_name'],
    templateHeaders: [
      'first_name',
      'last_name',
      'email',
      'phone',
      'title',
      'company_name',
      'job_title',
      'status',
      'source',
      'rating',
      'opportunity_amount',
      'close_date',
      'description',
      'assigned_emails',
      'team_names',
      'tags',
    ],
    templateExample: [
      'Alice',
      'Smith',
      'alice@acme.test',
      '+1 (555) 123-4567',
      'Enterprise rollout',
      'Acme Corp',
      'VP of Sales',
      'assigned',
      'email',
      'HOT',
      '12000',
      '2026-12-31',
      'Met at SaaStr',
      'agent@yourco.com',
      'Sales',
      'vip;trade-show',
    ],
  );

  const CsvImportTarget._({
    required _CsvKind kind,
    required this.singular,
    required this.plural,
    required this.description,
    required this.requiredHeaders,
    required this.templateHeaders,
    required this.templateExample,
    this.optionalHelp,
    this.objectKey,
    this.fields = const [],
  }) : _kind = kind;

  /// The three built-in targets.
  static const values = [contacts, tickets, leads];

  /// The records of the custom object [key]. The template and the sample line
  /// come from [fields], whose active, non-link members become columns; the
  /// columns a file can be matched to come from the server's preview.
  factory CsvImportTarget.forObject({
    required String key,
    required String label,
    required String labelPlural,
    String nameLabel = 'Name',
    List<ObjectField> fields = const [],
  }) {
    final columns = [
      for (final f in fields)
        if (f.isActive && !f.isLink && !_reservedImportKeys.contains(f.key)) f,
    ]..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    final lowerPlural = labelPlural.toLowerCase();
    return CsvImportTarget._(
      kind: _CsvKind.object,
      objectKey: key,
      fields: columns,
      singular: label.toLowerCase(),
      plural: lowerPlural,
      description:
          'Bring in a spreadsheet of $lowerPlural. You\'ll check how its '
          'columns match, and nothing is written until you choose Import.',
      requiredHeaders: [nameLabel],
      templateHeaders: [
        nameLabel,
        for (final f in columns) f.label,
        'Assigned to',
        'Tags',
      ],
      templateExample: [
        'Example ${label.toLowerCase()}',
        for (final f in columns) _exampleValue(f),
        'agent@yourco.com',
        'vip,featured',
      ],
    );
  }

  final _CsvKind _kind;

  /// The object's key, for a custom object's target.
  final String? objectKey;

  /// The columns a custom object's template and sample line are built from.
  final List<ObjectField> fields;

  @override
  bool operator ==(Object other) =>
      other is CsvImportTarget &&
      other._kind == _kind &&
      other.objectKey == objectKey;

  @override
  int get hashCode => Object.hash(_kind, objectKey);

  final String singular;
  final String plural;

  /// The web's description line, word for word: the ticket drawer's, or the
  /// contacts and leads import dialogs'.
  final String description;

  /// The headers the template-only import refuses a file without, and the
  /// first columns of every template.
  final List<String> requiredHeaders;

  /// The optional headers the template-only "CSV format" help lists, so
  /// tickets only. Contacts and leads take any column names and show no such
  /// list, as on the web.
  final String? optionalHelp;

  /// One header row and one example row, the same file the web's "Download a
  /// template" produces.
  final List<String> templateHeaders;
  final List<String> templateExample;

  /// Whether the import matches columns (`mapping`), which takes `.xlsx` too.
  /// Tickets keep the template-only import, `.csv` only.
  bool get usesMapping => _kind != _CsvKind.tickets;

  String get _moduleUrl => switch (_kind) {
    _CsvKind.contacts => ApiConfig.contacts,
    _CsvKind.tickets => ApiConfig.tickets,
    _CsvKind.leads => ApiConfig.leads,
    _CsvKind.object => ApiConfig.objectRecords(objectKey ?? ''),
  };

  String get previewUrl => ApiConfig.csvImportPreview(_moduleUrl);
  String get commitUrl => ApiConfig.csvImportCommit(_moduleUrl);

  /// A custom object's file is named by its key, as the web's is.
  String get templateFileName => '${objectKey ?? plural}-import-template.csv';

  /// The name the web drawer gives its "Download errors" file.
  String get errorsFileName => '$plural-import-errors.csv';

  /// The name the web's "Download skipped rows" gives its file.
  String get skippedFileName => '$plural-skipped-rows.csv';

  /// One valid row of a preview as the web drawer's sample table shows it:
  /// the name, then the other columns it prints, blanks left out. The row is
  /// this module's `valid[]` item: a `ContactImportRow`, `CaseImportValidRow`
  /// or `LeadImportRow`.
  ({String title, String details}) sampleLine(Map<String, dynamic> row) {
    String text(String? value) => value?.trim() ?? '';
    final List<String> details;
    final String title;
    switch (_kind) {
      case _CsvKind.contacts:
        final r = api.ContactImportRow.fromJson(row);
        title = '${text(r.firstName)} ${text(r.lastName)}'.trim();
        details = [text(r.email), text(r.phone), text(r.organization)];
      case _CsvKind.tickets:
        final r = api.CaseImportValidRow.fromJson(row);
        title = text(r.name);
        details = [
          text(r.status),
          text(r.priority),
          if (r.accountId != null) 'account linked',
        ];
      case _CsvKind.leads:
        final r = api.LeadImportRow.fromJson(row);
        title = '${text(r.firstName)} ${text(r.lastName)}'.trim();
        details = [text(r.email), text(r.companyName), text(r.status)];
      case _CsvKind.object:
        final r = enterprise.CustomRecordImportRow.fromJson(row);
        title = text(r.name);
        final values = r.customFields;
        details = [
          for (final f in fields)
            if (values != null && hasFieldValue(values[f.key]))
              displayValue(f, values[f.key]),
        ].take(3).toList();
    }
    return (
      title: title.isEmpty ? 'Unnamed' : title,
      details: details.where((d) => d.isNotEmpty).join(' \u00b7 '),
    );
  }

  /// The file's row number of one valid row (see [sampleLine]), if it says.
  int? sampleRow(Map<String, dynamic> row) => switch (_kind) {
    _CsvKind.contacts => api.ContactImportRow.fromJson(row).row,
    _CsvKind.tickets => api.CaseImportValidRow.fromJson(row).row,
    _CsvKind.leads => api.LeadImportRow.fromJson(row).row,
    _CsvKind.object => enterprise.CustomRecordImportRow.fromJson(row).row,
  };

  /// The template as CSV text, quoting a cell only when it holds a comma, as
  /// the web does.
  String get templateCsv => [
    templateHeaders.join(','),
    templateExample.map((v) => v.contains(',') ? '"$v"' : v).join(','),
  ].join('\n');

  String noun(int count) => count == 1 ? singular : plural;
}

/// Field keys the server never takes as import targets: they would collide
/// with the name, assignee and tags columns (and `full_name`).
const _reservedImportKeys = {'name', 'assigned_to', 'tags', 'full_name'};

/// A cell for a custom field's column in the template, by its type.
String _exampleValue(ObjectField f) {
  switch (f.fieldType) {
    case 'number':
      return '3';
    case 'checkbox':
      return 'Yes';
    case 'date':
      return '2026-12-31';
    case 'textarea':
      return 'A longer note';
    case 'dropdown':
      return f.options.isEmpty ? '' : f.options.first.label;
    default:
      return 'Example';
  }
}

/// Mirrors `MAX_UPLOAD_BYTES` in the three import views.
const int csvImportMaxBytes = 5 * 1024 * 1024;

/// The web's wording for a 403 (`frontend/src/lib/server/v2/csv-import.ts`),
/// kept identical so both clients say the same thing.
const String csvImportForbiddenMessage =
    'Importing needs an admin, or a member with sales access.';

/// The web's wording for a 429 from the per-user import throttle.
const String csvImportThrottledMessage =
    'Too many tries in a minute. Wait a moment, then try again.';

/// The web's wording for a 413: a proxy refused the upload for its size
/// before the API saw it, so the body is the proxy's own HTML page.
const String csvImportTooLargeMessage =
    'This file is too large to upload. Split it into smaller files.';

/// The server's own sentence for a file that is neither `.xlsx` nor `.csv`.
const String csvImportFileTypeMessage =
    'Save it as .xlsx or .csv and try again.';

/// Shown when no column matched any field, which usually means the first row
/// of the sheet is a title rather than the column names. The web's wording.
const String csvImportNoMatchHint =
    "We couldn't match any columns. Make sure the first row of your sheet "
    'holds the column names.';

/// How long a column change waits for the next one before the preview is
/// asked again. Preview and commit share a per-user throttle of 30 a minute.
const Duration csvImportDebounce = Duration(milliseconds: 400);

/// A picked file, held as bytes so the commit sends exactly what was
/// previewed.
class CsvImportFile {
  const CsvImportFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// One problem with one row of a template-only import. `row` is 1-based and
/// matches the data rows of the file (the header is row 0).
class CsvRowError {
  const CsvRowError({
    required this.row,
    required this.field,
    required this.message,
  });

  /// Reads a `LeadImportRowError`; the contacts and tickets ones are the
  /// same shape.
  factory CsvRowError.fromJson(Map<String, dynamic> json) {
    final w = api.LeadImportRowError.fromJson(json);
    return CsvRowError(
      row: w.row ?? 0,
      field: w.field ?? '',
      message: w.message ?? '',
    );
  }

  final int row;
  final String field;
  final String message;
}

/// One column of the file, as the server read it: its position, its header,
/// the field it is matched to (null for "Don't import") and up to three
/// values from it.
class CsvImportColumn {
  const CsvImportColumn({
    required this.index,
    required this.header,
    required this.field,
    required this.samples,
  });

  /// Reads an `ImportColumn`.
  factory CsvImportColumn.fromJson(Map<String, dynamic> json) {
    final w = api.ImportColumn.fromJson(json);
    return CsvImportColumn(
      index: w.index ?? 0,
      header: w.header ?? '',
      field: w.field,
      samples: w.samples ?? const [],
    );
  }

  final int index;
  final String header;
  final String? field;
  final List<String> samples;

  CsvImportColumn withField(String? field) => CsvImportColumn(
    index: index,
    header: header,
    field: field,
    samples: samples,
  );
}

/// A field a column can be matched to, from the module's own list.
class CsvImportField {
  const CsvImportField({
    required this.name,
    required this.label,
    required this.required,
  });

  /// Reads an `ImportField`.
  factory CsvImportField.fromJson(Map<String, dynamic> json) {
    final w = api.ImportField.fromJson(json);
    return CsvImportField(
      name: w.name ?? '',
      label: w.label ?? '',
      required: w.required_ == true,
    );
  }

  final String name;
  final String label;
  final bool required;
}

/// A row the import leaves out, with its own cells so it can be saved, fixed
/// and uploaded again. [kind] is `duplicate` (the record is already in the
/// org, or earlier in the file) or `row` (the row cannot become a record).
/// The helpers below read [kind]; [message] is for people.
///
/// [cells] are the file's own text, shown nowhere but the saved file, where
/// each cell is formula-guarded.
class CsvSkippedRow {
  const CsvSkippedRow({
    required this.row,
    required this.field,
    required this.message,
    required this.cells,
    required this.kind,
  });

  /// Reads an `ImportSkippedRow`.
  factory CsvSkippedRow.fromJson(Map<String, dynamic> json) {
    final w = api.ImportSkippedRow.fromJson(json);
    return CsvSkippedRow(
      row: w.row ?? 0,
      field: w.field ?? '',
      message: w.message ?? '',
      cells: w.cells ?? const [],
      kind: w.kind ?? '',
    );
  }

  final int row;
  final String field;
  final String message;
  final List<String> cells;
  final String kind;
}

List<T> _objects<T>(Object? raw, T Function(Map<String, dynamic>) read) =>
    raw is List
    ? raw.whereType<Map<String, dynamic>>().map(read).toList(growable: false)
    : const [];

List<CsvRowError> _rowErrors(Object? raw) =>
    _objects(raw, CsvRowError.fromJson);

List<CsvSkippedRow> _skippedRows(Object? raw) =>
    _objects(raw, CsvSkippedRow.fromJson);

/// `dropped` as the server sends it, `[{field, count}]`, keyed by field in the
/// server's order.
Map<String, int> _droppedCounts(List<api.ImportDropped>? rows) => {
  for (final d in rows ?? const <api.ImportDropped>[])
    d.field ?? '': d.count ?? 0,
};

/// One cell of a CSV this app writes, with the two rules the web
/// (`frontend/src/lib/utils/csv.ts`) and the server's exports
/// (`common/csv_export.py`) apply: a cell a spreadsheet would run as a formula
/// is prefixed with `'`, since a message can quote the value that was refused
/// and a skipped row carries the file's own cells; and a cell holding a quote,
/// comma or line break is quoted, quotes doubled.
String _csvCell(String value) {
  const formula = ['=', '+', '-', '@', '\t', '\r'];
  final trimmed = value.trimLeft();
  if (formula.any(value.startsWith) || formula.any(trimmed.startsWith)) {
    value = "'$value";
  }
  return RegExp(r'[",\r\n]').hasMatch(value)
      ? '"${value.replaceAll('"', '""')}"'
      : value;
}

/// A preview's or a commit's row errors as the CSV the web drawer's
/// "Download errors" saves: `row,field,message`, one line per error.
String csvImportErrorsCsv(List<CsvRowError> errors) => [
  'row,field,message',
  for (final e in errors)
    ['${e.row}', e.field, e.message].map(_csvCell).join(','),
].join('\n');

/// The skipped rows as a CSV to fix and upload again, the web's
/// `skippedRowsCsv`: the file's own headers and cells, plus a `Reason` column.
/// Short rows are padded so the reason always lands under `Reason`.
String csvSkippedRowsCsv(List<String> headers, List<CsvSkippedRow> rows) {
  final width = rows.fold(
    headers.length,
    (w, r) => r.cells.length > w ? r.cells.length : w,
  );
  List<String> pad(List<String> cells) =>
      List.generate(width, (i) => i < cells.length ? cells[i] : '');
  return [
    [...pad(headers), 'Reason'],
    for (final r in rows) [...pad(r.cells), r.message],
  ].map((cells) => cells.map(_csvCell).join(',')).join('\n');
}

/// Put [field] on the column at [index]. A field goes to one column only, so
/// a column that already held it becomes "Don't import" (null). The web's
/// `setColumnField`; [columns] is not changed.
List<CsvImportColumn> csvSetColumnField(
  List<CsvImportColumn> columns,
  int index,
  String? field,
) => [
  for (final c in columns)
    if (c.index == index)
      c.withField(field)
    else if (field != null && c.field == field)
      c.withField(null)
    else
      c,
];

/// The `mapping` form field for an explicit choice: `{"<index>": field}`,
/// null for "Don't import". The web's `mappingPayload`, byte for byte.
String csvMappingPayload(List<CsvImportColumn> columns) =>
    jsonEncode({for (final c in columns) '${c.index}': c.field});

/// Whether any column is matched to a field. The web's `hasAnyMatch`.
bool csvHasAnyMatch(List<CsvImportColumn> columns) =>
    columns.any((c) => c.field != null);

/// One sentence per field whose values were dropped, named by its label.
/// The web's `droppedLines`.
List<String> csvDroppedLines(
  Map<String, int> dropped,
  List<CsvImportField> fields,
) {
  final labels = {for (final f in fields) f.name: f.label};
  return [
    for (final MapEntry(key: field, value: count) in dropped.entries)
      count == 1
          ? "${labels[field] ?? field}: 1 value we couldn't use was left blank."
          : "${labels[field] ?? field}: $count values we couldn't use were "
                'left blank.',
  ];
}

/// The sentence above the Import button: what importing this file will do.
/// The web's `summaryLine`, sentence for sentence.
String csvImportSummaryLine(CsvImportTarget target, CsvImportPreview preview) {
  final total = preview.total;
  final valid = preview.valid;
  final skipped = preview.skippedCount;
  final duplicates =
      preview.skipped.isNotEmpty &&
      preview.skipped.every((s) => s.kind == 'duplicate');
  if (valid == 0) {
    if (total == 0) return 'This file has no rows to import.';
    // With nothing importable there is no earlier row to duplicate, so every
    // duplicate here is a record already in the org.
    if (duplicates) return 'Everything in this file is already in BottleCRM.';
    return 'Nothing in this file can be imported.';
  }
  final head = '$valid ${target.noun(valid)} will be imported';
  if (skipped == 0) return '$head.';
  final rows = skipped == 1 ? 'row' : 'rows';
  if (duplicates) {
    return '$head, and $skipped duplicate $rows will be skipped.';
  }
  return '$head, and $skipped $rows will be skipped.';
}

/// Whether to offer importing the file as leads instead: a contact needs a
/// first and a last name, a lead only one. A name skipped as a duplicate does
/// not count, since importing it as a lead would duplicate the person. The
/// web's `suggestLeads`, decided by `kind` and `field`, never by the message.
bool csvSuggestLeads(CsvImportTarget target, List<CsvSkippedRow> skipped) =>
    target == CsvImportTarget.contacts &&
    skipped.any(
      (s) =>
          s.kind == 'row' &&
          (s.field == 'first_name' || s.field == 'last_name'),
    );

/// What `import/preview/` answered, in either shape.
///
/// The template-only shape (tickets, or a server older than column matching)
/// carries [headerError], [errors] and [invalid]. The column-matching shape
/// carries [columns], [fields], [skipped], [dropped] and [skippedCount]; that
/// is what [mapped] tells apart.
class CsvImportPreview {
  const CsvImportPreview({
    required this.total,
    required this.valid,
    required this.invalid,
    required this.errors,
    this.validRows = const [],
    this.headerError,
    this.columns,
    this.fields = const [],
    this.skipped = const [],
    this.dropped = const {},
    this.skippedCount = 0,
  });

  /// Reads a `LeadImportPreviewResponse`, which is one of two shapes:
  /// `LeadImportTemplatePreview` (the shape `CaseImportPreviewResponse` has
  /// too) or `LeadImportMappedPreview`. The contacts ones match field for
  /// field.
  factory CsvImportPreview.fromJson(Map<String, dynamic> json) {
    final template = api.LeadImportTemplatePreview.fromJson(json);
    final mapped = api.LeadImportMappedPreview.fromJson(json);
    final headerError = template.headerError;
    final columns = mapped.columns;
    return CsvImportPreview(
      total: template.summary?.total ?? 0,
      valid: template.summary?.valid ?? 0,
      invalid: template.summary?.invalid ?? 0,
      errors: [
        for (final e in template.errors ?? const <api.LeadImportRowError>[])
          CsvRowError.fromJson(e.json),
      ],
      validRows: [
        for (final row in template.valid ?? const <api.LeadImportRow>[])
          row.json,
      ],
      headerError: (headerError == null || headerError.isEmpty)
          ? null
          : headerError,
      columns: columns == null
          ? null
          : [for (final c in columns) CsvImportColumn.fromJson(c.json)],
      fields: [
        for (final f in mapped.fields ?? const <api.ImportField>[])
          CsvImportField.fromJson(f.json),
      ],
      skipped: [
        for (final r in mapped.skipped ?? const <api.ImportSkippedRow>[])
          CsvSkippedRow.fromJson(r.json),
      ],
      dropped: _droppedCounts(mapped.dropped),
      skippedCount: mapped.summary?.skipped ?? 0,
    );
  }

  final int total;
  final int valid;
  final int invalid;
  final List<CsvRowError> errors;

  /// The rows that would import, each as the import view parsed it, for the
  /// sample the template-only sheet shows.
  final List<Map<String, dynamic>> validRows;

  /// Set when the file as a whole could not be read: missing or unknown
  /// headers, too many rows, not UTF-8. No row is checked in that case.
  final String? headerError;

  /// The columns as the server matched them, null in the template-only
  /// shape.
  final List<CsvImportColumn>? columns;
  final List<CsvImportField> fields;
  final List<CsvSkippedRow> skipped;

  /// Values left blank because they could not be used, counted per field in
  /// the server's order.
  final Map<String, int> dropped;
  final int skippedCount;

  bool get mapped => columns != null;

  /// What a mapped commit that found nothing importable reports: its own
  /// skipped rows in place of the preview's, so the summary says why.
  CsvImportPreview withOnlySkipped(List<CsvSkippedRow> rows) =>
      CsvImportPreview(
        total: rows.length,
        valid: 0,
        invalid: 0,
        errors: const [],
        columns: columns,
        fields: fields,
        skipped: rows,
        skippedCount: rows.length,
      );
}

/// What a successful commit reported, the web `ImportFlow`'s `result`. A
/// column-matching commit also says which rows it left out and which values
/// it left blank, which can differ from the preview's if the org's records
/// changed in between. A template-only commit refuses rather than skips, so
/// it reports neither.
class CsvImportResult {
  const CsvImportResult({
    required this.created,
    this.skipped = const [],
    this.dropped = const {},
  });

  /// Reads a `LeadImportCommitResponse`; the contacts and tickets ones are
  /// the same shape.
  factory CsvImportResult.fromJson(Map<String, dynamic> json) {
    final w = api.LeadImportCommitResponse.fromJson(json);
    return CsvImportResult(
      created: w.created ?? 0,
      skipped: [
        for (final row in w.skipped ?? const <api.ImportSkippedRow>[])
          CsvSkippedRow.fromJson(row.json),
      ],
      dropped: _droppedCounts(w.dropped),
    );
  }

  final int created;
  final List<CsvSkippedRow> skipped;
  final Map<String, int> dropped;
}

class CsvImportState {
  const CsvImportState({
    this.file,
    this.preview,
    this.columns = const [],
    this.previewed,
    this.busy = false,
    this.committing = false,
    this.error,
    this.commitErrors = const [],
    this.result,
  });

  final CsvImportFile? file;
  final CsvImportPreview? preview;

  /// The column choice on screen. It changes at once when someone picks a
  /// field; [preview] catches up after the debounce.
  final List<CsvImportColumn> columns;

  /// The `mapping` the shown [preview] was computed for, null for a
  /// template-only import.
  final String? previewed;

  /// A preview or a commit is in flight.
  final bool busy;

  /// The commit is in flight: the column choice is locked until it answers.
  final bool committing;
  final String? error;

  /// Rows a template-only commit refused, which happens only if the file or
  /// the org's data changed after the preview passed.
  final List<CsvRowError> commitErrors;

  /// Set once a commit succeeds. The preview and the columns are kept beside
  /// it, for the field labels and the file's headers.
  final CsvImportResult? result;

  List<CsvImportField> get fields => preview?.fields ?? const [];

  /// The preview's skipped rows and blanked values; a commit's own are in
  /// [result].
  List<CsvSkippedRow> get skipped => preview?.skipped ?? const [];
  Map<String, int> get dropped => preview?.dropped ?? const {};

  /// The choice on screen is not the one the preview shows, so the preview's
  /// counts are not yet true of it.
  bool get stale =>
      previewed != null && csvMappingPayload(columns) != previewed;

  /// The template-only commit refuses the whole file when any row fails
  /// (`commit_rows`: "Fix the invalid rows before importing"), so a preview
  /// with row errors cannot be committed either. A column-matching import
  /// skips the rows that cannot go in and imports the rest, so it only needs
  /// something importable and a preview of the choice on screen. Both are
  /// the web's Import button.
  bool get canCommit {
    final p = preview;
    if (busy || file == null || p == null || p.valid <= 0) return false;
    if (p.mapped) return !stale;
    return p.headerError == null && p.errors.isEmpty;
  }
}

class CsvImportNotifier extends Notifier<CsvImportState> {
  CsvImportNotifier(this.target);

  final CsvImportTarget target;
  final ApiService _api = ApiService();

  /// Bumped by every request and every fresh start. A reply whose number is
  /// no longer the latest is for a choice somebody has since changed, and is
  /// dropped, as the web's `seq` does.
  int _seq = 0;
  Timer? _debounce;
  Completer<void>? _pending;

  @override
  CsvImportState build() {
    ref.onDispose(_cancelPending);
    return const CsvImportState();
  }

  /// Take a file from the picker and preview it straight away. `null` is the
  /// picker being closed and changes nothing.
  ///
  /// The client-side half of reading the upload: the extension and the size
  /// are checked on what the picker reports before anything is read, so a
  /// large file is refused without loading it, and the size again on the
  /// bytes.
  Future<void> choose(PlatformFile? picked) async {
    if (picked == null) return;
    _cancelPending();
    _seq++;
    // `lengthSync` is what the picker reported, without I/O. Unknown counts
    // as 0 here; the bytes are checked again below either way.
    final early = _refuse(picked.name, picked.lengthSync() ?? 0);
    if (early != null) {
      state = CsvImportState(error: early);
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      if (ref.mounted) {
        state = const CsvImportState(
          error: 'That file could not be read. Try picking it again.',
        );
      }
      return;
    }
    if (!ref.mounted) return;
    final refusal = bytes.isEmpty
        ? (target.usesMapping ? 'Choose a file.' : 'Choose a CSV file.')
        : _refuse(picked.name, bytes.length);
    if (refusal != null) {
      state = CsvImportState(error: refusal);
      return;
    }
    await useFile(CsvImportFile(name: picked.name, bytes: bytes));
  }

  /// Preview [file] from the start. Also how a contacts file goes in as leads
  /// instead: the leads import is handed the bytes the contacts one read, and
  /// the server guesses its columns afresh.
  Future<void> useFile(CsvImportFile file) async {
    _cancelPending();
    _seq++;
    state = CsvImportState(file: file);
    await _preview(target.usesMapping ? 'auto' : null);
  }

  String? _refuse(String name, int size) {
    final lower = name.toLowerCase();
    if (target.usesMapping) {
      if (!lower.endsWith('.csv') && !lower.endsWith('.xlsx')) {
        return csvImportFileTypeMessage;
      }
    } else if (!lower.endsWith('.csv')) {
      return '$name is not a CSV file. Choose a file ending in .csv.';
    }
    if (size > csvImportMaxBytes) {
      final mb = (size / (1024 * 1024)).toStringAsFixed(1);
      final what = target.usesMapping ? 'Files' : 'CSV files';
      return '$name is $mb MB. $what must be 5 MB or smaller.';
    }
    return null;
  }

  /// Match the column at [index] to [field] (null for "Don't import"), the
  /// way the web's `setColumnField` does, then ask for the preview again once
  /// the changes stop for [csvImportDebounce]. The returned future completes
  /// when that preview has answered, or straight away when a later change
  /// takes its place. Nothing changes while the commit runs.
  Future<void> setColumnField(int index, String? field) {
    final current = state;
    if (current.preview == null || current.previewed == null) {
      return Future.value();
    }
    if (current.committing) return Future.value();
    // A new choice replaces whatever the last failed preview said.
    state = _keep(
      columns: csvSetColumnField(current.columns, index, field),
      busy: current.busy,
    );
    _debounce?.cancel();
    final superseded = _pending;
    final done = _pending = Completer<void>();
    if (superseded != null && !superseded.isCompleted) superseded.complete();
    _debounce = Timer(csvImportDebounce, () async {
      final mapping = csvMappingPayload(state.columns);
      // A request still in flight was for another choice; this one replaces
      // it.
      if (mapping != state.previewed || state.busy) await _preview(mapping);
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  /// Ask again for the preview of the choice on screen, after one failed.
  Future<void> retryPreview() => _preview(csvMappingPayload(state.columns));

  /// [mapping] is `auto`, an explicit choice, or null for a template-only
  /// import.
  Future<void> _preview(String? mapping) async {
    final file = state.file;
    if (file == null) return;
    final mine = ++_seq;
    state = _keep(busy: true);
    final response = await _upload(target.previewUrl, file, mapping);
    if (!ref.mounted || mine != _seq) return;
    final body = response.data;
    if (!response.success || body == null) {
      state = _keep(error: _failureMessage(response, 'Preview failed'));
      return;
    }
    final preview = CsvImportPreview.fromJson(body);
    final guessed = mapping == 'auto';
    final columns = guessed ? (preview.columns ?? const []) : state.columns;
    state = CsvImportState(
      file: file,
      preview: preview,
      columns: columns,
      previewed: guessed ? csvMappingPayload(columns) : mapping,
    );
  }

  /// Send the previewed bytes again, with the choice the preview showed.
  /// Returns whether rows were created; what the server reported is then in
  /// [CsvImportState.result].
  Future<bool> commit() async {
    if (!state.canCommit) return false;
    _cancelPending();
    _seq++;
    final file = state.file!;
    final preview = state.preview!;
    final mapping = state.previewed;
    state = _keep(busy: true, committing: true);
    final response = await _upload(target.commitUrl, file, mapping);
    if (!ref.mounted) return false;
    final body = response.data;
    if (response.success && body != null) {
      state = _keep(result: CsvImportResult.fromJson(body));
      return true;
    }
    final skipped = _skippedRows(body?['skipped']);
    if (preview.mapped && skipped.isNotEmpty) {
      // Nothing was importable after all, e.g. the records arrived since the
      // preview. Show the commit's own account; the summary line says why.
      state = _keep(preview: preview.withOnlySkipped(skipped));
      return false;
    }
    state = _keep(
      error: _failureMessage(response, 'Import failed'),
      commitErrors: _rowErrors(body?['errors']),
    );
    return false;
  }

  /// Back to an empty sheet, to pick a corrected file.
  void reset() {
    _cancelPending();
    _seq++;
    state = const CsvImportState();
  }

  /// The file, the preview and the column choice as they are, with the rest
  /// given anew.
  CsvImportState _keep({
    CsvImportPreview? preview,
    List<CsvImportColumn>? columns,
    bool busy = false,
    bool committing = false,
    String? error,
    List<CsvRowError> commitErrors = const [],
    CsvImportResult? result,
  }) => CsvImportState(
    file: state.file,
    preview: preview ?? state.preview,
    columns: columns ?? state.columns,
    previewed: state.previewed,
    busy: busy,
    committing: committing,
    error: error,
    commitErrors: commitErrors,
    result: result,
  );

  void _cancelPending() {
    _debounce?.cancel();
    _debounce = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<ApiResponse<Map<String, dynamic>>> _upload(
    String url,
    CsvImportFile file,
    String? mapping,
  ) => _api.postMultipart(
    url,
    fileField: 'file',
    fileBytes: file.bytes,
    fileName: file.name,
    fields: mapping == null ? const {} : {'mapping': mapping},
  );

  /// The web's mapping (`forwardCsvImport`, and `ImportFlow`'s 413): a 403,
  /// a 413 and a 429 get their own sentences, anything else the server's
  /// `message`, then its
  /// `header_error`. A network failure has neither and keeps ApiService's own
  /// message.
  String _failureMessage(
    ApiResponse<Map<String, dynamic>> response,
    String fallback,
  ) {
    if (response.statusCode == 403) return _forbiddenMessage(response.data);
    if (response.statusCode == 413) return csvImportTooLargeMessage;
    if (response.statusCode == 429) return csvImportThrottledMessage;
    final body = response.data;
    for (final key in const ['message', 'header_error']) {
      final value = body?[key];
      if (value is String && value.isNotEmpty) return value;
    }
    if (response.statusCode == 0 && response.message != null) {
      return response.message!;
    }
    return fallback;
  }
}

/// A 403 shows the server's `detail` sentence (the import permission, or the
/// plan not including custom objects), else the fixed permission sentence.
String _forbiddenMessage(Map<String, dynamic>? body) {
  final detail = body?['detail'];
  if (detail is String && detail.trim().isNotEmpty) return detail;
  return csvImportForbiddenMessage;
}

/// One import per module, discarded when its sheet closes, so reopening the
/// sheet starts empty as the web dialog does.
final csvImportProvider = NotifierProvider.autoDispose
    .family<CsvImportNotifier, CsvImportState, CsvImportTarget>(
      CsvImportNotifier.new,
    );

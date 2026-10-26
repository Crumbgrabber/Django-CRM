import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../data/api/schema.g.dart' as api;
import '../services/api_service.dart';
import 'accounts_provider.dart';
import 'contacts_provider.dart';
import 'leads_provider.dart';

/// Possible duplicates and merging, for leads, contacts and accounts (G19).
///
/// The API decides everything that matters. It searches only the records the
/// caller may open, so nothing here can show or count a hidden one, and it
/// refuses a merge the caller may not make. `canDelete` on a hit is a hint that
/// spares somebody a refusal, not a gate.
enum DuplicateModule {
  leads('leads', 'lead'),
  contacts('contacts', 'contact'),
  accounts('accounts', 'account');

  const DuplicateModule(this.path, this.singular);

  /// The API and router segment: `/leads/...`.
  final String path;
  final String singular;

  /// The id and the row the detail response nests under `lead_obj`,
  /// `contact_obj` or `account_obj`, or null if it carries none.
  (String?, Map<String, dynamic>)? _recordIn(Map<String, dynamic> body) {
    switch (this) {
      case leads:
        final row = api.LeadDetailResponse.fromJson(body).leadObj;
        return row == null ? null : (row.id, row.json);
      case contacts:
        final row = api.ContactDetailResponse.fromJson(body).contactObj;
        return row == null ? null : (row.id, row.json);
      case accounts:
        final row = api.AccountDetailResponse.fromJson(body).accountObj;
        return row == null ? null : (row.id, row.json);
    }
  }

  static DuplicateModule? parse(String? value) {
    for (final module in values) {
      if (module.path == value) return module;
    }
    return null;
  }

  /// What each create form may ask about. Mirrors `DuplicateQuerySerializer`.
  List<String> get queryFields => switch (this) {
    leads => const [
      'email',
      'phone',
      'first_name',
      'last_name',
      'company_name',
    ],
    contacts => const ['email', 'phone', 'first_name', 'last_name'],
    accounts => const ['name', 'email', 'phone', 'website'],
  };

  /// The rows the compare screen shows side by side, the same as the web's.
  /// Each reads the module's detail row: a `Lead`, `Contact` or `Account`.
  List<(String, String Function(Map<String, dynamic>))> get compareFields =>
      switch (this) {
        leads => [
          ('Name', _lead((l) => _personName(l.firstName, l.lastName))),
          ('Company', _lead((l) => l.companyName)),
          ('Email', _lead((l) => l.email)),
          ('Phone', _lead((l) => l.phone)),
          ('Website', _lead((l) => l.website)),
          ('Status', _lead((l) => l.status)),
          ('Created', _lead((l) => _day(l.createdAt))),
        ],
        contacts => [
          ('Name', _contact((c) => _personName(c.firstName, c.lastName))),
          ('Job title', _contact((c) => c.title)),
          ('Company', _contact((c) => c.organization)),
          ('Email', _contact((c) => c.email)),
          ('Phone', _contact((c) => c.phone)),
          ('City', _contact((c) => c.city)),
          ('Created', _contact((c) => _day(c.createdAt))),
        ],
        accounts => [
          ('Name', _account((a) => a.name)),
          ('Website', _account((a) => a.website)),
          ('Email', _account((a) => a.email)),
          ('Phone', _account((a) => a.phone)),
          ('Industry', _account((a) => a.industry)),
          ('City', _account((a) => a.city)),
          ('Created', _account((a) => _day(a.createdAt))),
        ],
      };

  String nameOf(Map<String, dynamic> record) {
    final String name;
    final String email;
    switch (this) {
      case leads:
        final l = api.Lead.fromJson(record);
        name = _personName(l.firstName, l.lastName);
        email = _text(l.email);
      case contacts:
        final c = api.Contact.fromJson(record);
        name = _personName(c.firstName, c.lastName);
        email = _text(c.email);
      case accounts:
        final a = api.Account.fromJson(record);
        name = _text(a.name);
        email = _text(a.email);
    }
    if (name.isNotEmpty) return name;
    return email.isNotEmpty ? email : singular;
  }
}

String Function(Map<String, dynamic>) _lead(String? Function(api.Lead) read) =>
    (o) => _text(read(api.Lead.fromJson(o)));

String Function(Map<String, dynamic>) _contact(
  String? Function(api.Contact) read,
) =>
    (o) => _text(read(api.Contact.fromJson(o)));

String Function(Map<String, dynamic>) _account(
  String? Function(api.Account) read,
) =>
    (o) => _text(read(api.Account.fromJson(o)));

String _text(String? value) => value?.trim() ?? '';

String _personName(String? first, String? last) =>
    [_text(first), _text(last)].where((s) => s.isNotEmpty).join(' ');

String _day(String? raw) {
  final text = _text(raw);
  return text.length >= 10 ? text.substring(0, 10) : text;
}

/// "email and phone": the API names each rule in plain words already.
String matchedLabel(List<String> reasons) {
  if (reasons.length <= 1) return reasons.join();
  return '${reasons.sublist(0, reasons.length - 1).join(', ')} and ${reasons.last}';
}

/// One possible duplicate. List-level fields only, which is all the API sends.
class DuplicateHit {
  const DuplicateHit({
    required this.id,
    required this.name,
    this.email = '',
    this.phone = '',
    this.matchedOn = const [],
    this.canDelete = false,
  });

  final String id;
  final String name;
  final String email;
  final String phone;
  final List<String> matchedOn;

  /// Whether the caller could merge this record away.
  final bool canDelete;

  String get matchedLabelText => matchedLabel(matchedOn);

  /// Reads a `DuplicateHit`.
  factory DuplicateHit.fromJson(Map<String, dynamic> json) {
    final w = api.DuplicateHit.fromJson(json);
    return DuplicateHit(
      id: w.id ?? '',
      name: _text(w.name),
      email: _text(w.email),
      phone: _text(w.phone),
      matchedOn: w.matchedOn ?? const [],
      canDelete: w.canDelete == true,
    );
  }
}

class RecordDuplicates {
  const RecordDuplicates({this.canDelete = false, this.hits = const []});

  /// Whether the caller could merge the record itself away.
  final bool canDelete;
  final List<DuplicateHit> hits;
}

/// One side of the compare screen.
class MergeSide {
  const MergeSide({
    required this.id,
    required this.name,
    required this.canDelete,
    required this.fields,
  });

  final String id;
  final String name;
  final bool canDelete;
  final List<(String, String)> fields;
}

/// A merge side that could not be loaded. `notFound` covers a missing record
/// and one the caller may not open, which the API answers identically.
class MergeSideError implements Exception {
  const MergeSideError({required this.notFound});
  final bool notFound;
}

class DuplicatesApi {
  DuplicatesApi([ApiService? api]) : _api = api ?? ApiService();

  final ApiService _api;

  /// Possible duplicates of a record being typed. Only the module's own
  /// fields are sent, blank ones dropped, in a POST body rather than a query
  /// string: an email and a phone in a URL are written to access logs. A
  /// failure answers none: it is a hint beside a form, and the form must
  /// still save.
  Future<List<DuplicateHit>> check(
    DuplicateModule module,
    Map<String, String> criteria,
  ) async {
    final query = <String, String>{
      for (final field in module.queryFields)
        if ((criteria[field] ?? '').trim().isNotEmpty)
          field: criteria[field]!.trim(),
    };
    if (query.isEmpty) return const [];
    final response = await _api.post(
      ApiConfig.duplicatesCheck(module.path),
      query,
    );
    if (!response.success || response.data == null) return const [];
    return _hits(api.DuplicatesResponse.fromJson(response.data!).duplicates);
  }

  /// Possible duplicates of a saved record. None when the check fails.
  Future<RecordDuplicates> forRecord(DuplicateModule module, String id) async {
    final response = await _api.get(
      ApiConfig.recordDuplicates(module.path, id),
    );
    if (!response.success || response.data == null) {
      return const RecordDuplicates();
    }
    final data = api.RecordDuplicatesResponse.fromJson(response.data!);
    return RecordDuplicates(
      canDelete: data.canDelete == true,
      hits: _hits(data.duplicates),
    );
  }

  /// One record for the compare screen: its detail, plus whether the caller
  /// may delete it (from its duplicates endpoint).
  Future<MergeSide> side(DuplicateModule module, String id) async {
    final results = await Future.wait([
      _api.get(ApiConfig.recordDetail(module.path, id)),
      _api.get(ApiConfig.recordDuplicates(module.path, id)),
    ]);
    final detail = results[0];
    final body = detail.data;
    final found = detail.success && body != null
        ? module._recordIn(body)
        : null;
    if (found == null) {
      throw MergeSideError(notFound: detail.statusCode == 404);
    }
    final (recordId, record) = found;
    final duplicates = results[1].data;
    return MergeSide(
      id: recordId ?? id,
      name: module.nameOf(record),
      canDelete:
          duplicates != null &&
          api.RecordDuplicatesResponse.fromJson(duplicates).canDelete == true,
      fields: [
        for (final (label, read) in module.compareFields) (label, read(record)),
      ],
    );
  }

  /// Merge [loserId] into [keeperId]. Null on success, else the reason.
  Future<String?> merge(
    DuplicateModule module,
    String keeperId,
    String loserId,
  ) async {
    final response = await _api.post(
      ApiConfig.mergeRecord(module.path, keeperId),
      {'merge_id': loserId},
    );
    if (response.success) return null;
    if (response.statusCode == 404) {
      return 'One of these ${module.singular}s no longer exists, or you do '
          'not have access to it.';
    }
    return response.message ?? 'Could not merge these ${module.singular}s.';
  }

  List<DuplicateHit> _hits(List<api.DuplicateHit>? rows) => [
    for (final row in rows ?? const <api.DuplicateHit>[])
      DuplicateHit.fromJson(row.json),
  ];
}

final duplicatesApiProvider = Provider<DuplicatesApi>((ref) => DuplicatesApi());

final recordDuplicatesProvider = FutureProvider.autoDispose
    .family<RecordDuplicates, (DuplicateModule, String)>(
      (ref, key) => ref.read(duplicatesApiProvider).forRecord(key.$1, key.$2),
    );

/// After a merge: the loser is gone from its list and the keeper changed, so
/// the module's list and every duplicates panel are read again.
void refreshAfterMerge(WidgetRef ref, DuplicateModule module) {
  switch (module) {
    case DuplicateModule.leads:
      ref.invalidate(leadsProvider);
    case DuplicateModule.contacts:
      ref.invalidate(contactsProvider);
    case DuplicateModule.accounts:
      ref.invalidate(accountsProvider);
  }
  ref.invalidate(recordDuplicatesProvider);
}

import '../api/schema.g.dart' as api;
import 'custom_field_definition.dart';

/// An account: the company a contact works for and a deal is booked against.
///
/// Mobile had no accounts module at all, while the deal form already fetched
/// them for its picker, so `AccountLookup` in `lookup_models.dart` exists and
/// carries four fields. This is the full record. The two are kept apart on
/// purpose: a picker that only needs an id and a name should not pay for a
/// rollup query, and widening the lookup would have made every deal form
/// heavier to serve one screen.
class Account {
  const Account({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.website,
    this.industry,
    this.numberOfEmployees,
    this.annualRevenue,
    this.currency,
    this.addressLine,
    this.city,
    this.state,
    this.postcode,
    this.country,
    this.countryDisplay,
    this.description,
    this.isActive = true,
    this.assignedToIds = const [],
    this.assignedToNames = const [],
    this.tagIds = const [],
    this.tagNames = const [],
    this.contacts = const [],
    this.opportunities = const [],
    this.cases = const [],
    this.tasks = const [],
    this.rollups,
    this.customFields = const {},
    this.customFieldDefinitions = const [],
    this.canDelete = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String? email;
  final String? phone;
  final String? website;

  final String? industry;
  final int? numberOfEmployees;
  final String? annualRevenue;
  final String? currency;

  final String? addressLine;
  final String? city;
  final String? state;
  final String? postcode;

  /// The stored ISO code, e.g. "IN".
  final String? country;

  /// The server's human label for [country], e.g. "India". Present on list and
  /// detail; absent when the account has no country, which is why it is
  /// nullable rather than defaulted to the code.
  final String? countryDisplay;

  final String? description;
  final bool isActive;

  final List<String> assignedToIds;
  final List<String> assignedToNames;
  final List<String> tagIds;
  final List<String> tagNames;

  final List<AccountRelation> contacts;
  final List<AccountRelation> opportunities;
  final List<AccountRelation> cases;
  final List<AccountRelation> tasks;

  /// What the account is worth, owes, and is complaining about.
  ///
  /// Null is meaningful and must stay distinguishable from zero: the server
  /// sends `null` on any endpoint that did not run the rollup annotation, and
  /// a screen given no numbers should say nothing rather than claim every
  /// total is zero.
  final AccountRollups? rollups;

  final Map<String, dynamic> customFields;

  /// The org's active account fields, sent beside the detail record like
  /// [canDelete]. Empty wherever they were not sent, such as a list row.
  final List<CustomFieldDefinition> customFieldDefinitions;

  final DateTime? createdAt;

  /// Whether the signed-in user may delete this account: the server's own delete
  /// rule (an admin, or whoever created it), sent as `can_delete` beside the
  /// detail record. False wherever it was not sent, such as a list row, so
  /// Delete is never offered on a guess.
  final bool canDelete;

  String get initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  /// One line for a list row: the city and country if known, else the website.
  String? get locationLine {
    final place = [
      city,
      countryDisplay ?? country,
    ].where((v) => v != null && v.trim().isNotEmpty).join(', ');
    if (place.isNotEmpty) return place;
    final site = website?.trim();
    return (site == null || site.isEmpty) ? null : site;
  }

  /// Reads an `AccountWithRelated`: the detail's `account_obj`, or a list
  /// row, which is the same `Account` without the related lists.
  factory Account.fromJson(
    Map<String, dynamic> json, {
    bool canDelete = false,
    List<CustomFieldDefinition> customFieldDefinitions = const [],
  }) {
    final w = api.AccountWithRelated.fromJson(json);
    final assigned = w.assignedTo ?? const <api.Profile>[];
    final tags = w.tags ?? const <api.Tags>[];
    final rollups = w.rollups;
    final customFields = w.customFields;
    return Account(
      id: w.id ?? '',
      name: w.name ?? '',
      email: _str(w.email),
      phone: _str(w.phone),
      website: _str(w.website),
      industry: _str(w.industry),
      numberOfEmployees: w.numberOfEmployees,
      annualRevenue: _str(w.annualRevenue),
      currency: _str(w.currency),
      addressLine: _str(w.addressLine),
      city: _str(w.city),
      state: _str(w.state),
      postcode: _str(w.postcode),
      country: _str(w.country),
      countryDisplay: _str(w.countryDisplay),
      description: _str(w.description),
      isActive: w.isActive ?? true,
      assignedToIds: _ids([for (final p in assigned) p.id]),
      assignedToNames: _names([
        for (final p in assigned) p.userDetails?.name ?? p.userDetails?.email,
      ]),
      tagIds: _ids([for (final t in tags) t.id]),
      tagNames: _names([for (final t in tags) t.name]),
      contacts: [
        for (final c in w.contacts ?? const <api.Contact>[])
          AccountRelation(id: c.id ?? '', label: _label(_contactLabel(c))),
      ],
      opportunities: [
        for (final d in w.opportunities ?? const <api.AccountDealRef>[])
          AccountRelation(
            id: d.id ?? '',
            label: _label(d.name),
            detail: _str(d.stageLabel) ?? _str(d.stage),
          ),
      ],
      cases: [
        for (final c in w.cases ?? const <api.AccountCaseRef>[])
          AccountRelation(id: c.id ?? '', label: _label(c.name)),
      ],
      tasks: [
        for (final t in w.tasks ?? const <api.AccountTaskRef>[])
          AccountRelation(id: t.id ?? '', label: _label(t.title)),
      ],
      rollups: rollups == null ? null : AccountRollups.fromJson(rollups.json),
      customFields: customFields is Map<String, dynamic>
          ? Map<String, dynamic>.from(customFields)
          : const {},
      customFieldDefinitions: customFieldDefinitions,
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      canDelete: canDelete,
    );
  }

  /// The payload the create and edit forms submit. Also the snapshot the
  /// unsaved-changes guard compares against, so anything omitted here is
  /// something the form cannot lose.
  Map<String, dynamic> toPayload() {
    return {
      'name': name.trim(),
      'email': _orNull(email),
      'phone': _orNull(phone),
      'website': _orNull(website),
      'industry': _orNull(industry),
      'number_of_employees': numberOfEmployees,
      'annual_revenue': _orNull(annualRevenue),
      'currency': _orNull(currency),
      'address_line': _orNull(addressLine),
      'city': _orNull(city),
      'state': _orNull(state),
      'postcode': _orNull(postcode),
      'country': _orNull(country),
      'description': _orNull(description),
      'assigned_to': assignedToIds,
      'tags': tagIds,
      'contacts': contacts.map((c) => c.id).toList(),
      'custom_fields': customFields,
    };
  }

  Account copyWith({
    String? name,
    String? email,
    String? phone,
    String? website,
    String? industry,
    int? numberOfEmployees,
    bool clearNumberOfEmployees = false,
    String? annualRevenue,
    String? currency,
    String? addressLine,
    String? city,
    String? state,
    String? postcode,
    String? country,
    String? description,
    bool? isActive,
    List<String>? assignedToIds,
    List<String>? tagIds,
    List<AccountRelation>? contacts,
    Map<String, dynamic>? customFields,
  }) {
    return Account(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      website: website ?? this.website,
      industry: industry ?? this.industry,
      numberOfEmployees: clearNumberOfEmployees
          ? null
          : (numberOfEmployees ?? this.numberOfEmployees),
      annualRevenue: annualRevenue ?? this.annualRevenue,
      currency: currency ?? this.currency,
      addressLine: addressLine ?? this.addressLine,
      city: city ?? this.city,
      state: state ?? this.state,
      postcode: postcode ?? this.postcode,
      country: country ?? this.country,
      countryDisplay: countryDisplay,
      description: description ?? this.description,
      isActive: isActive ?? this.isActive,
      assignedToIds: assignedToIds ?? this.assignedToIds,
      assignedToNames: assignedToNames,
      tagIds: tagIds ?? this.tagIds,
      tagNames: tagNames,
      contacts: contacts ?? this.contacts,
      opportunities: opportunities,
      cases: cases,
      tasks: tasks,
      rollups: rollups,
      customFields: customFields ?? this.customFields,
      customFieldDefinitions: customFieldDefinitions,
      createdAt: createdAt,
      canDelete: canDelete,
    );
  }
}

/// A row the account links to: a contact, deal, ticket or task. Enough to draw
/// a line and navigate, nothing more, because that is all the account
/// serializer sends for them.
class AccountRelation {
  const AccountRelation({required this.id, required this.label, this.detail});

  final String id;
  final String label;

  /// Stage for a deal, as the org names it (`stage_label`, falling back to
  /// the code from a server that predates it); absent for everything else.
  final String? detail;
}

/// The account's totals, from `accounts.views.ROLLUP_FIELDS` and
/// `attach_money_rollups`.
///
/// Every count is nullable for the same reason the whole object is: a number
/// the server did not compute must not read as zero. The names are the
/// server's, checked against the view rather than guessed, because a
/// misspelled key here yields a silent null and a panel that shows nothing.
///
/// Deals and invoices each carry a currency and there are no exchange rates,
/// so the money arrives per currency (`by_currency`) and is kept that way in
/// [money]. A server older than that sends only the plain figures, which are
/// kept under an empty code.
class AccountRollups {
  const AccountRollups({
    this.money = const [],
    this.wonCount,
    this.openDealCount,
    this.openTickets,
    this.firstWonOn,
  });

  /// Won, open and overdue money, one entry per currency, ordered by code.
  final List<RollupMoney> money;
  final int? wonCount;
  final int? openDealCount;
  final int? openTickets;

  /// When this account first bought anything. Null for a prospect.
  final DateTime? firstWonOn;

  bool get isEmpty =>
      money.isEmpty &&
      wonCount == null &&
      openDealCount == null &&
      openTickets == null;

  /// Reads an `AccountRollups`. Servers from the first rollups (2026-07-31)
  /// to `by_currency` (2026-09-26) sent only the plain figures.
  factory AccountRollups.fromJson(Map<String, dynamic> json) {
    final w = api.AccountRollups.fromJson(json);
    final rows = w.byCurrency;
    final hasPlain = json.containsKey('won_amount');
    return AccountRollups(
      money: rows != null
          ? [
              for (final row in rows)
                if (row.currency != null) RollupMoney.fromJson(row.json),
            ]
          : [
              if (hasPlain) RollupMoney.fromJson({...json, 'currency': ''}),
            ],
      wonCount: w.wonCount,
      openDealCount: w.openDealCount,
      openTickets: w.openTickets,
      firstWonOn: DateTime.tryParse(w.firstWonOn ?? ''),
    );
  }
}

/// An account's money in one currency.
class RollupMoney {
  const RollupMoney({
    required this.currency,
    this.wonAmount = 0,
    this.openPipeline = 0,
    this.overdueAmount = 0,
  });

  /// The currency code, or empty from a server that sent plain figures only.
  final String currency;

  /// Closed-won total.
  final double wonAmount;

  /// Value of everything still open.
  final double openPipeline;

  /// Invoiced and past due.
  final double overdueAmount;

  /// Reads an `AccountMoneyRow`, or an older server's plain figures given an
  /// empty `currency`.
  factory RollupMoney.fromJson(Map<String, dynamic> json) {
    final w = api.AccountMoneyRow.fromJson(json);
    return RollupMoney(
      currency: w.currency ?? '',
      wonAmount: double.tryParse(w.wonAmount ?? '') ?? 0,
      openPipeline: double.tryParse(w.openPipeline ?? '') ?? 0,
      overdueAmount: double.tryParse(w.overdueAmount ?? '') ?? 0,
    );
  }
}

/// A linked contact's name, else its email.
String? _contactLabel(api.Contact contact) {
  final name = [
    contact.firstName,
    contact.lastName,
  ].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
  if (name.isNotEmpty) return name;
  return contact.email;
}

String _label(String? raw) {
  final s = raw?.trim() ?? '';
  return s.isEmpty ? 'Untitled' : s;
}

String? _str(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

String? _orNull(String? v) {
  final s = v?.trim();
  return (s == null || s.isEmpty) ? null : s;
}

List<String> _ids(List<String?> ids) => [
  for (final id in ids)
    if (id != null && id.isNotEmpty) id,
];

List<String> _names(List<String?> names) => [
  for (final name in names)
    if (name != null && name.trim().isNotEmpty) name,
];

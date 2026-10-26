// Lookup models for deal form selectors
// These are simplified models used for dropdowns and multi-selects

import '../api/schema.g.dart' as api;

/// Account model for selector
class AccountLookup {
  final String id;
  final String name;
  final String? website;
  final String? phone;

  const AccountLookup({
    required this.id,
    required this.name,
    this.website,
    this.phone,
  });

  /// Reads an `Account`, a row of the accounts list.
  factory AccountLookup.fromJson(Map<String, dynamic> json) {
    final w = api.Account.fromJson(json);
    return AccountLookup(
      id: w.id ?? '',
      name: w.name ?? '',
      website: w.website,
      phone: w.phone,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountLookup &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Contact model for selector
class ContactLookup {
  final String id;
  final String firstName;
  final String lastName;
  final String? email;
  final String? phone;

  /// The `account` FK, from `account_detail`, NOT the `Account.contacts` M2M.
  ///
  /// The FK is the one the invoice serializer cross-checks ("Contact does not
  /// belong to the selected account"), so it is the one a picker has to filter
  /// on. It is also usually null: measured on the seeded org, 0 of 15 contacts
  /// had it set while 12 were in the M2M. That is why an unset value means
  /// "attaches to anyone" here rather than "belongs to nobody", and why
  /// filtering strictly on equality would empty the picker.
  final String? accountId;
  final String? accountName;

  const ContactLookup({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.email,
    this.phone,
    this.accountId,
    this.accountName,
  });

  /// Whether this contact may be billed on an invoice for [forAccountId].
  ///
  /// Mirrors `InvoiceCreateSerializer.validate`, which refuses only when the
  /// contact carries a *different* account. A contact with no account passes
  /// for any of them.
  bool billableFor(String? forAccountId) =>
      accountId == null || accountId!.isEmpty || accountId == forAccountId;

  String get fullName => '$firstName $lastName'.trim();

  String get initials {
    final first = firstName.isNotEmpty ? firstName[0] : '';
    final last = lastName.isNotEmpty ? lastName[0] : '';
    return '$first$last'.toUpperCase();
  }

  /// Reads a `Contact`, a row of the contacts list. A deal's `ContactLink`
  /// is a narrower shape of it.
  factory ContactLookup.fromJson(Map<String, dynamic> json) {
    final w = api.Contact.fromJson(json);
    // `account_detail` is the resolved FK, `{id, name}` or null. The bare
    // `account` key is read too so a leaner payload still populates this.
    final detail = w.accountDetail;
    return ContactLookup(
      id: w.id ?? '',
      firstName: w.firstName ?? '',
      lastName: w.lastName ?? '',
      email: w.email,
      phone: w.phone,
      accountId: detail != null ? detail.id : w.account,
      accountName: detail?.name,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactLookup &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// User/Profile model for assignment selector
class UserLookup {
  final String id;
  final String email;

  /// `user_details.name`, which the API has always sent and this model used to
  /// drop. Without it a picker labels somebody "aswin.1231" while the record
  /// they are assigned to labels the same person "Ashwin", from the same
  /// payload. Blank for a user who never set one.
  final String name;

  final String? profilePic;
  final String role;
  final bool isActive;

  const UserLookup({
    required this.id,
    required this.email,
    this.name = '',
    this.profilePic,
    required this.role,
    required this.isActive,
  });

  /// The name if there is one, otherwise the local part of the email.
  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : email.split('@').first;

  /// Get initials for avatar
  String get initials {
    final name = displayName;
    final parts = name.split(RegExp(r'[\s._-]+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.length >= 2
        ? name.substring(0, 2).toUpperCase()
        : name.toUpperCase();
  }

  /// Reads a `Profile`, or the flat `{id, email, name}` that web forms
  /// (`WebFormMember`) and approval rules (`ApprovalRuleApprover`) send.
  factory UserLookup.fromJson(Map<String, dynamic> json) {
    final w = api.Profile.fromJson(json);
    final flat = api.WebFormMember.fromJson(json);
    final details = w.userDetails;
    return UserLookup(
      id: w.id ?? '',
      email: details?.email ?? flat.email ?? '',
      name: details?.name ?? flat.name ?? '',
      profilePic: details?.profilePic,
      role: w.role ?? 'USER',
      isActive: w.isActive ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserLookup && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Team model for selector
class TeamLookup {
  final String id;
  final String name;
  final String? description;

  const TeamLookup({required this.id, required this.name, this.description});

  /// Reads a `Teams`. An approval rule's `ApprovalRuleTeam` is a narrower
  /// shape of it.
  factory TeamLookup.fromJson(Map<String, dynamic> json) {
    final w = api.Teams.fromJson(json);
    return TeamLookup(
      id: w.id ?? '',
      name: w.name ?? '',
      description: w.description,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TeamLookup && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Tag model for selector
class TagLookup {
  final String id;
  final String name;
  final String slug;
  final String color;

  const TagLookup({
    required this.id,
    required this.name,
    required this.slug,
    required this.color,
  });

  /// Reads a `TagsListRow`.
  factory TagLookup.fromJson(Map<String, dynamic> json) {
    final w = api.TagsListRow.fromJson(json);
    return TagLookup(
      id: w.id ?? '',
      name: w.name ?? '',
      slug: w.slug ?? '',
      color: w.color ?? 'gray',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TagLookup && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// A record a task can be attached to: one id, one label, nothing else.
///
/// The task form used to source these from the leads, deals and tickets list
/// providers, which hold whatever page the corresponding screen last loaded
/// under whatever filter it last applied. On a cold app those are empty, so the
/// picker said "Nothing to pick" for an org with twenty leads.
class EntityLookup {
  final String id;
  final String label;

  const EntityLookup({required this.id, required this.label});

  /// A record with one naming field. [labelKeys] are tried in order and the
  /// first non-empty one wins.
  factory EntityLookup.fromJson(
    Map<String, dynamic> json, {
    required List<String> labelKeys,
  }) {
    return EntityLookup(
      id: json['id']?.toString() ?? '',
      label: _firstNonEmpty(json, labelKeys) ?? 'Untitled',
    );
  }

  /// A person, whose name is two optional fields rather than one. Neither is
  /// required on a lead, so [fallbackKeys] is what keeps an unnamed row
  /// selectable instead of blank.
  factory EntityLookup.person(
    Map<String, dynamic> json, {
    List<String> fallbackKeys = const [],
  }) {
    final name = [
      json['first_name']?.toString().trim() ?? '',
      json['last_name']?.toString().trim() ?? '',
    ].where((part) => part.isNotEmpty).join(' ');
    return EntityLookup(
      id: json['id']?.toString() ?? '',
      label: name.isNotEmpty
          ? name
          : (_firstNonEmpty(json, fallbackKeys) ?? 'Unnamed'),
    );
  }

  static String? _firstNonEmpty(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EntityLookup &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

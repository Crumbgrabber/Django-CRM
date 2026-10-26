import '../api/schema.g.dart' as api;

/// User returned from authentication endpoints
class AuthUser {
  final String id;
  final String email;
  final String? name;
  final String? profilePic;

  const AuthUser({
    required this.id,
    required this.email,
    this.name,
    this.profilePic,
  });

  /// Reads a `User`, the profile's `user`. `GoogleOAuthUser` and
  /// `UserDetail` are narrower shapes of it. A user without an id or email
  /// throws.
  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final w = api.User.fromJson(json);
    return AuthUser(
      id: w.id!,
      email: w.email!,
      name: w.name,
      profilePic: w.profilePic,
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'email': email, 'name': name, 'profile_pic': profilePic};
  }

  /// Get display name (email if name not available)
  String get displayName => name ?? email.split('@').first;

  /// Get initials for avatar fallback
  String get initials {
    final parts = displayName.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return displayName
        .substring(0, displayName.length >= 2 ? 2 : 1)
        .toUpperCase();
  }

  @override
  String toString() => 'AuthUser(id: $id, email: $email)';
}

/// Organization model for multi-tenancy
class Organization {
  final String id;
  final String name;

  /// For display. Admin gates read [isOrganizationAdmin], never this.
  final String? role;

  /// Whether the signed-in user administers this org: the API's
  /// `is_org_admin` (the ADMIN role, or a Django superuser's membership),
  /// sent as `is_organization_admin` with every org the auth endpoints list.
  /// Read it through `isOrgAdminProvider`. UI affordances only.
  final bool isOrganizationAdmin;
  final String? defaultCurrency;
  final String? currencySymbol;
  final String? defaultCountry;

  const Organization({
    required this.id,
    required this.name,
    this.role,
    this.isOrganizationAdmin = false,
    this.defaultCurrency,
    this.currencySymbol,
    this.defaultCountry,
  });

  /// Reads an `AuthOrg`, as the sign-in answers list them and [toJson]
  /// caches them. `OrgCreated`, `UserOrganization` and the profile's
  /// `Organization` are narrower shapes of it. An org without an id or name
  /// throws.
  factory Organization.fromJson(Map<String, dynamic> json) {
    final w = api.AuthOrg.fromJson(json);
    return Organization(
      id: w.id!,
      // `Org.name` is nullable; an unnamed org must not sink the profile load.
      name: w.name ?? '',
      role: w.role,
      // Only a literal `true` counts. The key is absent only from an org
      // cached by a build older than 1.11.0, which stored the role and no
      // fact; for that one case the role (also server-issued) stands in until
      // the next sign-in or org switch replaces it (see [withMembership]). A
      // superuser holding the USER role is not recognised from such a cache,
      // which is the old behaviour.
      isOrganizationAdmin: json.containsKey('is_organization_admin')
          ? w.isOrganizationAdmin == true
          : w.role == 'ADMIN',
      defaultCurrency: w.defaultCurrency,
      currencySymbol: w.currencySymbol,
      defaultCountry: w.defaultCountry,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'role': role,
      'is_organization_admin': isOrganizationAdmin,
      'default_currency': defaultCurrency,
      'currency_symbol': currencySymbol,
      'default_country': defaultCountry,
    };
  }

  /// Get initials for avatar fallback
  String get initials {
    if (name.isEmpty) return 'O';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  /// This org with the caller's membership facts from `profile`, the
  /// `{role, is_organization_admin}` object `POST /api/auth/switch-org/`
  /// returns. Both are read fresh on every switch, so a promotion or demotion
  /// since sign-in (and an org built from the create response) is not left
  /// stale in the cache. An absent or malformed value keeps what we had.
  Organization withMembership(Object? profile) {
    if (profile is! Map<String, dynamic>) return this;
    final w = api.OrgSwitchProfile.fromJson(profile);
    return Organization(
      id: id,
      name: name,
      role: w.role ?? role,
      isOrganizationAdmin: w.isOrganizationAdmin ?? isOrganizationAdmin,
      defaultCurrency: defaultCurrency,
      currencySymbol: currencySymbol,
      defaultCountry: defaultCountry,
    );
  }

  @override
  String toString() => 'Organization(id: $id, name: $name, role: $role)';
}

/// Response from Google OAuth callback
class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final AuthUser user;

  const AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  /// Reads a `GoogleOAuthResponse`, from `/api/auth/google/callback/`.
  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final w = api.GoogleOAuthResponse.fromJson(json);
    return AuthResponse(
      accessToken: w.accessToken!,
      refreshToken: w.refreshToken!,
      user: AuthUser.fromJson(w.user!.json),
    );
  }

  @override
  String toString() => 'AuthResponse(user: ${user.email})';
}

/// Response from login endpoint (includes organizations)
class LoginResponse {
  final String accessToken;
  final String refreshToken;
  final AuthUser user;
  final List<Organization> organizations;
  final Organization? currentOrg;

  const LoginResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    required this.organizations,
    this.currentOrg,
  });

  /// Reads a `MagicLinkVerifyResponse`, whose `user` (a `UserDetail`) nests
  /// the orgs.
  factory LoginResponse.fromJson(Map<String, dynamic> json) {
    final w = api.MagicLinkVerifyResponse.fromJson(json);
    final user = w.user!;
    final current = w.currentOrg;
    return LoginResponse(
      accessToken: w.accessToken!,
      refreshToken: w.refreshToken!,
      user: AuthUser.fromJson(user.json),
      organizations: [
        for (final org in user.organizations ?? const <api.UserOrganization>[])
          Organization.fromJson(org.json),
      ],
      currentOrg: current == null ? null : Organization.fromJson(current.json),
    );
  }

  @override
  String toString() =>
      'LoginResponse(user: ${user.email}, orgs: ${organizations.length})';
}

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;
import 'attachment.dart';
import 'comment.dart';

/// Lead status enumeration matching backend LEAD_STATUS
enum LeadStatus {
  assigned('assigned', 'Assigned', AppColors.primary400),
  inProcess('in process', 'In Process', AppColors.warning500),
  converted('converted', 'Converted', AppColors.success600),
  recycled('recycled', 'Recycled', AppColors.gray500),
  closed('closed', 'Closed', AppColors.danger500);

  final String value;
  final String label;
  final Color color;

  const LeadStatus(this.value, this.label, this.color);

  String get displayName => label;

  static LeadStatus fromString(String? value) {
    if (value == null) return LeadStatus.assigned;
    final normalized = value.toLowerCase().trim();
    return LeadStatus.values.firstWhere(
      (s) => s.value == normalized,
      orElse: () => LeadStatus.assigned,
    );
  }
}

/// Lead rating/priority enumeration matching backend rating field
enum LeadRating {
  cold('COLD', 'Cold', AppColors.primary400),
  warm('WARM', 'Warm', AppColors.warning500),
  hot('HOT', 'Hot', AppColors.danger500);

  final String value;
  final String label;
  final Color color;

  const LeadRating(this.value, this.label, this.color);

  String get displayName => label;

  static LeadRating fromString(String? value) {
    if (value == null) return LeadRating.cold;
    final normalized = value.toUpperCase().trim();
    return LeadRating.values.firstWhere(
      (r) => r.value == normalized,
      orElse: () => LeadRating.cold,
    );
  }
}

/// Priority enumeration (for backwards compatibility)
enum Priority {
  low('Low', AppColors.success500),
  medium('Medium', AppColors.warning500),
  high('High', AppColors.danger500),
  urgent('Urgent', AppColors.purple500);

  final String label;
  final Color color;

  const Priority(this.label, this.color);

  String get displayName => label;

  static Priority fromString(String? value) {
    if (value == null) return Priority.medium;
    switch (value.toLowerCase()) {
      case 'low':
        return Priority.low;
      case 'medium':
        return Priority.medium;
      case 'high':
        return Priority.high;
      case 'urgent':
        return Priority.urgent;
      default:
        return Priority.medium;
    }
  }

  /// Convert from LeadRating
  static Priority fromRating(LeadRating rating) {
    switch (rating) {
      case LeadRating.cold:
        return Priority.low;
      case LeadRating.warm:
        return Priority.medium;
      case LeadRating.hot:
        return Priority.high;
    }
  }
}

/// Lead model for BottleCRM
class Lead {
  final String id;
  final String? title;
  final String? salutation;
  final String firstName;
  final String lastName;
  final String email;
  final String? phone;

  /// The phone in international form, set by the server; empty when it
  /// does not parse. WhatsApp needs it.
  final String phoneE164;
  final String? jobTitle;
  final String? website;
  final String? linkedinUrl;
  final String companyName;
  final LeadStatus status;

  /// A key from the org's source list, exactly as the server sent it (empty
  /// for none). Label it with `leadSourceLabel`.
  final String source;
  final String sourceDetail;
  final String sourceRef;
  final LeadRating rating;
  final String? industry;
  final double? opportunityAmount;
  final String? currency;
  final int? probability;
  final DateTime? closeDate;
  final String? addressLine;
  final String? city;
  final String? state;
  final String? postcode;
  final String? country;
  final DateTime? lastContacted;
  final DateTime? nextFollowUp;
  final String? description;
  final List<String> tags;
  final List<String> tagIds;
  final List<Map<String, dynamic>>? assignedTo;
  final List<String> assignedToIds;
  final List<Comment> comments;
  final List<Attachment> attachments;
  final Map<String, dynamic> customFieldValues;

  /// Email of the profile that created the lead, from `LeadSerializer`'s
  /// nested `created_by`. Carried because delete is the creator's right, not
  /// the assignee's, so the detail sheet needs it to decide what to offer.
  final String? createdByEmail;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final bool isActive;

  /// Null from an API that predates response times, true when the lead waits
  /// for a first reply, since [waitingSince].
  final bool? isUnanswered;
  final DateTime? waitingSince;

  const Lead({
    required this.id,
    this.title,
    this.salutation,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phone,
    this.phoneE164 = '',
    this.jobTitle,
    this.website,
    this.linkedinUrl,
    required this.companyName,
    required this.status,
    this.source = '',
    this.sourceDetail = '',
    this.sourceRef = '',
    required this.rating,
    this.industry,
    this.opportunityAmount,
    this.currency,
    this.probability,
    this.closeDate,
    this.addressLine,
    this.city,
    this.state,
    this.postcode,
    this.country,
    this.lastContacted,
    this.nextFollowUp,
    this.description,
    this.tags = const [],
    this.tagIds = const [],
    this.assignedTo,
    this.assignedToIds = const [],
    this.comments = const [],
    this.attachments = const [],
    this.customFieldValues = const {},
    this.createdByEmail,
    required this.createdAt,
    this.updatedAt,
    this.isActive = true,
    this.isUnanswered,
    this.waitingSince,
  });

  /// Full name combining first and last name
  String get name {
    final parts = [firstName, lastName].where((p) => p.isNotEmpty).toList();
    return parts.isNotEmpty ? parts.join(' ') : email;
  }

  /// Alias for companyName
  String get company => companyName;

  /// Priority based on rating
  Priority get priority => Priority.fromRating(rating);

  /// Get assigned user name (first one if multiple).
  ///
  /// Backend shape (ProfileSerializer): `{id, user_details: {name, email,
  /// profile_pic, ...}, role, ...}`. We prefer the display name, fall back
  /// to the email-local-part, and finally to "Unknown" so the avatar never
  /// shows just "?".
  String get assignedToName {
    if (assignedTo == null || assignedTo!.isEmpty) return 'Unassigned';
    final details = api.Profile.fromJson(assignedTo!.first).userDetails;
    final name = details?.name?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final email = details?.email?.trim() ?? '';
    if (email.isNotEmpty) return email.split('@').first;
    return 'Unknown';
  }

  /// Profile picture URL of the first assignee, if any.
  String? get assignedToProfilePic {
    if (assignedTo == null || assignedTo!.isEmpty) return null;
    final pic = api.Profile.fromJson(
      assignedTo!.first,
    ).userDetails?.profilePic?.trim();
    return pic == null || pic.isEmpty ? null : pic;
  }

  /// Get lead initials for avatar fallback
  String get initials {
    if (firstName.isNotEmpty && lastName.isNotEmpty) {
      return '${firstName[0]}${lastName[0]}'.toUpperCase();
    } else if (firstName.isNotEmpty) {
      return firstName
          .substring(0, firstName.length >= 2 ? 2 : 1)
          .toUpperCase();
    } else if (lastName.isNotEmpty) {
      return lastName.substring(0, lastName.length >= 2 ? 2 : 1).toUpperCase();
    }
    return '?';
  }

  /// Reads a `Lead`, the row the list pages and the detail's `lead_obj`
  /// share. Comments and attachments travel beside it in the detail answer,
  /// and the provider adds them.
  factory Lead.fromJson(Map<String, dynamic> json) {
    final w = api.Lead.fromJson(json);
    final tags = w.tags ?? const <api.Tags>[];
    final assigned = w.assignedTo;
    final customFields = w.customFields;
    return Lead(
      id: w.id ?? '',
      title: w.title,
      salutation: w.salutation,
      firstName: w.firstName ?? '',
      lastName: w.lastName ?? '',
      email: w.email ?? '',
      phone: w.phone,
      phoneE164: w.phoneE164 ?? '',
      jobTitle: w.jobTitle,
      website: w.website,
      linkedinUrl: w.linkedinUrl,
      companyName: w.companyName ?? '',
      status: LeadStatus.fromString(w.status),
      source: w.source ?? '',
      sourceDetail: w.sourceDetail ?? '',
      sourceRef: w.sourceRef ?? '',
      rating: LeadRating.fromString(w.rating),
      industry: w.industry,
      opportunityAmount: double.tryParse(w.opportunityAmount ?? ''),
      currency: w.currency,
      probability: w.probability,
      closeDate: DateTime.tryParse(w.closeDate ?? ''),
      addressLine: w.addressLine,
      city: w.city,
      state: w.state,
      postcode: w.postcode,
      country: w.country,
      lastContacted: DateTime.tryParse(w.lastContacted ?? ''),
      nextFollowUp: DateTime.tryParse(w.nextFollowUp ?? ''),
      description: w.description,
      tags: [
        for (final t in tags)
          if (t.name case final name? when name.isNotEmpty) name,
      ],
      tagIds: [
        for (final t in tags)
          if (t.id case final id? when id.isNotEmpty) id,
      ],
      assignedTo: assigned?.map((p) => p.json).toList(),
      assignedToIds: [
        for (final p in assigned ?? const <api.Profile>[])
          if (p.id case final id? when id.isNotEmpty) id,
      ],
      customFieldValues: customFields is Map<String, dynamic>
          ? Map<String, dynamic>.from(customFields)
          : const {},
      createdByEmail: w.createdBy?.email,
      createdAt: DateTime.tryParse(w.createdAt ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(w.updatedAt ?? ''),
      isActive: w.isActive ?? true,
      isUnanswered: w.isUnanswered,
      waitingSince: DateTime.tryParse(w.waitingSince ?? ''),
    );
  }

  /// Convert Lead to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'salutation': salutation,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'job_title': jobTitle,
      'website': website,
      'linkedin_url': linkedinUrl,
      'company_name': companyName,
      'status': status.value,
      'source': source,
      'rating': rating.value,
      'industry': industry,
      'opportunity_amount': opportunityAmount,
      'currency': currency,
      'probability': probability,
      'close_date': closeDate?.toIso8601String(),
      'address_line': addressLine,
      'city': city,
      'state': state,
      'postcode': postcode,
      'country': country,
      'last_contacted': lastContacted?.toIso8601String(),
      'next_follow_up': nextFollowUp?.toIso8601String(),
      'description': description,
      'is_active': isActive,
    };
  }

  Lead copyWith({
    String? id,
    String? title,
    String? salutation,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? phoneE164,
    String? jobTitle,
    String? website,
    String? linkedinUrl,
    String? companyName,
    LeadStatus? status,
    String? source,
    String? sourceDetail,
    String? sourceRef,
    LeadRating? rating,
    String? industry,
    double? opportunityAmount,
    String? currency,
    int? probability,
    DateTime? closeDate,
    String? addressLine,
    String? city,
    String? state,
    String? postcode,
    String? country,
    DateTime? lastContacted,
    DateTime? nextFollowUp,
    String? description,
    List<String>? tags,
    List<String>? tagIds,
    List<Map<String, dynamic>>? assignedTo,
    List<String>? assignedToIds,
    List<Comment>? comments,
    List<Attachment>? attachments,
    Map<String, dynamic>? customFieldValues,
    String? createdByEmail,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isActive,
    bool? isUnanswered,
    DateTime? waitingSince,
  }) {
    return Lead(
      id: id ?? this.id,
      title: title ?? this.title,
      salutation: salutation ?? this.salutation,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      phoneE164: phoneE164 ?? this.phoneE164,
      jobTitle: jobTitle ?? this.jobTitle,
      website: website ?? this.website,
      linkedinUrl: linkedinUrl ?? this.linkedinUrl,
      companyName: companyName ?? this.companyName,
      status: status ?? this.status,
      source: source ?? this.source,
      sourceDetail: sourceDetail ?? this.sourceDetail,
      sourceRef: sourceRef ?? this.sourceRef,
      rating: rating ?? this.rating,
      industry: industry ?? this.industry,
      opportunityAmount: opportunityAmount ?? this.opportunityAmount,
      currency: currency ?? this.currency,
      probability: probability ?? this.probability,
      closeDate: closeDate ?? this.closeDate,
      addressLine: addressLine ?? this.addressLine,
      city: city ?? this.city,
      state: state ?? this.state,
      postcode: postcode ?? this.postcode,
      country: country ?? this.country,
      lastContacted: lastContacted ?? this.lastContacted,
      nextFollowUp: nextFollowUp ?? this.nextFollowUp,
      description: description ?? this.description,
      tags: tags ?? this.tags,
      tagIds: tagIds ?? this.tagIds,
      assignedTo: assignedTo ?? this.assignedTo,
      assignedToIds: assignedToIds ?? this.assignedToIds,
      comments: comments ?? this.comments,
      attachments: attachments ?? this.attachments,
      customFieldValues: customFieldValues ?? this.customFieldValues,
      createdByEmail: createdByEmail ?? this.createdByEmail,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isActive: isActive ?? this.isActive,
      isUnanswered: isUnanswered ?? this.isUnanswered,
      waitingSince: waitingSince ?? this.waitingSince,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Lead && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

import '../api/schema.g.dart' as api;

/// Comment model for notes on leads, deals, etc.
class Comment {
  final String id;
  final String comment;
  final DateTime commentedOn;
  final String? commentedById;
  final String? commentedByName;
  final String? commentedByEmail;

  /// The customer who wrote this, when it came from the support portal.
  ///
  /// A portal reply has no Profile behind it, so `commented_by` is null on it
  /// and the two author fields are mutually exclusive. Without this the phone
  /// showed a customer's message as written by "Unknown".
  final String? commentedByContactName;

  const Comment({
    required this.id,
    required this.comment,
    required this.commentedOn,
    this.commentedById,
    this.commentedByName,
    this.commentedByEmail,
    this.commentedByContactName,
  });

  /// Get display name for the commenter
  String get authorName {
    if (commentedByName != null && commentedByName!.isNotEmpty) {
      return commentedByName!;
    }
    if (commentedByEmail != null && commentedByEmail!.isNotEmpty) {
      return commentedByEmail!.split('@').first;
    }
    if (commentedByContactName != null && commentedByContactName!.isNotEmpty) {
      return commentedByContactName!;
    }
    return 'Unknown';
  }

  /// Reads a `Comment`; a lead's `LeadComment` is the same shape without the
  /// portal and internal fields.
  factory Comment.fromJson(Map<String, dynamic> json) {
    final w = api.Comment.fromJson(json);
    final by = w.commentedBy;
    final contactName = w.commentedByContact?.name ?? '';
    return Comment(
      id: w.id ?? '',
      comment: w.comment ?? '',
      commentedOn: DateTime.tryParse(w.commentedOn ?? '') ?? DateTime.now(),
      commentedById: by?.id,
      commentedByEmail: by?.userDetails?.email,
      // A portal reply has no Profile behind it; the contact's name is
      // pre-joined server-side.
      commentedByContactName: contactName.isNotEmpty
          ? contactName
          : w.commentedByContact?.email,
    );
  }

  /// Convert Comment to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'comment': comment,
      'commented_on': commentedOn.toIso8601String(),
      'commented_by': commentedById,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Comment && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

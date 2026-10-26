import '../api/schema.g.dart' as api;

/// Backend-side `Attachments` row attached to a parent record via
/// ContentType. The detail endpoints return these as a top-level
/// `attachments` list separate from the parent object.
class Attachment {
  final String id;
  final String fileName;

  /// The stored path, kept only to tell whether a row has a file behind it.
  ///
  /// **Never turn this into a URL.** It resolves under `/media/`, which is
  /// served with no per-file authorization, so a request for it either fails
  /// (an external browser carries no token) or succeeds for somebody who
  /// should not have it. Download through
  /// `ApiConfig.attachmentDownload(id)` instead, which is gated by the parent
  /// record's own read predicate.
  final String? filePath;
  final DateTime? createdAt;
  final String? createdBy;

  /// Whether there is anything to download. See `filePath`.
  bool get hasFile => (filePath ?? '').trim().isNotEmpty;

  const Attachment({
    required this.id,
    required this.fileName,
    this.filePath,
    this.createdAt,
    this.createdBy,
  });

  /// Reads an `Attachments` row. Its `created_by` is the uploader's profile id.
  factory Attachment.fromJson(Map<String, dynamic> json) {
    final w = api.Attachments.fromJson(json);
    return Attachment(
      id: w.id ?? '',
      fileName: w.fileName ?? 'Attachment',
      filePath: w.filePath,
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
      createdBy: w.createdBy,
    );
  }
}

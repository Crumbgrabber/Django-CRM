import '../api/schema.g.dart' as api;

/// Inbound/outbound email associated with a ticket.
///
/// Mirrors `cases.models.EmailMessage`. Read-only for now. Direction is one
/// of `in` (customer → us) or `out` (us → customer).
class EmailMessage {
  final String id;
  final String direction;
  final String? fromAddress;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String? subject;
  final String? bodyText;
  final DateTime? receivedAt;
  final DateTime? createdAt;

  const EmailMessage({
    required this.id,
    required this.direction,
    this.fromAddress,
    this.toAddresses = const [],
    this.ccAddresses = const [],
    this.subject,
    this.bodyText,
    this.receivedAt,
    this.createdAt,
  });

  bool get isInbound => direction == 'in';

  /// Reads an `EmailMessage`. The address fields are one string, split on
  /// commas and semicolons.
  factory EmailMessage.fromJson(Map<String, dynamic> json) {
    final w = api.EmailMessage.fromJson(json);
    List<String> parseList(String? raw) => raw == null || raw.isEmpty
        ? const []
        : raw
              .split(RegExp(r'[;,]'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

    return EmailMessage(
      id: w.id ?? '',
      direction: w.direction ?? 'in',
      fromAddress: w.fromAddress,
      toAddresses: parseList(w.toAddresses),
      ccAddresses: parseList(w.ccAddresses),
      subject: w.subject,
      bodyText: w.bodyText,
      receivedAt: DateTime.tryParse(w.receivedAt ?? ''),
      createdAt: DateTime.tryParse(w.createdAt ?? ''),
    );
  }
}

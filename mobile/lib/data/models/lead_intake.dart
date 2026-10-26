/// Lead webhooks: a URL a form tool or portal posts to, each post a lead.
///
/// The key is never held here. The server answers it in full only to a create
/// or a replace, and this app shows that answer once and keeps nothing; every
/// read carries [LeadIntake.keyHint], its last four characters.
library;

import '../api/schema.g.dart' as api;

const Map<String, String> intakePresetLabels = {
  'generic': 'Any tool that posts JSON or a form',
  'google_ads': 'Google Ads lead form',
  'tally': 'Tally',
  'gravity_forms': 'Gravity Forms',
};

/// One line of a field mapping: a dot path in the posted body, and the lead
/// field it fills.
class IntakeMapping {
  const IntakeMapping({required this.from, required this.to});

  final String from;
  final String to;

  static List<IntakeMapping> listFrom(List<api.LeadIntakeMappingRow>? rows) => [
    for (final row in rows ?? const <api.LeadIntakeMappingRow>[])
      IntakeMapping(from: row.from ?? '', to: row.to ?? ''),
  ];
}

class LeadIntake {
  const LeadIntake({
    required this.id,
    this.name = '',
    this.preset = 'generic',
    this.url = '',
    this.keyHint = '',
    this.mapping = const [],
    this.defaultSource = '',
    this.sourceDetail = '',
    this.isActive = true,
    this.lastReceivedAt,
    this.lastError = '',
  });

  final String id;
  final String name;
  final String preset;

  /// The full public URL. It never changes, so it is safe to paste anywhere.
  final String url;
  final String keyHint;
  final List<IntakeMapping> mapping;
  final String defaultSource;
  final String sourceDetail;
  final bool isActive;
  final DateTime? lastReceivedAt;
  final String lastError;

  String get presetLabel => intakePresetLabels[preset] ?? 'Any tool';

  /// As the web words it: off, on with nothing yet, or on and receiving.
  String get stateLabel => !isActive
      ? 'Off'
      : lastReceivedAt == null
      ? 'Waiting'
      : 'Receiving';

  /// Reads a `LeadIntake`.
  factory LeadIntake.fromJson(Map<String, dynamic> json) {
    final w = api.LeadIntake.fromJson(json);
    return LeadIntake(
      id: w.id ?? '',
      name: w.name ?? '',
      preset: w.preset ?? 'generic',
      url: w.url ?? '',
      keyHint: w.keyHint ?? '',
      mapping: IntakeMapping.listFrom(w.mapping),
      defaultSource: w.defaultSource ?? '',
      sourceDetail: w.sourceDetail ?? '',
      isActive: w.isActive ?? true,
      lastReceivedAt: DateTime.tryParse(w.lastReceivedAt ?? '')?.toLocal(),
      lastError: w.lastError ?? '',
    );
  }
}

class IntakeDelivery {
  const IntakeDelivery({
    required this.id,
    this.receivedAt,
    this.result = '',
    this.leadId,
    this.externalId = '',
    this.error = '',
  });

  final String id;
  final DateTime? receivedAt;

  /// `created`, `merged`, `duplicate`, `test` or `rejected`.
  final String result;
  final String? leadId;
  final String externalId;
  final String error;

  String get resultLabel => switch (result) {
    'created' => 'Created',
    'merged' => 'Merged',
    'duplicate' => 'Duplicate',
    'test' => 'Test',
    'rejected' => 'Rejected',
    '' => 'Unknown',
    _ => result,
  };

  /// Reads a `LeadIntakeDelivery`.
  factory IntakeDelivery.fromJson(Map<String, dynamic> json) {
    final w = api.LeadIntakeDelivery.fromJson(json);
    final lead = w.lead;
    return IntakeDelivery(
      id: w.id ?? '',
      receivedAt: DateTime.tryParse(w.receivedAt ?? '')?.toLocal(),
      result: w.result ?? '',
      leadId: lead == null || lead.isEmpty ? null : lead,
      externalId: w.externalId ?? '',
      error: w.error ?? '',
    );
  }
}

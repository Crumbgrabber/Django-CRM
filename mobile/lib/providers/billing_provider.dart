import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/api_config.dart';
import '../services/api_service.dart';
import 'auth_provider.dart';

/// The org's plan name from `GET /api/billing/`, or null where the server
/// offers no billing (a 404) or the read failed. Either way the phone shows
/// nothing: the name is a courtesy, and buying or managing a plan is web-only.
final orgPlanNameProvider = FutureProvider.autoDispose<String?>((ref) async {
  ref.watch(selectedOrgProvider.select((o) => o?.id));
  final response = await ApiService().get(ApiConfig.billing);
  if (!response.success) return null;
  return planNameFrom(response.data);
});

/// The plan's name in a billing answer, or null when there is none to show.
String? planNameFrom(Map<String, dynamic>? data) {
  final plan = data?['plan'];
  if (plan is! Map) return null;
  final name = plan['name'];
  if (name is! String || name.trim().isEmpty) return null;
  return name.trim();
}

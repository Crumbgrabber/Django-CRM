import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../api/schema.g.dart' as api;
import 'deal.dart' show Currency;
import 'invoice.dart' show InvoiceStatus;
import 'project.dart' show ProjectRef;

/// `invoices.models.ESTIMATE_STATUS`. Six values, no underscores this time.
enum EstimateStatus {
  draft('Draft', 'Draft', AppColors.gray500),
  sent('Sent', 'Sent', AppColors.primary600),
  viewed('Viewed', 'Viewed', AppColors.primary600),
  accepted('Accepted', 'Accepted', AppColors.success600),
  declined('Declined', 'Declined', AppColors.danger600),
  expired('Expired', 'Expired', AppColors.warning600);

  const EstimateStatus(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;

  static EstimateStatus? fromString(String? raw) {
    if (raw == null) return null;
    for (final status in EstimateStatus.values) {
      if (status.value == raw) return status;
    }
    return null;
  }
}

/// A quote, from `EstimateListSerializer`.
///
/// `convertedToInvoiceNumber` is on the list row for a reason the serializer
/// spells out: the worklist exists to separate "accepted but not yet billed"
/// from "already billed". Without it the client would offer to raise a second
/// invoice for an estimate that already has one.
class Estimate {
  const Estimate({
    required this.id,
    this.estimateNumber = '',
    this.title = '',
    this.status,
    this.rawStatus = '',
    this.accountName,
    this.clientName = '',
    this.issueDate,
    this.expiryDate,
    this.totalAmount = 0,
    this.currency,
    this.isExpired = false,
    this.convertedInvoiceId,
    this.convertedInvoiceNumber,
    this.opportunityName,
    this.project,
    this.depositInvoice,
  });

  final String id;
  final String estimateNumber;
  final String title;
  final EstimateStatus? status;
  final String rawStatus;
  final String? accountName;
  final String clientName;
  final DateTime? issueDate;
  final DateTime? expiryDate;
  final double totalAmount;
  final String? currency;
  final bool isExpired;

  final String? convertedInvoiceId;
  final String? convertedInvoiceNumber;
  final String? opportunityName;

  /// Set by the server when the client accepts: the project the estimate
  /// started and the draft deposit invoice it raised.
  final ProjectRef? project;
  final EstimateDepositInvoice? depositInvoice;

  /// A deposit invoice that still bills the client. Raising the full invoice
  /// does not take it off, so the person is told before converting.
  EstimateDepositInvoice? get liveDepositInvoice {
    final deposit = depositInvoice;
    return deposit == null || deposit.isCancelled ? null : deposit;
  }

  String get statusLabel => status?.label ?? rawStatus;

  Color get statusColor => status?.color ?? AppColors.gray500;

  Currency get currencyInfo => Currency.fromString(currency);

  bool get isConverted => convertedInvoiceId != null;

  /// Convert is refused once an invoice exists, and that is the only refusal
  /// `EstimateConvertView` makes. A declined estimate can still be converted,
  /// which is the server's rule and not this client's to tighten.
  bool get canConvert => !isConverted;

  /// Mirrors `EstimateSendView`, which refuses Accepted, Declined and Expired,
  /// and separately refuses anything already past its expiry date.
  ///
  /// `isExpired` is checked as well as the status for the reason the server
  /// checks both: `check_expired_estimates` relabels quotes once a day, so
  /// between the expiry date passing and that task running a lapsed quote
  /// still reads as Sent. Reading only the status would draw a Send button
  /// that answers 400.
  bool get canSend =>
      !isExpired &&
      (status == EstimateStatus.draft ||
          status == EstimateStatus.sent ||
          status == EstimateStatus.viewed);

  /// Reads an `EstimateList` row.
  factory Estimate.fromJson(Map<String, dynamic> json) {
    final w = api.EstimateList.fromJson(json);
    final converted = w.convertedToInvoice;
    final projectId = w.project?.id ?? '';
    final deposit = w.depositInvoice;
    final depositId = deposit?.id ?? '';
    return Estimate(
      id: w.id ?? '',
      estimateNumber: w.estimateNumber ?? '',
      title: w.title ?? '',
      status: EstimateStatus.fromString(w.status),
      rawStatus: w.status ?? '',
      accountName: w.accountName,
      clientName: w.clientName ?? '',
      issueDate: _date(w.issueDate),
      expiryDate: _date(w.expiryDate),
      totalAmount: _num(w.totalAmount),
      currency: w.currency,
      isExpired: w.isExpired ?? false,
      convertedInvoiceId: converted?.id,
      convertedInvoiceNumber: converted?.invoiceNumber,
      opportunityName: w.opportunity?.name,
      project: projectId.isEmpty
          ? null
          : ProjectRef(id: projectId, name: w.project?.name ?? ''),
      depositInvoice: depositId.isEmpty
          ? null
          : EstimateDepositInvoice(
              id: depositId,
              invoiceNumber: deposit?.invoiceNumber ?? '',
              rawStatus: deposit?.status ?? '',
              totalAmount: _num(deposit?.totalAmount),
            ),
    );
  }
}

/// The draft deposit invoice an accepted estimate raised, as the list row
/// carries it.
class EstimateDepositInvoice {
  const EstimateDepositInvoice({
    required this.id,
    this.invoiceNumber = '',
    this.rawStatus = '',
    this.totalAmount = 0,
  });

  final String id;
  final String invoiceNumber;
  final String rawStatus;
  final double totalAmount;

  InvoiceStatus? get status => InvoiceStatus.fromString(rawStatus);

  String get statusLabel => status?.label ?? rawStatus.replaceAll('_', ' ');

  bool get isCancelled => status == InvoiceStatus.cancelled;
}

double _num(String? value) => double.tryParse(value ?? '') ?? 0;

/// A YYYY-MM-DD date as a local calendar date, never UTC midnight.
DateTime? _date(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty || text == 'null') return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    return DateTime.tryParse('${text}T00:00:00');
  }
  return DateTime.tryParse(text)?.toLocal();
}

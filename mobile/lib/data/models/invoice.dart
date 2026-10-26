import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/org_date.dart';
import '../api/schema.g.dart' as api;
import 'custom_field_definition.dart';
import 'deal.dart' show Currency;

/// The eight values `invoices.models.INVOICE_STATUS` accepts.
///
/// Stored exactly as the server spells them, underscore and all, because the
/// `?status=` filter matches on the stored value. `Partially_Paid` is the one
/// that reads wrong to a human, so the label is separate from the value.
///
/// Carries its own colour, as `LeadStatus` and `TicketStatus` do, so the
/// existing `StatusBadge` can draw it without a second palette. Red is money
/// at risk, green is settled, grey is not yet in play.
enum InvoiceStatus {
  draft('Draft', 'Draft', AppColors.gray500),
  sent('Sent', 'Sent', AppColors.primary600),
  viewed('Viewed', 'Viewed', AppColors.primary600),
  paid('Paid', 'Paid', AppColors.success600),
  partiallyPaid('Partially_Paid', 'Partially paid', AppColors.warning600),
  overdue('Overdue', 'Overdue', AppColors.danger600),
  pending('Pending', 'Pending', AppColors.warning600),
  cancelled('Cancelled', 'Cancelled', AppColors.gray500);

  const InvoiceStatus(this.value, this.label, this.color);

  final String value;
  final String label;
  final Color color;

  /// An unknown status keeps its server spelling rather than collapsing to a
  /// default. A new status added to the backend should look unfamiliar here,
  /// not silently render as "Draft".
  static InvoiceStatus? fromString(String? raw) {
    if (raw == null) return null;
    for (final status in InvoiceStatus.values) {
      if (status.value == raw) return status;
    }
    return null;
  }
}

/// Money is settled on these, so the due date stops meaning anything.
const _settled = {InvoiceStatus.paid, InvoiceStatus.cancelled};

/// One invoice.
///
/// Built from two serializers that overlap but do not match. The list
/// (`InvoiceListSerializer`) sends `account` as a bare uuid with the name
/// beside it in `account_name`; the detail (`InvoiceSerializer`) nests the
/// whole account object and drops `account_name` entirely. `fromJson` reads
/// both, so a row and a detail produce the same shape and `accountName` is
/// never the literal text of a map.
class Invoice {
  const Invoice({
    required this.id,
    required this.invoiceNumber,
    this.title = '',
    this.status,
    this.rawStatus = '',
    this.accountId,
    this.accountName,
    this.contactName,
    this.clientName = '',
    this.clientEmail = '',
    this.issueDate,
    this.dueDate,
    this.subtotal = 0,
    this.discountAmount = 0,
    this.taxAmount = 0,
    this.shippingAmount = 0,
    this.totalAmount = 0,
    this.amountPaid = 0,
    this.amountDue = 0,
    this.currency,
    this.isOverdue = false,
    this.lineItemsCount = 0,
    this.lineItems = const [],
    this.payments = const [],
    this.notes,
    this.terms,
    this.poNumber,
    this.customFields = const {},
    this.customFieldDefinitions = const [],
  });

  final String id;
  final String invoiceNumber;
  final String title;

  /// Null when the server sent a status this build does not know.
  final InvoiceStatus? status;

  /// What the server actually said, kept so an unknown status can still be
  /// shown and still round-trips through the `?status=` filter.
  final String rawStatus;

  final String? accountId;
  final String? accountName;
  final String? contactName;
  final String clientName;
  final String clientEmail;
  final DateTime? issueDate;
  final DateTime? dueDate;

  /// The detail's breakdown of [totalAmount], as the server computed it: the
  /// lines' net amounts summed, less the invoice's own discount, plus tax on
  /// what is left, plus shipping. The list rows do not carry these, so they
  /// read 0 there.
  final double subtotal;
  final double discountAmount;
  final double taxAmount;
  final double shippingAmount;

  /// Amounts arrive as decimal strings, so they are parsed rather than cast.
  final double totalAmount;
  final double amountPaid;
  final double amountDue;

  /// The invoice's own currency, not the org's. An org can bill in more than
  /// one, and the rate on the invoice is the one that was agreed.
  final String? currency;

  final bool isOverdue;

  /// The list sends a count; the detail sends the items themselves.
  final int lineItemsCount;
  final List<InvoiceLineItem> lineItems;
  final List<Payment> payments;

  final String? notes;
  final String? terms;
  final String? poNumber;

  final Map<String, dynamic> customFields;

  /// The org's active invoice fields, sent beside the detail record. Empty on
  /// a list row.
  final List<CustomFieldDefinition> customFieldDefinitions;

  String get statusLabel => status?.label ?? rawStatus;

  /// Grey for a status this build does not recognise: unfamiliar rather than
  /// wrong, since colouring an unknown status green would be a claim.
  Color get statusColor => status?.color ?? AppColors.gray500;

  Currency get currencyInfo => Currency.fromString(currency);

  bool get isSettled => status != null && _settled.contains(status);

  /// How many line items to claim. The detail carries the rows themselves and
  /// the list carries only a count, so neither field alone is right on both.
  int get itemCount => lineItems.isNotEmpty ? lineItems.length : lineItemsCount;

  /// Whole days past the due date, negative while there is still time.
  ///
  /// Null on a settled invoice and on one with no due date, because there is
  /// no honest answer in either case: "4 days late" against a paid invoice is
  /// simply wrong, and it was on screen in v1.
  int? get daysLate {
    final due = dueDate;
    if (due == null || isSettled) return null;
    // Counted from the org's today, the day the API marks an invoice overdue.
    return -orgDaysUntil(due);
  }

  bool get isLate => (daysLate ?? -1) > 0;

  /// Whether the send button should be offered.
  ///
  /// Deliberately narrower than the API, which refuses only Paid and
  /// Cancelled and would therefore allow a resend of anything else. The web
  /// list offers Send on a draft and Send reminder on an overdue invoice and
  /// nothing else, and this mirrors that rather than inventing a third rule.
  /// The server is still the check that counts.
  bool get canSend =>
      status == InvoiceStatus.draft || status == InvoiceStatus.overdue;

  /// Whether to offer recording a payment.
  ///
  /// There has to be a balance to settle, and a cancelled invoice is not owed.
  /// Both halves mirror a refusal the API enforces: `PaymentCreateSerializer`
  /// rejects a payment against a cancelled invoice outright, and rejects any
  /// amount above `amount_due`, which on a paid invoice is every amount.
  bool get canRecordPayment =>
      amountDue > 0 &&
      status != InvoiceStatus.cancelled &&
      status != InvoiceStatus.paid;

  /// Cancel is refused on an already-cancelled invoice and on a paid one.
  bool get canCancel =>
      status != null &&
      status != InvoiceStatus.cancelled &&
      status != InvoiceStatus.paid;

  /// Reads an `Invoice` (the detail's `invoice`) or an `InvoiceList` row, the
  /// two shapes described above.
  factory Invoice.fromJson(
    Map<String, dynamic> json, {
    List<CustomFieldDefinition> customFieldDefinitions = const [],
  }) {
    final w = api.Invoice.fromJson(json);
    final row = api.InvoiceList.fromJson(json);
    final account = w.account;
    final contact = w.contact;
    final customFields = w.customFields;
    return Invoice(
      id: w.id ?? '',
      invoiceNumber: w.invoiceNumber ?? '',
      title: w.invoiceTitle ?? '',
      status: InvoiceStatus.fromString(w.status),
      rawStatus: w.status ?? '',
      accountId: account != null ? account.id : row.account,
      accountName: account != null ? account.name : row.accountName,
      contactName: contact != null ? _personName(contact) : row.contactName,
      clientName: w.clientName ?? '',
      clientEmail: w.clientEmail ?? '',
      issueDate: _date(w.issueDate),
      dueDate: _date(w.dueDate),
      subtotal: _amount(w.subtotal),
      discountAmount: _amount(w.discountAmount),
      taxAmount: _amount(w.taxAmount),
      shippingAmount: _amount(w.shippingAmount),
      totalAmount: _amount(w.totalAmount),
      amountPaid: _amount(w.amountPaid),
      amountDue: _amount(w.amountDue),
      currency: w.currency,
      isOverdue: w.isOverdue ?? false,
      lineItemsCount: row.lineItemsCount ?? 0,
      lineItems: [
        for (final l in w.lineItems ?? const <api.InvoiceLineItem>[])
          InvoiceLineItem.fromJson(l.json),
      ],
      payments: [
        for (final p in w.payments ?? const <api.Payment>[])
          Payment.fromJson(p.json),
      ],
      notes: w.notes,
      terms: w.terms,
      poNumber: w.poNumber,
      customFields: customFields is Map
          ? Map<String, dynamic>.from(customFields)
          : const {},
      customFieldDefinitions: customFieldDefinitions,
    );
  }
}

/// One billed line.
class InvoiceLineItem {
  const InvoiceLineItem({
    required this.id,
    this.name = '',
    this.description,
    this.quantity = 0,
    this.unitPrice = 0,
    this.discountAmount = 0,
    this.amount = 0,
  });

  final String id;
  final String name;
  final String? description;
  final double quantity;
  final double unitPrice;

  /// What the line's own discount took off quantity x unit price.
  final double discountAmount;

  /// The server's `net_amount`: quantity x unit price less the line's own
  /// discount, which is what the lines add up to in the subtotal.
  final double amount;

  /// Trailing zeroes dropped, so 2 units reads "2" and 1.5 hours reads "1.5".
  String get quantityLabel {
    final whole = quantity.truncateToDouble() == quantity;
    return whole ? quantity.toStringAsFixed(0) : quantity.toString();
  }

  /// Reads an `InvoiceLineItem`.
  factory InvoiceLineItem.fromJson(Map<String, dynamic> json) {
    final w = api.InvoiceLineItem.fromJson(json);
    return InvoiceLineItem(
      id: w.id ?? '',
      // `name` is the line's own text and `product_name` is the catalogue
      // entry behind it. A free-text line has no product, so name comes first.
      name: w.name?.trim().isNotEmpty == true ? w.name! : w.productName ?? '',
      description: w.description,
      quantity: _amount(w.quantity),
      unitPrice: _amount(w.unitPrice),
      discountAmount: _amount(w.discountAmount),
      // A server before 1.10.0 sends no `net_amount`; its `total` was the
      // figure shown then.
      amount: _amount(w.netAmount ?? w.total),
    );
  }
}

/// A payment already recorded against an invoice.
class Payment {
  const Payment({
    required this.id,
    this.amount = 0,
    this.paymentDate,
    this.method = '',
    this.referenceNumber,
    this.notes,
  });

  final String id;
  final double amount;
  final DateTime? paymentDate;
  final String method;
  final String? referenceNumber;
  final String? notes;

  String get methodLabel => paymentMethods[method] ?? method;

  /// Reads a `Payment`.
  factory Payment.fromJson(Map<String, dynamic> json) {
    final w = api.Payment.fromJson(json);
    return Payment(
      id: w.id ?? '',
      amount: _amount(w.amount),
      paymentDate: _date(w.paymentDate),
      method: w.paymentMethod ?? '',
      referenceNumber: w.referenceNumber,
      notes: w.notes,
    );
  }
}

/// `invoices.models.PAYMENT_METHODS`, value to label.
const Map<String, String> paymentMethods = {
  'CASH': 'Cash',
  'CHECK': 'Check',
  'CREDIT_CARD': 'Credit card',
  'BANK_TRANSFER': 'Bank transfer',
  'PAYPAL': 'PayPal',
  'STRIPE': 'Stripe',
  'OTHER': 'Other',
};

/// The list header figures.
///
/// The API computes these over everything the caller can see, NOT over the
/// active filter and not over the loaded page. Labelling them as describing
/// the filtered list would be false, which is why the screen does not.
///
/// Every invoice carries its own currency and there are no exchange rates, so
/// the server never adds two currencies together: the amounts arrive as a
/// `by_currency` list and are kept here as one [InvoiceMoneyTotals] per
/// currency code. The counts have no currency and stay single figures.
class InvoiceTotals {
  const InvoiceTotals({
    this.count = 0,
    this.money = const {},
    this.actionNeeded = 0,
  });

  final int count;

  /// The amounts, keyed by currency code. Empty when nothing is visible. A
  /// server older than the per-currency totals sends only the plain figures,
  /// which are kept under an empty code.
  final Map<String, InvoiceMoneyTotals> money;

  /// A count, not an amount: drafts to send plus anything overdue to chase.
  final int actionNeeded;

  /// Reads the list page's `InvoiceTotals` block.
  factory InvoiceTotals.fromJson(Map<String, dynamic> json) {
    final w = api.InvoiceTotals.fromJson(json);
    final rows = w.byCurrency;
    return InvoiceTotals(
      count: w.count ?? 0,
      money: rows != null
          ? {
              for (final row in rows)
                ?row.currency: InvoiceMoneyTotals.fromJson(row.json),
            }
          : {'': InvoiceMoneyTotals.fromJson(json)},
      actionNeeded: w.actionNeeded ?? 0,
    );
  }
}

/// The list header's amounts in one currency.
class InvoiceMoneyTotals {
  const InvoiceMoneyTotals({
    this.outstanding = 0,
    this.overdue = 0,
    this.dueThisMonth = 0,
    this.paidThisQuarter = 0,
    this.draft = 0,
  });

  final double outstanding;
  final double overdue;
  final double dueThisMonth;
  final double paidThisQuarter;
  final double draft;

  /// Reads an `InvoiceTotalsCurrency` row. An older server's plain figures
  /// carry the same five keys on the `InvoiceTotals` block itself.
  factory InvoiceMoneyTotals.fromJson(Map<String, dynamic> json) {
    final w = api.InvoiceTotalsCurrency.fromJson(json);
    return InvoiceMoneyTotals(
      outstanding: _amount(w.outstanding),
      overdue: _amount(w.overdue),
      dueThisMonth: _amount(w.dueThisMonth),
      paidThisQuarter: _amount(w.paidThisQuarter),
      draft: _amount(w.draft),
    );
  }
}

String? _personName(api.ContactPicker contact) {
  final parts = [
    contact.firstName,
    contact.lastName,
  ].map((p) => p?.trim() ?? '').where((p) => p.isNotEmpty);
  final name = parts.join(' ');
  return name.isEmpty ? null : name;
}

/// Amounts cross the wire as decimal strings ("1250.00").
double _amount(String? value) => double.tryParse(value ?? '') ?? 0;

/// A YYYY-MM-DD date as a local calendar date.
///
/// Parsed with an explicit midnight so the value is local rather than UTC.
/// Reading a UTC midnight anywhere behind Greenwich lands on the day before,
/// which would report an invoice due today as a day overdue.
DateTime? _date(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty || text == 'null') return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    return DateTime.tryParse('${text}T00:00:00');
  }
  return DateTime.tryParse(text)?.toLocal();
}

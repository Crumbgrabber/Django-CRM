import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/theme.dart';

/// The server's bounds on a discount, in its wording (`LineAmountsMixin` for a
/// line, `validate_document_discount` for a document): a percentage not over
/// 100, and a flat amount not over what it comes off. Null when the API would
/// take it. The inputs here accept digits only and a deal line's discount is
/// checked when the deal is saved, so the server's "cannot be negative" case
/// never reaches this. A hint only: the API still refuses the rest.
String? discountBoundError(
  String type,
  double value,
  double cap,
  String capMessage,
) {
  if (type == 'PERCENTAGE') {
    return value > 100 ? 'A percentage discount cannot exceed 100.' : null;
  }
  // Compared in cents, as the server stores money, so a float sum does not
  // refuse a discount that exactly matches it.
  return value > (cap * 100).roundToDouble() / 100 ? capMessage : null;
}

/// [value] in hundredths: an amount in cents, or a quantity or percent the
/// API stores to two places. Exact for any value the forms let through.
int hundredths(double value) => (value * 100).round();

/// [numerator] / [denominator] (positive) rounded half up, away from zero, as
/// the server's `ROUND_HALF_UP`. Integer arithmetic, so a float that sits
/// just under a half (1.15 x 10% is 0.11499...) cannot round it down.
int divideHalfUp(int numerator, int denominator) {
  final magnitude = (numerator.abs() * 2 + denominator) ~/ (denominator * 2);
  return numerator < 0 ? -magnitude : magnitude;
}

/// A document's own discount, tax and shipping, as the web builders' adjustments
/// card sets them. The server recomputes every figure on save; [total] is the
/// same ladder in the same order (discount off the subtotal, tax on what is
/// left, shipping added untaxed), shown as a guide. Every step is in cents,
/// rounded half up as the server rounds it.
class DocumentAdjustments {
  const DocumentAdjustments({
    this.discountType = '',
    this.discountValue = 0,
    this.taxRate = 0,
    this.shipping = 0,
  });

  /// '' for none, `PERCENTAGE` or `FIXED`: `invoices.models.DISCOUNT_TYPES`.
  final String discountType;
  final double discountValue;
  final double taxRate;

  /// Invoices only. An estimate or a schedule has no shipping.
  final double shipping;

  /// Capped at the subtotal, as the server caps it.
  int _discountCents(int subtotal) {
    final discount = switch (discountType) {
      'PERCENTAGE' => divideHalfUp(subtotal * hundredths(discountValue), 10000),
      'FIXED' => hundredths(discountValue),
      _ => 0,
    };
    return discount < subtotal ? discount : subtotal;
  }

  int _pretaxCents(int subtotal) => subtotal - _discountCents(subtotal);

  int _taxCents(int taxable) =>
      divideHalfUp(taxable * hundredths(taxRate), 10000);

  double total(double subtotal) {
    final pretax = _pretaxCents(hundredths(subtotal));
    return (pretax + _taxCents(pretax) + hundredths(shipping)) / 100;
  }

  /// What the deposit invoice for [percent] of an estimate would total, as
  /// `estimate_deposit` bills it: that share of the pre-tax amount to the
  /// cent, then this tax rate on that part to the cent. Zero means the server
  /// drafts no deposit invoice.
  double depositAmount(double subtotal, double percent) {
    final pretax = _pretaxCents(hundredths(subtotal));
    final part = divideHalfUp(pretax * hundredths(percent), 10000);
    return (part + _taxCents(part)) / 100;
  }

  /// The API's refusal for this discount on [subtotal], or null.
  String? discountError(double subtotal) => discountType.isEmpty
      ? null
      : discountBoundError(
          discountType,
          discountValue,
          subtotal,
          'A discount cannot exceed the subtotal.',
        );

  /// The API's refusal for this tax rate, or null. The field takes digits
  /// only, so only the top of the 0 to 100 range can be crossed.
  String? get taxError => taxRate > 100 ? 'Tax rate cannot exceed 100.' : null;

  /// Whether the API would take these adjustments on [subtotal]. Shipping
  /// needs no check: its field cannot go negative.
  bool isValidFor(double subtotal) =>
      discountError(subtotal) == null && taxError == null;

  /// The web builders' payload shape: the discount only once a type is chosen,
  /// tax and shipping only when set.
  Map<String, dynamic> toPayload() => {
    if (discountType.isNotEmpty) ...{
      'discount_type': discountType,
      'discount_value': discountValue.toStringAsFixed(2),
    },
    if (taxRate != 0) 'tax_rate': taxRate.toStringAsFixed(2),
    if (shipping != 0) 'shipping_amount': shipping.toStringAsFixed(2),
  };
}

/// The adjustments card shared by the invoice, estimate and schedule forms:
/// discount type and amount, tax rate, and shipping where the document has it.
class AdjustmentsSection extends StatefulWidget {
  const AdjustmentsSection({
    super.key,
    required this.value,
    required this.subtotal,
    required this.symbol,
    required this.onChanged,
    this.showShipping = false,
  });

  final DocumentAdjustments value;
  final double subtotal;
  final String symbol;
  final bool showShipping;
  final ValueChanged<DocumentAdjustments> onChanged;

  @override
  State<AdjustmentsSection> createState() => _AdjustmentsSectionState();
}

class _AdjustmentsSectionState extends State<AdjustmentsSection> {
  late final _discount = TextEditingController(
    text: _text(widget.value.discountValue),
  );
  late final _tax = TextEditingController(text: _text(widget.value.taxRate));
  late final _shipping = TextEditingController(
    text: _text(widget.value.shipping),
  );

  static const _types = {
    '': 'No discount',
    'PERCENTAGE': 'Percentage',
    'FIXED': 'Fixed amount',
  };

  static final _decimal = [
    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
  ];

  static String _text(double value) => value == 0 ? '' : value.toString();

  @override
  void dispose() {
    _discount.dispose();
    _tax.dispose();
    _shipping.dispose();
    super.dispose();
  }

  double _read(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  void _emit({String? discountType}) {
    widget.onChanged(
      DocumentAdjustments(
        discountType: discountType ?? widget.value.discountType,
        discountValue: _read(_discount),
        taxRate: _read(_tax),
        shipping: widget.showShipping ? _read(_shipping) : 0,
      ),
    );
  }

  Widget _number(
    TextEditingController controller,
    String label, {
    String? prefix,
    String? suffix,
    String? error,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: _decimal,
      onChanged: (_) => _emit(),
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        suffixText: suffix,
        errorText: error,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.value.discountType;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: type,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Discount',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final entry in _types.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (value) => _emit(discountType: value ?? ''),
        ),
        if (type.isNotEmpty) ...[
          const SizedBox(height: 12),
          _number(
            _discount,
            type == 'PERCENTAGE' ? 'Percent off' : 'Amount off',
            prefix: type == 'FIXED' ? widget.symbol : null,
            suffix: type == 'PERCENTAGE' ? '%' : null,
            error: widget.value.discountError(widget.subtotal),
          ),
        ],
        const SizedBox(height: 12),
        _number(_tax, 'Tax rate', suffix: '%', error: widget.value.taxError),
        if (widget.showShipping) ...[
          const SizedBox(height: 12),
          _number(_shipping, 'Shipping', prefix: widget.symbol),
        ],
        const SizedBox(height: 8),
        Text(
          widget.showShipping
              ? 'Tax applies to the subtotal after the discount. Shipping is '
                    'added afterwards and is not taxed.'
              : 'Tax applies to the subtotal after the discount.',
          style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

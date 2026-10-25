import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';
import '../../data/models/deal.dart' show Currency;
import '../../data/models/project.dart';
import '../invoices/invoice_format.dart';

/// An amount as sent: two decimal places, as the web sends it.
String amountParam(double n) => n.toStringAsFixed(2);

/// A percent as sent: rounded to two places with trailing zeros dropped, as
/// the web's `Math.round(n * 100) / 100` writes it ("25", "33.33").
String percentParam(double n) {
  final rounded = (n * 100).round() / 100;
  return rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toString();
}

/// Drafts the invoice for exactly one of `amount` or `percent`, plus an
/// optional line description, and answers its id or the server's refusal.
typedef InvoiceAmountAction =
    Future<({String? id, String? error})> Function({
      String? amount,
      String? percent,
      String? description,
    });

/// Invoice an amount: a one-line Draft invoice for a fixed sum or a share of
/// a fixed-fee project's fee. Pops with the new invoice's id.
///
/// The checks mirror the API's (an amount above 0; a percent above 0, at most
/// 100, and only with a fee set). The server repeats them.
class InvoiceAmountSheet extends StatefulWidget {
  const InvoiceAmountSheet({
    super.key,
    required this.project,
    required this.onInvoice,
  });

  final Project project;
  final InvoiceAmountAction onInvoice;

  static Future<String?> show(
    BuildContext context, {
    required Project project,
    required InvoiceAmountAction onInvoice,
  }) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: InvoiceAmountSheet(project: project, onInvoice: onInvoice),
    ),
  );

  @override
  State<InvoiceAmountSheet> createState() => _InvoiceAmountSheetState();
}

class _InvoiceAmountSheetState extends State<InvoiceAmountSheet> {
  final _value = TextEditingController();
  final _description = TextEditingController();
  bool _byPercent = false;
  bool _saving = false;
  String? _error;

  Project get _p => widget.project;

  String get _symbol => Currency.symbolFor(_p.currency);

  bool get _hasFee => (_p.budgetAmountValue ?? 0) > 0;

  @override
  void dispose() {
    _value.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Why the typed value cannot be sent, or null when it can. Digits and a
  /// decimal point only: NaN, Infinity and exponents are refused here.
  String? get _problem {
    final text = _value.text.trim();
    if (text.isEmpty) return null;
    final n = parseDecimalText(text);
    if (n == null) return 'Enter a number.';
    if (n <= 0) return 'Enter more than 0.';
    if (_byPercent && n > 100) return 'A percent is at most 100.';
    return null;
  }

  bool get _ready =>
      !_saving && _value.text.trim().isNotEmpty && _problem == null;

  /// What the typed percent comes to, for the line under the field.
  String? get _percentOfFee {
    final n = parseDecimalText(_value.text);
    final fee = _p.budgetAmountValue;
    if (!_byPercent || n == null || fee == null || _problem != null) {
      return null;
    }
    return '${money(fee * n / 100, _symbol)} of the '
        '${money(fee, _symbol)} fee';
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final n = parseDecimalText(_value.text)!;
    final result = await widget.onInvoice(
      amount: _byPercent ? null : amountParam(n),
      percent: _byPercent ? percentParam(n) : null,
      description: _description.text,
    );
    if (!mounted) return;
    if (result.error != null || result.id == null) {
      setState(() {
        _saving = false;
        _error = result.error ?? 'Could not draft the invoice.';
      });
      return;
    }
    Navigator.pop(context, result.id);
  }

  @override
  Widget build(BuildContext context) {
    final fee = _p.budgetAmountValue;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.gray300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Invoice an amount', style: AppTypography.h3),
            const SizedBox(height: 4),
            Text(
              switch ((fee, _p.burn.invoicedAmount)) {
                (null, _) =>
                  'Drafts a one-line invoice for ${_p.account?.name ?? 'the client'}.',
                (final fee?, null) => 'Fee ${money(fee, _symbol)}.',
                (final fee?, final invoiced?) =>
                  'Fee ${money(fee, _symbol)}, invoiced so far '
                      '${money(invoiced, _symbol)}.',
              },
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              segments: [
                const ButtonSegment(value: false, label: Text('Amount')),
                ButtonSegment(
                  value: true,
                  enabled: _hasFee,
                  label: const Text('Percent of fee'),
                ),
              ],
              selected: {_byPercent},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _byPercent = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _byPercent ? 'Percent' : 'Amount',
                prefixText: _byPercent ? null : _symbol,
                suffixText: _byPercent ? '%' : null,
                errorText: _problem,
                helperText: _percentOfFee,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Line description (optional)',
                hintText: '${_p.name}, fixed fee',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: AppTypography.caption.copyWith(
                  color: AppColors.danger700,
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _ready ? _submit : null,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create draft invoice'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

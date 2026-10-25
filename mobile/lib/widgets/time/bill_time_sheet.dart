import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/theme.dart';
import '../../data/models/deal.dart' show Currency;
import '../../data/models/project.dart';
import '../../data/models/time_billing.dart';
import '../../data/models/time_entry.dart';
import '../../screens/invoices/invoice_format.dart';
import '../../services/org_date.dart';

/// The preview a project's sheet reads for a chosen up-to date.
typedef UnbilledLoader =
    Future<({ProjectUnbilled? unbilled, String? error})> Function(String upTo);

/// Drafts the invoice and answers its id, or the server's refusal.
typedef BillAction =
    Future<({String? invoiceId, String? error})> Function(
      BillGrouping grouping,
      String? upTo,
    );

/// Bill time: pick how lines group (and, on a project, the last day to
/// bill), see what will be billed, then draft the invoice. Pops with the new
/// invoice's id.
///
/// A project asks the server what is unbilled up to the date
/// ([loadPreview]); a ticket already holds its unbilled [entries].
class BillTimeSheet extends StatefulWidget {
  const BillTimeSheet({
    super.key,
    required this.onBill,
    this.loadPreview,
    this.entries,
    this.offerTaskGrouping = true,
    this.scrollController,
  }) : assert((loadPreview == null) != (entries == null));

  final BillAction onBill;
  final UnbilledLoader? loadPreview;
  final List<TimeEntry>? entries;
  final bool offerTaskGrouping;
  final ScrollController? scrollController;

  static Future<String?> show(
    BuildContext context, {
    required BillAction onBill,
    UnbilledLoader? loadPreview,
    List<TimeEntry>? entries,
    bool offerTaskGrouping = true,
  }) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, controller) => BillTimeSheet(
        onBill: onBill,
        loadPreview: loadPreview,
        entries: entries,
        offerTaskGrouping: offerTaskGrouping,
        scrollController: controller,
      ),
    ),
  );

  @override
  State<BillTimeSheet> createState() => _BillTimeSheetState();
}

class _BillTimeSheetState extends State<BillTimeSheet> {
  BillGrouping _grouping = BillGrouping.entry;
  DateTime _upTo = orgToday();
  ProjectUnbilled? _unbilled;
  bool _loading = false;
  bool _billing = false;
  String? _error;

  bool get _isProject => widget.loadPreview != null;

  late final UnbilledSummary? _summary = widget.entries == null
      ? null
      : UnbilledSummary.of(widget.entries!);

  String get _upToParam => DateFormat('yyyy-MM-dd').format(_upTo);

  @override
  void initState() {
    super.initState();
    if (_isProject) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await widget.loadPreview!(_upToParam);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _unbilled = result.unbilled;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _upTo,
      firstDate: DateTime(2000),
      lastDate: addDays(orgToday(), 1),
    );
    if (picked == null) return;
    setState(() => _upTo = picked);
    await _load();
  }

  /// Known to hold nothing. A project preview that failed to load is not:
  /// the invoice still takes every unbilled entry up to the date, as on the
  /// web.
  bool get _nothingToBill => _isProject
      ? _unbilled != null && _unbilled!.entryCount == 0
      : _summary!.entryCount == 0;

  bool get _ready =>
      !_billing &&
      !_loading &&
      !_nothingToBill &&
      !(_summary?.isMixedCurrency ?? false);

  Future<void> _bill() async {
    setState(() {
      _billing = true;
      _error = null;
    });
    final result = await widget.onBill(
      _grouping,
      _isProject ? _upToParam : null,
    );
    if (!mounted) return;
    if (result.error != null || result.invoiceId == null) {
      setState(() {
        _billing = false;
        _error = result.error ?? 'Could not draft the invoice.';
      });
      return;
    }
    Navigator.pop(context, result.invoiceId);
  }

  @override
  Widget build(BuildContext context) {
    final groupings = [
      for (final g in BillGrouping.values)
        if (g != BillGrouping.task || widget.offerTaskGrouping) g,
    ];
    return SafeArea(
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
          Text('Bill time', style: AppTypography.h3),
          const SizedBox(height: 4),
          Text(
            'Turns unbilled billable time into a draft invoice and marks the '
            'entries billed. Cancelling the invoice frees them again.',
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          if (_isProject) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: _billing ? null : _pickDate,
                child: Text(
                  'Bill up to ${DateFormat('d MMM yyyy').format(_upTo)}',
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _preview(),
          const SizedBox(height: 16),
          Text(
            'Group lines',
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          RadioGroup<BillGrouping>(
            groupValue: _grouping,
            onChanged: (g) {
              if (g != null && !_billing) setState(() => _grouping = g);
            },
            child: Column(
              children: [
                for (final g in groupings)
                  RadioListTile<BillGrouping>(
                    value: g,
                    contentPadding: EdgeInsets.zero,
                    title: Text(g.label),
                    subtitle: widget.entries == null
                        ? null
                        : Text(_lines(billLineCount(widget.entries!, g))),
                  ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppTypography.caption.copyWith(color: AppColors.danger700),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _ready ? _bill : null,
              child: _billing
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
    );
  }

  Widget _preview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.gray50,
        borderRadius: AppLayout.borderRadiusMd,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_previewText(), style: AppTypography.body),
          if (_unratedText() case final unrated?) ...[
            const SizedBox(height: 6),
            Text(
              unrated,
              style: AppTypography.caption.copyWith(
                color: AppColors.warning700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _unratedText() {
    if (_isProject && (_loading || _unbilled == null)) return null;
    final n = _isProject ? _unbilled!.unratedCount : _summary!.unratedCount;
    if (n <= 0) return null;
    return n == 1
        ? '1 entry has no rate and will be billed at 0.'
        : '$n of these entries have no rate and will be billed at 0.';
  }

  String _previewText() {
    if (_isProject) {
      if (_loading) return 'Counting unbilled time...';
      if (_unbilled == null) {
        return 'The preview could not be loaded. The invoice still takes '
            'every billable entry not yet billed up to this date.';
      }
      final u = _unbilled!;
      if (u.entryCount == 0) return 'Nothing unbilled up to this date.';
      return '${_entries(u.entryCount)}, ${hoursLabel(u.hours)}h, worth '
          '${money(u.value, Currency.symbolFor(u.currency ?? ''))}';
    }
    final s = _summary!;
    if (s.entryCount == 0) return 'Nothing unbilled.';
    if (s.isMixedCurrency) {
      return '${_entries(s.entryCount)} in ${s.currencies.join(' and ')}. '
          'One invoice takes one currency, so these cannot be billed together.';
    }
    return '${_entries(s.entryCount)}, ${hoursLabel(s.hours)}h, worth about '
        '${money(s.value, Currency.symbolFor(s.currency ?? ''))}';
  }

  static String _entries(int n) => n == 1 ? '1 entry' : '$n entries';

  static String _lines(int n) => n == 1 ? '1 line' : '$n lines';
}

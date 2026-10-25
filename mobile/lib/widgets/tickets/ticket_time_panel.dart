import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/theme.dart';
import '../../data/models/time_billing.dart';
import '../../data/models/time_entry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/invoices_provider.dart';
import '../../providers/org_modules_provider.dart';
import '../../providers/tickets_provider.dart';
import '../../routes/app_routes.dart';
import '../time/bill_time_sheet.dart';
import '../time/time_entry_parts.dart';

/// Time tracking panel: start/stop timer, manual entry, recent entries.
///
/// Self-contained, owns its own loading state and refreshes on demand. The
/// parent passes the ticket id and (optionally) the embedded `TimeSummary`
/// from the case envelope so the totals render before this widget's own
/// fetch resolves.
class TicketTimePanel extends ConsumerStatefulWidget {
  final String ticketId;
  final TimeSummary? initialSummary;

  /// Whether this person may log time or start a timer here: the ticket's
  /// write rule, which the detail payload reports as `comment_permission`.
  /// The API answers anyone else 403. Stopping your own running timer is not
  /// gated on it.
  final bool canLogTime;

  /// The ticket's account. Billing a ticket's time drafts the invoice for it,
  /// so without one there is nothing to bill to.
  final String? accountId;

  const TicketTimePanel({
    super.key,
    required this.ticketId,
    required this.canLogTime,
    this.initialSummary,
    this.accountId,
  });

  @override
  ConsumerState<TicketTimePanel> createState() => _TicketTimePanelState();
}

class _TicketTimePanelState extends ConsumerState<TicketTimePanel> {
  List<TimeEntry> _entries = const [];
  TimeSummary? _summary;
  bool _isBusy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _summary = widget.initialSummary;
    _load();
    // 30s ticker so the running-timer duration updates without rebuilding
    // the whole detail page.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _entries.any((e) => e.isRunning)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final notifier = ref.read(ticketsProvider.notifier);
    final results = await Future.wait([
      notifier.fetchTimeEntries(widget.ticketId),
      notifier.fetchTimeSummary(widget.ticketId),
    ]);
    if (!mounted) return;
    setState(() {
      _entries = results[0] as List<TimeEntry>;
      _summary = results[1] as TimeSummary? ?? _summary;
    });
  }

  TimeEntry? get _running =>
      _entries.where((e) => e.isRunning).cast<TimeEntry?>().firstOrNull;

  Future<void> _startTimer() async {
    setState(() => _isBusy = true);
    final res = await ref
        .read(ticketsProvider.notifier)
        .startTimer(widget.ticketId);
    if (!mounted) return;
    setState(() => _isBusy = false);
    if (res.success) {
      await _load();
      return;
    }
    // 409: a timer is already running, on a ticket or a project. The body
    // names it, so the snackbar offers a one-tap jump to stop it there.
    final running = runningTimerPath(res.data);
    if (res.statusCode == 409 && running != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            running.startsWith('/projects/')
                ? 'You already have a running timer on a project.'
                : 'You already have a running timer on another ticket.',
          ),
          backgroundColor: AppColors.danger600,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'View',
            textColor: Colors.white,
            onPressed: () => context.push(running),
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.message ?? 'Failed to start timer'),
        backgroundColor: AppColors.danger600,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _stopTimer(TimeEntry entry) async {
    setState(() => _isBusy = true);
    final res = await ref.read(ticketsProvider.notifier).stopTimer(entry.id);
    if (!mounted) return;
    setState(() => _isBusy = false);
    if (res.success) {
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.message ?? 'Failed to stop timer'),
          backgroundColor: AppColors.danger600,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _addManual() async {
    final result = await ManualEntrySheet.show(context);
    if (result == null || !mounted) return;
    setState(() => _isBusy = true);
    final res = await ref
        .read(ticketsProvider.notifier)
        .addManualTimeEntry(
          widget.ticketId,
          startedAt: result.startedAt,
          endedAt: result.endedAt,
          billable: result.billable,
          description: result.description,
        );
    if (!mounted) return;
    setState(() => _isBusy = false);
    if (res.success) {
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.message ?? 'Failed to add entry'),
          backgroundColor: AppColors.danger600,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Admins only, as the API: the ticket's unbilled billable entries, drafted
  /// onto one invoice for its account.
  Future<void> _billTime(List<TimeEntry> unbilled) async {
    final invoiceId = await BillTimeSheet.show(
      context,
      entries: unbilled,
      offerTaskGrouping: false,
      onBill: (grouping, _) => ref
          .read(invoicesProvider.notifier)
          .createFromTimeEntries(
            accountId: widget.accountId,
            entryIds: [for (final e in unbilled) e.id],
            groupBy: grouping.value,
          ),
    );
    if (invoiceId == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Draft invoice created'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await _load();
    if (mounted) context.push('${AppRoutes.invoices}/$invoiceId');
  }

  @override
  Widget build(BuildContext context) {
    final running = _running;
    final unbilled = unbilledEntries(_entries);
    final mayBill =
        ref.watch(isOrgAdminProvider) &&
        ref.watch(moduleOnProvider('invoices')) &&
        unbilled.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppLayout.borderRadiusLg,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.clock, size: 16, color: AppColors.gray600),
              const SizedBox(width: 8),
              Text(
                'TIME TRACKING',
                style: AppTypography.overline.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              if (widget.canLogTime)
                IconButton(
                  tooltip: 'Add manual entry',
                  icon: const Icon(LucideIcons.plus, size: 18),
                  onPressed: _isBusy ? null : _addManual,
                ),
            ],
          ),
          if (_summary != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _StatTile(
                  label: 'Total',
                  value: formatMinutes(_summary!.totalMinutes),
                ),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'Billable',
                  value: formatMinutes(_summary!.billableMinutes),
                  color: AppColors.success600,
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (running != null)
            RunningTimerCard(
              entry: running,
              isBusy: _isBusy,
              onStop: () => _stopTimer(running),
            )
          else if (widget.canLogTime)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _isBusy ? null : _startTimer,
                icon: const Icon(LucideIcons.play, size: 16),
                label: const Text('Start timer'),
              ),
            ),
          if (_entries.isNotEmpty) ...[
            const Divider(height: 24),
            ..._entries
                .where((e) => !e.isRunning)
                .take(5)
                .map((e) => TimeEntryRow(entry: e)),
            if (_entries.where((e) => !e.isRunning).length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '+ ${_entries.where((e) => !e.isRunning).length - 5} more',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
          ],
          if (mayBill) ...[
            const SizedBox(height: 12),
            if (widget.accountId == null)
              Text(
                'Link this ticket to an account to bill its time.',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: _isBusy ? null : () => _billTime(unbilled),
                  icon: const Icon(LucideIcons.receipt, size: 16),
                  label: Text(
                    'Bill time (${unbilled.length} '
                    '${unbilled.length == 1 ? 'entry' : 'entries'})',
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _StatTile({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.gray50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: AppTypography.h3.copyWith(
                color: color ?? AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

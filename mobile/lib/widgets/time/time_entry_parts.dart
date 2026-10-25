/// The pieces of a time panel shared by tickets and projects: the running
/// timer, one logged entry, and the sheet that logs a finished one.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/theme.dart';
import '../../data/models/time_entry.dart';

/// Where the timer a 409 names is running: its ticket or its project, from
/// `running_case_id` or `running_project_id`. Null when the body names
/// neither.
String? runningTimerPath(Map<String, dynamic>? body) {
  String? id(String key) {
    final v = body?[key]?.toString();
    return v == null || v.isEmpty ? null : v;
  }

  final ticket = id('running_case_id');
  if (ticket != null) return '/tickets/$ticket';
  final project = id('running_project_id');
  if (project != null) return '/projects/$project';
  return null;
}

/// Minutes as "1h 30m", "45m" or "2h".
String formatMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

class RunningTimerCard extends StatelessWidget {
  final TimeEntry entry;
  final bool isBusy;
  final VoidCallback onStop;

  /// What the timer runs on, under "Running" (a project's task, say).
  final String? caption;

  const RunningTimerCard({
    super.key,
    required this.entry,
    required this.isBusy,
    required this.onStop,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final d = entry.liveDuration;
    final running =
        '${d.inHours.toString().padLeft(2, '0')}:'
        '${(d.inMinutes % 60).toString().padLeft(2, '0')}:'
        '${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary200),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: AppColors.primary600,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Running',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.primary700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  running,
                  style: AppTypography.h3.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: AppColors.primary700,
                  ),
                ),
                if (caption != null)
                  Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.primary700,
                    ),
                  ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: isBusy ? null : onStop,
            icon: const Icon(LucideIcons.square, size: 14),
            label: const Text('Stop'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.danger600,
              side: BorderSide(color: AppColors.danger300),
              // Override the global theme's `minimumSize: Size.fromHeight(..)`
              // which is `Size(∞, X)`. Needed so this in-row button doesn't
              // try to layout at infinite width when there's no Expanded parent.
              minimumSize: const Size(0, 44),
            ),
          ),
        ],
      ),
    );
  }
}

/// One finished entry: what it was, who logged it, how long, and whether it
/// is on an invoice already.
class TimeEntryRow extends StatelessWidget {
  final TimeEntry entry;

  /// A second line under the person, such as the entry's task.
  final String? detail;

  const TimeEntryRow({super.key, required this.entry, this.detail});

  @override
  Widget build(BuildContext context) {
    final hasDescription = entry.description?.isNotEmpty == true;
    final secondary = [
      if (hasDescription && entry.profileName != null) entry.profileName!,
      ?detail,
      if (entry.isBilled)
        entry.invoiceNumber == null
            ? 'billed'
            : 'billed ${entry.invoiceNumber}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (entry.billable)
            Icon(LucideIcons.dollarSign, size: 14, color: AppColors.success600)
          else
            Icon(LucideIcons.minus, size: 14, color: AppColors.gray400),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasDescription
                      ? entry.description!
                      : (entry.profileName ?? 'Time entry'),
                  style: AppTypography.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (secondary.isNotEmpty)
                  Text(
                    secondary,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatMinutes(entry.durationMinutes ?? 0),
            style: AppTypography.label.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class ManualEntryResult {
  final DateTime startedAt;
  final DateTime endedAt;
  final bool billable;
  final String description;
  final String? taskId;
  const ManualEntryResult({
    required this.startedAt,
    required this.endedAt,
    required this.billable,
    required this.description,
    this.taskId,
  });
}

/// A task the entry may name, for the sheet's picker.
typedef TaskChoice = ({String id, String title});

/// Logs a finished entry. Open with [ManualEntrySheet.show].
class ManualEntrySheet extends StatefulWidget {
  /// Offered as an optional picker when not empty.
  final List<TaskChoice> tasks;
  final bool billableByDefault;

  /// False hides the Billable box and sends [billableByDefault].
  final bool offerBillable;

  const ManualEntrySheet({
    super.key,
    this.tasks = const [],
    this.billableByDefault = false,
    this.offerBillable = true,
  });

  static Future<ManualEntryResult?> show(
    BuildContext context, {
    List<TaskChoice> tasks = const [],
    bool billableByDefault = false,
    bool offerBillable = true,
  }) => showModalBottomSheet<ManualEntryResult>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ManualEntrySheet(
        tasks: tasks,
        billableByDefault: billableByDefault,
        offerBillable: offerBillable,
      ),
    ),
  );

  @override
  State<ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends State<ManualEntrySheet> {
  final _descController = TextEditingController();
  int _minutes = 30;
  late bool _billable = widget.billableByDefault;
  String? _taskId;

  @override
  void dispose() {
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
            Text('Add time entry', style: AppTypography.h3),
            const SizedBox(height: 16),
            Text(
              'Duration',
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [15, 30, 45, 60, 90, 120].map((m) {
                final sel = _minutes == m;
                return ChoiceChip(
                  label: Text(formatMinutes(m)),
                  selected: sel,
                  onSelected: (_) => setState(() => _minutes = m),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            // Required, not optional: `TimeEntryCreateSerializer` rejects a
            // blank description on a manual entry.
            TextField(
              controller: _descController,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'What did you work on?',
                filled: true,
                fillColor: AppColors.gray50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
            ),
            if (widget.tasks.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _taskId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Task (optional)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No task'),
                  ),
                  for (final t in widget.tasks)
                    DropdownMenuItem<String?>(
                      value: t.id,
                      child: Text(t.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _taskId = v),
              ),
            ],
            const SizedBox(height: 8),
            if (widget.offerBillable)
              CheckboxListTile(
                value: _billable,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Billable'),
                onChanged: (v) => setState(() => _billable = v ?? false),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    // Disabled until there is something to send, so the
                    // refusal happens under the empty field rather than as a
                    // snackbar after a round trip.
                    onPressed: _descController.text.trim().isEmpty
                        ? null
                        : () {
                            final end = DateTime.now();
                            final start = end.subtract(
                              Duration(minutes: _minutes),
                            );
                            Navigator.pop(
                              context,
                              ManualEntryResult(
                                startedAt: start,
                                endedAt: end,
                                billable: _billable,
                                description: _descController.text.trim(),
                                taskId: _taskId,
                              ),
                            );
                          },
                    child: const Text('Add entry'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
